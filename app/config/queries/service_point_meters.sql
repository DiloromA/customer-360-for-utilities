-- Meter installation history for a service point — one row per meter placement
-- window, ordered newest-first. Captures swaps: the replaced meter appears as
-- a closed row (removal_date set), the replacement as is_current.
-- Keyed by service_point_number (STRING natural key from dim_service_point).

-- @param service_point_number STRING

WITH sp AS (
  SELECT service_point_id
  FROM {{catalog}}.{{schema}}.dim_service_point
  WHERE service_point_number = :service_point_number
)
SELECT
  mi.meter_number,
  mi.installation_date,
  mi.removal_date,
  mi.is_current,
  mi.installation_status,
  mi.removal_reason_code,
  dm.manufacturer,
  dm.model_number,
  dm.communication_protocol,
  dm.status                                        AS meter_status
FROM sp
JOIN {{catalog}}.{{schema}}.meter_installation mi   ON mi.service_point_id = sp.service_point_id
LEFT JOIN {{catalog}}.{{schema}}.dim_meter dm        ON dm.meter_number = mi.meter_number
ORDER BY mi.installation_date DESC
LIMIT 20
