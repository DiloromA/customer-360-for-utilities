-- FEMA/ORNL USA Structures raw landing.
-- Reads the per-state parquet files written by 01_download_state.py.
-- Schema is identical across states, so a single MV with read_files works.
--
-- Geometry is kept as the WKB binary blob produced by pyogrio. The curated
-- layer materializes it as a native GEOMETRY via ST_GEOMFROMWKB.

CREATE OR REFRESH MATERIALIZED VIEW raw_buildings (
  CONSTRAINT non_null_uuid EXPECT (UUID IS NOT NULL),
  CONSTRAINT valid_latitude EXPECT (
    LATITUDE IS NULL OR LATITUDE BETWEEN -90 AND 90
  ),
  CONSTRAINT valid_longitude EXPECT (
    LONGITUDE IS NULL OR LONGITUDE BETWEEN -180 AND 180
  )
)
COMMENT 'Raw FEMA/ORNL USA Structures landing — building footprints with occupancy classification, county-filtered at download time to target_geoids (~1.55M rows for the default Detroit tri-county scope; the source dataset is ~125M US building footprints nationally). One parquet file per state/territory under the landing volume. Source: s3://fema-femadata/Partners/ORNL/USA_Structures/ (CC BY 4.0).'
AS
SELECT
  *,
  _metadata.file_path AS _source_file,
  current_timestamp() AS _ingested_at
FROM read_files(
  '${buildings_volume_path}',
  format => 'parquet'
);
