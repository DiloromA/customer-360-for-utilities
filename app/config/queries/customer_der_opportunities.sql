-- DER-detected program opportunities for the customer profile. Mirrors the Executive
-- map's program-adoption lens ("device detected · not enrolled"): for every DER
-- device AMI/DER data shows at this premise, list the ACTIVE programs that
-- target that device which the customer is NOT yet enrolled in. This keeps the
-- two personas consistent — what the map paints amber ("opportunity") is what
-- the rep sees as a concrete action on the call.
--
-- Keyed by account_number. DER detection is PREMISE-grain (a physical install on
-- THIS premise — scoped by premise_id so a multi-site customer's other sites
-- don't leak in); program enrollment is customer-grain (a customer relationship,
-- not a per-site install). One card per detected device (best-rebate program),
-- so the same device never repeats.
-- The program -> DER device CASE below MUST stay in sync with
-- geniePlugin.buildProgramAdoption() and customer_recommendations.sql.

-- @param account_number STRING

WITH acct AS (
  SELECT customer_id, premise_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
),
detected AS (
  -- Scope to THIS premise's physical DER (not the customer's whole portfolio).
  -- DISTINCT collapses multiple usage_points on one premise to one device row.
  SELECT DISTINCT d.device_type, d.device_subtype, d.system_size_kwh_or_dc
  FROM {{catalog}}.{{schema}}.fact_der_adoption d
  JOIN acct ON acct.premise_id = d.premise_id
),
enrolled AS (
  SELECT DISTINCT fpe.program_id
  FROM {{catalog}}.{{schema}}.fact_program_enrollment fpe
  JOIN acct ON acct.customer_id = fpe.customer_id
  WHERE fpe.enrollment_status IN ('active', 'completed')
),
program_device AS (
  SELECT
    program_id,
    program_name,
    program_type,
    rebate_amount_usd,
    avg_annual_kwh_saved,
    CASE
      WHEN program_id IN ('PRG-EV-CHARGER','PRG-TOU-EV') OR program_name ILIKE '%EV%'         THEN 'EV'
      WHEN program_id IN ('PRG-HP-REBATE','PRG-HPWH')    OR program_name ILIKE '%heat pump%'  THEN 'HEAT_PUMP'
      WHEN program_id IN ('PRG-SMART-TSTAT','PRG-BYOT')  OR program_name ILIKE '%thermostat%' THEN 'SMART_TSTAT'
      WHEN program_name ILIKE '%solar%' OR program_name ILIKE '%PV%'                          THEN 'PV'
      ELSE NULL
    END AS der_device_type
  FROM {{catalog}}.{{schema}}.dim_program
  WHERE program_status = 'Active'
)
SELECT
  d.device_type,
  d.device_subtype,
  d.system_size_kwh_or_dc,
  pd.program_id,
  pd.program_name,
  pd.program_type,
  pd.rebate_amount_usd,
  pd.avg_annual_kwh_saved
FROM detected d
JOIN program_device pd ON pd.der_device_type = d.device_type
WHERE pd.program_id NOT IN (SELECT program_id FROM enrolled)
-- One card per detected device: keep the single richest-rebate program so the
-- "<device> detected — not enrolled" headline never repeats for one device.
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY d.device_type
  ORDER BY pd.rebate_amount_usd DESC NULLS LAST, pd.program_id
) = 1
ORDER BY pd.rebate_amount_usd DESC
