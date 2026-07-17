-- Unified survey responses fact. Combines Qualtrics responses (NPS +
-- CSAT) and SQM call evaluations into one fact for cross-vendor
-- comparison. iPerceptions legacy stays separate due to different
-- scale (1-5) and historical-only nature.
--
-- The source vendor is captured in source_system so demo views can
-- filter to one vendor when needed.

CREATE OR REFRESH MATERIALIZED VIEW fact_survey_responses (
  survey_response_id        STRING NOT NULL,
  source_system              STRING,
  survey_id                  STRING,
  survey_type                 STRING,
  customer_id                 BIGINT,
  response_date                DATE,
  response_date_key             INT,
  score_0_10                  INT,
  nps_bucket                  STRING,
  outage_minutes_prior_90d       BIGINT,
  outage_events_prior_90d        BIGINT,
  complaint_count_prior_90d      BIGINT,
  comment_text                 STRING,
  comment_sentiment            STRING,
  comment_theme                STRING,
  interaction_id               STRING,
  agent_id                    STRING,
  sqm_total_score               INT,
  sqm_fcr_flag                 BOOLEAN,
  sqm_greeting_score            INT,
  sqm_empathy_score             INT,
  sqm_knowledge_score           INT,
  _ingested_at                 TIMESTAMP,
  CONSTRAINT fk_fsr_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fsr_date FOREIGN KEY (response_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY,
  CONSTRAINT fk_fsr_agent FOREIGN KEY (agent_id) REFERENCES dim_agent (agent_id) NOT ENFORCED RELY
)
COMMENT 'Unified survey responses fact. Qualtrics (NPS + CSAT) + SQM call evaluations. customer_id is a durable BIGINT key. sqm_greeting_score/sqm_empathy_score/sqm_knowledge_score are the SQM sub-dimensions (SQM rows only), used for CSAT driver analysis. comment_sentiment/comment_theme (Qualtrics NPS rows only, NULL where comment_text is NULL) power Voice-of-Customer views: sentiment is a cheap score_0_10 bucket, theme is classified against the same category taxonomy complaints use.'
AS

-- Qualtrics rows.
SELECT
  qr.response_id                                                      AS survey_response_id,
  'qualtrics'                                                         AS source_system,
  qr.survey_id,
  qr.survey_type,
  abs(xxhash64(qr.customer_id))                                            AS customer_id,
  qr.response_date,
  CAST(DATE_FORMAT(qr.response_date, 'yyyyMMdd') AS INT)              AS response_date_key,
  qr.score                                                            AS score_0_10,
  qr.nps_bucket,
  qr.outage_minutes_prior_90d,
  qr.outage_events_prior_90d,
  qr.complaint_count_prior_90d,
  qr.comment_text,
  -- Sentiment is a cheap score bucket (no LLM call) — meaningful only
  -- alongside a comment, so NULL where there is none.
  CASE
    WHEN qr.comment_text IS NULL THEN CAST(NULL AS STRING)
    WHEN qr.score >= 8                THEN 'positive'
    WHEN qr.score >= 6                THEN 'neutral'
    ELSE                                    'negative'
  END                                                                AS comment_sentiment,
  -- Theme tag via ai_classify, reusing raw_customer_complaint_event.sql's
  -- category taxonomy for a consistent vocabulary across the app. Only ever
  -- runs on the ~5% of NPS responses that have a comment (~1-2K rows), so
  -- the per-refresh cost is a small fraction of the complaint-text ai_query
  -- pass (raw_customer_complaint_text.sql, ~$0.50/refresh for 15-20K rows).
  CASE
    WHEN qr.comment_text IS NULL THEN CAST(NULL AS STRING)
    ELSE ai_classify(
      qr.comment_text,
      ARRAY('billing', 'outage', 'service_quality', 'customer_service', 'billing_process', 'program')
    )
  END                                                                AS comment_theme,
  -- Cross-vendor NULL columns.
  CAST(NULL AS STRING)                                                AS interaction_id,
  CAST(NULL AS STRING)                                                AS agent_id,
  CAST(NULL AS INT)                                                   AS sqm_total_score,
  CAST(NULL AS BOOLEAN)                                               AS sqm_fcr_flag,
  CAST(NULL AS INT)                                                   AS sqm_greeting_score,
  CAST(NULL AS INT)                                                   AS sqm_empathy_score,
  CAST(NULL AS INT)                                                   AS sqm_knowledge_score,
  current_timestamp()                                                 AS _ingested_at
FROM ${surveys_schema}.raw_qualtrics_response qr

UNION ALL

-- SQM evaluation rows. SQM total_score 0-100 mapped to 0-10 scale (/10)
-- for unified NPS-style comparison.
SELECT
  sqm.evaluation_id                                                   AS survey_response_id,
  'sqm'                                                               AS source_system,
  CAST(NULL AS STRING)                                                AS survey_id,
  'sqm_call_evaluation'                                               AS survey_type,
  abs(xxhash64(sqm.customer_id))                                           AS customer_id,
  CAST(sqm.call_date AS DATE)                                         AS response_date,
  CAST(DATE_FORMAT(sqm.call_date, 'yyyyMMdd') AS INT)                 AS response_date_key,
  CAST(sqm.total_score / 10 AS INT)                                   AS score_0_10,
  CASE
    WHEN sqm.total_score >= 80 THEN 'promoter'
    WHEN sqm.total_score >= 60 THEN 'passive'
    ELSE                            'detractor'
  END                                                                AS nps_bucket,
  CAST(NULL AS INT)                                                   AS outage_minutes_prior_90d,
  CAST(NULL AS INT)                                                   AS outage_events_prior_90d,
  CAST(NULL AS INT)                                                   AS complaint_count_prior_90d,
  CAST(NULL AS STRING)                                                AS comment_text,
  CAST(NULL AS STRING)                                                AS comment_sentiment,
  CAST(NULL AS STRING)                                                AS comment_theme,
  sqm.interaction_id,
  sqm.agent_id,
  sqm.total_score                                                     AS sqm_total_score,
  sqm.fcr_flag                                                        AS sqm_fcr_flag,
  sqm.greeting_score                                                  AS sqm_greeting_score,
  sqm.empathy_score                                                   AS sqm_empathy_score,
  sqm.knowledge_score                                                 AS sqm_knowledge_score,
  current_timestamp()                                                 AS _ingested_at
FROM ${surveys_schema}.raw_sqm_call_evaluation sqm;
