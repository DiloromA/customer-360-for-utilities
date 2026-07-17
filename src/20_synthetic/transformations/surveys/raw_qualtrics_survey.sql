-- Qualtrics Survey — metadata for each survey instance launched.
-- Small lookup table (~12 rows) describing the surveys that exist in
-- the qualtrics_response table. PK: survey_id.

CREATE OR REFRESH MATERIALIZED VIEW raw_qualtrics_survey
COMMENT 'Qualtrics survey metadata. ~12 surveys across 2017+2018 (4 quarterly NPS, post-call CSAT continuous, 2-3 custom outage / DSM follow-ups). PK: survey_id.'
AS

SELECT * FROM VALUES
  ('SVY-NPS-2017Q1',    'Relationship NPS 2017 Q1',        'nps_relationship', DATE'2017-01-15', DATE'2017-03-31', 'quarterly'),
  ('SVY-NPS-2017Q2',    'Relationship NPS 2017 Q2',        'nps_relationship', DATE'2017-04-15', DATE'2017-06-30', 'quarterly'),
  ('SVY-NPS-2017Q3',    'Relationship NPS 2017 Q3',        'nps_relationship', DATE'2017-07-15', DATE'2017-09-30', 'quarterly'),
  ('SVY-NPS-2017Q4',    'Relationship NPS 2017 Q4',        'nps_relationship', DATE'2017-10-15', DATE'2017-12-31', 'quarterly'),
  ('SVY-NPS-2018Q1',    'Relationship NPS 2018 Q1',        'nps_relationship', DATE'2018-01-15', DATE'2018-03-31', 'quarterly'),
  ('SVY-NPS-2018Q2',    'Relationship NPS 2018 Q2',        'nps_relationship', DATE'2018-04-15', DATE'2018-06-30', 'quarterly'),
  ('SVY-NPS-2018Q3',    'Relationship NPS 2018 Q3',        'nps_relationship', DATE'2018-07-15', DATE'2018-09-30', 'quarterly'),
  ('SVY-NPS-2018Q4',    'Relationship NPS 2018 Q4',        'nps_relationship', DATE'2018-10-15', DATE'2018-12-31', 'quarterly'),
  ('SVY-CSAT-CONT',     'Post-Call CSAT (continuous)',     'csat_transactional', DATE'2017-01-01', DATE'2018-12-31', 'continuous'),
  ('SVY-OUTAGE-2018',   'Outage Response Follow-up 2018',  'custom_outage',     DATE'2018-01-01', DATE'2018-12-31', 'event_triggered'),
  ('SVY-DSM-EE-2018',   'EE Program Enrollment Survey',    'custom_dsm',        DATE'2018-04-01', DATE'2018-09-30', 'event_triggered'),
  ('SVY-MOVE-IN-2018',  'New Customer Onboarding 2018',    'custom_move',       DATE'2018-01-01', DATE'2018-12-31', 'event_triggered')
AS t(survey_id, name, survey_type, launch_date, close_date, cadence);
