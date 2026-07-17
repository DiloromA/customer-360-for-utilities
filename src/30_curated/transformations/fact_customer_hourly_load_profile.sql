-- Hourly load profile pre-aggregated per (service_point, year_month, day_type,
-- hour_of_day). ~51K service points × 24 months × 2 day types × 24 hours
-- ≈ 60M rows. Drives the CSR view's "Hourly Load Profile" card and EE-marketing
-- shape comparisons. Pre-aggregated so demos read curated only;
-- raw_meter_readings is ~900M rows.
--
-- Physical grain only — same discipline raw_meter_readings itself already
-- follows (usage_point-keyed, no denormalized customer_id). account_id/
-- customer_id do NOT belong here: an occupant can change mid-window
-- (temporal-realism §5.2), so stamping a single "current occupant" onto every
-- row for a usage_point is wrong by construction once that happens. A
-- consumer that needs the billing account for a period joins
-- dim_service_agreement itself (as-of the period's own date), the same
-- pattern fact_meter_readings_monthly.sql uses.

CREATE OR REFRESH MATERIALIZED VIEW fact_customer_hourly_load_profile (
  service_point_id  BIGINT,
  premise_id        BIGINT,
  year_month        STRING,
  day_type          STRING,
  hour_of_day       INT,
  avg_kwh           DOUBLE,
  median_kwh        DOUBLE,
  p90_kwh           DOUBLE,
  max_kwh           DOUBLE,
  n_days_in_window  BIGINT,
  _ingested_at      TIMESTAMP,
  CONSTRAINT non_null_service_point_id EXPECT (service_point_id IS NOT NULL),
  CONSTRAINT non_null_hour       EXPECT (hour_of_day BETWEEN 0 AND 23),
  CONSTRAINT valid_day_type      EXPECT (day_type IN ('weekday','weekend')),
  CONSTRAINT fk_fchlp_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fchlp_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY
)
COMMENT 'Hourly load profile averaged per (service_point_id, year_month, day_type, hour_of_day) — physical only, no account_id/customer_id (see fact_meter_readings_monthly for as-of account/customer attribution). Carries premise_id (a structural, non-temporal property of the usage point). Joins dim_service_point / dim_premise by id. Source: raw_meter_readings.'
AS

WITH up_attr AS (
  -- Structural only: a usage point's service_point_id/premise_id never
  -- change, so this is a plain lookup, not an as-of resolution.
  SELECT
    usage_point_id,
    abs(xxhash64(usage_point_id)) AS service_point_id,
    abs(xxhash64(premise_id))     AS premise_id
  FROM ${customer_master_schema}.raw_usage_point
)

SELECT
  a.service_point_id,
  a.premise_id,
  DATE_FORMAT(m.timestamp_utc, 'yyyy-MM')                            AS year_month,
  CASE
    WHEN EXTRACT(DAYOFWEEK FROM m.timestamp_utc) IN (1, 7) THEN 'weekend'
    ELSE 'weekday'
  END                                                                AS day_type,
  CAST(EXTRACT(HOUR FROM m.timestamp_utc) AS INT)                     AS hour_of_day,
  ROUND(AVG(m.kwh_delivered),     3)                                 AS avg_kwh,
  ROUND(PERCENTILE(m.kwh_delivered, 0.5), 3)                         AS median_kwh,
  ROUND(PERCENTILE(m.kwh_delivered, 0.9), 3)                         AS p90_kwh,
  ROUND(MAX(m.kwh_delivered),     3)                                 AS max_kwh,
  COUNT(DISTINCT CAST(m.timestamp_utc AS DATE))                       AS n_days_in_window,
  current_timestamp() AS _ingested_at
FROM ${ami_schema}.raw_meter_readings m
JOIN up_attr a ON a.usage_point_id = m.usage_point_id
GROUP BY
  a.service_point_id, a.premise_id,
  DATE_FORMAT(m.timestamp_utc, 'yyyy-MM'),
  CASE WHEN EXTRACT(DAYOFWEEK FROM m.timestamp_utc) IN (1, 7) THEN 'weekend' ELSE 'weekday' END,
  CAST(EXTRACT(HOUR FROM m.timestamp_utc) AS INT);
