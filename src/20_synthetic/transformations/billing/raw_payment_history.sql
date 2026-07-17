-- Payment History — CIM PaymentTransaction. One row per bill payment
-- event. Status reflects archetype-driven payment behavior with autopay
-- override (autopay customers pay reliably regardless of archetype).
--
-- Statuses:
--   paid_on_time   payment received on or before due_date, in full
--   paid_late      payment received after due_date, in full
--   paid_partial   payment received late, for less than current_charges
--   unpaid         no payment by the end of the billing cycle
--
-- The status determination uses the same hash draw as the
-- previous_balance carry-forward in raw_customer_billing.sql so the two
-- tables agree row-for-row.

CREATE OR REFRESH MATERIALIZED VIEW raw_payment_history (
  CONSTRAINT non_null_payment_id EXPECT (payment_id IS NOT NULL),
  CONSTRAINT non_null_bill_id    EXPECT (bill_id IS NOT NULL),
  CONSTRAINT valid_status        EXPECT (payment_status IN ('paid_on_time','paid_late','paid_partial','unpaid'))
)
COMMENT 'Payment History — CIM PaymentTransaction. One row per bill, with payment_status reflecting archetype-driven behavior. Autopay customers pay on time ~99% of the time regardless of archetype; cost_stressed non-autopay customers skip or partial-pay ~45% of bills, accruing arrears that the customer_billing previous_balance picks up. PK: payment_id. FK: bill_id -> customer_billing.bill_id.'
AS

WITH base AS (
  SELECT
    cb.bill_id,
    cb.account_id,
    cb.customer_id,
    cb.current_charges,
    cb.bill_date,
    cb.due_date,
    a.autopay_enrolled,
    a.preferred_channel,
    c.archetype,
    abs(xxhash64(cb.account_id, cb.bill_id, 'pay_status', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_status,
    abs(xxhash64(cb.account_id, cb.bill_id, 'pay_lag',    ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_lag
  FROM raw_customer_billing cb
  JOIN ${customer_master_schema}.raw_customer_account a USING (account_id)
  JOIN ${customer_master_schema}.raw_customer c USING (customer_id)
),

-- Single source of truth for status + paid fraction. Everything else
-- (amount, days_late, payment_date) derives from this.
classified AS (
  SELECT
    *,
    CASE
      -- Autopay: 99% on-time, 1% NSF-late
      WHEN autopay_enrolled AND r_status < 0.99 THEN 'paid_on_time'
      WHEN autopay_enrolled                      THEN 'paid_late'
      -- Per-archetype thresholds (these must match raw_customer_billing.sql)
      WHEN archetype = 'efficient_engaged'        AND r_status < 0.99 THEN 'paid_on_time'
      WHEN archetype = 'tech_forward'             AND r_status < 0.97 THEN 'paid_on_time'
      WHEN archetype = 'senior_fixed_income'      AND r_status < 0.96 THEN 'paid_on_time'
      WHEN archetype = 'comfortable_indifferent'  AND r_status < 0.90 THEN 'paid_on_time'
      WHEN archetype = 'inefficient_unaware'      AND r_status < 0.83 THEN 'paid_on_time'
      WHEN archetype = 'cost_stressed'            AND r_status < 0.55 THEN 'paid_on_time'
      -- Partial-pay carve-outs (must match the carry-forward fractions in customer_billing)
      WHEN archetype = 'cost_stressed'       AND r_status < 0.75 THEN 'paid_partial'
      WHEN archetype = 'cost_stressed'       AND r_status < 0.85 THEN 'paid_partial'
      WHEN archetype = 'inefficient_unaware' AND r_status < 0.93 THEN 'paid_partial'
      -- All remaining cost_stressed go unpaid
      WHEN archetype = 'cost_stressed'                            THEN 'unpaid'
      -- Other archetypes: late instead of unpaid (more realistic — they pay eventually)
      ELSE 'paid_late'
    END                                                              AS payment_status,

    CASE
      WHEN archetype = 'cost_stressed' AND r_status >= 0.55 AND r_status < 0.75 THEN 0.5
      WHEN archetype = 'cost_stressed' AND r_status >= 0.75 AND r_status < 0.85 THEN 0.3
      WHEN archetype = 'inefficient_unaware' AND r_status >= 0.83 AND r_status < 0.93 THEN 0.6
      ELSE 1.0
    END                                                              AS pay_fraction_when_partial
  FROM base
),

with_lag AS (
  SELECT
    *,
    -- Days late: derived per status.
    CASE payment_status
      WHEN 'paid_on_time' THEN
        CASE
          WHEN autopay_enrolled THEN -2
          WHEN archetype = 'efficient_engaged'        THEN CAST(-3 + r_lag * 5 AS INT)  -- -3..+2
          WHEN archetype = 'tech_forward'             THEN CAST(-2 + r_lag * 5 AS INT)  -- -2..+2
          WHEN archetype = 'senior_fixed_income'      THEN CAST(0  + r_lag * 5 AS INT)  --  0..+4 (slow but reliable)
          WHEN archetype = 'comfortable_indifferent'  THEN CAST(-1 + r_lag * 5 AS INT)
          WHEN archetype = 'inefficient_unaware'      THEN CAST( 0 + r_lag * 5 AS INT)
          WHEN archetype = 'cost_stressed'            THEN CAST( 0 + r_lag * 5 AS INT)
          ELSE 0
        END
      WHEN 'paid_late'    THEN CAST(7  + r_lag * 23 AS INT)   -- 7-30 days late
      WHEN 'paid_partial' THEN CAST(10 + r_lag * 25 AS INT)   -- 10-35 days late
      WHEN 'unpaid'       THEN CAST(NULL AS INT)
    END                                                              AS days_late
  FROM classified
)

SELECT
  md5(CONCAT(bill_id, '_payment')) AS payment_id,
  bill_id,
  account_id,
  customer_id,

  payment_status,

  -- Amount paid: 0 for unpaid; full amount for on-time/late; partial fraction otherwise.
  ROUND(
    CASE payment_status
      WHEN 'paid_on_time' THEN current_charges
      WHEN 'paid_late'    THEN current_charges
      WHEN 'paid_partial' THEN current_charges * pay_fraction_when_partial
      WHEN 'unpaid'       THEN 0.0
    END, 2
  )                                                                  AS amount_paid,

  days_late,

  -- Payment date: due_date + days_late; NULL for unpaid.
  CASE WHEN payment_status = 'unpaid'
       THEN CAST(NULL AS DATE)
       ELSE DATE_ADD(due_date, days_late)
  END                                                                AS payment_date,

  -- Payment method.
  CASE
    WHEN payment_status = 'unpaid'                                  THEN CAST(NULL AS STRING)
    WHEN autopay_enrolled                                            THEN 'autopay'
    WHEN archetype = 'senior_fixed_income' AND r_lag < 0.70          THEN 'mail_check'
    WHEN archetype = 'senior_fixed_income'                           THEN 'phone'
    WHEN preferred_channel = 'email' AND r_lag < 0.85                THEN 'online_portal'
    WHEN preferred_channel = 'email'                                 THEN 'online_onetime'
    WHEN preferred_channel = 'sms'                                   THEN 'text_to_pay'
    WHEN r_lag < 0.50                                                THEN 'online_portal'
    WHEN r_lag < 0.80                                                THEN 'phone'
    WHEN r_lag < 0.95                                                THEN 'mail_check'
    ELSE                                                                  'in_person'
  END                                                                AS payment_method,

  current_timestamp()                                                AS _ingested_at
FROM with_lag;
