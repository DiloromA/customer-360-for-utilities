-- Customer Account — CIM CustomerAccount. Decoupled: an account is
-- the billing relationship for ONE premise, held by a customer.
-- customer→account is genuinely 1:many:
--   • Residential / standalone-commercial: one account per premise, held by the
--     per-premise customer (account_group='standard').
--   • Commercial chain: one account per site, all held by the chain customer and
--     grouped under a CORPORATE_PARENT account via parent_account_id
--     (account_group='consolidated_billing'). The parent is its own row
--     (account_group='corporate_parent', premise_id NULL — consolidated bill).
--   • Prior occupant (residential turnover): one CLOSED account per turnover
--     premise, held by the prior-occupant customer (ended pre-window for most,
--     in-window for relocations and ~40% of ordinary turnover — temporal-realism §5.2).
--
-- account_id is per-premise (md5(premise_id+'_acct')) for the live account, so a
-- chain customer cleanly holds N distinct accounts. Attributes (rate, autopay,
-- paperless) are biased by the holding customer's archetype. Commercial rate
-- tier depends on the PREMISE sqft. All dates anchor to ${as_of_date}.

CREATE OR REFRESH MATERIALIZED VIEW raw_customer_account (
  CONSTRAINT non_null_account_id  EXPECT (account_id IS NOT NULL),
  CONSTRAINT non_null_customer_id EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_account_group EXPECT (
    account_group IN ('standard','consolidated_billing','corporate_parent')
  ),
  CONSTRAINT valid_status EXPECT (current_status IN ('active','suspended','closed'))
)
COMMENT 'Customer Account — CIM CustomerAccount, one billing account per premise (customer→account is 1:many). Commercial-chain accounts are grouped under a corporate_parent account via parent_account_id (consolidated billing). Prior-occupant turnover premises carry a closed account that ended before or within the fact window. Rate schedule follows the utility''s rate schedule (D1 standard residential, D1.2 critical care, D3 low-income, D8 EV TOU, D3/D4/D6 commercial by size). PK: account_id. FK: customer_id -> customer.customer_id, premise_id -> premises.premise_id, parent_account_id -> customer_account.account_id.'
AS

-- ── Per-premise account context (current occupant) ──────────────────────────
WITH ctx AS (
  SELECT
    m.premise_id,
    m.current_customer_id                                          AS customer_id,
    m.chain_key,
    m.mover_role,
    c.customer_class,
    c.archetype,
    c.income_band,
    c.critical_care_flag,
    p.sqft,
    abs(xxhash64(m.premise_id, 'autopay',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_autopay,
    abs(xxhash64(m.premise_id, 'paperless', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_paperless,
    abs(xxhash64(m.premise_id, 'marketing', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_mktg,
    abs(xxhash64(m.premise_id, 'channel',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_chan,
    abs(xxhash64(m.premise_id, 'rate',      ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_rate,
    abs(xxhash64(m.premise_id, 'opened',    ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_open,
    abs(xxhash64(m.premise_id, 'status',    ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_status
  FROM raw_premise_customer_map m
  JOIN raw_customer c ON m.current_customer_id = c.customer_id
  JOIN raw_premises p ON m.premise_id = p.premise_id
),

current_accounts AS (
  -- A relocation destination's "current account" is the mover's own
  -- carried-over account (supplied by prior_accounts below with premise_id
  -- overridden to here), NOT a fresh default account for this premise —
  -- otherwise the destination premise would spawn a second, orphaned account
  -- with no account_premise_link row at all (temporal-realism §5.1).
  SELECT
    md5(CONCAT(premise_id, '_acct'))                               AS account_id,
    customer_id,
    premise_id,
    CASE WHEN chain_key IS NOT NULL THEN md5(CONCAT(chain_key, '_parent')) ELSE CAST(NULL AS STRING) END AS parent_account_id,
    CASE WHEN chain_key IS NOT NULL THEN 'consolidated_billing' ELSE 'standard' END AS account_group,
    customer_class,
    CASE
      WHEN customer_class = 'Residential' AND critical_care_flag                          THEN 'res_d1_2'
      WHEN customer_class = 'Residential' AND archetype = 'tech_forward' AND r_rate < 0.65 THEN 'res_d8_ev'
      WHEN customer_class = 'Residential' AND income_band = 'under_25k' AND r_rate < 0.40   THEN 'res_d3'
      WHEN customer_class = 'Residential'                                                  THEN 'res_d1'
      WHEN customer_class = 'Commercial'  AND sqft >= 30000                                THEN 'com_d6'
      WHEN customer_class = 'Commercial'  AND sqft >= 8000                                 THEN 'com_d4'
      ELSE                                                                                      'com_d3'
    END                                                            AS rate_schedule,
    CASE
      WHEN archetype = 'efficient_engaged'       THEN r_autopay < 0.72
      WHEN archetype = 'tech_forward'            THEN r_autopay < 0.80
      WHEN archetype = 'comfortable_indifferent' THEN r_autopay < 0.45
      WHEN archetype = 'inefficient_unaware'     THEN r_autopay < 0.32
      WHEN archetype = 'senior_fixed_income'     THEN r_autopay < 0.55
      WHEN archetype = 'cost_stressed'           THEN r_autopay < 0.18
      ELSE                                             r_autopay < 0.35
    END                                                            AS autopay_enrolled,
    CASE
      WHEN archetype = 'tech_forward'            THEN r_paperless < 0.92
      WHEN archetype = 'efficient_engaged'       THEN r_paperless < 0.80
      WHEN archetype = 'comfortable_indifferent' THEN r_paperless < 0.55
      WHEN archetype = 'inefficient_unaware'     THEN r_paperless < 0.42
      WHEN archetype = 'cost_stressed'           THEN r_paperless < 0.38
      WHEN archetype = 'senior_fixed_income'     THEN r_paperless < 0.10
      ELSE                                             r_paperless < 0.50
    END                                                            AS paperless_enrolled,
    r_mktg < 0.65                                                  AS marketing_consent,
    CASE
      WHEN archetype IN ('tech_forward','efficient_engaged') THEN
        CASE WHEN r_chan < 0.80 THEN 'email' WHEN r_chan < 0.95 THEN 'sms' ELSE 'mail' END
      WHEN archetype = 'senior_fixed_income' THEN
        CASE WHEN r_chan < 0.20 THEN 'email' WHEN r_chan < 0.25 THEN 'sms' ELSE 'mail' END
      ELSE
        CASE WHEN r_chan < 0.50 THEN 'email' WHEN r_chan < 0.75 THEN 'sms' ELSE 'mail' END
    END                                                            AS preferred_channel,
    -- Opened 1-20 yrs before as_of (the demo's now).
    DATE_SUB(DATE'${as_of_date}', CAST(365 + r_open * 365 * 19 AS INT)) AS account_opened_date,
    CASE
      WHEN r_status < 0.985 THEN 'active'
      WHEN r_status < 0.995 THEN 'suspended'
      ELSE                       'closed'
    END                                                            AS current_status
  FROM ctx
  WHERE mover_role IS NULL OR mover_role <> 'destination'
),

-- ── Corporate-parent accounts (one per chain, consolidated bill) ────────────
-- Derived from the child accounts: parent_account_id (= md5(chain_key+_parent))
-- and customer_id (the chain customer) are already on current_accounts.
parent_accounts AS (
  SELECT
    parent_account_id                                             AS account_id,
    customer_id,
    CAST(NULL AS STRING)                                           AS premise_id,
    CAST(NULL AS STRING)                                           AS parent_account_id,
    'corporate_parent'                                             AS account_group,
    'Commercial'                                                   AS customer_class,
    CAST(NULL AS STRING)                                           AS rate_schedule,
    true                                                           AS autopay_enrolled,
    true                                                           AS paperless_enrolled,
    true                                                           AS marketing_consent,
    'email'                                                        AS preferred_channel,
    MIN(account_opened_date)                                       AS account_opened_date,
    'active'                                                       AS current_status
  FROM current_accounts
  WHERE parent_account_id IS NOT NULL
  GROUP BY parent_account_id, customer_id
),

-- ── Prior-occupant accounts (closed before the fact window — or, for a
-- relocation origin, the mover's account, still active at the paired
-- destination premise: temporal-realism §5.1, "the account moves with the
-- customer") ──────────────────────────────────────────────────────────────
prior_accounts AS (
  SELECT
    md5(CONCAT(m.premise_id, '_acct_prior'))                       AS account_id,
    m.prior_customer_id                                            AS customer_id,
    CASE WHEN m.mover_role = 'origin' THEN m.mover_pair_premise_id
         ELSE m.premise_id
    END                                                            AS premise_id,
    CAST(NULL AS STRING)                                           AS parent_account_id,
    'standard'                                                     AS account_group,
    c.customer_class,
    CASE
      WHEN c.critical_care_flag THEN 'res_d1_2'
      WHEN c.income_band = 'under_25k' THEN 'res_d3'
      ELSE 'res_d1'
    END                                                            AS rate_schedule,
    false                                                          AS autopay_enrolled,
    false                                                          AS paperless_enrolled,
    false                                                          AS marketing_consent,
    'mail'                                                         AS preferred_channel,
    c.customer_since_date                                          AS account_opened_date,
    CASE WHEN m.mover_role = 'origin' THEN 'active'
         ELSE 'closed'
    END                                                            AS current_status
  FROM raw_premise_customer_map m
  JOIN raw_customer c ON m.prior_customer_id = c.customer_id
  WHERE m.has_prior_occupant
),

-- Landlord-vacancy account (entity-grain-design.md §5) — one CLOSED
-- historical account showing the landlord itself billing-responsible for
-- its vacancy-showcase premise, before the current tenant moved in. Purely
-- additive: the current tenant's own account (current_accounts) is untouched.
landlord_vacancy_accounts AS (
  SELECT
    md5(CONCAT(ctx.premise_id, '_acct_landlord_vacancy'))          AS account_id,
    lp.owner_customer_id                                           AS customer_id,
    ctx.premise_id,
    CAST(NULL AS STRING)                                           AS parent_account_id,
    'standard'                                                     AS account_group,
    ctx.customer_class,
    'res_d1'                                                       AS rate_schedule,
    false                                                          AS autopay_enrolled,
    false                                                          AS paperless_enrolled,
    false                                                          AS marketing_consent,
    'mail'                                                         AS preferred_channel,
    DATE_SUB(DATE'2016-01-01',
             CAST(abs(xxhash64(ctx.premise_id, 'landlord_vacancy_start', ${random_seed})) % 365 AS INT)) AS account_opened_date,
    'closed'                                                       AS current_status
  FROM ctx
  JOIN raw_landlord_portfolio lp ON lp.premise_id = ctx.premise_id AND lp.is_vacancy_showcase
)

SELECT account_id, customer_id, premise_id, parent_account_id, account_group,
       customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
       marketing_consent, preferred_channel, account_opened_date, current_status,
       current_timestamp() AS _ingested_at
FROM current_accounts
UNION ALL
SELECT account_id, customer_id, premise_id, parent_account_id, account_group,
       customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
       marketing_consent, preferred_channel, account_opened_date, current_status,
       current_timestamp() AS _ingested_at
FROM parent_accounts
UNION ALL
SELECT account_id, customer_id, premise_id, parent_account_id, account_group,
       customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
       marketing_consent, preferred_channel, account_opened_date, current_status,
       current_timestamp() AS _ingested_at
FROM prior_accounts
UNION ALL
SELECT account_id, customer_id, premise_id, parent_account_id, account_group,
       customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
       marketing_consent, preferred_channel, account_opened_date, current_status,
       current_timestamp() AS _ingested_at
FROM landlord_vacancy_accounts;
