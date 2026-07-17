-- Emplify Team Pulse — weekly team-level pulse surveys. 10 teams × ~104
-- weeks = ~1,040 rows. Pulse score is a roll-up of the team's individual
-- agent engagement plus a "topic of the week" prompt response.
--
-- Real Emplify cycles a different topic each week (workload, recognition,
-- diversity, communication, etc.); we model that as a string column.

CREATE OR REFRESH MATERIALIZED VIEW raw_emplify_team_pulse (
  CONSTRAINT non_null_pulse_id  EXPECT (pulse_id IS NOT NULL),
  CONSTRAINT non_null_team_id   EXPECT (team_id IS NOT NULL),
  CONSTRAINT valid_pulse_score  EXPECT (pulse_score BETWEEN 0 AND 100)
)
COMMENT 'Emplify weekly team-level pulse surveys. ~1,040 rows (10 teams x 104 weeks). pulse_score blends the team baseline (from agent engagement) with week-specific topic response. PK: pulse_id.'
AS

WITH

team_ids AS (
  SELECT EXPLODE(SEQUENCE(1, 10)) AS team_n
),

week_dates AS (
  SELECT EXPLODE(SEQUENCE(DATE'2017-01-08', DATE'2018-12-30', INTERVAL 1 WEEK)) AS week_end
),

base AS (
  SELECT
    CONCAT('TEAM-', LPAD(CAST(t.team_n AS STRING), 2, '0')) AS team_id,
    wd.week_end,
    abs(xxhash64(t.team_n, wd.week_end, 'pulse', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_pulse,
    abs(xxhash64(t.team_n, wd.week_end, 'topic', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_topic,
    abs(xxhash64(t.team_n, 'team_baseline', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS team_baseline,
    abs(xxhash64(t.team_n, wd.week_end, 'response', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_response
  FROM team_ids t
  CROSS JOIN week_dates wd
)

SELECT
  md5(CONCAT(team_id, '_', CAST(week_end AS STRING), '_pulse'))      AS pulse_id,
  team_id,
  week_end,

  -- Topic for the week (Emplify rotates through 10 categories).
  CASE CAST(r_topic * 10 AS INT)
    WHEN 0 THEN 'workload_balance'
    WHEN 1 THEN 'recognition'
    WHEN 2 THEN 'manager_relationship'
    WHEN 3 THEN 'team_collaboration'
    WHEN 4 THEN 'career_growth'
    WHEN 5 THEN 'work_environment'
    WHEN 6 THEN 'diversity_inclusion'
    WHEN 7 THEN 'communication'
    WHEN 8 THEN 'training_quality'
    ELSE        'company_alignment'
  END                                                                AS pulse_topic,

  -- Pulse score 0-100. Team baseline (30-80) + topic variance (+/-15).
  CAST(GREATEST(0, LEAST(100,
    40 + team_baseline * 40 + (r_pulse - 0.5) * 30
  )) AS INT)                                                         AS pulse_score,

  -- Response rate (what % of team responded to this week's pulse).
  CAST(GREATEST(20, LEAST(95,
    40 + team_baseline * 40 + (r_response - 0.5) * 30
  )) AS INT)                                                         AS response_rate_pct,

  -- Number of survey respondents in the team this week.
  CAST(8 + r_response * 15 AS INT)                                   AS respondent_count,

  current_timestamp()                                                AS _ingested_at

FROM base;
