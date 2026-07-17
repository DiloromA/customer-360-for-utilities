-- Owner portfolio roster — one row per owned premise, for the Owner
-- inspector's roster table + "light up portfolio" map action
-- (entity-grain-design.md §6.2). occupancy_type is the CURRENT occupancy at
-- that premise ('vacant' when there is no current bridge_account_premise
-- link — not expected today, since only the landlord-hero's one historical
-- gap is closed/non-current, but kept general). avg_monthly_kwh is this
-- premise's own trailing-12mo average, same window as premise_bills.sql.

-- @param owner_number STRING

WITH owner AS (
  SELECT customer_id
  FROM {{catalog}}.{{schema}}.dim_customer
  WHERE customer_number = :owner_number
),
portfolio AS (
  SELECT bpo.premise_id
  FROM {{catalog}}.{{schema}}.bridge_premise_owner bpo
  JOIN owner ON owner.customer_id = bpo.party_id
  WHERE bpo.is_current
),
cur_link AS (
  SELECT b.premise_id, b.account_id, b.customer_id, b.occupancy_type, b.link_start_date
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN portfolio p ON p.premise_id = b.premise_id
  WHERE b.is_current
),
-- One row per premise for address display. A large sub-metered commercial
-- premise (temporal-realism §5.3) has 2-5 dim_service_point rows sharing the
-- same address, so a naive join would duplicate this roster row — any one
-- sibling is a fine representative since the address fields are identical
-- across siblings.
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
),
kwh AS (
  -- Sum across sibling service_points per month first — a sub-metered
  -- premise bills one fact_customer_billing row PER usage_point, so AVG over
  -- the raw rows would average per-METER kwh, not the site's true monthly
  -- total.
  SELECT premise_id, AVG(month_total_kwh) AS avg_monthly_kwh
  FROM (
    SELECT sp.premise_id, cb.bill_period_end, SUM(cb.total_kwh) AS month_total_kwh
    FROM portfolio p
    JOIN {{catalog}}.{{schema}}.dim_service_point sp ON sp.premise_id = p.premise_id
    JOIN {{catalog}}.{{schema}}.fact_customer_billing cb ON cb.service_point_id = sp.service_point_id
    CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
    WHERE cb.bill_period_end BETWEEN ADD_MONTHS(cfg.as_of_date, -cfg.billing_lookback_months) AND cfg.as_of_date
    GROUP BY sp.premise_id, cb.bill_period_end
  ) monthly
  GROUP BY premise_id
)
SELECT
  dp.premise_number,
  sp.service_address,
  sp.service_city,
  sp.service_state,
  dp.building_subtype,
  dp.sqft,
  h3.latitude,
  h3.longitude,
  a.account_number                                   AS tenant_account_number,
  c.customer_number                                  AS tenant_customer_number,
  COALESCE(cl.occupancy_type, 'vacant')               AS occupancy_type,
  cl.link_start_date                                  AS tenant_since,
  k.avg_monthly_kwh
FROM portfolio p
JOIN {{catalog}}.{{schema}}.dim_premise dp    ON dp.premise_id = p.premise_id
JOIN primary_sp sp                            ON sp.premise_id = p.premise_id
JOIN {{catalog}}.{{schema}}.dim_premise_h3 h3  ON h3.premise_id = p.premise_id
LEFT JOIN cur_link cl                          ON cl.premise_id = p.premise_id
LEFT JOIN {{catalog}}.{{schema}}.dim_account a ON a.account_id = cl.account_id
LEFT JOIN {{catalog}}.{{schema}}.dim_customer c ON c.customer_id = cl.customer_id
LEFT JOIN kwh k                                ON k.premise_id = p.premise_id
ORDER BY dp.premise_number
