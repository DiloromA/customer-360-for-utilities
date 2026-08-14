-- Service Point — CIM UsagePoint-aligned. One per premise_service_attrs, EXCEPT
-- large commercial buildings (Commercial, sqft >= 25,000), which get 2-5
-- sub-metered service_points sharing the same premise_service_attrs — separate
-- meters for different building zones/tenants, all still tied to the same account
--. n_service_points is carried through so consumers
-- that apportion a building-level quantity across its meters
-- (raw_meter_readings.sql's base load) know how many siblings to divide by.
--
-- Service voltage, amperage, and phase code derive from customer class
-- and building size. Smart-meter penetration is high (~99.5% in the
-- utility's service territory) — the small AMR fraction lets the demo show a "no-AMI"
-- contrast in the CSR view when needed. Size/smart-meter draws are seeded by
-- (service_location_id, meter_seq) so sub-metered siblings can differ from
-- each other instead of cloning one meter's specs N times.

CREATE OR REFRESH MATERIALIZED VIEW raw_service_point (
  CONSTRAINT non_null_service_point_id    EXPECT (service_point_id IS NOT NULL),
  CONSTRAINT non_null_service_location_id EXPECT (service_location_id IS NOT NULL),
  CONSTRAINT valid_phase_code             EXPECT (phase_code IN ('single_phase','three_phase'))
)
COMMENT 'Service Point — CIM UsagePoint (point of delivery). One per premise_service_attrs, except large commercial buildings (sqft >= 25,000) which get 2-5 sub-metered service_points sharing the same premise_service_attrs. Captures physical service-delivery point characteristics (voltage, amperage, phase) and AMI-enabled flag. n_service_points is the sibling count sharing this service_location (1 for the non-submetered case). PK: service_point_id. FK: service_location_id -> premise_service_attrs. CIM: UsagePoint.'
AS

WITH sized AS (
  SELECT
    sl.service_location_id,
    sl.premise_id,
    sl.service_class,
    p.sqft,
    -- Large commercial premises get 2-5 sub-metered service_points; everyone
    -- else stays at exactly 1.
    CASE
      WHEN sl.service_class = 'Commercial' AND p.sqft >= 25000
        THEN 2 + CAST(abs(xxhash64(sl.service_location_id, 'n_service_points', ${random_seed})) % 4 AS INT)
      ELSE 1
    END AS n_service_points
  FROM raw_premise_service_attrs sl
  JOIN raw_premises p ON sl.premise_id = p.premise_id
),

exploded AS (
  SELECT sized.*, meter_seq
  FROM sized
  LATERAL VIEW explode(sequence(1, n_service_points)) AS meter_seq
),

base AS (
  SELECT
    service_location_id,
    premise_id,
    service_class,
    sqft,
    n_service_points,
    meter_seq,
    abs(xxhash64(service_location_id, meter_seq, 'service_size', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_size,
    abs(xxhash64(service_location_id, meter_seq, 'smart_meter',  ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_smart
  FROM exploded
)

SELECT
  -- Hash seed '_usage_point_' is intentionally preserved — changing it would
  -- re-key every downstream surrogate that derives from this id.
  md5(CONCAT(service_location_id, '_usage_point_', meter_seq)) AS service_point_id,
  service_location_id,
  premise_id,
  n_service_points,

  -- Usage point type. Single-meter residential is the dominant case;
  -- commercial gets a small / large variant by sqft.
  CASE
    WHEN service_class = 'Residential' THEN 'residential_single_meter'
    WHEN service_class = 'Commercial' AND sqft >= 15000 THEN 'commercial_large'
    WHEN service_class = 'Commercial'                   THEN 'commercial_small'
    ELSE 'other'
  END                                                              AS service_point_type,

  -- Phase code. Residential is single-phase (240V split-phase US standard);
  -- commercial is three-phase for anything > ~8000 sqft.
  CASE
    WHEN service_class = 'Residential' THEN 'single_phase'
    WHEN service_class = 'Commercial' AND sqft >= 8000 THEN 'three_phase'
    WHEN service_class = 'Commercial'                   THEN 'single_phase'
    ELSE 'single_phase'
  END                                                              AS phase_code,

  -- Nominal service voltage at the meter.
  CASE
    WHEN service_class = 'Residential' THEN 240
    WHEN service_class = 'Commercial' AND sqft >= 15000 THEN 480
    WHEN service_class = 'Commercial' AND sqft >= 8000  THEN 240
    WHEN service_class = 'Commercial'                   THEN 240
    ELSE 240
  END                                                              AS nominal_service_voltage,

  -- Amperage service size. Residential typical: 100A older / 150A mid /
  -- 200A newer; commercial larger.
  CASE
    WHEN service_class = 'Residential' THEN
      CASE
        WHEN r_size < 0.20 THEN 100   -- older homes, often pre-1980
        WHEN r_size < 0.55 THEN 150
        WHEN r_size < 0.95 THEN 200
        ELSE                    400   -- large homes / EV-ready upgrades
      END
    WHEN service_class = 'Commercial' AND sqft >= 30000 THEN 1200
    WHEN service_class = 'Commercial' AND sqft >= 15000 THEN  800
    WHEN service_class = 'Commercial' AND sqft >= 8000  THEN  400
    WHEN service_class = 'Commercial'                    THEN  200
    ELSE 200
  END                                                              AS amperage_service_size,

  -- Smart-meter flag — the utility deployed AMI broadly by 2017 (~99.5% by 2018).
  -- The 0.5% AMR fraction is the demo's "legacy meter" cohort.
  r_smart < 0.995                                                  AS is_smart_meter,

  current_timestamp()                                              AS _ingested_at
FROM base;
