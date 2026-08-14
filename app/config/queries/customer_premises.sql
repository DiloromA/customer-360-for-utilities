-- The customer's CURRENT premises — one row per current service location —
-- for the Premise pivot chip's location dropdown on a multi-site customer.
-- Current-only (is_current) so it matches the "N premises" headline count
-- exactly; customer_locations.sql (all tenancies, incl. closed) stays the
-- source for the map's "show all locations" action.
--
-- Keyed by the human premise_number (STRING) — the client's premise identity
-- and the pivot target — never the BIGINT premise_id.
--
-- @param account_number STRING

WITH acct AS (
  SELECT customer_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
),
-- One row per premise for address display (a sub-metered commercial premise
-- has 2-5 dim_service_point rows sharing an address — any one represents it).
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
)
SELECT DISTINCT
  pr.premise_number,
  sp.service_address,
  sp.service_city,
  sp.service_state,
  -- Coordinates so the map can fly straight to a premise the user picks from
  -- this dropdown — a second home is often off-screen, so the pivot must
  -- re-centre the camera, not just swap the rail card.
  h3.latitude,
  h3.longitude
FROM {{catalog}}.{{schema}}.bridge_account_premise b
JOIN acct ON acct.customer_id = b.customer_id AND b.is_current
JOIN {{catalog}}.{{schema}}.dim_premise pr ON pr.premise_id = b.premise_id
LEFT JOIN primary_sp sp ON sp.premise_id = b.premise_id
LEFT JOIN {{catalog}}.{{schema}}.dim_premise_h3 h3 ON h3.premise_id = b.premise_id
ORDER BY sp.service_address
