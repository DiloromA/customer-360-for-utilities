-- Marketing: top 50 high-fit customers who are NOT enrolled in the
-- selected program. Reuses the per-program relevance heuristic from
-- customer_recommendations, inverted to rank customers instead of programs.
--
-- Candidates = the CURRENT customer base of the program's segment (one row per
-- occupied premise via bridge_account_premise where is_current). Returns the
-- human account_number so a click can open that account in the customer profile.

-- @param program_id STRING

WITH program AS (
  SELECT * FROM {{catalog}}.{{schema}}.dim_program WHERE program_id = :program_id
),

enrolled AS (
  SELECT DISTINCT customer_id
  FROM {{catalog}}.{{schema}}.fact_program_enrollment
  WHERE program_id = :program_id
),

-- One row per premise for address display. A large sub-metered commercial
-- premise has 2-5 dim_service_point rows sharing the
-- same address, so a naive join would duplicate that account's row in the
-- target list — any one sibling is a fine representative since the address
-- fields are identical across siblings.
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
),

candidates AS (
  SELECT
    a.account_number,
    c.customer_class,
    c.payment_stressed_flag,
    c.high_user_flag,
    c.engagement_tier,
    c.liheap_eligible,
    c.tenure,
    c.income_band,
    c.avg_monthly_kwh_12mo,
    p.heating_fuel,
    p.envelope_quality,
    p.building_subtype,
    p.county,
    sp.service_address,
    sp.service_city
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN {{catalog}}.{{schema}}.dim_account a       ON a.account_id = b.account_id
  JOIN {{catalog}}.{{schema}}.dim_customer c      ON c.customer_id = b.customer_id
  JOIN {{catalog}}.{{schema}}.dim_premise p       ON p.premise_id = b.premise_id
  JOIN primary_sp sp                              ON sp.premise_id = b.premise_id
  CROSS JOIN program pr
  LEFT JOIN enrolled e ON e.customer_id = c.customer_id
  WHERE b.is_current
    AND LOWER(c.customer_class) = LOWER(pr.customer_segment)
    AND e.customer_id IS NULL
)

SELECT
  account_number,
  service_address,
  service_city,
  county,
  customer_class,
  engagement_tier,
  income_band,
  building_subtype,
  heating_fuel,
  high_user_flag,
  liheap_eligible,
  payment_stressed_flag,
  ROUND(avg_monthly_kwh_12mo, 0)                                                        AS avg_monthly_kwh_12mo,
  (CASE WHEN :program_id = 'PRG-WX-LMI'        AND liheap_eligible                THEN 100 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-INSULATION'  AND high_user_flag                  THEN  60 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-HP-REBATE'   AND heating_fuel != 'electricity'   THEN  50 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-SMART-TSTAT' AND engagement_tier != 'low'        THEN  40 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-LED-DISCOUNT'                                    THEN  20 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-HEA-AUDIT'   AND high_user_flag                  THEN  70 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-APPL-FRIDGE' AND envelope_quality = 'low'        THEN  25 ELSE 0 END)
  AS fit_score
FROM candidates
WHERE
  (CASE WHEN :program_id = 'PRG-WX-LMI'        AND liheap_eligible                THEN 100 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-INSULATION'  AND high_user_flag                  THEN  60 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-HP-REBATE'   AND heating_fuel != 'electricity'   THEN  50 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-SMART-TSTAT' AND engagement_tier != 'low'        THEN  40 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-LED-DISCOUNT'                                    THEN  20 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-HEA-AUDIT'   AND high_user_flag                  THEN  70 ELSE 0 END)
  + (CASE WHEN :program_id = 'PRG-APPL-FRIDGE' AND envelope_quality = 'low'        THEN  25 ELSE 0 END)
  > 0
ORDER BY fit_score DESC, avg_monthly_kwh_12mo DESC NULLS LAST
LIMIT 50
