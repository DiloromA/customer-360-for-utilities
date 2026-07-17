-- Active Outage Event fact — the real-time OMS incident snapshot (one row per
-- currently-open outage), enriched with a geographic centroid computed from the
-- premises actually knocked out, so incidents can be plotted as markers on the
-- Executive map's "Active outages (live)" layer.
--
-- n_customers_out is the ACTUAL fanned-out count (from the customer-impact
-- table) rather than the planned affected_customer_count on the raw event.

CREATE OR REFRESH MATERIALIZED VIEW fact_active_outage_event (
  active_outage_id         STRING  NOT NULL,
  circuit_id               INT,
  snapshot_at              TIMESTAMP,
  started_at               TIMESTAMP,
  minutes_out_so_far       INT,
  estimated_restoration_at TIMESTAMP,
  eta_minutes              INT,
  cause_code               STRING,
  weather_category         STRING,
  affected_customer_count  INT,
  n_customers_out          BIGINT,
  n_critical_care_out      BIGINT,
  crew_status              STRING,
  is_major_event_day       BOOLEAN,
  centroid_lat             DOUBLE,
  centroid_lon             DOUBLE,
  _ingested_at             TIMESTAMP
)
COMMENT 'Active Outage Event fact — real-time OMS snapshot of open outages with restoration ETA, crew status, and a lat/lon centroid of the impacted premises for map plotting. One row per active incident.'
AS

WITH
-- Centroid + actual out-count from the premises this incident darkened.
centroids AS (
  SELECT
    i.active_outage_id,
    AVG(p.latitude)  AS centroid_lat,
    AVG(p.longitude) AS centroid_lon,
    -- Distinct customers/premises, not fan-out rows: a customer can span several
    -- premises/usage-points on the circuit (impact_id repeats), so COUNT(*) would
    -- overstate the customer count driving the tooltip + marker radius.
    COUNT(DISTINCT i.customer_id)                                        AS n_customers_out,
    COUNT(DISTINCT CASE WHEN i.priority_restoration_flag THEN i.customer_id END) AS n_critical_care_out
  FROM ${outages_schema}.raw_active_outage_customer_impact i
  JOIN ${customer_master_schema}.raw_premises p ON p.premise_id = i.premise_id
  GROUP BY i.active_outage_id
)

SELECT
  e.active_outage_id,
  e.circuit_id,
  e.snapshot_at,
  e.started_at,
  e.minutes_out_so_far,
  e.estimated_restoration_at,
  e.eta_minutes,
  e.cause_code,
  e.weather_category,
  e.affected_customer_count,
  COALESCE(c.n_customers_out, 0)                                     AS n_customers_out,
  COALESCE(c.n_critical_care_out, 0)                                 AS n_critical_care_out,
  e.crew_status,
  e.is_major_event_day,
  c.centroid_lat,
  c.centroid_lon,
  current_timestamp()                                                AS _ingested_at
FROM ${outages_schema}.raw_active_outage_event e
LEFT JOIN centroids c USING (active_outage_id);
