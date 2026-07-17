-- End Device Asset — CIM EndDeviceAsset, specifically the meter. Realistic
-- utility meter fleet: Itron and Landis+Gyr dominate the AMI fleet; older AMR meters
-- (Sensus, Honeywell, GE) round it out.
--
-- install_date is anchored to service_location.in_service_date with a
-- meter-replacement jitter — the utility's AMI rollout completed around 2014, so smart
-- meters generally install in 2010-2018 even if the service itself goes back
-- further.
--
-- METER SWAPS (hierarchy nuance): most usage_points have ONE meter that is
-- never removed. A ~7% cohort of older smart meters (installed before 2017)
-- is SWAPPED during the 2017-2018 window — the original meter is marked
-- 'replaced' and a second, newer meter asset is emitted for the same
-- usage_point. This is what makes the usage_point ↔ meter relationship
-- many-to-one OVER TIME, modeled explicitly by meter_installation. The swap
-- cohort is deterministic via hash(usage_point_id, 'meter_swap', seed), so the
-- two emitters (this table and meter_installation) agree without shared state.

CREATE OR REFRESH MATERIALIZED VIEW raw_end_device_asset (
  CONSTRAINT non_null_end_device_asset_id EXPECT (end_device_asset_id IS NOT NULL),
  CONSTRAINT non_null_usage_point_id      EXPECT (usage_point_id IS NOT NULL),
  CONSTRAINT non_null_serial_number       EXPECT (serial_number IS NOT NULL)
)
COMMENT 'End Device Asset — CIM EndDeviceAsset (Meter). One or more physical meters per usage_point: every usage_point has an original meter, and a ~7% cohort of pre-2017 smart meters also has a replacement meter installed during the 2017-2018 swap window (original then has status=replaced). Realistic utility fleet manufacturer mix (Itron / Landis+Gyr / Sensus / Honeywell / GE). meter_seq orders meters at a usage_point (1=original, 2=replacement); meter_installation turns these into an effective-dated bridge. PK: end_device_asset_id. FK: usage_point_id -> usage_point.'
AS

WITH base AS (
  SELECT
    up.usage_point_id,
    up.service_location_id,
    up.is_smart_meter,
    up.amperage_service_size,
    sl.in_service_date,
    abs(xxhash64(up.usage_point_id, 'manufacturer', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_mfg,
    abs(xxhash64(up.usage_point_id, 'install',      ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_install,
    abs(xxhash64(up.usage_point_id, 'serial',       ${random_seed}))                                       AS r_serial
  FROM raw_usage_point up
  JOIN raw_service_location sl ON up.service_location_id = sl.service_location_id
),

-- Original meter attributes (one per usage_point), plus the swap decision.
meters AS (
  SELECT
    usage_point_id,
    is_smart_meter,
    amperage_service_size,
    r_mfg,
    r_install,
    r_serial,

    -- Install date. Smart-meter rollout was 2010-2018 in the utility's service territory; anchor
    -- to in_service_date but clamp into the AMI window when smart. AMR meters
    -- can be much older — bounded to in_service_date.
    CASE
      WHEN is_smart_meter THEN
        DATE_ADD(GREATEST(in_service_date, MAKE_DATE(2010, 1, 1)), CAST(r_install * 365 * 8 AS INT))
      ELSE
        DATE_ADD(in_service_date, CAST(r_install * 365 * 15 AS INT))
    END                                                            AS install_date,

    -- Swap cohort: ~7% of smart meters installed before 2017 get rotated in
    -- the 2017-2018 window. Constraining to pre-2017 installs guarantees the
    -- swap_date is strictly after the original install_date.
    abs(xxhash64(usage_point_id, 'meter_swap', ${random_seed})) % 100         AS swap_pct,
    DATE_ADD(MAKE_DATE(2017, 1, 1),
             CAST(abs(xxhash64(usage_point_id, 'swap_date', ${random_seed})) % 730 AS INT)) AS swap_date
  FROM base
),

flagged AS (
  SELECT
    *,
    (is_smart_meter AND install_date < DATE'2017-01-01' AND swap_pct < 7) AS will_swap
  FROM meters
),

-- ── Original meter (meter_seq = 1) ───────────────────────────────────────────
originals AS (
  SELECT
    md5(CONCAT(usage_point_id, '_meter'))            AS end_device_asset_id,
    usage_point_id,
    1                                                AS meter_seq,
    false                                            AS is_replacement,

    CONCAT(
      CASE
        WHEN NOT is_smart_meter THEN '900'
        WHEN r_mfg < 0.45 THEN '147'   -- Itron
        WHEN r_mfg < 0.80 THEN '258'   -- Landis+Gyr
        WHEN r_mfg < 0.92 THEN '369'   -- Honeywell (Elster)
        WHEN r_mfg < 0.97 THEN '482'   -- Sensus
        ELSE                   '593'   -- GE
      END,
      LPAD(CAST(abs(r_serial) % 10000000 AS STRING), 7, '0')
    )                                                AS serial_number,

    CASE
      WHEN NOT is_smart_meter THEN
        CASE WHEN r_mfg < 0.50 THEN 'Sensus' WHEN r_mfg < 0.85 THEN 'Honeywell' ELSE 'GE' END
      WHEN r_mfg < 0.45 THEN 'Itron'
      WHEN r_mfg < 0.80 THEN 'Landis+Gyr'
      WHEN r_mfg < 0.92 THEN 'Honeywell'
      WHEN r_mfg < 0.97 THEN 'Sensus'
      ELSE                   'GE'
    END                                              AS manufacturer,

    CASE
      WHEN NOT is_smart_meter THEN
        CASE WHEN r_mfg < 0.50 THEN 'iCon A' WHEN r_mfg < 0.85 THEN 'Elster A1700' ELSE 'GE I-210+' END
      WHEN r_mfg < 0.45 THEN
        CASE WHEN amperage_service_size >= 400 THEN 'Itron OpenWay CENTRON C2SX' ELSE 'Itron OpenWay CENTRON' END
      WHEN r_mfg < 0.80 THEN 'Landis+Gyr Focus AXR-SD'
      WHEN r_mfg < 0.92 THEN 'Honeywell A3 ALPHA'
      WHEN r_mfg < 0.97 THEN 'Sensus iConA G3'
      ELSE                   'GE I-210+c'
    END                                              AS model_number,

    install_date,

    CASE
      WHEN NOT is_smart_meter THEN 'none_amr_walk_by'
      WHEN r_mfg < 0.45 THEN       'rf_mesh_openway'
      WHEN r_mfg < 0.80 THEN       'rf_mesh_gridstream'
      WHEN r_mfg < 0.94 THEN       'rf_mesh_other'
      ELSE                         'cellular'
    END                                              AS communication_protocol,

    CASE
      WHEN NOT is_smart_meter THEN CAST(NULL AS STRING)
      ELSE CONCAT(
        CAST(3 + (CAST(r_install * 100 AS INT) % 4) AS STRING), '.',
        CAST((CAST(r_install * 1000 AS INT) % 10) AS STRING), '.',
        CAST((CAST(r_install * 10000 AS INT) % 20) AS STRING)
      )
    END                                              AS firmware_version,

    -- Swap-cohort originals are 'replaced'; everything else 'active'.
    CASE WHEN will_swap THEN 'replaced' ELSE 'active' END AS status
  FROM flagged
),

-- ── Replacement meter (meter_seq = 2), swap cohort only ──────────────────────
-- A newer AMI meter installed at swap_date. Manufacturer/serial differ from
-- the original via a distinct hash purpose ('_meter_2'); always a smart meter.
replacements AS (
  SELECT
    md5(CONCAT(usage_point_id, '_meter_2'))          AS end_device_asset_id,
    usage_point_id,
    2                                                AS meter_seq,
    true                                             AS is_replacement,

    CONCAT(
      CASE WHEN r_mfg < 0.55 THEN '147' ELSE '258' END,   -- Itron / Landis+Gyr
      LPAD(CAST(abs(xxhash64(usage_point_id, 'serial_2', ${random_seed})) % 10000000 AS STRING), 7, '0')
    )                                                AS serial_number,

    CASE WHEN r_mfg < 0.55 THEN 'Itron' ELSE 'Landis+Gyr' END AS manufacturer,

    CASE
      WHEN r_mfg < 0.55 THEN
        CASE WHEN amperage_service_size >= 400 THEN 'Itron OpenWay Riva C2SX' ELSE 'Itron OpenWay Riva' END
      ELSE 'Landis+Gyr Revelo'
    END                                              AS model_number,

    swap_date                                        AS install_date,
    CASE WHEN r_mfg < 0.55 THEN 'rf_mesh_openway' ELSE 'rf_mesh_gridstream' END AS communication_protocol,

    -- Newer firmware (major version 5/6) reflecting the recent install.
    CONCAT(
      CAST(5 + (CAST(r_install * 100 AS INT) % 2) AS STRING), '.',
      CAST((CAST(r_install * 1000 AS INT) % 10) AS STRING), '.',
      CAST((CAST(r_install * 10000 AS INT) % 20) AS STRING)
    )                                                AS firmware_version,

    'active'                                         AS status
  FROM flagged
  WHERE will_swap
)

SELECT end_device_asset_id, usage_point_id, meter_seq, is_replacement,
       serial_number, manufacturer, model_number, install_date,
       communication_protocol, firmware_version, status,
       current_timestamp() AS _ingested_at
FROM originals

UNION ALL

SELECT end_device_asset_id, usage_point_id, meter_seq, is_replacement,
       serial_number, manufacturer, model_number, install_date,
       communication_protocol, firmware_version, status,
       current_timestamp() AS _ingested_at
FROM replacements;
