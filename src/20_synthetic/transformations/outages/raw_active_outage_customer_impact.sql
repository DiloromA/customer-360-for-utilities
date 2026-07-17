-- Active Outage Customer Impact — one row per (active outage, currently-out
-- customer). The real-time fan-out of raw_active_outage_event to the specific
-- customers/premises that are WITHOUT POWER right now (as of ${as_of_date}).
--
-- Same hit model as the historical raw_outage_customer_impact: every customer
-- on a downed circuit has probability (affected_customer_count / circuit_size)
-- of being out, decided per-pair by xxhash64(active_outage_id, customer_id).
-- Storm feeders saturate (60-100% affected), so most customers on a downed
-- circuit are dark.
--
-- premise_id is carried through (unlike some historical joins) so the curated
-- layer can resolve geography (dim_premise_h3) for map dots + H3 cells.
-- priority_restoration_flag carries critical-care customers for crew routing.

CREATE OR REFRESH MATERIALIZED VIEW raw_active_outage_customer_impact (
  CONSTRAINT non_null_impact_id        EXPECT (impact_id IS NOT NULL),
  CONSTRAINT non_null_active_outage_id EXPECT (active_outage_id IS NOT NULL),
  CONSTRAINT non_null_customer         EXPECT (customer_id IS NOT NULL),
  CONSTRAINT currently_out             EXPECT (still_out = true)
)
COMMENT 'Active Outage Customer Impact — real-time fan-out of raw_active_outage_event to the customers/premises currently without power as of the demo now. PK: impact_id. FK: active_outage_id -> raw_active_outage_event, customer_id -> raw_customer. Carries premise_id for geography.'
AS

WITH

-- Customer + their premise + circuit (same derivation the historical impact and
-- active-event tables use). The affected party is the premise's CURRENT
-- occupant. A sub-metered commercial premise (temporal-realism §5.3) has 2-5
-- usage_points, which would otherwise fan this out to duplicate rows for the
-- same customer — an outage takes out the whole building, not one meter, so
-- QUALIFY collapses back to one row per customer (same idiom
-- raw_dsm_enrollment.sql uses for multi-usage_point DER).
customer_circuit AS (
  SELECT
    c.customer_id,
    p.premise_id,
    up.usage_point_id,
    c.critical_care_flag,
    CAST(abs(xxhash64(p.census_tract, p.county_fips)) % 1000 AS INT) AS circuit_id
  FROM ${customer_master_schema}.raw_premises p
  JOIN ${customer_master_schema}.raw_service_location sl ON sl.premise_id = p.premise_id
  JOIN ${customer_master_schema}.raw_usage_point up ON up.service_location_id = sl.service_location_id
  JOIN ${customer_master_schema}.raw_premise_customer_map m ON m.premise_id = p.premise_id
  JOIN ${customer_master_schema}.raw_customer c ON c.customer_id = m.current_customer_id
  QUALIFY ROW_NUMBER() OVER (PARTITION BY c.customer_id ORDER BY up.usage_point_id) = 1
),

circuit_size AS (
  SELECT circuit_id, COUNT(*) AS circuit_customer_count
  FROM customer_circuit
  GROUP BY circuit_id
),

joined AS (
  SELECT
    o.active_outage_id,
    o.circuit_id,
    o.snapshot_at,
    o.started_at,
    o.estimated_restoration_at,
    o.affected_customer_count,
    cc.customer_id,
    cc.premise_id,
    cc.usage_point_id,
    cc.critical_care_flag,
    cs.circuit_customer_count,
    abs(xxhash64(o.active_outage_id, cc.customer_id, 'hit', ${random_seed})) % 1000000 AS r_hit_mil
  FROM raw_active_outage_event o
  JOIN customer_circuit cc USING (circuit_id)
  JOIN circuit_size      cs USING (circuit_id)
)

SELECT
  md5(CONCAT(active_outage_id, '_', customer_id))                    AS impact_id,
  active_outage_id,
  customer_id,
  premise_id,
  usage_point_id,
  circuit_id,

  snapshot_at,
  started_at                                                         AS out_since,
  estimated_restoration_at,
  -- Minutes out so far as of the snapshot.
  CAST(TIMESTAMPDIFF(MINUTE, started_at, snapshot_at) AS INT)        AS minutes_out_so_far,

  critical_care_flag                                                 AS priority_restoration_flag,
  true                                                               AS still_out,

  current_timestamp()                                                AS _ingested_at
FROM joined
WHERE
  -- Hit if a uniform [0, 1M) draw falls below the hit threshold.
  r_hit_mil < CAST(affected_customer_count * 1000000.0 / circuit_customer_count AS BIGINT);
