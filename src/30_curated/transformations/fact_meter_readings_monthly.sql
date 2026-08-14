-- Monthly meter readings. ~51K service points × 24 months ≈ 1.2M rows.
-- Aggregated from the daily fact. Drives monthly trending in the CCO and EE
-- marketing views. Grain: (account_id, service_point_id, month_end_date_key).
--
-- fact_meter_readings_daily is physical-only (no account_id/customer_id —
-- see its own header comment). This is the ONE place in the curated layer
-- where account/customer attribution happens: each daily reading resolves
-- against the service agreement whose half-open window covers that reading's
-- own date — not a single "current customer" pick —
-- so a mid-month customer transition correctly splits into two account rows
-- instead of assigning the whole month to whichever customer is "current"
-- overall. peer_monthly_usage_benchmark.sql (which reads this fact) needs no
-- change as a result.
--
-- customer_id and premise_id are attributed as-of month_end_date (the last
-- reading date in the month's window) rather than included in the GROUP BY.
-- Including them in GROUP BY would split any month where the customer changed
-- mid-month into two rows, violating the declared grain.
-- customer_changed_mid_month=true flags those transition months so consumers can
-- detect them rather than silently attributing a full month's kWh to the successor.

CREATE OR REFRESH MATERIALIZED VIEW fact_meter_readings_monthly (
  account_id                BIGINT,
  customer_id               BIGINT,
  service_point_id          BIGINT,
  premise_id                BIGINT,
  year                      INT,
  month                     INT,
  month_end_date_key        INT,
  month_end_date            DATE,
  kwh_delivered             DOUBLE,
  kwh_received              DOUBLE,
  kwh_base                  DOUBLE,
  kwh_ev                    DECIMAL(37,2),
  kwh_pv                    DOUBLE,
  kwh_hp                    DOUBLE,
  kwh_tstat_savings         DOUBLE,
  month_peak_hour_kwh       DOUBLE,
  days_in_month_with_data   BIGINT,
  customer_changed_mid_month BOOLEAN,
  _ingested_at              TIMESTAMP,
  CONSTRAINT non_null_account_id EXPECT (account_id IS NOT NULL),
  CONSTRAINT non_negative_kwh    EXPECT (kwh_delivered >= 0),
  CONSTRAINT fk_fmrm_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrm_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrm_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrm_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrm_date FOREIGN KEY (month_end_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Monthly meter readings, aggregated from fact_meter_readings_daily with as-of account/customer attribution against dim_service_agreement. Grain: (account_id, service_point_id, month_end_date_key) — one row per service point per month per account. customer_id and premise_id are month-end attributions (as of the last reading date in the month), not whole-month invariants. customer_changed_mid_month=true when the customer changed during that month. Component channels: kwh_base, kwh_ev, kwh_pv, kwh_hp, kwh_tstat_savings.'
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
),

-- Pre-compute month-end attributed customer_id/premise_id using LAST_VALUE over
-- reading_date so the GROUP BY can stay at (account_id, service_point_id, month).
-- Cannot include customer_id/premise_id in GROUP BY directly — a mid-month
-- reassignment would split that month into two rows, violating the grain.
with_month_end_attrs AS (
  SELECT
    *,
    LAST_VALUE(customer_id) OVER (
      PARTITION BY account_id, service_point_id, LAST_DAY(reading_date)
      ORDER BY reading_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS month_end_customer_id,
    LAST_VALUE(premise_id) OVER (
      PARTITION BY account_id, service_point_id, LAST_DAY(reading_date)
      ORDER BY reading_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS month_end_premise_id
  FROM attributed
  WHERE rn = 1
)

SELECT
  account_id,
  -- month-end attribution: value as of the last reading date in the month.
  MAX(month_end_customer_id)                                            AS customer_id,
  service_point_id,
  MAX(month_end_premise_id)                                             AS premise_id,
  YEAR(reading_date)                                                    AS year,
  MONTH(reading_date)                                                   AS month,
  CAST(DATE_FORMAT(LAST_DAY(reading_date), 'yyyyMMdd') AS INT)          AS month_end_date_key,
  LAST_DAY(reading_date)                                                AS month_end_date,
  ROUND(SUM(kwh_delivered),     2) AS kwh_delivered,
  ROUND(SUM(kwh_received),      2) AS kwh_received,
  ROUND(SUM(kwh_base),          2) AS kwh_base,
  ROUND(SUM(kwh_ev),            2) AS kwh_ev,
  ROUND(SUM(kwh_pv),            2) AS kwh_pv,
  ROUND(SUM(kwh_hp),            2) AS kwh_hp,
  ROUND(SUM(kwh_tstat_savings), 2) AS kwh_tstat_savings,
  ROUND(MAX(peak_hour_kwh),     2) AS month_peak_hour_kwh,
  COUNT(DISTINCT reading_date)     AS days_in_month_with_data,
  -- true when the customer changed mid-month.
  -- A consumer summing a full month's kWh should check this flag before
  -- attributing the whole month to the month-end customer.
  (COUNT(DISTINCT customer_id) > 1)                                     AS customer_changed_mid_month,
  current_timestamp() AS _ingested_at
FROM with_month_end_attrs
GROUP BY account_id, service_point_id,
         YEAR(reading_date), MONTH(reading_date), LAST_DAY(reading_date);
