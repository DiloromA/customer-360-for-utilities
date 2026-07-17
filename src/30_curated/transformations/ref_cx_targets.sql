-- CX target/benchmark reference seed. Static catalog of internal goals and
-- external benchmarks (J.D. Power, ACSI) per (metric, year, segment), used to
-- draw target lines and vs-target deltas on the CSAT view. Materialized as a
-- static VALUES list (not synthesized from data) — same pattern as
-- dim_rate_schedule. jdpower_value/acsi_value are only meaningful for the
-- csat metric today and are NULL elsewhere.

CREATE OR REFRESH MATERIALIZED VIEW ref_cx_targets (
  metric        STRING NOT NULL,
  year          INT NOT NULL,
  segment       STRING NOT NULL,
  target_value  DOUBLE,
  jdpower_value DOUBLE,
  acsi_value    DOUBLE
)
COMMENT 'CX target/benchmark reference seed. One row per (metric, year, segment) with the internal goal and, for csat, external J.D. Power / ACSI benchmark figures. Static catalog, not synthesized from data.'
AS
SELECT
  metric,
  CAST(year AS INT)          AS year,
  segment,
  CAST(target_value AS DOUBLE)  AS target_value,
  CAST(jdpower_value AS DOUBLE)  AS jdpower_value,
  CAST(acsi_value AS DOUBLE)    AS acsi_value
FROM VALUES
  -- CSAT: top-2-box % target, plus J.D. Power (residential electric, ~1000-pt scale) and ACSI (0-100) benchmarks.
  ('csat', 2017, 'all',         85.0, 750.0, 73.0),
  ('csat', 2017, 'residential', 85.0, 760.0, 74.0),
  ('csat', 2017, 'commercial',  82.0, 720.0, 71.0),
  ('csat', 2018, 'all',         86.0, 755.0, 74.0),
  ('csat', 2018, 'residential', 86.0, 765.0, 75.0),
  ('csat', 2018, 'commercial',  83.0, 725.0, 72.0),
  -- NPS: target score (promoters - detractors, -100..100 scale). No external benchmark tracked.
  ('nps', 2017, 'all',         30.0, NULL, NULL),
  ('nps', 2017, 'residential', 32.0, NULL, NULL),
  ('nps', 2017, 'commercial',  22.0, NULL, NULL),
  ('nps', 2018, 'all',         32.0, NULL, NULL),
  ('nps', 2018, 'residential', 34.0, NULL, NULL),
  ('nps', 2018, 'commercial',  24.0, NULL, NULL),
  -- FCR: target rate as a %.
  ('fcr', 2017, 'all',         75.0, NULL, NULL),
  ('fcr', 2017, 'residential', 76.0, NULL, NULL),
  ('fcr', 2017, 'commercial',  72.0, NULL, NULL),
  ('fcr', 2018, 'all',         77.0, NULL, NULL),
  ('fcr', 2018, 'residential', 78.0, NULL, NULL),
  ('fcr', 2018, 'commercial',  74.0, NULL, NULL),
  -- AHT: target average handle time in seconds (lower is better).
  ('aht', 2017, 'all',         360.0, NULL, NULL),
  ('aht', 2017, 'residential', 340.0, NULL, NULL),
  ('aht', 2017, 'commercial',  420.0, NULL, NULL),
  ('aht', 2018, 'all',         350.0, NULL, NULL),
  ('aht', 2018, 'residential', 330.0, NULL, NULL),
  ('aht', 2018, 'commercial',  410.0, NULL, NULL)
AS t(metric, year, segment, target_value, jdpower_value, acsi_value);
