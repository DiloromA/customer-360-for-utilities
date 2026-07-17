-- Emplify Agent Engagement — quarterly engagement scores per CSR agent.
-- Emplify (now WorkTango) is an employee-engagement survey platform the utility
-- runs against its 200 contact-center agents. 8 quarters × 200 agents
-- = 1,600 rows.
--
-- Engagement is anchored to the same per-agent quality bias the SQM
-- scorecards use, so high-performing agents tend to have high engagement
-- (a known correlation in CX operations research).

CREATE OR REFRESH MATERIALIZED VIEW raw_emplify_agent_engagement (
  CONSTRAINT non_null_engagement_id EXPECT (engagement_id IS NOT NULL),
  CONSTRAINT non_null_agent_id      EXPECT (agent_id IS NOT NULL),
  CONSTRAINT valid_score            EXPECT (engagement_score BETWEEN 0 AND 100)
)
COMMENT 'Emplify quarterly agent engagement scores. 200 agents x 8 quarters = 1,600 rows. Agent-quality bias is the dominant driver of engagement score (high performers more engaged). PK: engagement_id. agent_id matches raw_interaction.agent_id.'
AS

WITH

agents AS (
  -- Reconstruct the agent pool from the Genesys interaction table.
  SELECT DISTINCT agent_id
  FROM ${genesys_schema}.raw_interaction
  WHERE agent_id IS NOT NULL
    AND agent_id LIKE 'AGT-%'
),

quarters AS (
  SELECT * FROM VALUES
    ('2017Q1', DATE'2017-03-31'),
    ('2017Q2', DATE'2017-06-30'),
    ('2017Q3', DATE'2017-09-30'),
    ('2017Q4', DATE'2017-12-31'),
    ('2018Q1', DATE'2018-03-31'),
    ('2018Q2', DATE'2018-06-30'),
    ('2018Q3', DATE'2018-09-30'),
    ('2018Q4', DATE'2018-12-31')
  AS t(quarter_label, quarter_end_date)
),

cross_join AS (
  SELECT
    a.agent_id,
    q.quarter_label,
    q.quarter_end_date,
    abs(xxhash64(a.agent_id, q.quarter_label, 'eng',     ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_engagement,
    abs(xxhash64(a.agent_id, q.quarter_label, 'csat',    ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_csat,
    abs(xxhash64(a.agent_id, q.quarter_label, 'rec',     ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_rec,
    -- Per-agent baseline quality (matches the SQM agent_quality factor).
    abs(xxhash64(a.agent_id, 'agent_quality', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS agent_quality,
    -- Each agent belongs to one of 10 teams.
    abs(xxhash64(a.agent_id, 'team_assign')) % 10                    AS team_idx
  FROM agents a
  CROSS JOIN quarters q
)

SELECT
  md5(CONCAT(agent_id, '_', quarter_label, '_emplify'))              AS engagement_id,
  agent_id,
  CONCAT('TEAM-', LPAD(CAST(team_idx + 1 AS STRING), 2, '0'))        AS team_id,
  quarter_label,
  quarter_end_date,

  -- Engagement score 0-100. Agent quality is the dominant driver
  -- (0.4 weight) plus per-quarter variance (+/-15 points).
  CAST(GREATEST(0, LEAST(100,
    35 + agent_quality * 50            -- 35-85 baseline by quality
    + (r_engagement - 0.5) * 30        -- +/-15 per-quarter variance
  )) AS INT)                                                         AS engagement_score,

  -- eNPS-style metric (-100 to +100, like NPS).
  CAST(
    CASE
      WHEN agent_quality > 0.75 THEN  20 + (r_engagement - 0.5) * 40   --  0 to +40
      WHEN agent_quality > 0.50 THEN   5 + (r_engagement - 0.5) * 50   -- -20 to +30
      WHEN agent_quality > 0.25 THEN -10 + (r_engagement - 0.5) * 60   -- -40 to +20
      ELSE                           -30 + (r_engagement - 0.5) * 50   -- -55 to -5
    END
    AS INT)                                                          AS enps_score,

  -- Self-reported metrics from the Emplify quarterly survey (1-5 scale).
  CAST(GREATEST(1, LEAST(5,
    ROUND(2.5 + agent_quality * 2 + (r_csat - 0.5), 0)
  )) AS INT)                                                         AS career_growth_score_1_5,
  CAST(GREATEST(1, LEAST(5,
    ROUND(2.5 + agent_quality * 1.8 + (r_engagement - 0.5), 0)
  )) AS INT)                                                         AS manager_relationship_score_1_5,
  CAST(GREATEST(1, LEAST(5,
    ROUND(2.5 + agent_quality * 2.2 + (r_rec - 0.5), 0)
  )) AS INT)                                                         AS recognition_score_1_5,

  current_timestamp()                                                AS _ingested_at

FROM cross_join;
