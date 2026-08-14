-- iPerceptions Snapshot — legacy CX vendor data, frozen 2015-2016.
-- iPerceptions did web-intercept surveys (popup on the utility's website when
-- customers browsed the site). The utility decommissioned the platform around
-- 2017 in favor of Qualtrics, but the historical snapshots are retained for
-- trending.
--
-- This table doesn't get new rows — it's a frozen historical artifact
-- demonstrating a real Customer 360 pattern: the lakehouse has to absorb
-- legacy data from deprecated tools.
--
-- ~3K snapshots (we sample a small fraction of the customer base that
-- existed in 2015-2016; some customers will have multiple snapshots).

CREATE OR REFRESH MATERIALIZED VIEW raw_iperceptions_snapshot (
  CONSTRAINT non_null_snapshot_id  EXPECT (snapshot_id IS NOT NULL),
  CONSTRAINT non_null_customer_id  EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_snapshot_date   EXPECT (snapshot_date BETWEEN DATE'2015-01-01' AND DATE'2016-12-31')
)
COMMENT 'iPerceptions web-intercept survey snapshots, frozen 2015-2016. The utility deprecated this platform in 2017 (replaced by Qualtrics). Retained as legacy CX data. Demonstrates how the lakehouse absorbs deprecated-tool history. ~3K rows. PK: snapshot_id. FK: customer_id -> raw_customer.'
AS

WITH

candidates AS (
  SELECT
    c.customer_id,
    c.archetype,
    abs(xxhash64(c.customer_id, 'iperc_select', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_select,
    abs(xxhash64(c.customer_id, 'iperc_year', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_year,
    abs(xxhash64(c.customer_id, 'iperc_day', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_day,
    abs(xxhash64(c.customer_id, 'iperc_intent', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_intent,
    abs(xxhash64(c.customer_id, 'iperc_csat', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_csat,
    abs(xxhash64(c.customer_id, 'iperc_task', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_task
  FROM ${customer_master_schema}.raw_customer c
  -- Historical era (2015-2016): prior customers were active customers then,
  -- so they are intentionally INCLUDED here (no is_prior_customer filter).
  -- ~6% of customers visited the utility website and were intercepted by iPerceptions.
  WHERE abs(xxhash64(c.customer_id, 'iperc_visit', ${random_seed})) % 100 < 6
)

SELECT
  md5(CONCAT('iperc_', customer_id))                                 AS snapshot_id,
  customer_id,
  -- Snapshot date: 50/50 split between 2015 and 2016.
  CASE WHEN r_year < 0.50
    THEN DATE_ADD(DATE'2015-01-01', CAST(r_day * 364 AS INT))
    ELSE DATE_ADD(DATE'2016-01-01', CAST(r_day * 365 AS INT))
  END                                                                AS snapshot_date,

  -- Visit intent (the iPerceptions question "Why did you visit the website today?").
  CASE
    WHEN r_intent < 0.40 THEN 'view_or_pay_bill'
    WHEN r_intent < 0.60 THEN 'report_outage'
    WHEN r_intent < 0.75 THEN 'usage_or_account'
    WHEN r_intent < 0.85 THEN 'service_move'
    WHEN r_intent < 0.92 THEN 'energy_efficiency_programs'
    ELSE                      'general_info'
  END                                                                AS visit_intent,

  -- Task completion (did the customer accomplish what they came for?).
  -- Skewed lower for engaged archetypes who actually engage with the survey.
  CASE
    WHEN r_task < 0.62 THEN true
    ELSE                    false
  END                                                                AS task_completed_flag,

  -- Site CSAT (1-5 scale, iPerceptions specific).
  CASE
    WHEN archetype = 'tech_forward'      AND r_csat < 0.65 THEN 5
    WHEN archetype = 'tech_forward'      AND r_csat < 0.85 THEN 4
    WHEN archetype = 'efficient_engaged' AND r_csat < 0.70 THEN 5
    WHEN archetype = 'efficient_engaged' AND r_csat < 0.88 THEN 4
    WHEN archetype = 'cost_stressed'     AND r_csat < 0.25 THEN 5
    WHEN archetype = 'cost_stressed'     AND r_csat < 0.45 THEN 4
    WHEN archetype = 'cost_stressed'     AND r_csat < 0.70 THEN 3
    WHEN archetype = 'cost_stressed'                       THEN 2
    WHEN r_csat < 0.55 THEN 4
    WHEN r_csat < 0.85 THEN 3
    ELSE                    2
  END                                                                AS site_csat_1_5,

  -- Completion rate (% of survey questions answered, since this was a popup).
  -- iPerceptions surveys had high abandonment; we model ~70% completion.
  CAST(60 + r_task * 40 AS INT)                                      AS completion_rate_pct,

  'iperceptions_legacy'                                              AS data_source,
  current_timestamp()                                                AS _ingested_at

FROM candidates;
