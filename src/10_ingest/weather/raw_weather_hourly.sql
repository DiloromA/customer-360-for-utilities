-- NREL End-Use Load Profiles AMY2018 weather — raw landing for the demo
-- territory. Reads per-county CSVs written by 01_download.py, keyless via
-- the public OEDI S3 bucket (same source the load-shape download reads).
--
-- Source: https://data.openei.org/submissions/4520 (End-Use Load Profiles for
-- the U.S. Building Stock), AMY2018 weather files. Public, no API key.
--
-- Timestamp convention (deliberate, do not "fix"): `date_time` is local
-- standard time with no UTC offset in the file. The AMY load-shape hours in
-- raw_meter_readings are ALSO local standard time, merely labeled 'UTC' by
-- MAKE_TIMESTAMP(..., 'UTC'). We parse date_time as-is with no timezone
-- conversion and name the column timestamp_utc to match that existing (fake-
-- UTC, actually-LST) convention, so weather and load share one clock and
-- solar noon lines up with load noon.

CREATE OR REFRESH MATERIALIZED VIEW raw_weather_hourly (
  CONSTRAINT non_null_geoid EXPECT (geoid IS NOT NULL),
  CONSTRAINT non_null_timestamp EXPECT (timestamp_utc IS NOT NULL),
  CONSTRAINT non_negative_ghi EXPECT (ghi_w_m2 IS NULL OR ghi_w_m2 >= 0)
)
COMMENT 'NREL End-Use Load Profiles AMY2018 weather (OEDI public S3, keyless). One row per (geoid, timestamp_utc) hourly. PK: (geoid, timestamp_utc). timestamp_utc is actually local standard time (see header note) to stay clock-aligned with raw_meter_readings AMY hours. Source: https://data.openei.org/submissions/4520.'
AS
SELECT
  -- GISJOIN filename encoding: G + 2-digit state FIPS + 0 + 3-digit county
  -- FIPS + 0, e.g. G2601630 -> geoid 26163.
  CONCAT(
    REGEXP_EXTRACT(_metadata.file_path, 'G(\\d{2})0(\\d{3})0_', 1),
    REGEXP_EXTRACT(_metadata.file_path, 'G(\\d{2})0(\\d{3})0_', 2)
  )                                                AS geoid,
  CAST(date_time AS TIMESTAMP)                     AS timestamp_utc,
  CAST(`Dry Bulb Temperature [°C]` AS DOUBLE)       AS temperature_c,
  CAST(`Global Horizontal Radiation [W/m2]` AS DOUBLE)  AS ghi_w_m2,
  CAST(`Direct Normal Radiation [W/m2]` AS DOUBLE)      AS dni_w_m2,
  CAST(`Diffuse Horizontal Radiation [W/m2]` AS DOUBLE) AS dhi_w_m2,
  CAST(`Relative Humidity [%]` AS DOUBLE)           AS relative_humidity_pct,
  CAST(`Wind Speed [m/s]` AS DOUBLE)                AS wind_speed_m_s,
  _metadata.file_path                               AS _source_file,
  current_timestamp()                               AS _ingested_at
FROM read_files(
  '${weather_volume_path}',
  format => 'csv',
  header => true
);
