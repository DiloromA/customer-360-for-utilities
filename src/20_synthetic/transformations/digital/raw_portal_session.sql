-- Portal Session — one row per customer login to the utility web portal or
-- mobile app. ~1.5M sessions over 2017+2018.
--
-- Frequency is archetype-biased. Pattern: tech_forward & efficient_engaged
-- log in often (monthly+, sometimes weekly); senior_fixed_income rarely
-- (a few per year). cost_stressed and inefficient_unaware land in the
-- middle (drive-by payments + bill questions).
--
-- On top of the archetype baseline, energy-efficiency / DSM program
-- participants (raw_dsm_enrollment) get a session-frequency boost: enrolling
-- in a rebate/audit/DR program is itself a digital act, so participants use the
-- web/app portal more. This is the explicit EE -> digital referential-integrity
-- link, and it flows through to digital_adoption_score in dim_customer.
--
-- We EXPLODE a per-customer monthly session count to materialize sessions
-- with realistic spread across the month.

CREATE OR REFRESH MATERIALIZED VIEW raw_portal_session (
  CONSTRAINT non_null_session_id  EXPECT (session_id IS NOT NULL),
  CONSTRAINT non_null_customer_id EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_platform       EXPECT (platform IN ('web','ios','android')),
  CONSTRAINT positive_duration    EXPECT (duration_seconds > 0)
)
COMMENT 'Portal Session — one row per utility web/app login. ~1.5M rows over 2017+2018. Archetype-biased session frequency. Current customers only (prior-customer customers excluded); joined to the customer''s single primary account. PK: session_id. FK: customer_id -> raw_customer.'
AS

WITH

years AS (
  SELECT DISTINCT YEAR(d) AS year
  FROM (SELECT EXPLODE(SEQUENCE(
    DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
    DATE'${as_of_date}',
    INTERVAL 1 MONTH
  )) AS d)
),
months AS (
  SELECT EXPLODE(SEQUENCE(1, 12)) AS month
),

-- Energy-efficiency / DSM participants. Enrolling in a rebate, audit, or DR
-- program is a digitally-engaged act (applications, rebate tracking, program
-- pages), so participants log into the web/app portal MORE than their archetype
-- baseline. This is the explicit referential-integrity link the demo needs:
-- EE participation causally lifts digital usage (and, downstream, the
-- digital_adoption_score in dim_customer). The whole DSM portfolio
-- counts as "EE" here (see raw_dsm_program). SDP resolves this same-pipeline
-- read into a DAG edge automatically (no cycle: digital never feeds DSM).
ee_participants AS (
  SELECT DISTINCT customer_id
  FROM ${dsm_programs_schema}.raw_dsm_enrollment
  WHERE enrollment_status IN ('enrolled','completed')
),

customer_months AS (
  SELECT
    c.customer_id,
    c.archetype,
    a.account_id,
    a.preferred_channel,
    y.year, m.month,
    (ee.customer_id IS NOT NULL) AS is_ee_participant,
    abs(xxhash64(c.customer_id, y.year, m.month, 'sess_count', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_count
  FROM ${customer_master_schema}.raw_customer c
  JOIN ${customer_master_schema}.raw_customer_account a
    ON a.customer_id = c.customer_id
   AND a.account_group IN ('standard','corporate_parent')   -- exactly one account per current customer (no chain fan-out)
  LEFT JOIN ee_participants ee ON ee.customer_id = c.customer_id
  CROSS JOIN years y
  CROSS JOIN months m
  WHERE NOT c.is_prior_customer                              -- current customers only
),

with_count AS (
  SELECT *,
    CAST(
      CASE archetype
        WHEN 'tech_forward' THEN
          CASE WHEN r_count < 0.10 THEN 1
               WHEN r_count < 0.35 THEN 2
               WHEN r_count < 0.65 THEN 3
               WHEN r_count < 0.85 THEN 4
               WHEN r_count < 0.95 THEN 5
               ELSE                      7 END
        WHEN 'efficient_engaged' THEN
          CASE WHEN r_count < 0.20 THEN 1
               WHEN r_count < 0.55 THEN 2
               WHEN r_count < 0.85 THEN 3
               WHEN r_count < 0.97 THEN 4
               ELSE                      5 END
        WHEN 'cost_stressed' THEN
          CASE WHEN r_count < 0.35 THEN 0
               WHEN r_count < 0.65 THEN 1
               WHEN r_count < 0.90 THEN 2
               ELSE                      3 END
        WHEN 'inefficient_unaware' THEN
          CASE WHEN r_count < 0.55 THEN 0
               WHEN r_count < 0.85 THEN 1
               ELSE                      2 END
        WHEN 'comfortable_indifferent' THEN
          CASE WHEN r_count < 0.50 THEN 0
               WHEN r_count < 0.85 THEN 1
               ELSE                      2 END
        WHEN 'senior_fixed_income' THEN
          CASE WHEN r_count < 0.85 THEN 0
               WHEN r_count < 0.97 THEN 1
               ELSE                      2 END
        ELSE
          CASE WHEN r_count < 0.50 THEN 0
               WHEN r_count < 0.90 THEN 1
               ELSE                      2 END
      END
      AS INT
    ) AS n_sessions_base
  FROM customer_months
),

-- Apply the EE-participation boost. Participants get ~30% more sessions (at
-- least +1 when already active), and a chance of a login in a month they would
-- otherwise have skipped — a modest, deterministic lift that keeps the
-- archetype shape but makes EE enrollees measurably more digitally active.
with_boost AS (
  SELECT
    *,
    CAST(
      CASE
        WHEN is_ee_participant AND n_sessions_base > 0
          THEN n_sessions_base + GREATEST(1, CAST(n_sessions_base * 0.3 AS INT))
        WHEN is_ee_participant AND n_sessions_base = 0 AND r_count < 0.40
          THEN 1
        ELSE n_sessions_base
      END
      AS INT
    ) AS n_sessions
  FROM with_count
),

session_seq AS (
  SELECT
    cm.customer_id, cm.account_id, cm.archetype, cm.preferred_channel,
    cm.year, cm.month, sess.idx AS sess_idx
  FROM (SELECT * FROM with_boost WHERE n_sessions > 0) cm
  LATERAL VIEW EXPLODE(SEQUENCE(1, cm.n_sessions)) sess AS idx
),

with_attrs AS (
  SELECT
    *,
    abs(xxhash64(customer_id, year, month, sess_idx, 'secs_in_month', ${random_seed}))
      % (86400 * 28)                                                 AS r_second_in_month,
    abs(xxhash64(customer_id, year, month, sess_idx, 'platform', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_platform,
    abs(xxhash64(customer_id, year, month, sess_idx, 'entry', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_entry,
    abs(xxhash64(customer_id, year, month, sess_idx, 'duration', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_duration,
    abs(xxhash64(customer_id, year, month, sess_idx, 'pages', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_pages,
    abs(xxhash64(customer_id, year, month, sess_idx, 'outcome', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_outcome
  FROM session_seq
)

SELECT
  md5(CONCAT(customer_id, '_', CAST(year AS STRING),
             '_', LPAD(CAST(month AS STRING), 2, '0'),
             '_sess_', CAST(sess_idx AS STRING)))                    AS session_id,
  customer_id,
  account_id,

  -- Platform mix:
  --   tech_forward: 50% mobile (iOS/Android split), 50% web
  --   efficient_engaged: 35% mobile, 65% web
  --   senior_fixed_income: 5% mobile, 95% web (and that 5% is iOS)
  --   others: 25% mobile, 75% web
  CASE
    WHEN archetype = 'tech_forward'        AND r_platform < 0.30 THEN 'ios'
    WHEN archetype = 'tech_forward'        AND r_platform < 0.50 THEN 'android'
    WHEN archetype = 'tech_forward'                                THEN 'web'
    WHEN archetype = 'efficient_engaged'   AND r_platform < 0.20 THEN 'ios'
    WHEN archetype = 'efficient_engaged'   AND r_platform < 0.35 THEN 'android'
    WHEN archetype = 'efficient_engaged'                            THEN 'web'
    WHEN archetype = 'senior_fixed_income' AND r_platform < 0.05 THEN 'ios'
    WHEN archetype = 'senior_fixed_income'                          THEN 'web'
    WHEN r_platform < 0.15                                          THEN 'ios'
    WHEN r_platform < 0.25                                          THEN 'android'
    ELSE                                                                 'web'
  END                                                                AS platform,

  -- Started_at = random second within the month.
  TIMESTAMPADD(SECOND,
    CAST(r_second_in_month AS INT),
    MAKE_TIMESTAMP(year, month, 1, 0, 0, 0, 'UTC')
  )                                                                  AS started_at,

  -- Duration: lognormal-ish. Most sessions 60-180s (pay-and-go);
  -- some longer (browsing, program enrollment); rare 30+ min "researching" sessions.
  CAST(
    CASE
      WHEN r_duration < 0.65 THEN 30  + r_duration / 0.65 * 150     -- 30-180s
      WHEN r_duration < 0.92 THEN 180 + (r_duration - 0.65) / 0.27 * 420  -- 180-600s
      WHEN r_duration < 0.99 THEN 600 + (r_duration - 0.92) / 0.07 * 1200 -- 600-1800s
      ELSE                       1800 + (r_duration - 0.99) / 0.01 * 1800 -- 1800-3600s
    END
    AS INT)                                                          AS duration_seconds,

  -- Entry page reflects what the customer is there to do.
  CASE
    WHEN r_entry < 0.55 THEN 'dashboard'           -- the default home
    WHEN r_entry < 0.78 THEN 'billing'              -- direct nav to pay
    WHEN r_entry < 0.88 THEN 'usage'
    WHEN r_entry < 0.93 THEN 'outage_map'
    WHEN r_entry < 0.97 THEN 'programs'
    ELSE                     'account_settings'
  END                                                                AS entry_page,

  -- Pages viewed (proxy for engagement depth).
  CAST(1 + r_pages * 8 AS INT)                                       AS pages_viewed,

  -- Session outcome.
  CASE
    WHEN r_entry < 0.55 AND r_outcome < 0.30 THEN 'paid_bill'
    WHEN r_entry < 0.78 AND r_outcome < 0.60 THEN 'paid_bill'
    WHEN r_entry < 0.93 AND r_outcome < 0.20 THEN 'reported_outage'
    WHEN r_entry < 0.97 AND r_outcome < 0.30 THEN 'enrolled_program'
    WHEN r_outcome > 0.97                    THEN 'errored'
    ELSE                                          'viewed_only'
  END                                                                AS session_outcome,

  current_timestamp()                                                AS _ingested_at
FROM with_attrs;
