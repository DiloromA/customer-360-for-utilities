-- Is this customer's premise currently without power? Returns 0 rows if not,
-- or 1 row with the live incident's restoration ETA / cause / crew status for
-- the customer profile's "currently without power" banner.

-- @param account_number STRING

WITH acct AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
)
SELECT
  i.active_outage_id,
  i.out_since,
  i.estimated_restoration_at,
  i.minutes_out_so_far,
  i.priority_restoration_flag,
  e.cause_code,
  e.weather_category,
  e.crew_status,
  e.n_customers_out
FROM acct
JOIN {{catalog}}.{{schema}}.fact_active_outage_customer_impact i
  ON i.premise_id = acct.premise_id AND i.still_out
JOIN {{catalog}}.{{schema}}.fact_active_outage_event e
  ON e.active_outage_id = i.active_outage_id
LIMIT 1
