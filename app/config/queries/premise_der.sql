-- DER devices physically installed at this premise (solar stays with the
-- house, unlike EV which moves with the person). A straight device list —
-- no program-opportunity matching here; that stays customer-side in
-- customer_der_opportunities.sql, since program enrollment is a customer
-- (billing) relationship, not a per-site install. Keyed by premise_number
-- (STRING) — see premise_header.sql's note on the BIGINT/client boundary.

-- @param premise_number STRING

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
)
SELECT DISTINCT
  d.device_type,
  d.device_subtype,
  d.system_size_kwh_or_dc,
  d.install_date
FROM prem
JOIN {{catalog}}.{{schema}}.fact_der_adoption d ON d.premise_id = prem.premise_id
ORDER BY d.install_date DESC
