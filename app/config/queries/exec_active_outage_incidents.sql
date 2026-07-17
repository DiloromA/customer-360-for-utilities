-- Executive map — all active (currently-open) outage incidents for the Active
-- outages (live) layer's incident markers. One row per open incident, placed at
-- the centroid of its impacted premises. Small result set (a storm's worth of
-- feeders), so this is served over the analytics() SSE path.

SELECT
  active_outage_id,
  circuit_id,
  centroid_lat,
  centroid_lon,
  cause_code,
  weather_category,
  crew_status,
  n_customers_out,
  n_critical_care_out,
  started_at,
  minutes_out_so_far,
  estimated_restoration_at,
  eta_minutes,
  is_major_event_day
FROM {{catalog}}.{{schema}}.fact_active_outage_event
WHERE centroid_lat IS NOT NULL
ORDER BY n_customers_out DESC;
