-- Service points at this premise: one row per metered delivery point.
-- Includes the currently installed meter via meter_installation (is_current).
-- Sub-metered commercial premises return 2-5 rows here by design.
-- Keyed by premise_number (STRING natural key).

-- @param premise_number STRING

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
)
SELECT
  sp.service_point_number,
  sp.commodity,
  sp.phase_code,
  sp.nominal_service_voltage,
  mi.meter_number                                  AS current_meter_number,
  mi.installation_date                             AS meter_installed_date,
  mi.installation_status
FROM prem
JOIN {{catalog}}.{{schema}}.dim_service_point sp   ON sp.premise_id = prem.premise_id
LEFT JOIN {{catalog}}.{{schema}}.meter_installation mi
  ON mi.service_point_id = sp.service_point_id
 AND mi.is_current
ORDER BY sp.service_point_number
