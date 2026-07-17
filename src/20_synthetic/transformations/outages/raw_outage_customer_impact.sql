-- Outage Customer Impact — one row per (outage, affected customer).
-- ~1M rows targeting SAIFI ~1.5 (avg 1.5 outage-impacts per customer/yr).
--
-- Pattern: every customer in the affected circuit has probability
-- (affected_count / circuit_size) of being hit, decided per-pair by
-- xxhash64(outage_id, customer_id). Expected hits per outage =
-- affected_customer_count; actual count varies by ~sqrt(N) per the
-- binomial. Acceptable demo-grade randomness.
--
-- For demo simplicity, all hit customers experience the full outage
-- duration (real outages have rolling restoration; we ignore that
-- nuance).
--
-- Priority restoration flag for critical_care customers (carries through
-- from raw_customer.critical_care_flag) — a real
-- utility OMS would re-route restoration crews to these locations first.

CREATE OR REFRESH MATERIALIZED VIEW raw_outage_customer_impact (
  CONSTRAINT non_null_impact_id  EXPECT (impact_id IS NOT NULL),
  CONSTRAINT non_null_outage_id  EXPECT (outage_id IS NOT NULL),
  CONSTRAINT non_null_customer   EXPECT (customer_id IS NOT NULL),
  CONSTRAINT positive_minutes    EXPECT (minutes_out > 0)
)
COMMENT 'Outage Customer Impact — CIM CustomerOutage fan-out. One row per (outage_id, customer_id) for customers in the outages circuit who were hit. PK: impact_id. FK: outage_id -> outage_event, customer_id -> raw_customer.'
AS

WITH

-- Customer + their circuit_id (same hash as outage_event uses).
-- Keyed to the physical spine (premise/usage_point); the affected party is the
-- premise's CURRENT occupant (via premise_customer_map). Occupancy is stable
-- across the fact window, so one current customer per usage_point — EXCEPT a
-- sub-metered commercial premise (temporal-realism §5.3), whose 2-5
-- usage_points would otherwise fan this join out to duplicate rows for the
-- same customer. An outage takes out the whole building, not one meter, so
-- QUALIFY collapses back to one row per customer (same idiom
-- raw_dsm_enrollment.sql uses for multi-usage_point DER).
customer_circuit AS (
  SELECT
    c.customer_id,
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

-- For each circuit, count its customer base so per-outage hit probability is
-- known.
circuit_size AS (
  SELECT circuit_id, COUNT(*) AS circuit_customer_count
  FROM customer_circuit
  GROUP BY circuit_id
),

joined AS (
  SELECT
    o.outage_id,
    o.circuit_id,
    o.started_at,
    o.ended_at,
    o.duration_minutes,
    o.affected_customer_count,
    cc.customer_id,
    cc.usage_point_id,
    cc.critical_care_flag,
    cs.circuit_customer_count,
    -- Per-(outage, customer) deterministic random.
    abs(xxhash64(o.outage_id, cc.customer_id, 'hit', ${random_seed})) % 1000000 AS r_hit_mil
  FROM raw_outage_event o
  JOIN customer_circuit cc USING (circuit_id)
  JOIN circuit_size      cs USING (circuit_id)
)

SELECT
  md5(CONCAT(outage_id, '_', customer_id)) AS impact_id,
  outage_id,
  customer_id,
  usage_point_id,
  circuit_id,

  -- All hit customers experience the full outage window.
  started_at                                                         AS affected_start,
  ended_at                                                           AS affected_end,
  duration_minutes                                                   AS minutes_out,

  critical_care_flag                                                 AS priority_restoration_flag,

  current_timestamp()                                                AS _ingested_at
FROM joined
WHERE
  -- Hit if a uniform [0, 1M) draw falls below the hit threshold.
  -- threshold = affected_customer_count / circuit_customer_count * 1_000_000
  r_hit_mil < CAST(affected_customer_count * 1000000.0 / circuit_customer_count AS BIGINT);
