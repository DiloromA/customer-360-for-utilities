-- CSAT view — Row 6 survey health. Response volume by survey type over
-- time, plus response rate for NPS quarterly surveys (fact_survey_invitations).
-- CSAT/SQM have no invited/declined population modeled — see
-- raw_qualtrics_invitation.sql — so they stay volume-only here, labeled
-- honestly in the app rather than implying a rate that doesn't exist.
--
-- One long result (metric_type discriminator) so the app can render two
-- panels from one query: 'volume' rows carry (period_label, survey_type, n);
-- 'response_rate' rows carry (period_label, survey_id, n_invited,
-- n_responded, response_rate_pct) — the columns not applicable to a given
-- metric_type are NULL.

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

volume AS (
  SELECT
    DATE_TRUNC('MONTH', response_date) AS period,
    survey_type,
    COUNT(*)                           AS n
  FROM scoped_responses
  GROUP BY 1, 2
),

invitations AS (
  SELECT
    fsi.survey_id,
    MIN(d.date_value)   AS launch_date,
    SUM(fsi.n_invited)   AS n_invited,
    SUM(fsi.n_responded) AS n_responded
  FROM {{catalog}}.{{schema}}.fact_survey_invitations fsi
  JOIN {{catalog}}.{{schema}}.dim_date d ON d.date_key = fsi.period_date_key
  WHERE d.date_value >= CAST(:date_from AS DATE)
    AND d.date_value <  DATE_ADD(CAST(:date_to AS DATE), 1)
    AND (:segment = 'all' OR fsi.segment = :segment)
  GROUP BY fsi.survey_id
)

SELECT
  'volume'                            AS metric_type,
  DATE_FORMAT(period, 'yyyy-MM')      AS period_label,
  YEAR(period) * 12 + MONTH(period)   AS period_order,
  survey_type,
  CAST(NULL AS STRING)                AS survey_id,
  n,
  CAST(NULL AS BIGINT)                AS n_invited,
  CAST(NULL AS BIGINT)                AS n_responded,
  CAST(NULL AS DOUBLE)                AS response_rate_pct
FROM volume

UNION ALL

SELECT
  'response_rate',
  DATE_FORMAT(launch_date, 'yyyy-MM'),
  YEAR(launch_date) * 12 + MONTH(launch_date),
  'nps_relationship',
  survey_id,
  n_responded                                                    AS n,
  n_invited,
  n_responded,
  ROUND(100.0 * n_responded / NULLIF(n_invited, 0), 1)           AS response_rate_pct
FROM invitations

ORDER BY metric_type, period_order
