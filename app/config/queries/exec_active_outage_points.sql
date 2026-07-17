-- Executive map — currently-out customers within the viewport, for the Active
-- outages (live) layer's per-customer dots. One row per premise whose current
-- occupant is without power right now. Carries the parent incident's cause /
-- crew status / restoration ETA for the dot tooltip.

-- @param south STRING  -- viewport bounds (CAST to DOUBLE)
-- @param north STRING
-- @param west STRING
-- @param east STRING

SELECT
  a.account_number,
  h3.premise_number,
  h3.latitude,
  h3.longitude,
  c.customer_class,
  c.critical_care_flag,
  i.priority_restoration_flag,
  i.out_since,
  i.estimated_restoration_at,
  i.minutes_out_so_far,
  e.cause_code,
  e.weather_category,
  e.crew_status,
  e.active_outage_id
FROM {{catalog}}.{{schema}}.fact_active_outage_customer_impact i
JOIN {{catalog}}.{{schema}}.fact_active_outage_event e
  ON e.active_outage_id = i.active_outage_id
JOIN {{catalog}}.{{schema}}.dim_premise_h3 h3
  ON h3.premise_id = i.premise_id
JOIN {{catalog}}.{{schema}}.bridge_account_premise b
  ON b.premise_id = i.premise_id AND b.is_current
JOIN {{catalog}}.{{schema}}.dim_account a
  ON a.account_id = b.account_id
JOIN {{catalog}}.{{schema}}.dim_customer c
  ON c.customer_id = i.customer_id
WHERE i.still_out
  AND h3.latitude  BETWEEN CAST(:south AS DOUBLE) AND CAST(:north AS DOUBLE)
  AND h3.longitude BETWEEN CAST(:west AS DOUBLE) AND CAST(:east AS DOUBLE)
ORDER BY c.critical_care_flag DESC, i.minutes_out_so_far DESC
LIMIT 25000;
