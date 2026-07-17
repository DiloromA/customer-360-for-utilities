-- Premise profile header: building/address + current occupant + PV
-- detection. Mirrors customer_header.sql's building/occupant/PV fields but
-- keyed by the premise directly (the map's own atom) instead of resolving
-- through an account_number. LEFT JOINs to the occupant so a vacant
-- premise (no current bridge_account_premise link) still renders.
--
-- Keyed by the human premise_number (the FEMA UUID natural key), not the
-- durable BIGINT premise_id — same reason the rest of the app keys
-- customers by account_number: a hashed BIGINT can lose precision crossing
-- to JSON on the client, so the client only ever carries the STRING key.

-- @param premise_number STRING

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
),
-- One row per premise for address display. A large sub-metered commercial
-- premise (temporal-realism §5.3) has 2-5 dim_service_point rows sharing the
-- same address, so a naive join would duplicate this single-row header —
-- any one of them is a fine representative since the address fields are
-- identical across siblings.
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
),
cur_link AS (
  -- The current billing-responsibility occupant of this premise, if any.
  SELECT b.account_id, b.customer_id, b.link_start_date AS tenant_since
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN prem ON prem.premise_id = b.premise_id
  WHERE b.is_current
  ORDER BY b.link_start_date DESC
  LIMIT 1
),
prior_occ AS (
  -- Previous occupant(s) of this premise (closed links = tenant turnover).
  -- A landlord-held vacancy episode (occupancy_type = 'vacant') isn't a prior
  -- occupant, so it's excluded from the count/timeline.
  SELECT MAX(b.link_end_date) AS previous_occupant_until,
         COUNT(*)             AS previous_occupant_count
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN prem ON prem.premise_id = b.premise_id
  WHERE NOT b.is_current
    AND (b.occupancy_type IS NULL OR b.occupancy_type != 'vacant')
),
owner AS (
  -- This premise's current owner-of-record, if the ownership edge has one
  -- (entity-grain-design.md §4.2) — the pivot target for the Owner chip.
  SELECT bpo.party_id
  FROM {{catalog}}.{{schema}}.bridge_premise_owner bpo
  JOIN prem ON prem.premise_id = bpo.premise_id
  WHERE bpo.is_current
),
pv_at_premise AS (
  -- Registered PV bolted to THIS roof — the grain the DER card actually reads.
  SELECT 1 AS x
  FROM {{catalog}}.{{schema}}.fact_der_adoption d
  JOIN prem ON prem.premise_id = d.premise_id
  WHERE d.device_type = 'PV'
  LIMIT 1
),
pv_anywhere AS (
  -- Registered PV for the occupant at ANY premise they hold — lets us tell
  -- "no PV anywhere" apart from "PV, just not on this roof" (multi-site chains).
  SELECT 1 AS x
  FROM {{catalog}}.{{schema}}.fact_der_adoption d
  JOIN cur_link cl ON cl.customer_id = d.customer_id
  WHERE d.device_type = 'PV'
  LIMIT 1
)
SELECT
  p.premise_number,
  p.occupancy_class,
  p.primary_occupancy,
  p.building_subtype,
  p.sqft,
  p.year_built,
  p.heating_fuel,
  p.envelope_quality,
  p.hvac_system_type,
  p.county,
  p.climate_zone,
  sp.service_address,
  sp.service_city,
  sp.service_state,
  sp.service_zip,
  a.account_number                                                   AS occupant_account_number,
  c.customer_number                                                  AS occupant_customer_number,
  c.customer_class                                                   AS occupant_customer_class,
  cl.tenant_since,
  po.previous_occupant_until,
  COALESCE(po.previous_occupant_count, 0)                            AS previous_occupant_count,
  -- PV detection (ml_pv_detector) is scored at customer_id grain (features
  -- sum ALL of the occupant's service points), but "on record" must be
  -- premise-scoped or the badge and the DER card (premise-grained) disagree
  -- for multi-site customers whose registered PV sits at a different site.
  ROUND(100 * pv.pv_probability, 1)                                  AS pv_probability_pct,
  CAST(pv.pv_likely_flag AS BOOLEAN)                                 AS pv_likely_flag,
  CAST(pv_at_premise.x IS NOT NULL AS BOOLEAN)                       AS pv_on_record,
  CAST(pv_anywhere.x IS NOT NULL AS BOOLEAN)                         AS pv_on_record_elsewhere,
  oc.customer_number                                                 AS owner_number,
  own_bpo.display_name                                               AS owner_display_name
FROM prem
JOIN {{catalog}}.{{schema}}.dim_premise p        ON p.premise_id = prem.premise_id
JOIN primary_sp sp ON sp.premise_id = prem.premise_id
LEFT JOIN cur_link cl                            ON true
LEFT JOIN {{catalog}}.{{schema}}.dim_account a   ON a.account_id  = cl.account_id
LEFT JOIN {{catalog}}.{{schema}}.dim_customer c  ON c.customer_id = cl.customer_id
LEFT JOIN prior_occ po                           ON true
LEFT JOIN {{catalog}}.{{schema}}.ml_pv_detection_predictions pv ON pv.customer_id = cl.customer_id
LEFT JOIN owner                                  ON true
LEFT JOIN {{catalog}}.{{schema}}.dim_customer oc ON oc.customer_id = owner.party_id
LEFT JOIN {{catalog}}.{{schema}}.bridge_premise_owner own_bpo
  ON own_bpo.premise_id = prem.premise_id AND own_bpo.party_id = owner.party_id AND own_bpo.is_current
LEFT JOIN pv_at_premise                          ON true
LEFT JOIN pv_anywhere                            ON true
