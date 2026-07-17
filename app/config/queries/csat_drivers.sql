-- CSAT view — Row 4b driver analysis. "What moves the score": CSAT by
-- wait-time bucket, transfer count, and first-call resolution from
-- fact_csr_interactions (complete series — csat_score_1_5 is populated on
-- every interaction, not just the ~10% independently surveyed via
-- fact_survey_responses); SQM sub-score correlation (greeting/empathy/
-- knowledge) from the SQM-evaluated slice of fact_survey_responses (a 5%
-- sample of voice interactions, joined back to the scoped interaction set
-- by interaction_id).
--
-- Deliberately stays on the star schema rather than metric_csat:
-- it buckets row-level operational
-- fields (wait_time_seconds, transfer_count), which is outside the
-- aggregate-only metric-view constraint. Filters on raw started_at, not a
-- month-truncated dimension — no metric-view grain constraint applies here.
--
-- Result is one long table (UNION ALL of driver cuts) so the app can render
-- two chart families from one query: driver_type IN
-- ('wait_time_bucket','transfer_count','fcr') carries top2box_pct/mean_score;
-- driver_type = 'sqm_subscore' carries sqm_dimension/sqm_avg_score instead
-- (top2box_pct/mean_score are NULL there, and vice versa).

-- @param date_from STRING
-- @param date_to STRING
-- @param segment STRING  -- all | residential | commercial

WITH scoped_interactions AS (
  SELECT ci.*
  FROM {{catalog}}.{{schema}}.fact_csr_interactions ci
  JOIN {{catalog}}.{{schema}}.dim_customer dc ON dc.customer_id = ci.customer_id
  WHERE ci.started_at >= CAST(:date_from AS DATE)
    AND ci.started_at <  DATE_ADD(CAST(:date_to AS DATE), 1)
    AND (:segment = 'all' OR LOWER(dc.customer_class) = :segment)
),

sqm_scoped AS (
  SELECT fsr.sqm_fcr_flag, fsr.sqm_greeting_score, fsr.sqm_empathy_score, fsr.sqm_knowledge_score
  FROM {{catalog}}.{{schema}}.fact_survey_responses fsr
  JOIN scoped_interactions si ON si.interaction_id = fsr.interaction_id
  WHERE fsr.source_system = 'sqm'
)

SELECT
  'wait_time_bucket'                                                    AS driver_type,
  CASE
    WHEN wait_time_seconds < 60  THEN '< 1 min'
    WHEN wait_time_seconds < 180 THEN '1-3 min'
    WHEN wait_time_seconds < 300 THEN '3-5 min'
    ELSE                              '5+ min'
  END                                                                    AS bucket,
  CASE
    WHEN wait_time_seconds < 60  THEN 0
    WHEN wait_time_seconds < 180 THEN 1
    WHEN wait_time_seconds < 300 THEN 2
    ELSE                              3
  END                                                                    AS bucket_order,
  COUNT(*)                                                                AS n,
  ROUND(100.0 * AVG(CASE WHEN csat_score_1_5 >= 4 THEN 1.0 ELSE 0.0 END), 1) AS top2box_pct,
  ROUND(AVG(csat_score_1_5), 2)                                           AS mean_score,
  CAST(NULL AS STRING)                                                    AS sqm_dimension,
  CAST(NULL AS DOUBLE)                                                    AS sqm_avg_score
FROM scoped_interactions
GROUP BY 1, 2, 3

UNION ALL

SELECT
  'transfer_count',
  CASE WHEN transfer_count = 0 THEN '0' WHEN transfer_count = 1 THEN '1' ELSE '2+' END,
  CASE WHEN transfer_count = 0 THEN 0 WHEN transfer_count = 1 THEN 1 ELSE 2 END,
  COUNT(*),
  ROUND(100.0 * AVG(CASE WHEN csat_score_1_5 >= 4 THEN 1.0 ELSE 0.0 END), 1),
  ROUND(AVG(csat_score_1_5), 2),
  CAST(NULL AS STRING),
  CAST(NULL AS DOUBLE)
FROM scoped_interactions
GROUP BY 1, 2, 3

UNION ALL

SELECT
  'fcr',
  CASE WHEN first_call_resolution_flag THEN 'Resolved first call' ELSE 'Not resolved first call' END,
  CASE WHEN first_call_resolution_flag THEN 0 ELSE 1 END,
  COUNT(*),
  ROUND(100.0 * AVG(CASE WHEN csat_score_1_5 >= 4 THEN 1.0 ELSE 0.0 END), 1),
  ROUND(AVG(csat_score_1_5), 2),
  CAST(NULL AS STRING),
  CAST(NULL AS DOUBLE)
FROM scoped_interactions
GROUP BY 1, 2, 3

UNION ALL

SELECT
  'sqm_subscore',
  CASE WHEN sqm_fcr_flag THEN 'Resolved first call' ELSE 'Not resolved first call' END,
  CASE WHEN sqm_fcr_flag THEN 0 ELSE 1 END,
  COUNT(*),
  CAST(NULL AS DOUBLE),
  CAST(NULL AS DOUBLE),
  'Greeting',
  ROUND(AVG(sqm_greeting_score), 2)
FROM sqm_scoped
GROUP BY 1, 2, 3

UNION ALL

SELECT
  'sqm_subscore',
  CASE WHEN sqm_fcr_flag THEN 'Resolved first call' ELSE 'Not resolved first call' END,
  CASE WHEN sqm_fcr_flag THEN 0 ELSE 1 END,
  COUNT(*),
  CAST(NULL AS DOUBLE),
  CAST(NULL AS DOUBLE),
  'Empathy',
  ROUND(AVG(sqm_empathy_score), 2)
FROM sqm_scoped
GROUP BY 1, 2, 3

UNION ALL

SELECT
  'sqm_subscore',
  CASE WHEN sqm_fcr_flag THEN 'Resolved first call' ELSE 'Not resolved first call' END,
  CASE WHEN sqm_fcr_flag THEN 0 ELSE 1 END,
  COUNT(*),
  CAST(NULL AS DOUBLE),
  CAST(NULL AS DOUBLE),
  'Knowledge',
  ROUND(AVG(sqm_knowledge_score), 2)
FROM sqm_scoped
GROUP BY 1, 2, 3

ORDER BY driver_type, bucket_order
