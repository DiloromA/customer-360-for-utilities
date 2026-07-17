-- Marketing: complaint themes among enrollees of the selected program.
-- The comparison column (rate_per_1k_enrollees vs rate_per_1k_population)
-- exposes themes where enrollees complain disproportionately — i.e.
-- the program's onboarding or rebate process may be friction.
--
-- The population denominator counts the CURRENT customer base (bridge
-- is_current), so the per-1k population rate isn't diluted by historical rows.

-- @param program_id STRING

WITH enrolled AS (
  SELECT DISTINCT customer_id
  FROM {{catalog}}.{{schema}}.fact_program_enrollment
  WHERE program_id = :program_id
    AND enrollment_status IN ('active', 'completed')
),

enrollee_complaints AS (
  SELECT cc.sub_category, COUNT(*) AS n
  FROM {{catalog}}.{{schema}}.fact_customer_complaints cc
  JOIN enrolled e ON e.customer_id = cc.customer_id
  CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
  WHERE cc.complaint_date BETWEEN ADD_MONTHS(cfg.as_of_date, -cfg.billing_lookback_months) AND cfg.as_of_date
  GROUP BY cc.sub_category
),

population_complaints AS (
  SELECT cc.sub_category, COUNT(*) AS n
  FROM {{catalog}}.{{schema}}.fact_customer_complaints cc
  CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
  WHERE cc.complaint_date BETWEEN ADD_MONTHS(cfg.as_of_date, -cfg.billing_lookback_months) AND cfg.as_of_date
  GROUP BY cc.sub_category
),

denominators AS (
  SELECT
    (SELECT COUNT(*) FROM enrolled)                                                 AS n_enrolled,
    (SELECT COUNT(*) FROM {{catalog}}.{{schema}}.bridge_account_premise
      WHERE is_current)                                                             AS n_population
)

SELECT
  COALESCE(ec.sub_category, pc.sub_category)                                   AS sub_category,
  COALESCE(ec.n, 0)                                                            AS n_enrollee_complaints,
  COALESCE(pc.n, 0)                                                            AS n_population_complaints,
  ROUND(1000.0 * COALESCE(ec.n, 0) / NULLIF(d.n_enrolled, 0), 2)               AS rate_per_1k_enrollees,
  ROUND(1000.0 * COALESCE(pc.n, 0) / NULLIF(d.n_population, 0), 2)             AS rate_per_1k_population,
  ROUND(
    (1000.0 * COALESCE(ec.n, 0) / NULLIF(d.n_enrolled, 0))
    / NULLIF(1000.0 * COALESCE(pc.n, 0) / NULLIF(d.n_population, 0), 0),
    2
  )                                                                            AS enrollee_lift_ratio
FROM enrollee_complaints ec
FULL OUTER JOIN population_complaints pc USING (sub_category)
CROSS JOIN denominators d
WHERE COALESCE(ec.n, 0) > 0
ORDER BY n_enrollee_complaints DESC
LIMIT 12
