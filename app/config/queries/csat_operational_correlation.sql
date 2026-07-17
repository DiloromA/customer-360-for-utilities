-- CSAT view — Row 5 operational correlation. Satisfaction vs outage
-- exposure (NPS's own trailing-90d outage-minutes field) and vs bill shock
-- (nearest bill before the response, from fact_customer_billing).
--
-- Deliberately stays on the star schema rather than a metric view:
-- "nearest bill as of response date"
-- is a row-level temporal join, not an aggregate-only cut.
--
-- outage_exposure is NPS-only: outage_minutes_prior_90d is populated only on
-- Qualtrics NPS rows (fact_survey_responses), not CSAT/SQM rows — so its
-- satisfaction measure is the NPS score (%promoter - %detractor), the metric
-- that field was built to explain. bill_shock uses the unified score_0_10
-- across every survey type and reports top2box_pct (score_0_10 >= 8, i.e.
-- 4-5 of 5 on the CSAT scale the 0-10 mapping derives from — the design
-- doc's "score_0_10 >= 9" phrasing is an off-by-one; 4-5/5 maps to 8/10 via
-- the existing csat_score_1_5 * 2 convention in raw_qualtrics_response.sql /
-- fact_survey_responses.sql, not 9/10).
--
-- Response is scoped by response_date, not a month-truncated dimension —
-- fine here since these are row-level correlations, not trend buckets.

-- @param date_from STRING
-- @param date_to STRING
-- @param segment STRING  -- all | residential | commercial

WITH scoped_responses AS (
  SELECT fsr.*
  FROM {{catalog}}.{{schema}}.fact_survey_responses fsr
  JOIN {{catalog}}.{{schema}}.dim_customer dc ON dc.customer_id = fsr.customer_id
  WHERE fsr.response_date >= CAST(:date_from AS DATE)
    AND fsr.response_date <  DATE_ADD(CAST(:date_to AS DATE), 1)
    AND (:segment = 'all' OR LOWER(dc.customer_class) = :segment)
),

outage_cut AS (
  SELECT *,
    CASE
      WHEN outage_minutes_prior_90d IS NULL OR outage_minutes_prior_90d = 0 THEN 'No recent outage'
      WHEN outage_minutes_prior_90d <= 60                                  THEN '1-60 min'
      WHEN outage_minutes_prior_90d <= 240                                 THEN '61-240 min'
      ELSE                                                                      '240+ min'
    END                                                                    AS bucket,
    CASE
      WHEN outage_minutes_prior_90d IS NULL OR outage_minutes_prior_90d = 0 THEN 0
      WHEN outage_minutes_prior_90d <= 60                                  THEN 1
      WHEN outage_minutes_prior_90d <= 240                                 THEN 2
      ELSE                                                                      3
    END                                                                    AS bucket_order
  FROM scoped_responses
  WHERE survey_type = 'nps_relationship'
),

nearest_bill AS (
  -- bill_id tiebreaks same-day bill_period_end ties so the attributed bill
  -- (and its bill_shock_pct) is deterministic, not arbitrary.
  SELECT
    r.survey_response_id,
    b.bill_shock_pct,
    ROW_NUMBER() OVER (PARTITION BY r.survey_response_id ORDER BY b.bill_period_end DESC, b.bill_id DESC) AS rn
  FROM scoped_responses r
  JOIN {{catalog}}.{{schema}}.fact_customer_billing b
    ON b.customer_id = r.customer_id
   AND b.bill_period_end <= r.response_date
),

bill_cut AS (
  SELECT
    r.*,
    CASE
      WHEN nb.bill_shock_pct IS NULL THEN 'No bill history'
      WHEN nb.bill_shock_pct <= 0.05 THEN 'Normal (<=5%)'
      WHEN nb.bill_shock_pct <= 0.20 THEN 'Elevated (5-20%)'
      ELSE                                'Bill shock (20%+)'
    END                                                                    AS bucket,
    CASE
      WHEN nb.bill_shock_pct IS NULL THEN 0
      WHEN nb.bill_shock_pct <= 0.05 THEN 1
      WHEN nb.bill_shock_pct <= 0.20 THEN 2
      ELSE                                3
    END                                                                    AS bucket_order
  FROM scoped_responses r
  LEFT JOIN nearest_bill nb ON nb.survey_response_id = r.survey_response_id AND nb.rn = 1
)

SELECT
  'outage_exposure'                                                       AS driver_type,
  bucket,
  bucket_order,
  COUNT(*)                                                                AS n,
  ROUND(AVG(score_0_10), 2)                                               AS avg_score_0_10,
  ROUND(100.0 * (
    SUM(CASE WHEN nps_bucket = 'promoter'  THEN 1 ELSE 0 END) -
    SUM(CASE WHEN nps_bucket = 'detractor' THEN 1 ELSE 0 END)
  ) / NULLIF(COUNT(*), 0), 1)                                             AS nps_score,
  CAST(NULL AS DOUBLE)                                                    AS top2box_pct
FROM outage_cut
GROUP BY 1, 2, 3

UNION ALL

SELECT
  'bill_shock',
  bucket,
  bucket_order,
  COUNT(*),
  ROUND(AVG(score_0_10), 2),
  CAST(NULL AS DOUBLE),
  ROUND(100.0 * AVG(CASE WHEN score_0_10 >= 8 THEN 1.0 ELSE 0.0 END), 1)
FROM bill_cut
GROUP BY 1, 2, 3

ORDER BY driver_type, bucket_order
