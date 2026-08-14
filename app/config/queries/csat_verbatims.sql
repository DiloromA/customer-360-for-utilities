-- CSAT view — Row 7 Voice of Customer. Verbatim feed of open-ended survey
-- comments, most-negative first, for the "what are customers actually
-- saying" panel.
--
-- Comments only exist on Qualtrics NPS rows (~5% of NPS responses,
-- LLM-generated at build time in raw_qualtrics_response.sql — CSAT/SQM rows
-- never have comment_text, so this panel is NPS-only by construction, same
-- as the response-rate panel). comment_sentiment/comment_theme are curated
-- in fact_survey_responses.sql: sentiment is a cheap score_0_10 bucket,
-- theme is ai_classify against the same category taxonomy
-- raw_customer_complaint_event.sql uses for complaints, so Voice-of-Customer
-- themes read consistently with the complaint-theme vocabulary elsewhere in
-- the app. Theme-frequency counts are derived client-side from this same
-- row-level feed (the panel is deliberately thin — no
-- separate aggregate query needed).
--
-- account_number resolves customer_id -> one canonical account per customer
-- (MIN_BY, active accounts preferred) so the "Open profile" deep-link has a
-- single deterministic target even for multi-account commercial customers.

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
  r.score_0_10,
  r.nps_bucket,
  r.comment_text,
  r.comment_sentiment,
  r.comment_theme,
  a.account_number
FROM {{catalog}}.{{schema}}.fact_survey_responses r
JOIN {{catalog}}.{{schema}}.dim_customer dc ON dc.customer_id = r.customer_id
LEFT JOIN accounts a ON a.customer_id = r.customer_id
WHERE r.comment_text IS NOT NULL
  AND r.response_date >= CAST(:date_from AS DATE)
  AND r.response_date <  DATE_ADD(CAST(:date_to AS DATE), 1)
  AND (:segment = 'all' OR LOWER(dc.customer_class) = :segment)
ORDER BY
  CASE r.comment_sentiment WHEN 'negative' THEN 0 WHEN 'neutral' THEN 1 ELSE 2 END,
  r.response_date DESC
LIMIT 200
