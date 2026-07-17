-- Per-customer hourly load profile for a chosen month and day type.
-- fact_customer_hourly_load_profile is physical (service_point) grain, not
-- account grain (temporal-realism §5.2 — an occupant can change mid-window,
-- so the fact itself carries no account_id). Resolve the account's
-- service_point(s) as-of the requested period's end via dim_service_agreement,
-- then join the fact by service_point_id. A large sub-metered commercial
-- account (temporal-realism §5.3) has 2-5 CONCURRENT service_points, so sum
-- across them per hour — otherwise this would only show one meter's slice of
-- the site's load. Returns 24 rows (hour 0-23).

-- @param account_number STRING
-- @param year_month     STRING   -- e.g. "2018-07"
-- @param day_type       STRING   -- "weekday" or "weekend"

WITH acct AS (
  SELECT account_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
),
sp AS (
  -- As-of the requested period's end: which service_point(s) this account was
  -- tied to. Ordinarily an account has exactly one tenancy ever; a relocated
  -- account (temporal-realism §5.1) has two over time (this picks whichever
  -- was active at period-end); a sub-metered commercial account
  -- (temporal-realism §5.3) has 2-5 active at once (this picks all of them).
  SELECT DISTINCT sa.service_point_id
  FROM acct
  JOIN {{catalog}}.{{schema}}.dim_service_agreement sa ON sa.account_id = acct.account_id
  WHERE sa.effective_date <= LAST_DAY(TO_DATE(:year_month || '-01'))
    AND (sa.termination_date IS NULL OR sa.termination_date > LAST_DAY(TO_DATE(:year_month || '-01')))
)
SELECT
  lp.hour_of_day,
  ROUND(SUM(lp.avg_kwh),    3) AS avg_kwh,
  ROUND(SUM(lp.median_kwh), 3) AS median_kwh,
  ROUND(SUM(lp.p90_kwh),    3) AS p90_kwh,
  MAX(lp.n_days_in_window)     AS n_days
FROM sp
JOIN {{catalog}}.{{schema}}.fact_customer_hourly_load_profile lp
  ON lp.service_point_id = sp.service_point_id
WHERE lp.year_month = :year_month
  AND lp.day_type   = :day_type
GROUP BY lp.hour_of_day
ORDER BY lp.hour_of_day
