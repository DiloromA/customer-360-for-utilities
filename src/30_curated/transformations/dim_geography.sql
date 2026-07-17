-- Geography dimension. One row per (county_fips, census_tract) pair
-- in the demo population. Adds county-level attrs from TIGER + the
-- service-territory + climate-zone constants. (The utility display name is
-- a neutral placeholder here; it is centralized in the app's dim_utility
-- config row.)

CREATE OR REFRESH MATERIALIZED VIEW dim_geography
COMMENT 'Geography dimension. One row per (county_fips, census_tract). PK: census_tract.'
AS

WITH base AS (
  SELECT DISTINCT
    census_tract,
    county_fips,
    county,
    city,
    zip_code
  FROM ${customer_master_schema}.raw_premises
)

SELECT
  b.census_tract                                                     AS tract_id,
  b.county_fips,
  b.county                                                            AS county_name,
  b.city                                                              AS primary_city,
  b.zip_code                                                          AS primary_zip,
  -- TIGER metadata.
  tc.NAMELSAD                                                         AS county_name_lsad,
  tc.ALAND                                                            AS county_land_sqm,
  tc.AWATER                                                           AS county_water_sqm,
  -- Operating constants for the service territory (utility display name is
  -- a neutral placeholder; the branded name lands via dim_utility).
  'Electric Utility'                                                  AS utility_name,
  'MI'                                                                AS state_code,
  '5A'                                                                AS climate_zone,
  current_timestamp()                                                 AS _ingested_at
FROM base b
LEFT JOIN ${tiger_counties_schema}.raw_counties tc ON tc.GEOID = b.county_fips;
