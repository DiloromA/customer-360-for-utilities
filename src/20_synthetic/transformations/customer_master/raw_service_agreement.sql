-- Service Agreement — CIM ServiceAgreement / the industry model's
-- customer.customer_service_agreement: the contract binding an account to a
-- usage_point under a rate schedule for a date range. Effective-dated,
-- WITH rate-switch history:
--   • Every account-on-premise has a CURRENT agreement (open if the account is
--     live; terminated on the account_premise_link end date for closed/prior
--     accounts).
--   • RATE SWITCHERS — accounts now on res_d8_ev (EV time-of-use) or ~half of
--     res_d3 (low-income) — switched INTO that rate from res_d1 mid-window. They
--     get a SECOND, earlier, terminated agreement on res_d1 (effective from the
--     occupancy start to the switch date), so the account↔rate relationship is
--     captured over time.
-- Corporate-parent accounts (no premise/usage_point) have no agreement.
-- effective_date comes from account_premise_link.link_start_date; all dates
-- anchor to ${as_of_date}.
--
-- Joins to account_premise_link by account_id ONLY (not account_id+premise_id)
-- so it fans out one row per TENANCY, not per account (temporal-realism §5.1):
-- a relocated account has two account_premise_link rows (origin, closed;
-- destination, open) and must produce two service agreements — one per
-- premise/usage_point it was ever tied to. For the ~99%+ of accounts with
-- exactly one tenancy this is a no-op (still exactly one agreement).
--
-- The join to raw_usage_point (via service_location) also already fans out
-- per CONCURRENT usage_point, not just per tenancy: a large commercial
-- premise's 2-5 sub-metered usage_points (temporal-realism §5.3) each get
-- their own agreement under the same account.

CREATE OR REFRESH MATERIALIZED VIEW raw_service_agreement (
  CONSTRAINT non_null_service_agreement_id EXPECT (service_agreement_id IS NOT NULL),
  CONSTRAINT non_null_account_id           EXPECT (account_id IS NOT NULL),
  CONSTRAINT non_null_usage_point_id       EXPECT (usage_point_id IS NOT NULL),
  CONSTRAINT valid_status                  EXPECT (status IN ('active','terminated','suspended')),
  CONSTRAINT term_after_effective          EXPECT (termination_date IS NULL OR termination_date >= effective_date)
)
COMMENT 'Service Agreement — CIM ServiceAgreement linking an account to a usage_point under a rate schedule for a date range (effective-dated). Accounts now on res_d8_ev or ~half of res_d3 carry a prior terminated agreement on res_d1 (rate switch). is_current marks the live agreement; agreement_seq orders an account''s agreements over time. rate_schedule is denormalized so AMI -> agreement -> rate joins do not need customer_account. PK: service_agreement_id. FK: account_id -> customer_account.account_id, usage_point_id -> usage_point.usage_point_id.'
AS

WITH base AS (
  SELECT
    ca.account_id,
    ca.customer_id,
    apl.premise_id,
    ca.customer_class,
    ca.rate_schedule                                              AS current_rate,
    ca.current_status,
    up.usage_point_id,
    apl.link_start_date,
    apl.link_end_date,
    DATE_ADD(DATE'2017-06-01',
             CAST(abs(xxhash64(ca.account_id, 'switch_date', ${random_seed})) % 395 AS INT)) AS switch_date,
    (ca.customer_class = 'Residential'
       AND ca.current_status <> 'closed'
       AND (ca.rate_schedule = 'res_d8_ev'
            OR (ca.rate_schedule = 'res_d3'
                AND abs(xxhash64(ca.account_id, 'switch', ${random_seed})) % 100 < 50))) AS is_switch_candidate
  FROM raw_customer_account ca
  JOIN raw_account_premise_link apl ON apl.account_id = ca.account_id
  JOIN raw_service_location sl      ON sl.premise_id = apl.premise_id
  JOIN raw_usage_point      up      ON sl.service_location_id = up.service_location_id
  WHERE ca.account_group <> 'corporate_parent'
),

flagged AS (
  SELECT *,
    (is_switch_candidate AND link_start_date < switch_date) AS is_switcher
  FROM base
),

current_agr AS (
  SELECT
    md5(CONCAT(account_id, '_', usage_point_id, '_agr_cur'))       AS service_agreement_id,
    account_id, usage_point_id, premise_id, customer_id,
    current_rate                                                  AS rate_schedule,
    CASE WHEN is_switcher THEN switch_date ELSE link_start_date END AS effective_date,
    link_end_date                                                 AS termination_date,
    CASE
      WHEN link_end_date IS NOT NULL    THEN 'terminated'
      WHEN current_status = 'suspended' THEN 'suspended'
      ELSE                                   'active'
    END                                                           AS status,
    (link_end_date IS NULL AND current_status <> 'closed')        AS is_current,
    CASE WHEN is_switcher THEN 2 ELSE 1 END                       AS agreement_seq,
    CASE WHEN link_end_date IS NOT NULL THEN 'account_closed' ELSE CAST(NULL AS STRING) END AS termination_reason
  FROM flagged
),

prior_rate_agr AS (
  SELECT
    md5(CONCAT(account_id, '_', usage_point_id, '_agr_prev'))      AS service_agreement_id,
    account_id, usage_point_id, premise_id, customer_id,
    'res_d1'                                                      AS rate_schedule,
    link_start_date                                               AS effective_date,
    switch_date                                                   AS termination_date,
    'terminated'                                                  AS status,
    false                                                         AS is_current,
    1                                                             AS agreement_seq,
    'rate_change'                                                 AS termination_reason
  FROM flagged
  WHERE is_switcher
)

SELECT service_agreement_id, account_id, usage_point_id, premise_id, customer_id,
       rate_schedule, effective_date, termination_date, status, is_current,
       agreement_seq, termination_reason, current_timestamp() AS _ingested_at
FROM current_agr
UNION ALL
SELECT service_agreement_id, account_id, usage_point_id, premise_id, customer_id,
       rate_schedule, effective_date, termination_date, status, is_current,
       agreement_seq, termination_reason, current_timestamp() AS _ingested_at
FROM prior_rate_agr;
