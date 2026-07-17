-- Census TIGER/Line county boundaries — raw landing for the demo territory.
-- Reads parquet files written by 01_download_tiger.py (one per state run).
-- Geometry is preserved as WKB binary by pyogrio; the curated/synth layer
-- materializes it as a native GEOMETRY via ST_GEOMFROMWKB when needed.
--
-- Source: Census Bureau TIGER/Line (public domain).
-- URL pattern: https://www2.census.gov/geo/tiger/TIGER<year>/COUNTY/
--
-- CRS: NAD83 (EPSG:4269). Differs from WGS84 (EPSG:4326) by <1 m for the
-- conterminous US — acceptable for clipping FEMA building centroids.

CREATE OR REFRESH MATERIALIZED VIEW raw_counties (
  CONSTRAINT non_null_geoid EXPECT (GEOID IS NOT NULL),
  CONSTRAINT five_digit_geoid EXPECT (LENGTH(GEOID) = 5),
  CONSTRAINT non_null_name EXPECT (NAME IS NOT NULL)
)
COMMENT 'Raw Census TIGER/Line county boundaries — one row per county for the loaded state(s). Geometry is WKB binary in NAD83 (EPSG:4269); use ST_GEOMFROMWKB to materialize as GEOMETRY. PK: GEOID (state FIPS + county FIPS). Source: https://www2.census.gov/geo/tiger/.'
AS
SELECT
  STATEFP,
  COUNTYFP,
  GEOID,
  NAME,
  NAMELSAD,
  LSAD,
  CAST(ALAND AS BIGINT)      AS ALAND,
  CAST(AWATER AS BIGINT)     AS AWATER,
  CAST(INTPTLAT AS DOUBLE)   AS INTPTLAT,
  CAST(INTPTLON AS DOUBLE)   AS INTPTLON,
  -- Geometry stays as raw WKB bytes; downstream callers run ST_GEOMFROMWKB.
  -- Column is named `wkb_geometry` by pyogrio's Arrow output.
  wkb_geometry               AS wkb_geometry,
  _metadata.file_path        AS _source_file,
  current_timestamp()        AS _ingested_at
FROM read_files(
  '${volume_path}',
  format => 'parquet'
);
