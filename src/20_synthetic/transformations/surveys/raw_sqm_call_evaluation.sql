-- SQM Call Evaluation — QA scorecards on a 5% sample of Genesys voice
-- interactions. SQM's methodology: an evaluator (QA analyst) listens to
-- the call recording and scores the agent on multiple dimensions, then
-- the customer is contacted for a brief CSR-specific follow-up survey.
--
-- The headline metric is FCR (First Call Resolution): did the customer's
-- issue get resolved without a callback/transfer? FCR is computed
-- deterministically from the parent interaction's disposition_code.
--
-- ~16K rows (5% of 327K Genesys interactions).

CREATE OR REFRESH MATERIALIZED VIEW raw_sqm_call_evaluation (
  CONSTRAINT non_null_evaluation_id  EXPECT (evaluation_id IS NOT NULL),
  CONSTRAINT non_null_interaction_id EXPECT (interaction_id IS NOT NULL),
  CONSTRAINT valid_scores            EXPECT (
    greeting_score BETWEEN 0 AND 5
    AND empathy_score BETWEEN 0 AND 5
    AND knowledge_score BETWEEN 0 AND 5
    AND total_score BETWEEN 0 AND 100
  )
)
COMMENT 'SQM call evaluations. CSR-specific QA scorecards on a 5% sample of Genesys voice interactions. Headline metric: FCR (first-call resolution). Scores derive from agent quality (some agents are systematically better - encoded via xxhash on agent_id) + call complexity (complaints score lower; routine inquiries score higher). PK: evaluation_id. FK: interaction_id -> raw_interaction.'
AS

WITH

sampled AS (
  SELECT
    i.interaction_id,
    i.customer_id,
    i.agent_id,
    i.started_at,
    i.disposition_code,
    i.transfer_count,
    i.source_kind,
    abs(xxhash64(i.interaction_id, 'sqm_greeting', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_greet,
    abs(xxhash64(i.interaction_id, 'sqm_empathy',  ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_emp,
    abs(xxhash64(i.interaction_id, 'sqm_knowledge',${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_know,
    abs(xxhash64(i.interaction_id, 'sqm_evaluator',${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_evaluator,
    -- Per-agent quality bias: some agents systematically score higher.
    abs(xxhash64(i.agent_id, 'agent_quality', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS agent_quality
  FROM ${genesys_schema}.raw_interaction i
  WHERE i.media_type = 'voice'
    -- 5% sample
    AND abs(xxhash64(i.interaction_id, 'sqm_sample', ${random_seed})) % 100 < 5
),

scored AS (
  SELECT *,
    -- Agent-quality adjustment: better agents add up to +0.8 to each score,
    -- worse agents subtract up to -0.8.
    (agent_quality - 0.5) * 1.6 AS agent_adj,
    -- Complaint-call penalty: complaints score lower because the situation
    -- is hard.
    CASE source_kind WHEN 'complaint' THEN -0.5 ELSE 0.0 END AS complaint_adj
  FROM sampled
)

SELECT
  md5(CONCAT('sqm_', interaction_id))                                AS evaluation_id,
  interaction_id,
  customer_id,
  agent_id,
  CAST(started_at AS DATE)                                           AS call_date,

  -- Greeting score (5-point scale). Strong agent / no complaint -> high.
  CAST(GREATEST(0, LEAST(5,
    ROUND(3.5 + (r_greet - 0.5) * 1.5 + agent_adj + complaint_adj, 0)
  )) AS INT)                                                         AS greeting_score,

  CAST(GREATEST(0, LEAST(5,
    ROUND(3.5 + (r_emp - 0.5) * 1.5 + agent_adj + complaint_adj, 0)
  )) AS INT)                                                         AS empathy_score,

  CAST(GREATEST(0, LEAST(5,
    ROUND(3.7 + (r_know - 0.5) * 1.5 + agent_adj + complaint_adj * 0.5, 0)
  )) AS INT)                                                         AS knowledge_score,

  -- Total score 0-100 — weighted blend of three 0-5 dimensions plus FCR bonus.
  --   greeting    weight 20  -> dimension score × 4   (max 20)
  --   empathy     weight 25  -> dimension score × 5   (max 25)
  --   knowledge   weight 25  -> dimension score × 5   (max 25)
  --   FCR bonus              -> 0-30 from disposition (max 30)
  -- Theoretical max: 100. Theoretical min: 0.
  CAST(GREATEST(0, LEAST(100,
    4.0 * GREATEST(0, LEAST(5, 3.5 + (r_greet - 0.5) * 1.5 + agent_adj + complaint_adj))
    + 5.0 * GREATEST(0, LEAST(5, 3.5 + (r_emp - 0.5) * 1.5 + agent_adj + complaint_adj))
    + 5.0 * GREATEST(0, LEAST(5, 3.7 + (r_know - 0.5) * 1.5 + agent_adj + complaint_adj * 0.5))
    + CASE disposition_code
        WHEN 'resolved_first_call'    THEN 30
        WHEN 'inquiry_resolved'       THEN 30
        WHEN 'information_provided'   THEN 25
        WHEN 'service_request_created' THEN 22
        WHEN 'program_enrolled'       THEN 25
        WHEN 'tech_dispatched'        THEN 18
        WHEN 'outage_acknowledged'    THEN 18
        WHEN 'escalated_supervisor'   THEN 5
        WHEN 'callback_scheduled'     THEN 8
        WHEN 'transferred_followup'   THEN 10
        ELSE                                15
      END
  )) AS INT)                                                         AS total_score,

  -- First-call resolution flag (the SQM headline metric).
  CASE
    WHEN transfer_count = 0
     AND disposition_code IN ('resolved_first_call','inquiry_resolved','information_provided',
                              'service_request_created','program_enrolled')
      THEN true
    ELSE false
  END                                                                AS fcr_flag,

  -- Evaluator ID: ~30 QA analysts in the pool.
  CONCAT('EVL-', LPAD(CAST(1 + CAST(r_evaluator * 30 AS INT) AS STRING), 3, '0'))
                                                                     AS evaluator_id,

  current_timestamp()                                                AS _ingested_at
FROM scored;
