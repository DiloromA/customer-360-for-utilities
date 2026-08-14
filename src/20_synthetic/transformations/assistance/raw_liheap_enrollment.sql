-- LIHEAP Enrollment — Low-Income Home Energy Assistance Program.
-- Federal program; eligibility is income-based. We enrolled at ~40%
-- of liheap_eligible customers per federal fiscal year (Oct 1 - Sep 30).
-- ~5-7K rows total across two program years.
--
-- Benefit amounts vary by state allocation and household need. We model
-- $200-800 per enrollment (typical Michigan range).

CREATE OR REFRESH MATERIALIZED VIEW raw_liheap_enrollment (
  CONSTRAINT non_null_enrollment_id  EXPECT (enrollment_id IS NOT NULL),
  CONSTRAINT non_null_customer_id    EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_status            EXPECT (benefit_status IN ('approved','pending','denied')),
  CONSTRAINT positive_benefit        EXPECT (benefit_amount_usd > 0 OR benefit_status != 'approved')
)
COMMENT 'LIHEAP enrollment. One row per (eligible current customer, program year); prior-customer customers excluded. ~40% of liheap_eligible customers enroll each year. Drives compliance + vulnerable-customer reporting. PK: enrollment_id. FK: customer_id -> raw_customer.'
AS

WITH

eligible AS (
  SELECT customer_id, archetype, income_band, household_size, language_preference
  FROM ${customer_master_schema}.raw_customer
  WHERE liheap_eligible = true
    AND NOT is_prior_customer                                          -- current customers only
),

program_years AS (
  SELECT * FROM VALUES
    (2017, DATE'2016-10-01', DATE'2017-09-30'),
    (2018, DATE'2017-10-01', DATE'2018-09-30')
  AS t(program_year, ffy_start, ffy_end)
),

candidates AS (
  SELECT
    e.*,
    py.program_year,
    py.ffy_start,
    py.ffy_end,
    abs(xxhash64(e.customer_id, py.program_year, 'enroll', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_enroll,
    abs(xxhash64(e.customer_id, py.program_year, 'day', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_day,
    abs(xxhash64(e.customer_id, py.program_year, 'amount', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_amount,
    abs(xxhash64(e.customer_id, py.program_year, 'status', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_status,
    abs(xxhash64(e.customer_id, py.program_year, 'type', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_type
  FROM eligible e
  CROSS JOIN program_years py
),

-- ~40% enroll. Cost_stressed customers enroll at higher rate (more aware).
enrolled AS (
  SELECT *
  FROM candidates
  WHERE r_enroll <
    CASE
      WHEN archetype = 'cost_stressed'        THEN 0.55
      WHEN archetype = 'senior_fixed_income'  THEN 0.50
      WHEN archetype = 'inefficient_unaware'  THEN 0.30
      ELSE                                         0.35
    END
)

SELECT
  md5(CONCAT(customer_id, '_liheap_', CAST(program_year AS STRING)))  AS enrollment_id,
  customer_id,
  program_year,
  DATE_ADD(ffy_start, CAST(r_day * 200 AS INT))                       AS enrollment_date,
  ffy_start                                                            AS federal_fiscal_year_start,
  ffy_end                                                              AS federal_fiscal_year_end,

  -- Benefit amount $200-800 typical, with household-size scaling.
  CAST(
    (200 + r_amount * 350) * (0.8 + COALESCE(household_size, 2) * 0.10)
    AS INT)                                                            AS benefit_amount_usd,

  -- Benefit status. ~80% approved, 15% pending (during initial review),
  -- 5% denied (missing documentation, ineligibility after review).
  CASE
    WHEN r_status < 0.80 THEN 'approved'
    WHEN r_status < 0.95 THEN 'pending'
    ELSE                      'denied'
  END                                                                  AS benefit_status,

  -- Type of LIHEAP assistance.
  CASE
    WHEN r_type < 0.55 THEN 'heating_assistance'
    WHEN r_type < 0.75 THEN 'cooling_assistance'
    WHEN r_type < 0.92 THEN 'crisis_assistance'
    ELSE                    'weatherization_referral'
  END                                                                  AS payment_assistance_type,

  -- Application channel.
  CASE
    WHEN r_day < 0.40 THEN 'community_action_agency'
    WHEN r_day < 0.65 THEN 'online_portal'
    WHEN r_day < 0.85 THEN 'phone'
    ELSE                   'in_person'
  END                                                                  AS application_channel,

  language_preference                                                  AS application_language,

  current_timestamp()                                                  AS _ingested_at
FROM enrolled;
