-- Monthly meter readings. ~51K service points × 24 months ≈ 1.2M rows.
-- Aggregated from the daily fact. Drives monthly trending in the CCO and EE
-- marketing views. Grain: (account_id, year, month); carries customer_id,
-- service_point_id, premise_id (durable BIGINT keys).
--
-- fact_meter_readings_daily is physical-only (no account_id/customer_id —
-- see its own header comment). This is the ONE place in the curated layer
-- where account/customer attribution happens: each daily reading resolves
-- against the service agreement whose half-open window covers that reading's
-- own date (temporal-realism §5.2) — not a single "current occupant" pick —
-- so a mid-month occupant transition correctly splits into two account rows
-- instead of assigning the whole month to whichever occupant is "current"
-- overall. peer_monthly_usage_benchmark.sql (which reads this fact) needs no
-- change as a result.

CREATE OR REFRESH MATERIALIZED VIEW fact_meter_readings_monthly (
  account_id              BIGINT,
  customer_id             BIGINT,
  service_point_id        BIGINT,
  premise_id              BIGINT,
  year                    INT,
  month                   INT,
  month_end_date_key      INT,
  month_end_date          DATE,
  kwh_delivered           DOUBLE,
  kwh_received            DOUBLE,
  kwh_base                DOUBLE,
  kwh_ev                  DECIMAL(37,2),
  kwh_pv                  DOUBLE,
  kwh_hp                  DOUBLE,
  kwh_bess                DOUBLE,
  kwh_tstat_savings       DOUBLE,
  month_peak_hour_kwh     DOUBLE,
  days_in_month_with_data BIGINT,
  _ingested_at            TIMESTAMP,
  CONSTRAINT non_null_account_id EXPECT (account_id IS NOT NULL),
  CONSTRAINT non_negative_kwh    EXPECT (kwh_delivered >= 0),
  CONSTRAINT fk_fmrm_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrm_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrm_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrm_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrm_date FOREIGN KEY (month_end_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Monthly meter readings, aggregated from fact_meter_readings_daily with as-of account/customer attribution against dim_service_agreement. Grain: (account_id, year, month). Carries customer_id, service_point_id, premise_id. Joins dim_account / dim_customer by id.'
AS

WITH agr AS (
  SELECT service_point_id, account_id, customer_id, effective_date, termination_date
  FROM dim_service_agreement
),

-- As-of attribution: each daily reading resolves against the agreement whose
-- half-open window covers its own reading_date. Agreement windows shouldn't
-- overlap by construction (each tenancy's effective_date is the prior one's
-- termination_date), so the ROW_NUMBER is a defensive dedup only.
attributed AS (
  SELECT
    d.*,
    a.account_id,
    a.customer_id,
    ROW_NUMBER() OVER (
      PARTITION BY d.service_point_id, d.reading_date
      ORDER BY a.effective_date DESC
    ) AS rn
  FROM fact_meter_readings_daily d
  JOIN agr a
    ON a.service_point_id = d.service_point_id
   AND a.effective_date <= d.reading_date
   AND (a.termination_date IS NULL OR d.reading_date < a.termination_date)
)

SELECT
  account_id,
  customer_id,
  service_point_id,
  premise_id,
  YEAR(reading_date)                                                  AS year,
  MONTH(reading_date)                                                 AS month,
  CAST(DATE_FORMAT(LAST_DAY(reading_date), 'yyyyMMdd') AS INT)        AS month_end_date_key,
  LAST_DAY(reading_date)                                              AS month_end_date,
  ROUND(SUM(kwh_delivered),     2) AS kwh_delivered,
  ROUND(SUM(kwh_received),      2) AS kwh_received,
  ROUND(SUM(kwh_base),          2) AS kwh_base,
  ROUND(SUM(kwh_ev),            2) AS kwh_ev,
  ROUND(SUM(kwh_pv),            2) AS kwh_pv,
  ROUND(SUM(kwh_hp),            2) AS kwh_hp,
  ROUND(SUM(kwh_bess),          2) AS kwh_bess,
  ROUND(SUM(kwh_tstat_savings), 2) AS kwh_tstat_savings,
  ROUND(MAX(peak_hour_kwh),     2) AS month_peak_hour_kwh,
  COUNT(DISTINCT reading_date)     AS days_in_month_with_data,
  current_timestamp() AS _ingested_at
FROM attributed
WHERE rn = 1
GROUP BY account_id, customer_id, service_point_id, premise_id,
         YEAR(reading_date), MONTH(reading_date), LAST_DAY(reading_date);
