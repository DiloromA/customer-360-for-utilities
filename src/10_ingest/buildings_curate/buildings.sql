-- Curated buildings domain.
-- Reshapes raw FEMA/ORNL USA Structures into a stable, demo-friendly
-- contract: snake_case columns, two-letter state codes, native GEOMETRY
-- types, and explicit null-out of records with non-WGS84 coordinates.

CREATE OR REFRESH MATERIALIZED VIEW curated_buildings (
  CONSTRAINT non_null_building_id EXPECT (building_id IS NOT NULL),
  CONSTRAINT non_null_state_code EXPECT (state_code IS NOT NULL),
  CONSTRAINT valid_centroid EXPECT (
    centroid_point IS NULL
    OR (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)
  )
)
COMMENT 'Curated FEMA/ORNL USA Structures — buildings with occupancy classification, footprint geometry, and centroid point, county-filtered at download time to target_geoids (~1.55M rows for the default Detroit tri-county scope; the source dataset is ~125M US buildings nationally). Two-letter state codes; latitude/longitude in WGS84. PK: building_id. Source: raw_buildings.'
AS
SELECT
  UUID                                    AS building_id,
  OCC_CLS                                 AS occupancy_class,
  PRIM_OCC                                AS primary_occupancy,
  PROP_ADDR                               AS address,
  PROP_CITY                               AS city,

  -- Two-letter state/territory code mapped from the FEMA full-name field.
  -- Falls back to the source value when no mapping matches (defensive only;
  -- the FEMA dataset uses the names listed below).
  CASE PROP_ST
    WHEN 'Alabama'                       THEN 'AL'
    WHEN 'Alaska'                        THEN 'AK'
    WHEN 'Arizona'                       THEN 'AZ'
    WHEN 'Arkansas'                      THEN 'AR'
    WHEN 'California'                    THEN 'CA'
    WHEN 'Colorado'                      THEN 'CO'
    WHEN 'Connecticut'                   THEN 'CT'
    WHEN 'Delaware'                      THEN 'DE'
    WHEN 'District of Columbia'          THEN 'DC'
    WHEN 'Florida'                       THEN 'FL'
    WHEN 'Georgia'                       THEN 'GA'
    WHEN 'Hawaii'                        THEN 'HI'
    WHEN 'Idaho'                         THEN 'ID'
    WHEN 'Illinois'                      THEN 'IL'
    WHEN 'Indiana'                       THEN 'IN'
    WHEN 'Iowa'                          THEN 'IA'
    WHEN 'Kansas'                        THEN 'KS'
    WHEN 'Kentucky'                      THEN 'KY'
    WHEN 'Louisiana'                     THEN 'LA'
    WHEN 'Maine'                         THEN 'ME'
    WHEN 'Maryland'                      THEN 'MD'
    WHEN 'Massachusetts'                 THEN 'MA'
    WHEN 'Michigan'                      THEN 'MI'
    WHEN 'Minnesota'                     THEN 'MN'
    WHEN 'Mississippi'                   THEN 'MS'
    WHEN 'Missouri'                      THEN 'MO'
    WHEN 'Montana'                       THEN 'MT'
    WHEN 'Nebraska'                      THEN 'NE'
    WHEN 'Nevada'                        THEN 'NV'
    WHEN 'New Hampshire'                 THEN 'NH'
    WHEN 'New Jersey'                    THEN 'NJ'
    WHEN 'New Mexico'                    THEN 'NM'
    WHEN 'New York'                      THEN 'NY'
    WHEN 'North Carolina'                THEN 'NC'
    WHEN 'North Dakota'                  THEN 'ND'
    WHEN 'Ohio'                          THEN 'OH'
    WHEN 'Oklahoma'                      THEN 'OK'
    WHEN 'Oregon'                        THEN 'OR'
    WHEN 'Pennsylvania'                  THEN 'PA'
    WHEN 'Rhode Island'                  THEN 'RI'
    WHEN 'South Carolina'                THEN 'SC'
    WHEN 'South Dakota'                  THEN 'SD'
    WHEN 'Tennessee'                     THEN 'TN'
    WHEN 'Texas'                         THEN 'TX'
    WHEN 'Utah'                          THEN 'UT'
    WHEN 'Vermont'                       THEN 'VT'
    WHEN 'Virginia'                      THEN 'VA'
    WHEN 'Washington'                    THEN 'WA'
    WHEN 'West Virginia'                 THEN 'WV'
    WHEN 'Wisconsin'                     THEN 'WI'
    WHEN 'Wyoming'                       THEN 'WY'
    WHEN 'American Samoa'                THEN 'AS'
    WHEN 'Guam'                          THEN 'GU'
    WHEN 'Northern Mariana Islands'      THEN 'MP'
    WHEN 'Puerto Rico'                   THEN 'PR'
    WHEN 'US Virgin Islands'             THEN 'VI'
    WHEN 'United States Virgin Islands'  THEN 'VI'
    ELSE PROP_ST
  END                                    AS state_code,

  PROP_ZIP                                AS zip_code,
  PROP_CNTY                               AS county,
  FIPS                                    AS county_fips,

  -- A small fraction of source rows ship State Plane coordinates rather
  -- than WGS84; null those out so they don't poison downstream joins.
  CASE WHEN LATITUDE BETWEEN -90 AND 90 THEN CAST(LATITUDE AS DOUBLE) END
                                          AS latitude,
  CASE WHEN LONGITUDE BETWEEN -180 AND 180 THEN CAST(LONGITUDE AS DOUBLE) END
                                          AS longitude,

  SQFEET                                  AS sqft,
  SQMETERS                                AS sqm,
  HEIGHT                                  AS height_m,
  POP_MEDIAN                              AS pop_median,
  CENSUSCODE                              AS census_tract,

  -- Native GEOMETRY columns. ST_POINT skips rows with out-of-range coords
  -- by virtue of the CASE WHEN guard above.
  ST_POINT(
    CASE WHEN LONGITUDE BETWEEN -180 AND 180 THEN CAST(LONGITUDE AS DOUBLE) END,
    CASE WHEN LATITUDE BETWEEN -90 AND 90 THEN CAST(LATITUDE AS DOUBLE) END
  )                                       AS centroid_point,
  ST_GEOMFROMWKB(Shape)                   AS footprint_polygon,

  CAST('fema_usa_structures' AS STRING)   AS source_dataset,
  _ingested_at                            AS ingested_at

FROM ${raw_schema}.raw_buildings;
