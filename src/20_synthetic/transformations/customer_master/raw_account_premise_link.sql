-- Account ↔ Premise Link — the effective-dated bridge that says which account
-- was billing-responsible for a premise during which date range (the industry
-- model's customer.account_premise_link). This is how move-in / move-out and
-- tenant turnover are represented over time.
--   • Current tenancy: one open link per premise (link_end_date NULL,
--     is_current=true) from the current account. For ~15% of premises that had
--     a prior customer, link_start_date is the move-in date — pre-window for
--     most, but ~40% of that turnover population lands in-window, splitting
--     a fact across customers for those premises.
--   • Prior tenancy: a CLOSED link from the prior account, ending on the
--     current customer's move-in date (link_termination_reason='move_out').
-- Corporate-parent accounts (no premise) are intentionally absent.
-- All dates anchor to ${as_of_date}.
--
-- Relocations: for the ~5% of premises paired by
-- raw_premise_customer_map (mover_pair_premise_id IS NOT NULL), move_in_date is
-- overridden to the pair's shared relocation_date (in-window), and the
-- destination's account_id is overridden to the mover's own carried-over
-- account (md5(origin_premise_id||'_acct_prior')) instead of the destination's
-- default account — this is what makes "the account moves with the customer"
-- (one account, two sequential tenancies) instead of a new account per premise.
--
-- In-window turnover: for the remaining (non-mover)
-- ~15% turnover population, ~40% of those premises draw move_in_date from
-- inside the display window (same uniform-over-window formula as
-- relocation_date); the rest pre-date it. Unlike a relocation, the prior
-- and current customers here are genuinely different customers/accounts, so
-- this is what makes a premise's transition month split a bill across two
-- unrelated accounts — the "mess real utilities have day one."

CREATE OR REFRESH MATERIALIZED VIEW raw_account_premise_link (
  CONSTRAINT non_null_link_id    EXPECT (account_premise_link_id IS NOT NULL),
  CONSTRAINT non_null_account_id EXPECT (account_id IS NOT NULL),
  CONSTRAINT non_null_premise_id EXPECT (premise_id IS NOT NULL),
  CONSTRAINT valid_link_status   EXPECT (link_status IN ('active','ended')),
  CONSTRAINT link_end_after_start EXPECT (link_end_date IS NULL OR link_end_date > link_start_date)
)
COMMENT 'Account ↔ Premise effective-dated bridge — which account was billing-responsible for a premise during which date range. One open link per premise for the current customer; ~15% of premises also have a closed prior-customer link that ended on the current move-in date (in-window for ~40% of that turnover population, pre-window for the rest). billing_responsibility_flag marks the responsible party; tenancy_type is owner_occupied | tenant | commercial. PK: account_premise_link_id. FK: account_id -> customer_account.account_id, premise_id -> premises.premise_id.'
AS

WITH cur AS (
  SELECT
    m.premise_id,
    m.current_customer_id                                          AS customer_id,
    m.has_prior_customer,
    m.prior_customer_id,
    m.mover_pair_premise_id,
    m.mover_role,
    -- A relocation destination's account is the mover's own carried-over
    -- account (from the origin), not this premise's default account.
    CASE WHEN m.mover_role = 'destination'
         THEN md5(CONCAT(m.mover_pair_premise_id, '_acct_prior'))
         ELSE md5(CONCAT(m.premise_id, '_acct'))
    END                                                             AS account_id,
    c.customer_class,
    c.tenure,
    ca.account_opened_date,
    ca.current_status,
    -- A relocation's move-in date is the pair's shared, in-window
    -- relocation_date (both origin and destination rows carry it), not an
    -- independently-drawn pre-window date. Otherwise, for ~40% of the general
    -- turnover population, draw an in-window move-in date (same uniform
    -- window-start..as_of_date formula relocation_date uses); the rest keep
    -- the pre-window behavior.
    CASE
      WHEN m.mover_pair_premise_id IS NOT NULL
        THEN m.relocation_date
      WHEN m.has_prior_customer
           AND abs(xxhash64(m.premise_id, 'inwindow_turnover', ${random_seed})) % 100 < 40
        THEN DATE_ADD(
               DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
               CAST(abs(xxhash64(m.premise_id, 'inwindow_movein', ${random_seed}))
                    % DATEDIFF(
                        DATE'${as_of_date}',
                        DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
                      ) AS INT)
             )
      ELSE DATE_SUB(DATE'2017-01-01',
             CAST(abs(xxhash64(m.premise_id, 'movein', ${random_seed})) % 365 AS INT))
    END                                                             AS move_in_date
  FROM raw_premise_customer_map m
  JOIN raw_customer c          ON m.current_customer_id = c.customer_id
  JOIN raw_customer_account ca
    ON ca.account_id = CASE WHEN m.mover_role = 'destination'
                             THEN md5(CONCAT(m.mover_pair_premise_id, '_acct_prior'))
                             ELSE md5(CONCAT(m.premise_id, '_acct'))
                        END
),

cur_enriched AS (
  -- Materialize link_start_date once so the closed-link move-out below can
  -- clamp against it (a sibling SELECT alias can't be referenced in-place).
  SELECT *,
    CASE WHEN has_prior_customer THEN move_in_date ELSE account_opened_date END AS link_start_date
  FROM cur
),

current_links AS (
  SELECT
    md5(CONCAT(account_id, '_', premise_id, '_link'))              AS account_premise_link_id,
    account_id,
    premise_id,
    customer_id,
    link_start_date,
    -- Closed links end on a recent move-out (within ~180d of as_of). Clamp it
    -- so an in-window move-in drawn LATER than the independent move-out draw
    -- can't invert the interval (link_end < link_start): floor at
    -- link_start_date + 15d (a minimum tenancy) and cap at as_of. Without the
    -- clamp, ~15 residential turnover accounts got link_end < link_start, which
    -- emptied their 5-way hierarchy_version intersection and stranded the
    -- customer's outage/timeline views (they had no HV row at all). The floor
    -- keeps the common case (link_start far in the past) byte-identical.
    CASE WHEN current_status = 'closed'
         THEN LEAST(
                DATE'${as_of_date}',
                GREATEST(
                  DATE_SUB(DATE'${as_of_date}', CAST(abs(xxhash64(premise_id, 'moveout', ${random_seed})) % 180 AS INT)),
                  DATE_ADD(link_start_date, 15)
                ))
         ELSE CAST(NULL AS DATE) END                               AS link_end_date,
    CASE WHEN current_status = 'closed' THEN false ELSE true END   AS is_current,
    CASE WHEN current_status = 'closed' THEN 'ended' ELSE 'active' END AS link_status,
    CASE WHEN current_status = 'closed' THEN false ELSE true END   AS billing_responsibility_flag,
    CASE
      WHEN customer_class = 'Commercial' THEN 'commercial'
      WHEN tenure = 'own'                THEN 'owner_occupied'
      ELSE                                    'tenant'
    END                                                            AS tenancy_type,
    CASE WHEN current_status = 'closed' THEN 'move_out' ELSE CAST(NULL AS STRING) END AS link_termination_reason
  FROM cur_enriched
),

prior_links AS (
  SELECT
    md5(CONCAT(md5(CONCAT(premise_id, '_acct_prior')), '_', premise_id, '_link')) AS account_premise_link_id,
    md5(CONCAT(premise_id, '_acct_prior'))                         AS account_id,
    premise_id,
    prior_customer_id                                             AS customer_id,
    DATE_SUB(move_in_date, CAST(365 + abs(xxhash64(premise_id, 'prior_tenure', ${random_seed})) % (365 * 7) AS INT)) AS link_start_date,
    move_in_date                                                  AS link_end_date,
    false                                                         AS is_current,
    'ended'                                                       AS link_status,
    false                                                         AS billing_responsibility_flag,
    'tenant'                                                      AS tenancy_type,
    'move_out'                                                    AS link_termination_reason
  FROM cur
  WHERE has_prior_customer
),

-- Landlord-vacancy link — closed, ending exactly
-- when the current tenant's own link starts, so the timeline reads "landlord
-- billed directly until this tenant moved in." tenancy_type='vacant' is a
-- new value (no CHECK constraint enforces the enum here, so this is additive).
-- Matches landlord_vacancy_accounts in raw_customer_account.sql by account_id
-- so raw_service_agreement's existing (unmodified) join picks it up for free.
landlord_vacancy_links AS (
  SELECT
    md5(CONCAT(md5(CONCAT(cur.premise_id, '_acct_landlord_vacancy')), '_', cur.premise_id, '_link')) AS account_premise_link_id,
    md5(CONCAT(cur.premise_id, '_acct_landlord_vacancy'))          AS account_id,
    cur.premise_id                                                 AS premise_id,
    lp.owner_customer_id                                           AS customer_id,
    DATE_SUB(
      CASE WHEN has_prior_customer THEN move_in_date ELSE account_opened_date END,
      200
    )                                                               AS link_start_date,
    CASE WHEN has_prior_customer THEN move_in_date ELSE account_opened_date END AS link_end_date,
    false                                                           AS is_current,
    'ended'                                                        AS link_status,
    true                                                            AS billing_responsibility_flag,
    'vacant'                                                       AS tenancy_type,
    'tenant_turnover'                                              AS link_termination_reason
  FROM cur
  JOIN raw_landlord_portfolio lp ON lp.premise_id = cur.premise_id AND lp.is_vacancy_showcase
)

SELECT account_premise_link_id, account_id, premise_id, customer_id,
       link_start_date, link_end_date, is_current, link_status,
       billing_responsibility_flag, tenancy_type, link_termination_reason,
       current_timestamp() AS _ingested_at
FROM current_links
UNION ALL
SELECT account_premise_link_id, account_id, premise_id, customer_id,
       link_start_date, link_end_date, is_current, link_status,
       billing_responsibility_flag, tenancy_type, link_termination_reason,
       current_timestamp() AS _ingested_at
FROM prior_links
UNION ALL
SELECT account_premise_link_id, account_id, premise_id, customer_id,
       link_start_date, link_end_date, is_current, link_status,
       billing_responsibility_flag, tenancy_type, link_termination_reason,
       current_timestamp() AS _ingested_at
FROM landlord_vacancy_links;
