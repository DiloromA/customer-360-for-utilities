-- Customer billing fact. Pass-through from raw customer_billing with
-- a few computed columns useful for the demo:
--   yoy_kwh_change_pct      this month's kWh vs same month last year
--   yoy_bill_change_pct     this month's bill vs same month last year
--   bill_shock_pct          this month vs trailing-12-month avg
--
-- The LAG/trailing-avg windows below are computed over a (account,
-- calendar-month) DEDUPLICATED grain, not raw bill rows: a relocation's or
-- in-window turnover's transition month can contribute 2 rows for one
-- account+period, and a ROW-count-based LAG(,12)
-- would silently desync by one calendar month for the rest of that account's
-- history the moment any month contributes more than one row.

CREATE OR REFRESH MATERIALIZED VIEW fact_customer_billing (
  CONSTRAINT non_null_bill_id    EXPECT (bill_id IS NOT NULL),
  CONSTRAINT non_null_account_id EXPECT (account_id IS NOT NULL),
  CONSTRAINT fk_fcb_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fcb_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fcb_service_agreement FOREIGN KEY (service_agreement_id) REFERENCES dim_service_agreement (service_agreement_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fcb_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fcb_date FOREIGN KEY (date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY,
  CONSTRAINT fk_fcb_rate_schedule FOREIGN KEY (rate_schedule) REFERENCES dim_rate_schedule (rate_schedule_id) NOT ENFORCED RELY
)
COMMENT 'Customer billing fact. CIM CustomerBilling with year-over-year and trailing-average context. Grain: one row per bill (bill_id, a natural-key string). account_id / customer_id / service_agreement_id / service_point_id are durable BIGINT keys; rate_schedule joins dim_rate_schedule. A rate switcher bills res_d1 before the switch and the new rate after (the as-of agreement is resolved in raw billing).'
AS

WITH base AS (
  SELECT *
  FROM ${billing_schema}.raw_customer_billing
),

-- Collapse to one row per (account, calendar month) before windowing, so a
-- transition month's extra row (2 service points billed under one account)
-- doesn't shift the ROW-based LAG/trailing-avg off by a month.
monthly AS (
  SELECT
    account_id,
    bill_period_end,
    SUM(total_kwh)       AS month_total_kwh,
    SUM(current_charges) AS month_total_charges
  FROM base
  GROUP BY account_id, bill_period_end
),

monthly_lags AS (
  SELECT
    account_id,
    bill_period_end,
    -- Same month last year (LAG 12 over account, now 12 calendar months
    -- since the grain below is deduplicated).
    LAG(month_total_kwh, 12) OVER (
      PARTITION BY account_id ORDER BY bill_period_end
    )                                                                AS prior_year_kwh,
    LAG(month_total_charges, 12) OVER (
      PARTITION BY account_id ORDER BY bill_period_end
    )                                                                AS prior_year_charges,
    -- Trailing-12 avg charges (excluding current).
    AVG(month_total_charges) OVER (
      PARTITION BY account_id ORDER BY bill_period_end
      ROWS BETWEEN 11 PRECEDING AND 1 PRECEDING
    )                                                                AS trailing_12_avg_charges
  FROM monthly
),

with_lags AS (
  SELECT
    b.*,
    ml.prior_year_kwh,
    ml.prior_year_charges,
    ml.trailing_12_avg_charges
  FROM base b
  JOIN monthly_lags ml
    ON ml.account_id = b.account_id AND ml.bill_period_end = b.bill_period_end
)

SELECT
  bill_id,
  abs(xxhash64(account_id))           AS account_id,
  abs(xxhash64(customer_id))          AS customer_id,
  abs(xxhash64(service_agreement_id)) AS service_agreement_id,
  abs(xxhash64(service_point_id))       AS service_point_id,
  rate_schedule,
  bill_period_start,
  bill_period_end,
  CAST(DATE_FORMAT(bill_period_end, 'yyyyMMdd') AS INT)              AS date_key,
  bill_date,
  due_date,

  total_kwh,
  peak_kwh,
  offpeak_kwh,
  peak_demand_kw,
  exported_kwh,

  service_charge,
  energy_charge,
  demand_charge,
  pscr_adjustment,
  net_metering_credit,
  current_charges,

  payment_status,
  unpaid_carry,
  previous_balance,
  total_amount_due,

  -- YoY change percentages (NULL when no prior-year data exists).
  CASE WHEN prior_year_kwh > 0
       THEN ROUND((total_kwh - prior_year_kwh) / prior_year_kwh, 3)
       ELSE CAST(NULL AS DOUBLE)
  END                                                                AS yoy_kwh_change_pct,
  CASE WHEN prior_year_charges > 1
       THEN ROUND((current_charges - prior_year_charges) / prior_year_charges, 3)
       ELSE CAST(NULL AS DOUBLE)
  END                                                                AS yoy_bill_change_pct,

  -- Bill shock vs trailing 12.
  CASE WHEN trailing_12_avg_charges > 1
       THEN ROUND((current_charges - trailing_12_avg_charges) / trailing_12_avg_charges, 3)
       ELSE CAST(NULL AS DOUBLE)
  END                                                                AS bill_shock_pct,

  current_timestamp() AS _ingested_at
FROM with_lags;
