-- Qualtrics Invitation — the invited-but-not-necessarily-responding NPS
-- population (response-rate denominator, csat-experience-view-design.md
-- §4.2).
--
-- raw_qualtrics_response.sql already computes an "invited" draw (r_sample)
-- and a "responded" draw (r_respond) for every (survey, customer) pair, but
-- both filters are applied in one WHERE and only the surviving (invited AND
-- responded) rows are kept — the invited-but-silent rows are discarded, so
-- no response-rate denominator is otherwise queryable. This view reruns
-- the identical NPS candidate population with the identical xxhash64 draws
-- (same keys: survey_id, customer_id, 'sample' / 'respond', ${random_seed})
-- and keeps every invited row, flagging whether it went on to respond.
-- responded_flag = true here will exactly match — by construction, same
-- deterministic draws — the NPS rows in raw_qualtrics_response for that
-- survey_id.
--
-- CSAT has no invited/responded split modeled: the 10% CSAT sample in
-- raw_qualtrics_response is drawn directly from Genesys interactions as the
-- response itself, with no "offered a survey, declined" step. So this table
-- covers NPS only; CSAT survey health stays volume-only (labeled honestly
-- in the app), per the design doc's own recommendation.
--
-- ~25% of (survey × current-occupant customer) pairs are invited per
-- quarterly NPS survey -> comparable row count to nps_candidates in
-- raw_qualtrics_response.sql (~200K invited rows across 8 quarters).

CREATE OR REFRESH MATERIALIZED VIEW raw_qualtrics_invitation (
  CONSTRAINT non_null_survey_id   EXPECT (survey_id IS NOT NULL),
  CONSTRAINT non_null_customer_id EXPECT (customer_id IS NOT NULL)
)
COMMENT 'Invited (sampled) population for quarterly NPS surveys, including those who did not respond — the response-rate denominator raw_qualtrics_response.sql discards. responded_flag reuses the same deterministic xxhash64 draw as raw_qualtrics_response.sql, so it agrees with that table by construction. NPS only (CSAT has no invite/decline step modeled). PK: (survey_id, customer_id). FK: survey_id -> qualtrics_survey; customer_id -> raw_customer.'
AS

SELECT
  s.survey_id,
  s.launch_date,
  c.customer_id,
  (abs(xxhash64(s.survey_id, c.customer_id, 'respond', ${random_seed}))
    / CAST(9223372036854775807 AS DOUBLE)) < 0.30                      AS responded_flag,
  current_timestamp()                                                  AS _ingested_at
FROM raw_qualtrics_survey s
CROSS JOIN ${customer_master_schema}.raw_customer c
WHERE s.survey_type = 'nps_relationship'
  AND NOT c.is_prior_occupant                                          -- current occupants only, matches nps_candidates
  AND (abs(xxhash64(s.survey_id, c.customer_id, 'sample', ${random_seed}))
    / CAST(9223372036854775807 AS DOUBLE)) < 0.25;                     -- the invited/sampled 25%
