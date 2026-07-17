-- Daily meter readings — aggregate of the ~900M-row hourly AMI to daily.
-- ~51K service points × 730 days ≈ 37M rows.
--
-- Physical grain only — same discipline raw_meter_readings itself already
-- follows one layer down (usage_point-keyed, no denormalized customer_id).
-- account_id/customer_id do NOT belong here: an occupant can change mid-window
-- (temporal-realism §5.2 relocations/in-window turnover), so stamping a single
-- "current occupant" onto every row for a usage_point is wrong by
-- construction once that happens. Account/customer attribution is resolved
-- once, as-of each reading's own date, in fact_meter_readings_monthly.sql —
-- consumers that need it there (or via their own as-of join against
-- dim_service_agreement) get it correctly time-varying. Grain: (service_point_id,
-- date_key). premise_id is carried because it's a structural, non-temporal
-- property of the usage point (a usage point's premise never changes).

CREATE OR REFRESH MATERIALIZED VIEW fact_meter_readings_daily (
  CONSTRAINT non_null_service_point_id EXPECT (service_point_id IS NOT NULL),
  CONSTRAINT non_null_date_key   EXPECT (date_key IS NOT NULL),
  CONSTRAINT non_negative_kwh    EXPECT (kwh_delivered >= 0),
  CONSTRAINT fk_fmrd_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrd_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fmrd_date FOREIGN KEY (date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Daily meter readings, aggregated from the hourly AMI fact. Grain: (service_point_id, date_key) — physical only, no account_id/customer_id (see fact_meter_readings_monthly for as-of account/customer attribution). Carries premise_id (a structural, non-temporal property of the usage point). Joins dim_service_point / dim_premise by id and dim_date by date_key. midday_kwh / min_hour_kwh are derivable from any hourly AMI feed (real-utility drop-in contract).'
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
  CAST(DATE_FORMAT(m.timestamp_utc, 'yyyyMMdd') AS INT)   AS date_key,
  CAST(m.timestamp_utc AS DATE)                           AS reading_date,
  ROUND(SUM(m.kwh_delivered),       2) AS kwh_delivered,
  ROUND(SUM(m.kwh_received),        2) AS kwh_received,
  ROUND(SUM(m.kwh_base),            2) AS kwh_base,
  ROUND(SUM(m.kwh_ev),              2) AS kwh_ev,
  ROUND(SUM(m.kwh_pv),              2) AS kwh_pv,
  ROUND(SUM(m.kwh_hp),              2) AS kwh_hp,
  ROUND(SUM(m.kwh_bess),            2) AS kwh_bess,
  ROUND(SUM(m.kwh_tstat_savings),   2) AS kwh_tstat_savings,
  ROUND(MAX(m.kwh_delivered),       2) AS peak_hour_kwh,
  CAST(MAX_BY(HOUR(m.timestamp_utc), m.kwh_delivered) AS INT) AS peak_hour_of_day,
  ROUND(SUM(CASE WHEN HOUR(m.timestamp_utc) BETWEEN 10 AND 14
                THEN m.kwh_delivered ELSE 0 END), 2) AS midday_kwh,
  ROUND(MIN(m.kwh_delivered),       2)                AS min_hour_kwh,
  current_timestamp() AS _ingested_at
FROM ${ami_schema}.raw_meter_readings m
JOIN up_attr a ON a.usage_point_id = m.usage_point_id
GROUP BY a.service_point_id, a.premise_id,
         CAST(DATE_FORMAT(m.timestamp_utc, 'yyyyMMdd') AS INT), CAST(m.timestamp_utc AS DATE);
