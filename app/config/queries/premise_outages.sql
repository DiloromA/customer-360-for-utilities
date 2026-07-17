-- Outage history at this premise (address), last 24 months. Premise-native
-- version of customer_outages.sql — outage impact is already premise-grain
-- (fact_outage_customer_impact carries premise_id). Keyed by premise_number
-- (STRING) — see premise_header.sql's note on the BIGINT/client boundary.

-- @param premise_number STRING

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
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
FROM prem
JOIN {{catalog}}.{{schema}}.fact_outage_customer_impact ci ON ci.premise_id = prem.premise_id
JOIN {{catalog}}.{{schema}}.fact_outage_events o USING (outage_id)
ORDER BY ci.affected_start DESC
LIMIT 30
