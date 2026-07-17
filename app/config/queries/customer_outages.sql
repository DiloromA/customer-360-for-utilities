-- Outage history for the customer's premise (last 24 months).
-- Outage impact is premise-grain in the new model (fact_outage_customer_impact
-- carries premise_id), so we resolve the account_number to its premise.

-- @param account_number STRING

WITH acct AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
)
SELECT
  ci.impact_id,
  ci.outage_id,
  ci.affected_start,
  ci.affected_end,
  ci.minutes_out,
  ci.priority_restoration_flag,
  o.cause_code,
  o.weather_category,
  o.is_major_event_day,
  o.duration_bucket,
  o.affected_customer_count                                           AS circuit_affected_count
FROM acct
JOIN {{catalog}}.{{schema}}.fact_outage_customer_impact ci
  ON ci.premise_id = acct.premise_id
JOIN {{catalog}}.{{schema}}.fact_outage_events o USING (outage_id)
ORDER BY ci.affected_start DESC
LIMIT 30
