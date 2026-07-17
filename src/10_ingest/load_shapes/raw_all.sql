-- Pipeline-scoped view over ALL CSV files in the landing volume.
-- Files are NREL load profiles downloaded by 01_download.py.
-- ResStock (residential) and ComStock (commercial) share the same column schema.
-- Temporary view: no data stored. Downstream tables read source files directly.

CREATE TEMPORARY VIEW _all_raw
AS
SELECT
  *,
  _metadata.file_path AS _source_file,
  current_timestamp() AS _ingested_at
FROM read_files(
  '${load_shapes_volume_path}',
  format => 'csv',
  header => true
);
