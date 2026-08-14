-- Owner (portfolio) profile header — party-level summary for the Owner
-- inspector. Keyed by owner_number, the
-- natural dim_customer.customer_number — same STRING-key-to-client convention
-- as account_number/premise_number (see premise_header.sql's note).
--
-- n_currently_vacant counts owned premises with no current customer link
-- today; n_historical_vacancies counts owned premises that ever carried a
-- closed tenancy_type='vacant' link (the landlord-hero's billing-reverts
-- episode — see raw_account_premise_link.sql). avg_monthly_kwh_portfolio is
-- the trailing-12mo average billed kWh across every premise in the
-- portfolio, same window dim_customer.avg_monthly_kwh_12mo uses.

-- @param owner_number STRING

WITH owner AS (
  SELECT customer_id
  FROM {{catalog}}.{{schema}}.dim_customer
  WHERE customer_number = :owner_number
),
portfolio AS (
  SELECT bpo.premise_id, bpo.basis, bpo.display_name, bpo.owns_from
  FROM {{catalog}}.{{schema}}.bridge_premise_owner bpo
  JOIN owner ON owner.customer_id = bpo.party_id
  WHERE bpo.is_current
),
occ AS (
  -- Current customer per owned premise (no row = currently vacant).
  SELECT b.premise_id, b.account_id
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN portfolio p ON p.premise_id = b.premise_id
  WHERE b.is_current
),
historical_vacancy AS (
  SELECT DISTINCT b.premise_id
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN portfolio p ON p.premise_id = b.premise_id
  WHERE b.tenancy_type = 'vacant'
),
kwh AS (
  -- Sum across sibling service_points per premise-month first — a
  -- sub-metered premise bills one
  -- fact_customer_billing row PER service point, so AVG over the raw rows
  -- would average per-METER kwh, not the portfolio's true monthly total.
  SELECT AVG(month_total_kwh) AS avg_monthly_kwh
  FROM (
    SELECT sp.premise_id, cb.bill_period_end, SUM(cb.total_kwh) AS month_total_kwh
    FROM portfolio p
    JOIN {{catalog}}.{{schema}}.dim_service_point sp ON sp.premise_id = p.premise_id
    JOIN {{catalog}}.{{schema}}.fact_customer_billing cb ON cb.service_point_id = sp.service_point_id
    CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
    WHERE cb.bill_period_end BETWEEN ADD_MONTHS(cfg.as_of_date, -cfg.billing_lookback_months) AND cfg.as_of_date
    GROUP BY sp.premise_id, cb.bill_period_end
  ) monthly
)
SELECT
  :owner_number                                                          AS owner_number,
  ANY_VALUE(p.display_name)                                              AS display_name,
  ANY_VALUE(p.basis)                                                     AS basis,
  MIN(p.owns_from)                                                       AS owns_since,
  COUNT(DISTINCT p.premise_id)                                           AS n_premises,
  COUNT(DISTINCT CASE WHEN o.account_id IS NULL THEN p.premise_id END)   AS n_currently_vacant,
  COUNT(DISTINCT hv.premise_id)                                          AS n_historical_vacancies,
  (SELECT avg_monthly_kwh FROM kwh)                                      AS avg_monthly_kwh_portfolio
FROM portfolio p
LEFT JOIN occ o              ON o.premise_id = p.premise_id
LEFT JOIN historical_vacancy hv ON hv.premise_id = p.premise_id
GROUP BY 1
