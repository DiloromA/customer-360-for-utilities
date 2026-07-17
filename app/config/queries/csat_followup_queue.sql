-- CSAT view — Row 8 closed-loop follow-up queue. Detractor-scored survey
-- responses (nps_bucket = 'detractor', the same bucket used everywhere else
-- in the CSAT view — NPS <=6, CSAT 1-2/5, SQM total_score <60) across all
-- three survey types, most recent first, for an agent call-back list.
--
-- Ties the reactive signal (this response) to the proactive one
-- (ml_complaint_risk_scores.risk_tier) so a detractor who is ALSO
-- predicted high-risk stands out as the priority call.
--
-- account_number resolves customer_id -> one canonical account per customer
-- (MIN_BY, active accounts preferred, same resolution as csat_verbatims.sql)
-- so "Open profile" always has a single deterministic deep-link target.
-- agent_id is populated for SQM rows only (dim_agent has no display name,
-- so it's shown as-is).

-- @param date_from STRING
-- @param date_to STRING
-- @param segment STRING  -- all | residential | commercial

WITH accounts AS (
  SELECT
    customer_id,
    MIN_BY(
      account_number,
      CONCAT(CASE WHEN current_status = 'active' THEN '0' ELSE '1' END, account_number)
    ) AS account_number
  FROM {{catalog}}.{{schema}}.dim_account
  GROUP BY customer_id
)

SELECT
  r.survey_response_id,
  r.response_date,
  r.survey_type,
  r.score_0_10,
  r.comment_text,
  r.agent_id,
  a.account_number,
  s.risk_tier          AS complaint_risk_tier,
  s.top_category       AS complaint_risk_category
FROM {{catalog}}.{{schema}}.fact_survey_responses r
JOIN {{catalog}}.{{schema}}.dim_customer dc ON dc.customer_id = r.customer_id
LEFT JOIN accounts a ON a.customer_id = r.customer_id
LEFT JOIN {{catalog}}.{{schema}}.ml_complaint_risk_scores s ON s.customer_id = r.customer_id
WHERE r.nps_bucket = 'detractor'
  AND r.response_date >= CAST(:date_from AS DATE)
  AND r.response_date <  DATE_ADD(CAST(:date_to AS DATE), 1)
  AND (:segment = 'all' OR LOWER(dc.customer_class) = :segment)
ORDER BY
  CASE WHEN s.risk_tier = 'high' THEN 0 ELSE 1 END,
  r.response_date DESC
LIMIT 200
