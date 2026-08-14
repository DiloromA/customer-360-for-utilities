-- Premises — FEMA-anchored, filtered to the utility's service territory by county_fips,
-- contiguous-saturation-sampled, enriched with synthesized building characteristics
-- used by the AMI load-shape stack.
--
-- Pipeline stages:
--   1. county_prefilter: cheap FIPS filter on county_fips IN the target set.
--      Default is the Detroit tri-county metro core (Wayne, Oakland, Macomb).
--      Whole-county membership is a >80% accurate approximation of the actual
--      service-territory polygon; this trade-off is accepted vs the cost of a
--      3M-row ST_INTERSECTS spatial join.
--   2. contiguous_saturation_sample: rank census tracts by distance from a
--      seed point (seed_lat/seed_lon), accumulate tracts nearest-first until
--      cumulative buildings reach customer_sample_size, then take EVERY
--      eligible building in the selected tracts (trimming only the last,
--      boundary tract via hash order to land on the target count). This
--      renders as one dense, contiguous blob around the seed rather than
--      scattered dots — the seed defaults to the Detroit/Oakland county line
--      near the 8 Mile corridor, so the blob spans both urban and suburban
--      fabric. Residential/commercial mix falls out naturally per tract
--      rather than being held to a fixed proportion.
--   3. enriched: synthesize building characteristics that FEMA doesn't
--      carry (year_built, heating_fuel, envelope_quality, hvac_type),
--      plus sqft fallback for FEMA nulls.
--
-- All randomness derives from hash(building_id, '<purpose>', ${random_seed})
-- so re-runs are deterministic. Different ${random_seed} -> different cohort.

CREATE OR REFRESH MATERIALIZED VIEW raw_premises (
  CONSTRAINT non_null_premise_id EXPECT (premise_id IS NOT NULL),
  CONSTRAINT canonical_premise_id EXPECT (premise_id NOT LIKE '{%}' AND premise_id = LOWER(premise_id)),
  CONSTRAINT non_null_county_fips EXPECT (county_fips IS NOT NULL),
  CONSTRAINT realistic_sqft EXPECT (sqft BETWEEN 200 AND 200000),
  CONSTRAINT valid_year_built EXPECT (year_built BETWEEN 1850 AND 2024)
)
COMMENT 'Premises — FEMA building footprints inside the utility''s service territory (default: the Detroit tri-county metro core — Wayne, Oakland, Macomb), contiguous-saturation-sampled around a seed point (default: the 8 Mile corridor, spanning urban Detroit + suburban fabric) so the footprint renders as one dense served area rather than scattered dots, enriched with synthesized building characteristics for AMI load-shape stacking. PK: premise_id (canonical unbraced lowercase UUID). source_building_id preserves the FEMA source value for lineage. FK: county_fips -> raw_counties.GEOID. Source: curated_buildings.buildings (FEMA USA Structures) + synthesized vintage/fuel/envelope/HVAC. Row count configurable via customer_sample_size (default 1,000); footprint via target_geoids + seed_lat/seed_lon.'
AS

WITH

-- 1. County-FIPS prefilter — keeps ~3M SE Michigan rows from ~125M total.
--    Drops obvious outliers (sqft < 200 = outbuildings/sheds) and buildings
--    without coordinates (needed for the seed-distance ranking below).
in_territory AS (
  SELECT
    building_id,
    occupancy_class,
    primary_occupancy,
    sqft,
    city,
    zip_code,
    county,
    county_fips,
    census_tract,
    latitude,
    longitude,
    centroid_point,
    footprint_polygon
  FROM ${buildings_table}
  WHERE ARRAY_CONTAINS(SPLIT('${target_geoids}', ','), county_fips)
    AND occupancy_class IN ('Residential', 'Commercial')
    AND (sqft IS NULL OR sqft >= 200)
    AND latitude IS NOT NULL
    AND longitude IS NOT NULL
),

-- 2. Rank census tracts by distance from the seed point (longitude scaled by
--    cos(seed_lat) so the metro-scale distance isn't skewed by latitude).
--    A stable tiebreaker (census_tract) keeps the ordering deterministic.
tract_stats AS (
  SELECT
    census_tract,
    AVG(latitude)  AS tract_lat,
    AVG(longitude) AS tract_lon,
    COUNT(*)       AS tract_building_count
  FROM in_territory
  GROUP BY census_tract
),
tract_ordered AS (
  SELECT
    *,
    SQRT(
      POWER(tract_lat - ${seed_lat}, 2) +
      POWER((tract_lon - ${seed_lon}) * COS(RADIANS(${seed_lat})), 2)
    ) AS dist_from_seed
  FROM tract_stats
),
tract_ranked AS (
  SELECT
    *,
    SUM(tract_building_count) OVER (
      ORDER BY dist_from_seed, census_tract
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) - tract_building_count AS cumulative_before
  FROM tract_ordered
),

-- 3. Select tracts nearest-first until the running total reaches
--    customer_sample_size. is_boundary_tract marks the one tract that
--    pushes the total over the target, so it can be trimmed below.
selected_tracts AS (
  SELECT
    census_tract,
    cumulative_before,
    tract_building_count,
    (cumulative_before + tract_building_count > CAST(${customer_sample_size} AS DOUBLE)) AS is_boundary_tract
  FROM tract_ranked
  WHERE cumulative_before < CAST(${customer_sample_size} AS DOUBLE)
),

-- 4. Take every building in the selected tracts, except the boundary tract
--    where only the top-ranked (by hash) buildings needed to hit the target
--    are kept.
stratified AS (
  SELECT
    i.*,
    st.cumulative_before,
    st.is_boundary_tract,
    ROW_NUMBER() OVER (
      PARTITION BY i.census_tract
      ORDER BY abs(xxhash64(i.building_id, 'sample', ${random_seed}))
    ) AS within_tract_rank
  FROM in_territory i
  JOIN selected_tracts st ON i.census_tract = st.census_tract
),
sampled AS (
  SELECT * EXCEPT (cumulative_before, is_boundary_tract, within_tract_rank)
  FROM stratified
  WHERE NOT is_boundary_tract
     OR within_tract_rank <= (CAST(${customer_sample_size} AS DOUBLE) - cumulative_before)
),

-- 5. Enrich with synthesized building characteristics.
--    All hash-derived; r_* are deterministic uniform [0, 1) draws.
enriched AS (
  SELECT
    s.*,
    -- Independent uniform random draws per purpose
    abs(xxhash64(building_id, 'vintage',  ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_vintage,
    abs(xxhash64(building_id, 'fuel',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_fuel,
    abs(xxhash64(building_id, 'envelope', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_envelope,
    abs(xxhash64(building_id, 'hvac',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_hvac,
    abs(xxhash64(building_id, 'sqft',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_sqft
  FROM sampled s
)

SELECT
  -- FEMA supplies UUIDs in braced form {xxxxxxxx-xxxx-...}; strip braces and
  -- lowercase defensively to produce a clean canonical natural key.
  -- source_building_id preserves the raw value for lineage.
  building_id                                                      AS source_building_id,
  LOWER(REGEXP_REPLACE(building_id, '^\\{|\\}$', ''))              AS premise_id,
  occupancy_class,
  primary_occupancy,

  -- sqft fallback. FEMA sqft is mostly present but has nulls and a long tail
  -- of obviously-wrong values. Use FEMA when in (300, 50000); otherwise
  -- synthesize a plausible value from the occupancy_class.
  CAST(
    CASE
      WHEN sqft IS NULL OR sqft < 300 OR sqft > 50000 THEN
        CASE occupancy_class
          WHEN 'Residential' THEN 900  + r_sqft * 2200   -- ~900-3100 sqft typical SF
          WHEN 'Commercial'  THEN 1500 + r_sqft * 18500  -- ~1500-20000 sqft small biz
          ELSE                       1000 + r_sqft * 4000
        END
      ELSE sqft
    END AS INT)                                                    AS sqft,

  -- Year built: MI vintage weighting -- pre-1940 (15%), 1940-1969 (25%),
  -- 1970-1989 (25%), 1990-2009 (20%), 2010+ (15%).
  CAST(
    CASE
      WHEN r_vintage < 0.15 THEN 1900 + r_vintage / 0.15 * 40
      WHEN r_vintage < 0.40 THEN 1940 + (r_vintage - 0.15) / 0.25 * 30
      WHEN r_vintage < 0.65 THEN 1970 + (r_vintage - 0.40) / 0.25 * 20
      WHEN r_vintage < 0.85 THEN 1990 + (r_vintage - 0.65) / 0.20 * 20
      ELSE                       2010 + (r_vintage - 0.85) / 0.15 * 14
    END AS INT)                                                    AS year_built,

  -- Heating fuel: MI distribution (per ACS heating fuel tables): natural gas
  -- ~75%, electricity ~15%, propane/LP ~5%, fuel oil ~5%. Commercial skews
  -- slightly more to gas (~85%).
  CASE
    WHEN occupancy_class = 'Commercial' THEN
      CASE
        WHEN r_fuel < 0.85 THEN 'natural_gas'
        WHEN r_fuel < 0.95 THEN 'electricity'
        ELSE                    'propane'
      END
    ELSE
      CASE
        WHEN r_fuel < 0.75 THEN 'natural_gas'
        WHEN r_fuel < 0.90 THEN 'electricity'
        WHEN r_fuel < 0.95 THEN 'propane'
        ELSE                    'fuel_oil'
      END
  END                                                              AS heating_fuel,

  -- Envelope quality: rough proxy for insulation + air-sealing + window quality.
  -- Newer homes skew better; we encode that by mixing year_built into the draw.
  -- low / medium / high
  CASE
    WHEN r_envelope + (CASE
        WHEN r_vintage > 0.85 THEN 0.30   -- post-2010
        WHEN r_vintage > 0.65 THEN 0.15   -- 1990-2009
        WHEN r_vintage > 0.40 THEN 0.00   -- 1970-1989
        ELSE                       -0.15  -- pre-1970
      END) < 0.25 THEN 'low'
    WHEN r_envelope + (CASE
        WHEN r_vintage > 0.85 THEN 0.30
        WHEN r_vintage > 0.65 THEN 0.15
        WHEN r_vintage > 0.40 THEN 0.00
        ELSE                       -0.15
      END) < 0.70 THEN 'medium'
    ELSE 'high'
  END                                                              AS envelope_quality,

  -- HVAC system type. MI has high central-AC penetration in newer homes
  -- (~85% post-1990), window-only in older small homes.
  CASE
    WHEN occupancy_class = 'Commercial' THEN 'rooftop_unit'
    WHEN r_vintage > 0.65 AND r_hvac < 0.92 THEN 'central_ac'
    WHEN r_hvac < 0.55                       THEN 'central_ac'
    WHEN r_hvac < 0.88                       THEN 'window_units'
    ELSE                                          'no_cooling'
  END                                                              AS hvac_system_type,

  -- Pass-through location attributes
  city,
  zip_code,
  county,
  county_fips,
  census_tract,
  latitude,
  longitude,
  centroid_point,
  footprint_polygon,

  current_timestamp()                                              AS _ingested_at
FROM enriched;
