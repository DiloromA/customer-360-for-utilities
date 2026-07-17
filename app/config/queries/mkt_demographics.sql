-- Marketing: demographics comparison for the selected program.
-- Returns one row per (bucket, dimension, value) where bucket is
-- either 'enrolled' or 'eligible_not_enrolled'. The UI normalizes to
-- percentages within each bucket so the bars are comparable even
-- though the two groups have different sizes.
--
-- Population = the CURRENT customer base of the program's segment (one row per
-- occupied premise via bridge_account_premise where is_current). Premise
-- attributes come from the premise the current link points at, since
-- dim_customer is profile-only in the new model.

-- @param program_id STRING

WITH program AS (
  SELECT customer_segment FROM {{catalog}}.{{schema}}.dim_program WHERE program_id = :program_id
),

enrolled AS (
  SELECT DISTINCT customer_id
  FROM {{catalog}}.{{schema}}.fact_program_enrollment
  WHERE program_id = :program_id
    AND enrollment_status IN ('active', 'completed')
),

classified AS (
  SELECT
    c.customer_id,
    c.income_band,
    c.engagement_tier,
    c.usage_band,
    c.tenure,
    c.age_band_hoh,
    p.building_subtype,
    p.heating_fuel,
    CASE WHEN e.customer_id IS NOT NULL THEN 'enrolled' ELSE 'eligible_not_enrolled' END AS bucket
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN {{catalog}}.{{schema}}.dim_customer c ON c.customer_id = b.customer_id
  JOIN {{catalog}}.{{schema}}.dim_premise p  ON p.premise_id = b.premise_id
  CROSS JOIN program pr
  LEFT JOIN enrolled e ON e.customer_id = c.customer_id
  WHERE b.is_current
    AND LOWER(c.customer_class) = LOWER(pr.customer_segment)
)

SELECT bucket, 'income_band'    AS dimension, COALESCE(income_band, 'unknown')    AS value, COUNT(*) AS n FROM classified GROUP BY bucket, income_band
UNION ALL
SELECT bucket, 'engagement_tier' AS dimension, COALESCE(engagement_tier, 'unknown') AS value, COUNT(*) AS n FROM classified GROUP BY bucket, engagement_tier
UNION ALL
SELECT bucket, 'usage_band'      AS dimension, COALESCE(usage_band, 'unknown')      AS value, COUNT(*) AS n FROM classified GROUP BY bucket, usage_band
UNION ALL
SELECT bucket, 'tenure'          AS dimension, COALESCE(tenure, 'unknown')          AS value, COUNT(*) AS n FROM classified GROUP BY bucket, tenure
UNION ALL
SELECT bucket, 'building_subtype' AS dimension, COALESCE(building_subtype, 'unknown') AS value, COUNT(*) AS n FROM classified GROUP BY bucket, building_subtype
UNION ALL
SELECT bucket, 'heating_fuel'    AS dimension, COALESCE(heating_fuel, 'unknown')    AS value, COUNT(*) AS n FROM classified GROUP BY bucket, heating_fuel
