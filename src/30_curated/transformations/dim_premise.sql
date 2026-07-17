-- Premise dimension. ~50K rows. Joins the FEMA-anchored premise
-- record with synthesized building characteristics. Adds the
-- ResStock-aligned building_subtype that AMI uses (Single-Family
-- Detached / Multi-Family / Mobile Home / Small/Medium/Large Office).
--
-- KEYS: premise_id is the durable BIGINT identity key (xxhash64 of the raw
-- premise string); premise_number is the human/natural key (the FEMA UUID).
-- NOTE: this dim carries native GEOMETRY columns (centroid_point,
-- footprint_polygon). A bare `GEOMETRY` type name in typed-column DDL
-- resolves to GEOMETRY(ANY), which cannot be persisted (SDP gotcha) — the
-- fix is to declare the explicit SRID actually stored, GEOMETRY(0), matching
-- the geometry(0) the SELECT produces (ST_GeomFromWKT/ST_Point-style results
-- carry no SRID). With every column typed, premise_id can be a declared PK.

CREATE OR REFRESH MATERIALIZED VIEW dim_premise (
  premise_id         BIGINT    NOT NULL PRIMARY KEY,
  premise_number     STRING    NOT NULL,
  occupancy_class    STRING,
  primary_occupancy  STRING,
  building_subtype   STRING,
  sqft               INT,
  year_built         INT,
  heating_fuel       STRING,
  envelope_quality   STRING,
  hvac_system_type   STRING,
  city               STRING,
  zip_code           STRING,
  county             STRING,
  county_fips        STRING,
  census_tract       STRING,
  latitude           DOUBLE,
  longitude          DOUBLE,
  centroid_point     GEOMETRY(0),
  footprint_polygon  GEOMETRY(0),
  climate_zone       STRING,
  sqft_band          STRING,
  _ingested_at       TIMESTAMP
)
COMMENT 'Premise dimension. One row per sampled FEMA building inside the utility service territory. Adds the ResStock-aligned building_subtype derivation that downstream AMI math uses. premise_id is the durable BIGINT key; premise_number is the FEMA UUID natural key. Carries native GEOMETRY (centroid_point/footprint_polygon), declared as GEOMETRY(0) to match the stored SRID.'
AS

SELECT
  abs(xxhash64(p.premise_id))                                             AS premise_id,
  p.premise_id                                                       AS premise_number,
  p.occupancy_class,
  p.primary_occupancy,

  -- Building subtype that aligns with ResStock building types.
  CASE
    WHEN p.occupancy_class = 'Residential' THEN
      CASE
        -- FEMA labels manufactured homes explicitly; a sqft threshold is NOT
        -- a valid proxy (footprint sqft sweeps dense-urban single-family
        -- houses into Mobile Home). Must stay in sync with the same CASE in
        -- raw_meter_readings.sql and dim_customer.sql.
        WHEN UPPER(p.primary_occupancy) LIKE '%MANUFACTURED%'
          OR UPPER(p.primary_occupancy) LIKE '%MOBILE%'                    THEN 'Mobile Home'
        WHEN UPPER(p.primary_occupancy) LIKE '%MULTI%'
          OR UPPER(p.primary_occupancy) LIKE '%APARTMENT%'                 THEN
          CASE WHEN p.sqft < 5000 THEN 'Multi-Family with 2 - 4 Units'
                                  ELSE 'Multi-Family with 5+ Units' END
        WHEN UPPER(p.primary_occupancy) LIKE '%TOWN%'
          OR UPPER(p.primary_occupancy) LIKE '%ROW%'
          OR UPPER(p.primary_occupancy) LIKE '%ATTACHED%'                  THEN 'Single-Family Attached'
        ELSE                                                                    'Single-Family Detached'
      END
    ELSE
      CASE
        WHEN p.sqft < 5000  THEN 'SmallOffice'
        WHEN p.sqft < 25000 THEN 'MediumOffice'
        ELSE                     'LargeOffice'
      END
  END                                                                AS building_subtype,

  p.sqft,
  p.year_built,
  p.heating_fuel,
  p.envelope_quality,
  p.hvac_system_type,
  p.city,
  p.zip_code,
  p.county,
  p.county_fips,
  p.census_tract,
  p.latitude,
  p.longitude,
  p.centroid_point,
  p.footprint_polygon,
  -- The demo territory is climate zone 5A. Hardcoded for now; if the demo
  -- ever pivots to a multi-zone utility this becomes a join to a
  -- climate_zone dim.
  '5A' AS climate_zone,
  -- sqft band for peer-group benchmarks.
  CASE
    WHEN p.sqft < 1000  THEN '<1000'
    WHEN p.sqft < 1500  THEN '1000-1499'
    WHEN p.sqft < 2000  THEN '1500-1999'
    WHEN p.sqft < 2500  THEN '2000-2499'
    WHEN p.sqft < 3500  THEN '2500-3499'
    WHEN p.sqft < 5000  THEN '3500-4999'
    WHEN p.sqft < 15000 THEN '5000-14999'
    ELSE                     '15000+'
  END                                                                AS sqft_band,
  current_timestamp() AS _ingested_at
FROM ${customer_master_schema}.raw_premises p;
