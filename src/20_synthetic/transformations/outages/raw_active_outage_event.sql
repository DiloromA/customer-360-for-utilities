-- Active (real-time) Outage Event — a point-in-time OMS snapshot of the
-- outages that are OPEN right now, as of the demo's "now" (${as_of_date}).
--
-- The historical raw_outage_event table spreads ~7,000 incidents/year
-- UNIFORMLY across the calendar, so a naive "which outages are open at this
-- instant" slice would surface only ~2-3 events — not enough to drive a map
-- layer. Instead we synthesize a believable ACTIVE STORM: a cluster of feeders
-- (circuits) that are currently down, with dispatch/restoration state, so the
-- "who is out of power right now" layer has something to show.
--
-- "Now" is anchored to ${as_of_date} at an evening hour (19:30) — a winter
-- (December) storm for the seeded Michigan territory. Everything is derived
-- deterministically from (circuit_id, ${random_seed}) so the snapshot is stable
-- across pipeline runs.
--
-- circuit_id uses the SAME derivation as raw_outage_event / the historical
-- customer-impact fan-out: abs(xxhash64(census_tract, county_fips)) % 1000. A
-- circuit is a set of premises sharing a census tract, so a downed circuit is
-- geographically contiguous on the map — the outage clusters read as a storm
-- front, not random noise.

CREATE OR REFRESH MATERIALIZED VIEW raw_active_outage_event (
  CONSTRAINT non_null_active_outage_id EXPECT (active_outage_id IS NOT NULL),
  CONSTRAINT non_null_started_at       EXPECT (started_at IS NOT NULL),
  CONSTRAINT restoration_in_future     EXPECT (estimated_restoration_at > snapshot_at),
  CONSTRAINT valid_cause               EXPECT (cause_code IN (
    'weather','equipment_failure','vegetation','animal','vehicle','unknown'
  )),
  CONSTRAINT valid_crew_status         EXPECT (crew_status IN (
    'assessing','dispatched','en_route','on_site'
  ))
)
COMMENT 'Active Outage Event — real-time OMS snapshot of outages OPEN as of the demo now (${as_of_date} 19:30). A synthesized active winter storm across a cluster of feeders so the "currently out of power" map layer has live incidents. PK: active_outage_id. circuit_id shared with raw_active_outage_customer_impact for fan-out.'
AS

WITH

-- "Now" — the snapshot instant. All active outages started before this and are
-- estimated to restore after it.
snapshot AS (
  SELECT to_timestamp('${as_of_date} 19:30:00') AS snapshot_at
),

-- Distinct circuits in the territory with their customer base size (same
-- derivation used everywhere else).
circuits AS (
  SELECT
    abs(xxhash64(census_tract, county_fips)) % 1000 AS circuit_id,
    COUNT(*)                                         AS circuit_customer_count
  FROM ${customer_master_schema}.raw_premises
  GROUP BY abs(xxhash64(census_tract, county_fips)) % 1000
),

-- Pick the storm's downed feeders: the ~20 circuits with the lowest storm-pick
-- hash (deterministic), preferring feeders with at least a couple of customers
-- so each incident actually darkens a neighborhood. ROW_NUMBER makes the count
-- scale-independent (always up to 20 regardless of territory size).
storm_circuits AS (
  SELECT circuit_id, circuit_customer_count, pick_rank
  FROM (
    SELECT
      circuit_id,
      circuit_customer_count,
      ROW_NUMBER() OVER (
        ORDER BY abs(xxhash64(circuit_id, 'storm_pick', ${random_seed}))
      ) AS pick_rank
    FROM circuits
    WHERE circuit_customer_count >= 2
  )
  WHERE pick_rank <= 20
),

with_attrs AS (
  SELECT
    sc.circuit_id,
    sc.circuit_customer_count,
    s.snapshot_at,
    abs(xxhash64(sc.circuit_id, 'minutes_out', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_out,
    abs(xxhash64(sc.circuit_id, 'eta',         ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_eta,
    abs(xxhash64(sc.circuit_id, 'cause',       ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_cause,
    abs(xxhash64(sc.circuit_id, 'affect',      ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_affect
  FROM storm_circuits sc
  CROSS JOIN snapshot s
),

derived AS (
  SELECT
    circuit_id,
    circuit_customer_count,
    snapshot_at,

    -- How long this feeder has already been out: 20 min – 6 hours before now.
    CAST(20 + r_out * 340 AS INT)                                    AS minutes_out_so_far,

    -- Cause: storm-dominated.
    CASE
      WHEN r_cause < 0.55 THEN 'weather'
      WHEN r_cause < 0.75 THEN 'vegetation'
      WHEN r_cause < 0.92 THEN 'equipment_failure'
      WHEN r_cause < 0.97 THEN 'animal'
      ELSE                     'unknown'
    END                                                              AS cause_code,

    -- Estimated additional time to restore: 30 min – 8 hours from now.
    CAST(30 + r_eta * 450 AS INT)                                    AS eta_minutes,

    -- Storm outages saturate the feeder: 60–100% of the circuit is out.
    GREATEST(1, CAST(circuit_customer_count * (0.60 + r_affect * 0.40) AS INT)) AS affected_customer_count
  FROM with_attrs
)

SELECT
  md5(CONCAT('active_outage_', CAST(circuit_id AS STRING)))          AS active_outage_id,
  CAST(circuit_id AS INT)                                            AS circuit_id,
  snapshot_at,

  -- When the feeder went down (before now).
  TIMESTAMPADD(MINUTE, -minutes_out_so_far, snapshot_at)             AS started_at,
  minutes_out_so_far,

  -- Estimated restoration (after now).
  TIMESTAMPADD(MINUTE, eta_minutes, snapshot_at)                     AS estimated_restoration_at,
  eta_minutes                                                        AS eta_minutes,

  cause_code,

  -- Weather category — December in Michigan: ice / wind driven.
  CASE
    WHEN cause_code = 'weather'
      THEN CASE WHEN abs(xxhash64(circuit_id, 'wx', ${random_seed})) % 2 = 0
                THEN 'ice_storm' ELSE 'wind_storm' END
    ELSE 'clear'
  END                                                                AS weather_category,

  affected_customer_count,

  -- Crew state escalates with how long the feeder has been out.
  CASE
    WHEN minutes_out_so_far < 45  THEN 'assessing'
    WHEN minutes_out_so_far < 120 THEN 'dispatched'
    WHEN minutes_out_so_far < 240 THEN 'en_route'
    ELSE                               'on_site'
  END                                                                AS crew_status,

  -- Major-event-class if the feeder is large or restoration is far out.
  (affected_customer_count > 200 OR eta_minutes > 360)               AS is_major_event_day,

  current_timestamp()                                                AS _ingested_at
FROM derived;
