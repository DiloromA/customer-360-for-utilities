-- Digital Event — discrete digital touchpoints outside of full portal
-- sessions. One row per event. Event types:
--   payment_failed              autopay NSF / expired card / failed manual
--   payment_succeeded           successful payment (autopay or manual)
--   paperless_enrolled          customer toggled paperless ON
--   paperless_unenrolled        customer toggled paperless OFF
--   mobile_app_installed        one-time install event per customer (if applicable)
--   password_reset              self-service password reset
--   outage_text_alert_optin     enrolled in SMS outage alerts
--
-- Total ~300K events over 2017+2018. The payment_failed events are the
-- highest-value for the demo - they drive collections workflows and
-- correlate with cost_stressed archetype.

CREATE OR REFRESH MATERIALIZED VIEW raw_digital_event (
  CONSTRAINT non_null_event_id  EXPECT (event_id IS NOT NULL),
  CONSTRAINT non_null_customer_id EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_event_type EXPECT (event_type IN (
    'payment_failed','payment_succeeded','paperless_enrolled',
    'paperless_unenrolled','mobile_app_installed','password_reset',
    'outage_text_alert_optin'
  ))
)
COMMENT 'Digital Event — discrete non-session digital touchpoints. payment_failed events are highest-value for the demo (collections workflow + cost_stressed correlation). ~300K rows. PK: event_id. FK: customer_id -> raw_customer.'
AS

WITH

years AS (
  SELECT DISTINCT YEAR(d) AS year
  FROM (SELECT EXPLODE(SEQUENCE(
    DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
    DATE'${as_of_date}',
    INTERVAL 1 MONTH
  )) AS d)
),

-- Display-window bounds for the one-time (non-yearly) events below
-- (app_installs, outage_alert_optins).
window_bounds AS (
  SELECT
    DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1) AS window_start,
    DATEDIFF(
      DATE'${as_of_date}',
      DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
    ) + 1                                                                            AS window_days
),

-- Payment events derive from payment_history. Every paid_late + paid_partial
-- + unpaid bill that wasn't autopay had some failed-payment activity.
payment_events AS (
  SELECT
    md5(CONCAT(ph.payment_id, '_evt'))                               AS event_id,
    ph.customer_id,
    ph.bill_id,
    -- Successful manual payments produce a payment_succeeded event.
    -- Failed autopay produces payment_failed.
    CASE
      WHEN ph.payment_status = 'paid_on_time'  THEN 'payment_succeeded'
      WHEN ph.payment_status = 'paid_late'     THEN 'payment_succeeded'
      WHEN ph.payment_status = 'paid_partial'  THEN 'payment_succeeded'
      WHEN ph.payment_status = 'unpaid'        THEN 'payment_failed'
    END                                                              AS event_type,
    ph.payment_method,
    ph.payment_date                                                  AS event_date,
    -- Build a timestamp at a deterministic hour within the day.
    TIMESTAMPADD(
      SECOND,
      CAST(abs(xxhash64(ph.payment_id, 'sec_of_day', ${random_seed})) % 86400 AS INT),
      MAKE_TIMESTAMP(YEAR(COALESCE(ph.payment_date, ph.bill_id)),
                     MONTH(COALESCE(ph.payment_date, ph.bill_id)),
                     DAY(COALESCE(ph.payment_date, CURRENT_DATE())),
                     0, 0, 0, 'UTC')
    )                                                                AS event_timestamp,
    CASE ph.payment_status
      WHEN 'unpaid' THEN false
      ELSE              true
    END                                                              AS success_flag,
    -- Failure reason (NULL for success)
    CASE
      WHEN ph.payment_status = 'unpaid' AND ph.payment_method IS NULL
        THEN CASE WHEN abs(xxhash64(ph.payment_id, 'reason', ${random_seed})) % 3 = 0 THEN 'insufficient_funds'
                  WHEN abs(xxhash64(ph.payment_id, 'reason', ${random_seed})) % 3 = 1 THEN 'card_expired'
                  ELSE                                                                      'no_attempt'
             END
      ELSE CAST(NULL AS STRING)
    END                                                              AS failure_reason
  FROM ${billing_schema}.raw_payment_history ph
  WHERE ph.payment_date IS NOT NULL OR ph.payment_status = 'unpaid'
),

-- Paperless toggles. ~2% of customers toggle their paperless setting each year.
paperless_toggles AS (
  SELECT
    md5(CONCAT(c.customer_id, '_paperless_', CAST(y.year AS STRING))) AS event_id,
    c.customer_id,
    CAST(NULL AS STRING)                                              AS bill_id,
    CASE WHEN abs(xxhash64(c.customer_id, y.year, 'direction', ${random_seed})) % 2 = 0
         THEN 'paperless_enrolled' ELSE 'paperless_unenrolled' END    AS event_type,
    CAST(NULL AS STRING)                                              AS payment_method,
    DATE_ADD(MAKE_DATE(y.year, 1, 1),
      CAST(abs(xxhash64(c.customer_id, y.year, 'day', ${random_seed})) % 365 AS INT))
                                                                      AS event_date,
    TIMESTAMPADD(SECOND,
      CAST(abs(xxhash64(c.customer_id, y.year, 'sec', ${random_seed})) % 86400 AS INT),
      MAKE_TIMESTAMP(y.year, 1, 1, 0, 0, 0, 'UTC')
    )                                                                 AS event_timestamp,
    true                                                              AS success_flag,
    CAST(NULL AS STRING)                                              AS failure_reason
  FROM ${customer_master_schema}.raw_customer c
  CROSS JOIN years y
  WHERE NOT c.is_prior_customer                                        -- current customers only
    AND abs(xxhash64(c.customer_id, y.year, 'toggle', ${random_seed})) % 100 < 2
),

-- Mobile app installs - one-time event for ~25% of customers (those who
-- ever logged in via mobile). Modeled as a single event somewhere in the
-- display window (window_bounds).
--
-- Energy-efficiency / DSM participants (raw_dsm_enrollment) are more likely to
-- install the app (they manage rebates / DR events there), so their archetype
-- install probability is lifted by +0.15 (capped at 0.90). This is the same
-- EE -> digital referential-integrity link as raw_portal_session, and it feeds
-- the mobile-app component of digital_adoption_score in dim_customer.
ee_participants AS (
  SELECT DISTINCT customer_id
  FROM ${dsm_programs_schema}.raw_dsm_enrollment
  WHERE enrollment_status IN ('enrolled','completed')
),

app_installs AS (
  SELECT
    md5(CONCAT(c.customer_id, '_app_install'))                       AS event_id,
    c.customer_id,
    CAST(NULL AS STRING)                                             AS bill_id,
    'mobile_app_installed'                                           AS event_type,
    CAST(NULL AS STRING)                                             AS payment_method,
    DATE_ADD(wb.window_start,
      CAST(abs(xxhash64(c.customer_id, 'app_day', ${random_seed})) % wb.window_days AS INT)) AS event_date,
    TIMESTAMPADD(SECOND,
      CAST(abs(xxhash64(c.customer_id, 'app_sec', ${random_seed})) % 86400 AS INT),
      TIMESTAMP(DATE_ADD(wb.window_start,
        CAST(abs(xxhash64(c.customer_id, 'app_day', ${random_seed})) % wb.window_days AS INT))))
                                                                      AS event_timestamp,
    true                                                             AS success_flag,
    CAST(NULL AS STRING)                                             AS failure_reason
  FROM ${customer_master_schema}.raw_customer c
  CROSS JOIN window_bounds wb
  LEFT JOIN ee_participants ee ON ee.customer_id = c.customer_id
  WHERE
    -- Archetype install probability (same mix as portal_session), lifted for
    -- EE/DSM participants.
    LEAST(0.90,
      CASE c.archetype
        WHEN 'tech_forward'        THEN 0.65
        WHEN 'efficient_engaged'   THEN 0.40
        WHEN 'inefficient_unaware' THEN 0.15
        WHEN 'cost_stressed'       THEN 0.18
        WHEN 'comfortable_indifferent' THEN 0.25
        WHEN 'senior_fixed_income' THEN 0.05
        ELSE 0.20
      END
      + CASE WHEN ee.customer_id IS NOT NULL THEN 0.15 ELSE 0.0 END
    ) > abs(xxhash64(c.customer_id, 'app_install_prob', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE)
    AND NOT c.is_prior_customer                                        -- current customers only
),

-- Password resets. ~6% of customers per year have at least one.
password_resets AS (
  SELECT
    md5(CONCAT(c.customer_id, '_pw_', CAST(y.year AS STRING)))      AS event_id,
    c.customer_id,
    CAST(NULL AS STRING)                                             AS bill_id,
    'password_reset'                                                 AS event_type,
    CAST(NULL AS STRING)                                             AS payment_method,
    DATE_ADD(MAKE_DATE(y.year, 1, 1),
      CAST(abs(xxhash64(c.customer_id, y.year, 'pw_day', ${random_seed})) % 365 AS INT))
                                                                     AS event_date,
    TIMESTAMPADD(SECOND,
      CAST(abs(xxhash64(c.customer_id, y.year, 'pw_sec', ${random_seed})) % 86400 AS INT),
      MAKE_TIMESTAMP(y.year, 1, 1, 0, 0, 0, 'UTC'))                  AS event_timestamp,
    true                                                             AS success_flag,
    CAST(NULL AS STRING)                                             AS failure_reason
  FROM ${customer_master_schema}.raw_customer c
  CROSS JOIN years y
  WHERE NOT c.is_prior_customer                                        -- current customers only
    AND abs(xxhash64(c.customer_id, y.year, 'pw_reset', ${random_seed})) % 100 < 6
),

-- Outage text-alert opt-in (one-time per customer).
outage_alert_optins AS (
  SELECT
    md5(CONCAT(c.customer_id, '_outage_optin'))                      AS event_id,
    c.customer_id,
    CAST(NULL AS STRING)                                             AS bill_id,
    'outage_text_alert_optin'                                        AS event_type,
    CAST(NULL AS STRING)                                             AS payment_method,
    DATE_ADD(wb.window_start,
      CAST(abs(xxhash64(c.customer_id, 'optin_day', ${random_seed})) % wb.window_days AS INT))
                                                                     AS event_date,
    TIMESTAMPADD(SECOND,
      CAST(abs(xxhash64(c.customer_id, 'optin_sec', ${random_seed})) % 86400 AS INT),
      TIMESTAMP(DATE_ADD(wb.window_start,
        CAST(abs(xxhash64(c.customer_id, 'optin_day', ${random_seed})) % wb.window_days AS INT))))
                                                                     AS event_timestamp,
    true                                                             AS success_flag,
    CAST(NULL AS STRING)                                             AS failure_reason
  FROM ${customer_master_schema}.raw_customer c
  CROSS JOIN window_bounds wb
  WHERE NOT c.is_prior_customer                                        -- current customers only
    AND abs(xxhash64(c.customer_id, 'outage_optin', ${random_seed})) % 100 < 42
)

SELECT event_id, customer_id, bill_id, event_type, event_timestamp,
       event_date, payment_method, success_flag, failure_reason,
       current_timestamp() AS _ingested_at
FROM payment_events
UNION ALL
SELECT event_id, customer_id, bill_id, event_type, event_timestamp,
       event_date, payment_method, success_flag, failure_reason,
       current_timestamp() AS _ingested_at
FROM paperless_toggles
UNION ALL
SELECT event_id, customer_id, bill_id, event_type, event_timestamp,
       event_date, payment_method, success_flag, failure_reason,
       current_timestamp() AS _ingested_at
FROM app_installs
UNION ALL
SELECT event_id, customer_id, bill_id, event_type, event_timestamp,
       event_date, payment_method, success_flag, failure_reason,
       current_timestamp() AS _ingested_at
FROM password_resets
UNION ALL
SELECT event_id, customer_id, bill_id, event_type, event_timestamp,
       event_date, payment_method, success_flag, failure_reason,
       current_timestamp() AS _ingested_at
FROM outage_alert_optins;
