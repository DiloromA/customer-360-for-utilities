-- Meter Installation — the effective-dated bridge that places a meter
-- (end_device_asset) on a usage_point / premise for a date range. This is the
-- table that makes the usage_point ↔ meter relationship many-to-one OVER TIME:
-- a stable usage_point can host meter A (installed, later removed) then meter B
-- (the swap-in). CIM aligns this with EndDeviceAsset ↔ UsagePoint over time;
-- the industry model calls it metering.meter_installation.
--
-- Derived entirely from end_device_asset by windowing meters at each
-- usage_point by install_date:
--   removal_date            = the install_date of the NEXT meter at the same
--                             usage_point (NULL for the current meter)
--   to_end_device_asset_id  = that next meter (the swap target; NULL if current)
--   is_current              = true when there is no successor meter
--
-- For the ~93% of usage_points with a single meter this yields exactly one
-- current installation row. For the ~7% swap cohort it yields two rows: the
-- original (removed when the replacement was installed) and the replacement
-- (current). No randomness here — all of it lives in end_device_asset.

CREATE OR REFRESH MATERIALIZED VIEW raw_meter_installation (
  CONSTRAINT non_null_meter_installation_id EXPECT (meter_installation_id IS NOT NULL),
  CONSTRAINT non_null_end_device_asset_id   EXPECT (end_device_asset_id IS NOT NULL),
  CONSTRAINT non_null_usage_point_id        EXPECT (usage_point_id IS NOT NULL),
  CONSTRAINT valid_installation_status      EXPECT (installation_status IN ('active','removed')),
  CONSTRAINT removal_after_install           EXPECT (removal_date IS NULL OR removal_date >= installation_date)
)
COMMENT 'Meter Installation — effective-dated bridge placing a meter (end_device_asset) on a usage_point/premise for a date range. One current row per usage_point for single-meter points; two rows (original removed + replacement current) for the ~7% meter-swap cohort. removal_date is the next meter''s install date (NULL if current); to_end_device_asset_id is the swap-in meter (NULL if current). This is how the usage_point ↔ meter relationship is captured over time, so a meter reading resolves to the meter that was installed when the reading was taken. PK: meter_installation_id. FK: end_device_asset_id -> end_device_asset, usage_point_id -> usage_point.'
AS

WITH installs AS (
  SELECT
    eda.end_device_asset_id,
    eda.usage_point_id,
    up.premise_id,
    eda.install_date                                                 AS installation_date,
    eda.meter_seq,
    eda.is_replacement,
    LEAD(eda.end_device_asset_id) OVER (
      PARTITION BY eda.usage_point_id ORDER BY eda.install_date, eda.meter_seq
    )                                                                AS to_end_device_asset_id,
    LEAD(eda.install_date) OVER (
      PARTITION BY eda.usage_point_id ORDER BY eda.install_date, eda.meter_seq
    )                                                                AS next_install_date
  FROM raw_end_device_asset eda
  JOIN raw_usage_point up ON eda.usage_point_id = up.usage_point_id
)

SELECT
  md5(CONCAT(end_device_asset_id, '_install'))                       AS meter_installation_id,
  end_device_asset_id,
  usage_point_id,
  premise_id,
  installation_date,
  next_install_date                                                  AS removal_date,
  to_end_device_asset_id,
  -- Reason the meter left service: a swap-in supersession for removed originals.
  CASE WHEN next_install_date IS NULL THEN CAST(NULL AS STRING) ELSE 'meter_exchange' END AS removal_reason_code,
  (next_install_date IS NULL)                                        AS is_current,
  CASE WHEN next_install_date IS NULL THEN 'active' ELSE 'removed' END AS installation_status,
  current_timestamp()                                                AS _ingested_at
FROM installs;
