-- Payment Plan — deferred payment plan agreements.
-- Customers whose arrears (previous_balance) exceed $300 are offered a
-- payment plan; ~60% accept. One plan per customer per "qualifying"
-- billing month (we take the first month they crossed $300).
--
-- Terms: 6 months default, 12 months for larger balances. Monthly
-- payment = initial_balance / term_months + small admin fee.
--
-- Plan status reflects whether they completed it or defaulted (broke
-- the plan with a missed payment). Cost_stressed customers default
-- more often.

CREATE OR REFRESH MATERIALIZED VIEW raw_payment_plan (
  CONSTRAINT non_null_plan_id      EXPECT (plan_id IS NOT NULL),
  CONSTRAINT non_null_customer_id  EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_status          EXPECT (plan_status IN ('active','completed','defaulted','cancelled')),
  CONSTRAINT positive_balance      EXPECT (initial_balance_usd > 0)
)
COMMENT 'Payment Plan agreements. Customers with previous_balance > $300 are offered a plan; ~60% accept. Cost_stressed defaults more often. PK: plan_id. FK: customer_id -> raw_customer.'
AS

WITH

-- Find the first billing month where each customer crossed $300 in arrears.
ranked_arrears AS (
  SELECT
    customer_id,
    account_id,
    bill_period_end,
    previous_balance,
    ROW_NUMBER() OVER (
      PARTITION BY customer_id
      ORDER BY bill_period_end
    ) AS rn
  FROM ${billing_schema}.raw_customer_billing
  WHERE previous_balance > 300
),

qualifying_first AS (
  SELECT
    customer_id,
    account_id,
    bill_period_end                       AS first_arrears_month,
    previous_balance                      AS initial_balance_usd
  FROM ranked_arrears
  WHERE rn = 1
),

with_attrs AS (
  SELECT
    q.*,
    c.archetype,
    abs(xxhash64(q.customer_id, 'pp_accept',   ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_accept,
    abs(xxhash64(q.customer_id, 'pp_outcome',  ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_outcome
  FROM qualifying_first q
  JOIN ${customer_master_schema}.raw_customer c USING (customer_id)
),

-- ~60% accept the offered plan.
accepted AS (
  SELECT * FROM with_attrs WHERE r_accept < 0.60
)

SELECT
  md5(CONCAT(customer_id, '_pp_', CAST(first_arrears_month AS STRING)))  AS plan_id,
  customer_id,
  account_id,

  -- Plan starts ~14 days after the qualifying bill closed.
  DATE_ADD(first_arrears_month, 14)                                    AS plan_start_date,

  -- Term: 6 months default, 12 months for larger balances ($800+).
  CASE WHEN initial_balance_usd > 800 THEN 12 ELSE 6 END               AS term_months,

  ROUND(initial_balance_usd, 2)                                        AS initial_balance_usd,

  -- Monthly payment = balance / term + $5 admin fee.
  ROUND(
    initial_balance_usd / CASE WHEN initial_balance_usd > 800 THEN 12 ELSE 6 END
    + 5.00, 2
  )                                                                    AS monthly_payment_usd,

  -- Status:
  --   cost_stressed defaults more often (~45%)
  --   others default ~15%
  CASE
    WHEN archetype = 'cost_stressed' AND r_outcome < 0.45 THEN 'defaulted'
    WHEN archetype = 'cost_stressed' AND r_outcome < 0.75 THEN 'completed'
    WHEN archetype = 'cost_stressed' AND r_outcome < 0.95 THEN 'active'
    WHEN archetype = 'cost_stressed'                       THEN 'cancelled'
    WHEN r_outcome < 0.15                                  THEN 'defaulted'
    WHEN r_outcome < 0.65                                  THEN 'completed'
    WHEN r_outcome < 0.93                                  THEN 'active'
    ELSE                                                        'cancelled'
  END                                                                  AS plan_status,

  current_timestamp()                                                  AS _ingested_at
FROM accepted;
