-- Survey invitations aggregate — the response-rate denominator for the CSAT
-- view's Survey Health panel (csat-experience-view-design.md §4.2).
--
-- Grain: (survey_id, period_date_key, segment). period_date_key is the
-- survey's launch date (the invitation event), not the response date —
-- invitations happen at launch, so this is the natural period anchor for a
-- per-quarter response-rate trend. NPS only: CSAT has no invited/declined
-- population modeled (see raw_qualtrics_invitation.sql), so it is not
-- represented here and the app must keep CSAT survey health volume-only.

CREATE OR REFRESH MATERIALIZED VIEW fact_survey_invitations (
  survey_id       STRING NOT NULL,
  period_date_key INT NOT NULL,
  segment         STRING,
  n_invited       BIGINT,
  n_responded     BIGINT,
  _ingested_at    TIMESTAMP,
  CONSTRAINT fk_fsi_date FOREIGN KEY (period_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'NPS survey invitation/response counts by survey and customer segment, for response-rate reporting (n_responded / n_invited). Grain: (survey_id, period_date_key, segment). period_date_key is the survey launch date, not the response date. NPS only — CSAT has no invited/declined step modeled, so CSAT survey health stays volume-only.'
AS

SELECT
  i.survey_id,
  CAST(DATE_FORMAT(i.launch_date, 'yyyyMMdd') AS INT)   AS period_date_key,
  LOWER(dc.customer_class)                              AS segment,
  COUNT(*)                                               AS n_invited,
  SUM(CASE WHEN i.responded_flag THEN 1 ELSE 0 END)      AS n_responded,
  current_timestamp()                                    AS _ingested_at
FROM ${surveys_schema}.raw_qualtrics_invitation i
JOIN dim_customer dc ON dc.customer_id = abs(xxhash64(i.customer_id))
GROUP BY
  i.survey_id,
  CAST(DATE_FORMAT(i.launch_date, 'yyyyMMdd') AS INT),
  LOWER(dc.customer_class);
