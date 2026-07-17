-- Agent dimension. ~200 rows. Unifies CSR agents from Genesys
-- (interaction.agent_id) with Emplify engagement (agent + team).
-- Aggregates engagement to the latest quarter for current state.

CREATE OR REFRESH MATERIALIZED VIEW dim_agent (
  agent_id                    STRING NOT NULL PRIMARY KEY,
  team_id                     STRING,
  latest_engagement_score     INT,
  latest_enps_score           INT,
  latest_career_growth        INT,
  latest_manager_relationship INT,
  latest_recognition          INT,
  _ingested_at                TIMESTAMP
)
COMMENT 'Agent dimension — CSR agents (matches raw_interaction.agent_id and raw_emplify_agent_engagement.agent_id). Latest quarter Emplify engagement scores attached. agent_id is the natural key.'
AS

WITH latest_emplify AS (
  SELECT agent_id,
    MAX_BY(team_id,                          quarter_end_date) AS team_id,
    MAX_BY(engagement_score,                 quarter_end_date) AS latest_engagement_score,
    MAX_BY(enps_score,                       quarter_end_date) AS latest_enps_score,
    MAX_BY(career_growth_score_1_5,          quarter_end_date) AS latest_career_growth,
    MAX_BY(manager_relationship_score_1_5,   quarter_end_date) AS latest_manager_relationship,
    MAX_BY(recognition_score_1_5,            quarter_end_date) AS latest_recognition
  FROM ${cx_legacy_schema}.raw_emplify_agent_engagement
  GROUP BY agent_id
)

SELECT
  agent_id,
  team_id,
  latest_engagement_score,
  latest_enps_score,
  latest_career_growth,
  latest_manager_relationship,
  latest_recognition,
  current_timestamp() AS _ingested_at
FROM latest_emplify;
