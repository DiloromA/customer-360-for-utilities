-- Hourly load profile for a chosen month + day type, at this premise.
-- Premise-native version of customer_load_profile.sql. Grain of
-- fact_customer_hourly_load_profile is physical: (service_point_id,
-- year_month, day_type, hour_of_day) — no account_id (temporal-realism §5.2:
-- an occupant can change mid-window, so the fact is never account-stamped).
-- A large sub-metered commercial premise (temporal-realism §5.3) has 2-5
-- dim_service_point rows, so sum across them per hour — otherwise this would
-- return 24×N rows (one set per meter) instead of the site's combined
-- profile. Keyed by premise_number (STRING) — see premise_header.sql's note
-- on the BIGINT/client boundary.

-- @param premise_number STRING
-- @param year_month  STRING   -- e.g. "2018-07"
-- @param day_type    STRING   -- "weekday" or "weekend"

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
)
SELECT
  lp.hour_of_day,
  ROUND(SUM(lp.avg_kwh),    3) AS avg_kwh,
  ROUND(SUM(lp.median_kwh), 3) AS median_kwh,
  ROUND(SUM(lp.p90_kwh),    3) AS p90_kwh,
  MAX(lp.n_days_in_window)     AS n_days
FROM prem
JOIN {{catalog}}.{{schema}}.dim_service_point sp ON sp.premise_id = prem.premise_id
JOIN {{catalog}}.{{schema}}.fact_customer_hourly_load_profile lp
  ON lp.service_point_id = sp.service_point_id
WHERE lp.year_month = :year_month
  AND lp.day_type   = :day_type
GROUP BY lp.hour_of_day
ORDER BY lp.hour_of_day
