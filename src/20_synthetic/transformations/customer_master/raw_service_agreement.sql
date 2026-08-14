-- Service Agreement — CIM ServiceAgreement / the industry model's
-- customer.customer_service_agreement: the contract binding an account to a
-- service point under a rate schedule for a date range. Effective-dated,
-- WITH rate-switch history AND an account-reassignment episode:
--   • Every account-on-premise has a CURRENT agreement (open if the account is
--     live; terminated on the account_premise_link end date for closed/prior
--     accounts).
--   • RATE SWITCHERS — accounts now on res_d8_ev (EV time-of-use) or ~half of
--     res_d3 (low-income) — switched INTO that rate from res_d1 mid-window. They
--     get a SECOND, earlier, terminated agreement on res_d1 (effective from the
--     tenancy start to the switch date), so the account↔rate relationship is
--     captured over time.
--   • ACCOUNT REASSIGNMENT — one account (from raw_account_reassignment) has its
--     single current agreement split at transfer_date into a pre-transfer row
--     (from_customer, terminated at transfer_date) and a post-transfer row
--     (to_customer, starting at transfer_date). This is what causes
--     customer_changed_mid_month=true in the monthly AMI fact for the month
--     the transfer falls in.
-- Corporate-parent accounts (no premise/service point) have no agreement.
-- effective_date comes from account_premise_link.link_start_date; all dates
-- anchor to ${as_of_date}.
--
-- Joins to account_premise_link by account_id ONLY (not account_id+premise_id)
-- so it fans out one row per TENANCY, not per account:
-- a relocated account has two account_premise_link rows (origin, closed;
-- destination, open) and must produce two service agreements — one per
-- premise/service point it was ever tied to. For the ~99%+ of accounts with
-- exactly one tenancy this is a no-op (still exactly one agreement).
--
-- The join to raw_service_point (via raw_premise_service_attrs) also fans out
-- per CONCURRENT service point, not just per tenancy: a large commercial
-- premise's 2-5 sub-metered service points each get
-- their own agreement under the same account.

CREATE OR REFRESH MATERIALIZED VIEW raw_service_agreement (
  CONSTRAINT non_null_service_agreement_id EXPECT (service_agreement_id IS NOT NULL),
  CONSTRAINT non_null_account_id           EXPECT (account_id IS NOT NULL),
  CONSTRAINT non_null_service_point_id     EXPECT (service_point_id IS NOT NULL),
  CONSTRAINT valid_status                  EXPECT (status IN ('active','terminated','suspended')),
  CONSTRAINT term_after_effective          EXPECT (termination_date IS NULL OR termination_date >= effective_date)
)
COMMENT 'Service Agreement — CIM ServiceAgreement linking an account to a service point under a rate schedule for a date range (effective-dated). Rate switchers carry a prior terminated agreement on res_d1 plus the current agreement. One account carries a mid-window ownership transfer: its agreement is split at the transfer date into a pre-transfer row (prior customer) and a post-transfer row (current customer), producing customer_changed_mid_month=true in the monthly AMI fact for that month. is_current marks the live agreement; agreement_seq orders an account''s agreements over time. PK: service_agreement_id. FK: account_id -> customer_account.account_id, service_point_id -> raw_service_point.service_point_id.'
AS

WITH base AS (
  SELECT
    ca.account_id,
    ca.customer_id,
    apl.premise_id,
    ca.customer_class,
    ca.rate_schedule                                              AS current_rate,
    ca.current_status,
    up.service_point_id,
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
  JOIN raw_premise_service_attrs sl ON sl.premise_id = apl.premise_id
  JOIN raw_service_point         up ON up.service_location_id = sl.service_location_id
  WHERE ca.account_group <> 'corporate_parent'
),

flagged AS (
  SELECT *,
    (is_switch_candidate AND link_start_date < switch_date) AS is_switcher
  FROM base
),

current_agr AS (
  SELECT
    md5(CONCAT(account_id, '_', service_point_id, '_agr_cur'))       AS service_agreement_id,
    account_id, service_point_id, premise_id, customer_id,
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
    md5(CONCAT(account_id, '_', service_point_id, '_agr_prev'))      AS service_agreement_id,
    account_id, service_point_id, premise_id, customer_id,
    'res_d1'                                                      AS rate_schedule,
    link_start_date                                               AS effective_date,
    switch_date                                                   AS termination_date,
    'terminated'                                                  AS status,
    false                                                         AS is_current,
    1                                                             AS agreement_seq,
    'rate_change'                                                 AS termination_reason
  FROM flagged
  WHERE is_switcher
),

-- Reassigned account IDs (one account, one row).
reassigned AS (
  SELECT account_id, from_customer_id, to_customer_id, transfer_date
  FROM raw_account_reassignment
),

-- The agreements actually eligible to be split: transfer_date must fall
-- STRICTLY INSIDE the agreement's own window, or the two slices below would
-- invert (effective_date > termination_date, tripping term_after_effective).
-- Splitting is therefore conditional, and the pass-through below excludes
-- only the (account, service point) pairs that really were split.
split_base AS (
  SELECT
    ca.*,
    r.from_customer_id,
    r.to_customer_id,
    r.transfer_date
  FROM current_agr ca
  JOIN reassigned r ON r.account_id = ca.account_id
  WHERE ca.effective_date < r.transfer_date
    AND (ca.termination_date IS NULL OR r.transfer_date < ca.termination_date)
),

-- For the reassigned account: split its current_agr row into two.
-- Pre-transfer: the prior customer (from_customer_id) held the agreement
-- from effective_date until transfer_date.
reassign_pre AS (
  SELECT
    md5(CONCAT(sb.account_id, '_', sb.service_point_id, '_agr_reassign_pre')) AS service_agreement_id,
    sb.account_id,
    sb.service_point_id,
    sb.premise_id,
    sb.from_customer_id                                           AS customer_id,
    sb.rate_schedule,
    sb.effective_date,
    sb.transfer_date                                              AS termination_date,
    'terminated'                                                  AS status,
    false                                                         AS is_current,
    sb.agreement_seq,
    'account_reassignment'                                        AS termination_reason
  FROM split_base sb
),

-- Post-transfer: the current customer (to_customer_id) holds the agreement
-- from transfer_date onwards — open-ended, is_current=true.
reassign_post AS (
  SELECT
    md5(CONCAT(sb.account_id, '_', sb.service_point_id, '_agr_reassign_post')) AS service_agreement_id,
    sb.account_id,
    sb.service_point_id,
    sb.premise_id,
    sb.to_customer_id                                             AS customer_id,
    sb.rate_schedule,
    sb.transfer_date                                              AS effective_date,
    sb.termination_date,
    sb.status,
    sb.is_current,
    sb.agreement_seq,
    sb.termination_reason
  FROM split_base sb
)

SELECT service_agreement_id, account_id, service_point_id, premise_id, customer_id,
       rate_schedule, effective_date, termination_date, status, is_current,
       agreement_seq, termination_reason, current_timestamp() AS _ingested_at
FROM current_agr
-- Exclude only the rows actually replaced by the reassignment split below.
-- Keyed on (account_id, service_point_id) — not account_id alone — because a
-- sub-metered premise has several service points under one account and only
-- the splittable ones are replaced.
WHERE NOT EXISTS (
  SELECT 1 FROM split_base sb
  WHERE sb.account_id       = current_agr.account_id
    AND sb.service_point_id = current_agr.service_point_id
)
UNION ALL
SELECT service_agreement_id, account_id, service_point_id, premise_id, customer_id,
       rate_schedule, effective_date, termination_date, status, is_current,
       agreement_seq, termination_reason, current_timestamp() AS _ingested_at
FROM prior_rate_agr
UNION ALL
SELECT service_agreement_id, account_id, service_point_id, premise_id, customer_id,
       rate_schedule, effective_date, termination_date, status, is_current,
       agreement_seq, termination_reason, current_timestamp() AS _ingested_at
FROM reassign_pre
UNION ALL
SELECT service_agreement_id, account_id, service_point_id, premise_id, customer_id,
       rate_schedule, effective_date, termination_date, status, is_current,
       agreement_seq, termination_reason, current_timestamp() AS _ingested_at
FROM reassign_post;
