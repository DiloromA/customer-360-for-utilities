-- Is any of this customer's current premises without power? Returns 0 rows if
-- not, or the worst/earliest live incident across the customer's own sites for
-- the "currently without power" banner.
-- Resolves to all current premises via hierarchy_version (direct scope —
-- hv.customer_id, is_current=true), covering single- and multi-site customers.

-- @param account_number STRING

WITH acct AS (
  SELECT a.customer_id
  FROM {{catalog}}.{{schema}}.dim_account a
  WHERE a.account_number = :account_number
),
current_premises AS (
  SELECT DISTINCT hv.premise_id
  FROM acct
  JOIN {{catalog}}.{{schema}}.hierarchy_version hv
    ON hv.customer_id = acct.customer_id
   AND hv.is_current
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
FROM current_premises cp
JOIN {{catalog}}.{{schema}}.fact_active_outage_customer_impact i
  ON i.premise_id = cp.premise_id AND i.still_out
JOIN {{catalog}}.{{schema}}.fact_active_outage_event e
  ON e.active_outage_id = i.active_outage_id
ORDER BY i.out_since ASC
LIMIT 1
