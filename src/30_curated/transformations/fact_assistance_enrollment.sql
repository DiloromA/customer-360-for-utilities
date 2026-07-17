-- Assistance Enrollment fact. Unifies LIHEAP + payment plans + critical
-- care registration into one fact with a program_type discriminator.

CREATE OR REFRESH MATERIALIZED VIEW fact_assistance_enrollment (
  enrollment_id       STRING NOT NULL,
  program_type        STRING,
  customer_id         BIGINT,
  enrollment_date     DATE,
  enrollment_date_key INT,
  program_subtype     STRING,
  benefit_amount_usd  DOUBLE,
  status              STRING,
  detail_attr         STRING,
  _ingested_at        TIMESTAMP,
  CONSTRAINT fk_fae_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fae_date FOREIGN KEY (enrollment_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Assistance enrollment fact - unified LIHEAP + payment plans + critical care. customer_id is a durable BIGINT key.'
AS

-- LIHEAP
SELECT
  l.enrollment_id,
  'liheap'                                                            AS program_type,
  abs(xxhash64(l.customer_id))                                             AS customer_id,
  l.enrollment_date,
  CAST(DATE_FORMAT(l.enrollment_date, 'yyyyMMdd') AS INT)             AS enrollment_date_key,
  CAST(l.program_year AS STRING)                                      AS program_subtype,
  l.benefit_amount_usd,
  l.benefit_status                                                    AS status,
  l.payment_assistance_type                                           AS detail_attr,
  current_timestamp() AS _ingested_at
FROM ${assistance_schema}.raw_liheap_enrollment l

UNION ALL

-- Payment plans
SELECT
  pp.plan_id                                                          AS enrollment_id,
  'payment_plan'                                                      AS program_type,
  abs(xxhash64(pp.customer_id))                                            AS customer_id,
  pp.plan_start_date                                                  AS enrollment_date,
  CAST(DATE_FORMAT(pp.plan_start_date, 'yyyyMMdd') AS INT)            AS enrollment_date_key,
  CONCAT(CAST(pp.term_months AS STRING), '_month')                    AS program_subtype,
  pp.initial_balance_usd                                              AS benefit_amount_usd,
  pp.plan_status                                                      AS status,
  CONCAT('monthly_', CAST(ROUND(pp.monthly_payment_usd, 0) AS STRING))AS detail_attr,
  current_timestamp() AS _ingested_at
FROM ${assistance_schema}.raw_payment_plan pp

UNION ALL

-- Critical care
SELECT
  ccr.registration_id                                                 AS enrollment_id,
  'critical_care'                                                     AS program_type,
  abs(xxhash64(ccr.customer_id))                                           AS customer_id,
  ccr.registration_date                                               AS enrollment_date,
  CAST(DATE_FORMAT(ccr.registration_date, 'yyyyMMdd') AS INT)         AS enrollment_date_key,
  ccr.medical_equipment_type                                          AS program_subtype,
  CAST(NULL AS DOUBLE)                                                AS benefit_amount_usd,
  CASE
    -- As-of the demo's frozen "now" (2018-12-31), matching every other curated
    -- table; CURRENT_DATE() would mark every 2017-2018 registration lapsed.
    WHEN ccr.expiration_date >= DATE'2018-12-31' THEN 'active'
    ELSE                                              'lapsed'
  END                                                                AS status,
  ccr.outage_notification_preference                                  AS detail_attr,
  current_timestamp() AS _ingested_at
FROM ${assistance_schema}.raw_critical_care_registration ccr;
