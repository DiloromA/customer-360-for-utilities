-- Meter Installation — the effective-dated bridge that places a meter on a
-- service point / premise for a date range. This is the table that makes the
-- service point ↔ meter relationship many-to-one OVER TIME:
-- a stable service point can host meter A (installed, later removed) then meter B
-- (the swap-in). CIM aligns this with EndDeviceAsset ↔ UsagePoint over time;
-- the industry model calls it metering.meter_installation.
--
-- Derived entirely from raw_meter by windowing meters at each service point
-- by install_date:
--   removal_date            = the install_date of the NEXT meter at the same
--                             service point (NULL for the current meter)
--   to_meter_number  = that next meter (the swap target; NULL if current)
--   is_current              = true when there is no successor meter
--
-- For the ~93% of service points with a single meter this yields exactly one
-- current installation row. For the ~7% swap cohort it yields two rows: the
-- original (removed when the replacement was installed) and the replacement
-- (current). No randomness here — all of it lives in raw_meter.

CREATE OR REFRESH MATERIALIZED VIEW raw_meter_installation (
  CONSTRAINT non_null_meter_installation_id EXPECT (meter_installation_id IS NOT NULL),
  CONSTRAINT non_null_meter_number          EXPECT (meter_number IS NOT NULL),
  CONSTRAINT non_null_service_point_id      EXPECT (service_point_id IS NOT NULL),
  CONSTRAINT valid_installation_status      EXPECT (installation_status IN ('active','removed')),
  CONSTRAINT removal_after_install          EXPECT (removal_date IS NULL OR removal_date >= installation_date)
)
COMMENT 'Meter Installation — effective-dated bridge placing a meter on a service point/premise for a date range. One current row per service point for single-meter points; two rows (original removed + replacement current) for the ~7% meter-swap cohort. removal_date is the next meter''s install date (NULL if current); to_meter_number is the swap-in meter (NULL if current). This is how the service point ↔ meter relationship is captured over time, so a meter reading resolves to the meter that was installed when the reading was taken. PK: meter_installation_id. FK: meter_number -> raw_meter, service_point_id -> raw_service_point.'
AS

WITH installs AS (
  SELECT
    m.meter_number,
    m.service_point_id,
    up.premise_id,
    m.install_date                                                 AS installation_date,
    m.meter_seq,
    m.is_replacement,
    LEAD(m.meter_number) OVER (
      PARTITION BY m.service_point_id ORDER BY m.install_date, m.meter_seq
    )                                                                AS to_meter_number,
    LEAD(m.install_date) OVER (
      PARTITION BY m.service_point_id ORDER BY m.install_date, m.meter_seq
    )                                                                AS next_install_date
  FROM raw_meter m
  JOIN raw_service_point up ON m.service_point_id = up.service_point_id
)

SELECT
  md5(CONCAT(meter_number, '_install'))                       AS meter_installation_id,
  meter_number,
  service_point_id,
  premise_id,
  installation_date,
  next_install_date                                                  AS removal_date,
  to_meter_number,
  -- Reason the meter left service: a swap-in supersession for removed originals.
  CASE WHEN next_install_date IS NULL THEN CAST(NULL AS STRING) ELSE 'meter_exchange' END AS removal_reason_code,
  (next_install_date IS NULL)                                        AS is_current,
  CASE WHEN next_install_date IS NULL THEN 'active' ELSE 'removed' END AS installation_status,
  current_timestamp()                                                AS _ingested_at
FROM installs;
