-- Recommended DSM programs: active programs the customer is NOT yet
-- enrolled in. Ranked by relevance heuristic from customer signals.
--
-- Keyed by account_number; program enrollment is customer-grain, DER detection
-- and premise attributes (heating fuel / envelope) are scoped to the account's
-- premise (DER is a physical per-site install, so it must not span a multi-site
-- customer's other premises).
--
-- The program -> DER device CASE below MUST stay in sync with
-- geniePlugin.buildProgramAdoption() and customer_der_opportunities.sql.

-- @param account_number STRING

WITH acct AS (
  SELECT a.account_id, a.customer_id, acp.premise_id
  FROM {{catalog}}.{{schema}}.dim_account a
  LEFT JOIN {{catalog}}.{{schema}}.account_current_premise acp
    ON acp.account_id = a.account_id
  WHERE a.account_number = :account_number
),
enrolled AS (
  SELECT DISTINCT fpe.program_id
  FROM {{catalog}}.{{schema}}.fact_program_enrollment fpe
  JOIN acct ON acct.customer_id = fpe.customer_id
),
detected_devices AS (
  -- DER devices AMI/DER data shows at THIS premise. A program that targets a
  -- detected device the customer hasn't enrolled in is the strongest signal
  -- there is (it's the same "detected · not enrolled" the exec map paints amber).
  -- Scoped by premise_id so a multi-site customer's other sites don't leak in.
  SELECT DISTINCT d.device_type
  FROM {{catalog}}.{{schema}}.fact_der_adoption d
  JOIN acct ON acct.premise_id = d.premise_id
),
customer_signals AS (
  SELECT
    c.customer_class,
    c.payment_stressed_flag,
    c.high_user_flag,
    c.engagement_tier,
    c.liheap_eligible,
    c.tenure,
    p.heating_fuel,
    p.envelope_quality
  FROM acct
  JOIN {{catalog}}.{{schema}}.dim_customer c ON c.customer_id = acct.customer_id
  JOIN {{catalog}}.{{schema}}.dim_premise p  ON p.premise_id = acct.premise_id
)
SELECT
  p.program_id,
  p.program_name,
  p.program_type,
  p.customer_segment,
  p.rebate_amount_usd,
  p.avg_annual_kwh_saved,
  -- Relevance score: higher = more relevant for this customer.
  (CASE WHEN EXISTS (
          SELECT 1 FROM detected_devices dd
          WHERE dd.device_type = CASE
            WHEN p.program_id IN ('PRG-EV-CHARGER','PRG-TOU-EV') OR p.program_name ILIKE '%EV%'         THEN 'EV'
            WHEN p.program_id IN ('PRG-HP-REBATE','PRG-HPWH')    OR p.program_name ILIKE '%heat pump%'  THEN 'HEAT_PUMP'
            WHEN p.program_id IN ('PRG-SMART-TSTAT','PRG-BYOT')  OR p.program_name ILIKE '%thermostat%' THEN 'SMART_TSTAT'
            WHEN p.program_name ILIKE '%solar%' OR p.program_name ILIKE '%PV%'                          THEN 'PV'
            ELSE NULL END
        ) THEN 90 ELSE 0 END)
  + (CASE WHEN p.program_id = 'PRG-WX-LMI'        AND cs.liheap_eligible              THEN 100 ELSE 0 END)
  + (CASE WHEN p.program_id = 'PRG-INSULATION'  AND cs.high_user_flag                THEN  60 ELSE 0 END)
  + (CASE WHEN p.program_id = 'PRG-HP-REBATE'   AND cs.heating_fuel != 'electricity' THEN  50 ELSE 0 END)
  + (CASE WHEN p.program_id = 'PRG-SMART-TSTAT' AND cs.engagement_tier != 'low'      THEN  40 ELSE 0 END)
  + (CASE WHEN p.program_id = 'PRG-LED-DISCOUNT'                                     THEN  20 ELSE 0 END)
  + (CASE WHEN p.program_id = 'PRG-HEA-AUDIT'   AND cs.high_user_flag                THEN  70 ELSE 0 END)
  + (CASE WHEN p.program_id = 'PRG-APPL-FRIDGE' AND cs.envelope_quality = 'low'      THEN  25 ELSE 0 END)
  AS relevance_score
FROM {{catalog}}.{{schema}}.dim_program p
CROSS JOIN customer_signals cs
WHERE p.program_status = 'Active'
  AND LOWER(p.customer_segment) = LOWER(cs.customer_class)
  AND p.program_id NOT IN (SELECT program_id FROM enrolled)
ORDER BY relevance_score DESC, p.rebate_amount_usd DESC
LIMIT 5
