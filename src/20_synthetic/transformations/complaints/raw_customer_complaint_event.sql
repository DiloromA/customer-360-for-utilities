-- Customer Complaint Event — CIM CustomerComplaint. One row per complaint.
-- ~15-20K events over 2017+2018 with structured fields derived deterministically
-- from the causal stack (archetype × bill_shock × outages × arrears).
--
-- Propensity model (monthly probability):
--   propensity = base_rate[archetype]
--              × bill_shock_multiplier
--              × outage_multiplier
--              × arrears_multiplier
--
-- Base rates approximate the high end of utility customer-care call rates
-- (this models "customer called and complained", not formal PSC filings):
--   efficient_engaged       0.3%  /month
--   tech_forward            0.5%
--   senior_fixed_income     1.2%
--   comfortable_indifferent 1.0%
--   inefficient_unaware     1.8%
--   cost_stressed           4.0%
--
-- Multipliers:
--   bill_shock > 50%    × 5.0
--   bill_shock > 30%    × 3.0
--   bill_shock > 15%    × 1.5
--   outage_30d > 720m   × 5.0
--   outage_30d > 240m   × 2.5
--   outage_30d > 60m    × 1.3
--   prev_balance > $300 × 1.8
--
-- Category derives from the dominant driver:
--   bill_shock > 30%             -> 'billing' / 'high_bill_dispute'
--   outage_30d > 240m and most recent <2 weeks -> 'outage' / 'frequent_outages' or 'extended_outage'
--   prev_balance > $300          -> 'billing_process' / 'payment_plan_request'
--   else                          -> 'customer_service' or 'service_quality' by hash

CREATE OR REFRESH MATERIALIZED VIEW raw_customer_complaint_event (
  CONSTRAINT non_null_complaint_id EXPECT (complaint_id IS NOT NULL),
  CONSTRAINT non_null_customer_id  EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_category EXPECT (category IN (
    'billing','outage','service_quality','customer_service','billing_process','program'
  )),
  CONSTRAINT valid_channel  EXPECT (channel IN (
    'phone','online_chat','email','social_media','in_person','mail'
  )),
  CONSTRAINT valid_status   EXPECT (resolution_status IN (
    'open','in_progress','resolved','escalated'
  ))
)
COMMENT 'Customer Complaint Event — CIM CustomerComplaint. ~15-20K events over 2017+2018, propensity-driven from bill shock + outages + archetype + arrears. driver_bill_id / driver_outage_id link back to the triggering record when applicable. PK: complaint_id. FK: customer_id -> raw_customer.'
AS

WITH

-- Collapse to (account, calendar month) BEFORE windowing the trailing
-- average or rolling the complaint dice. A sub-metered commercial account
-- (temporal-realism §5.3) bills one row PER usage_point per month — and a
-- relocation's transition month (temporal-realism §5.1) already bills one
-- row per premise — so without this collapse, a ROW-count-based "11
-- PRECEDING" window would silently desync from "11 calendar months back" the
-- moment any month contributes more than one row, AND a customer with
-- multiple same-month bill rows would get multiple INDEPENDENT complaint
-- dice rolls that month instead of one.
monthly_bills AS (
  SELECT
    account_id,
    customer_id,
    bill_period_end,
    MIN(bill_id)          AS bill_id,
    SUM(current_charges)  AS current_charges,
    SUM(previous_balance) AS previous_balance
  FROM ${billing_schema}.raw_customer_billing
  GROUP BY account_id, customer_id, bill_period_end
),

bills AS (
  SELECT
    account_id,
    customer_id,
    bill_id,
    bill_period_end,
    current_charges,
    previous_balance,
    -- Trailing 12-month average current_charges per account (excludes current row).
    AVG(current_charges) OVER (
      PARTITION BY account_id
      ORDER BY bill_period_end
      ROWS BETWEEN 11 PRECEDING AND 1 PRECEDING
    ) AS trailing_12_avg_charges
  FROM monthly_bills
),

-- Outage exposure in the 30 days before each bill_period_end.
outages_30d AS (
  SELECT
    b.customer_id,
    b.bill_period_end,
    COUNT(*) AS outages_count_30d,
    COALESCE(SUM(oci.minutes_out), 0) AS outage_minutes_30d,
    MAX(oci.minutes_out)              AS max_outage_minutes_30d,
    MAX(oci.outage_id)                AS most_recent_outage_id
  FROM bills b
  LEFT JOIN ${outages_schema}.raw_outage_customer_impact oci
    ON oci.customer_id = b.customer_id
   AND oci.affected_start BETWEEN b.bill_period_end - INTERVAL 30 DAYS
                              AND b.bill_period_end
  GROUP BY b.customer_id, b.bill_period_end
),

candidates AS (
  SELECT
    b.account_id,
    b.customer_id,
    b.bill_id,
    b.bill_period_end,
    b.current_charges,
    b.previous_balance,
    b.trailing_12_avg_charges,
    -- Bill shock as a fraction (current - avg)/avg; 0 when no trailing avg.
    CASE
      WHEN b.trailing_12_avg_charges IS NULL OR b.trailing_12_avg_charges < 1 THEN 0.0
      ELSE (b.current_charges - b.trailing_12_avg_charges) / b.trailing_12_avg_charges
    END                                                              AS bill_shock_pct,
    COALESCE(o.outages_count_30d,    0)                              AS outages_count_30d,
    COALESCE(o.outage_minutes_30d,   0)                              AS outage_minutes_30d,
    COALESCE(o.max_outage_minutes_30d, 0)                            AS max_outage_minutes_30d,
    o.most_recent_outage_id,
    c.archetype,
    c.language_preference,
    c.critical_care_flag,
    a.preferred_channel,
    abs(xxhash64(b.customer_id, b.bill_id, 'complain', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_complain,
    abs(xxhash64(b.customer_id, b.bill_id, 'channel',  ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_chan,
    abs(xxhash64(b.customer_id, b.bill_id, 'category', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_cat,
    abs(xxhash64(b.customer_id, b.bill_id, 'day',      ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_day,
    abs(xxhash64(b.customer_id, b.bill_id, 'resolve',  ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_resolve,
    abs(xxhash64(b.customer_id, b.bill_id, 'agent',    ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_agent
  FROM bills b
  LEFT JOIN outages_30d o
    ON o.customer_id = b.customer_id AND o.bill_period_end = b.bill_period_end
  JOIN ${customer_master_schema}.raw_customer c USING (customer_id)
  JOIN ${customer_master_schema}.raw_customer_account a
    ON a.customer_id = c.customer_id
   AND a.account_group IN ('standard','corporate_parent')   -- exactly one account per current customer (no chain fan-out)
),

with_propensity AS (
  SELECT *,
    CASE archetype
      WHEN 'efficient_engaged'        THEN 0.003
      WHEN 'tech_forward'             THEN 0.005
      WHEN 'comfortable_indifferent'  THEN 0.010
      WHEN 'inefficient_unaware'      THEN 0.018
      WHEN 'senior_fixed_income'      THEN 0.012
      WHEN 'cost_stressed'            THEN 0.040
      ELSE 0.010
    END *
    CASE
      WHEN bill_shock_pct > 0.50 THEN 5.0
      WHEN bill_shock_pct > 0.30 THEN 3.0
      WHEN bill_shock_pct > 0.15 THEN 1.5
      ELSE 1.0
    END *
    CASE
      WHEN outage_minutes_30d > 720 THEN 5.0
      WHEN outage_minutes_30d > 240 THEN 2.5
      WHEN outage_minutes_30d > 60  THEN 1.3
      ELSE 1.0
    END *
    CASE WHEN previous_balance > 300 THEN 1.8 ELSE 1.0 END
    AS monthly_propensity
  FROM candidates
),

complaining AS (
  SELECT * FROM with_propensity WHERE r_complain < monthly_propensity
)

SELECT
  md5(CONCAT(customer_id, '_', bill_id, '_complaint'))               AS complaint_id,
  customer_id,
  account_id,

  -- Complaint date: random day within the billing month after bill_date.
  -- (bills are delivered just after period_end; complaints land in the
  -- next few weeks.)
  DATE_ADD(bill_period_end, CAST(2 + r_day * 25 AS INT))             AS complaint_date,

  -- Channel: skew by preferred_channel.
  CASE
    WHEN preferred_channel = 'email' AND r_chan < 0.30  THEN 'email'
    WHEN preferred_channel = 'email' AND r_chan < 0.65  THEN 'online_chat'
    WHEN preferred_channel = 'email'                    THEN 'phone'
    WHEN preferred_channel = 'sms'   AND r_chan < 0.45  THEN 'online_chat'
    WHEN preferred_channel = 'sms'   AND r_chan < 0.80  THEN 'phone'
    WHEN preferred_channel = 'sms'                      THEN 'social_media'
    WHEN preferred_channel = 'mail'  AND r_chan < 0.70  THEN 'phone'
    WHEN preferred_channel = 'mail'  AND r_chan < 0.90  THEN 'in_person'
    WHEN preferred_channel = 'mail'                     THEN 'mail'
    ELSE                                                     'phone'
  END                                                                AS channel,

  -- Category derived from the dominant driver.
  CASE
    WHEN bill_shock_pct > 0.30                                       THEN 'billing'
    WHEN max_outage_minutes_30d > 240                                THEN 'outage'
    WHEN outages_count_30d >= 3                                      THEN 'outage'
    WHEN previous_balance > 300                                      THEN 'billing_process'
    WHEN r_cat < 0.55                                                THEN 'customer_service'
    WHEN r_cat < 0.85                                                THEN 'service_quality'
    ELSE                                                                  'program'
  END                                                                AS category,

  -- Sub-category for more specific routing.
  CASE
    WHEN bill_shock_pct > 0.50                                       THEN 'high_bill_dispute'
    WHEN bill_shock_pct > 0.30                                       THEN 'unexpected_charges'
    WHEN max_outage_minutes_30d > 720                                THEN 'extended_outage'
    WHEN max_outage_minutes_30d > 240                                THEN 'restoration_delay'
    WHEN outages_count_30d >= 3                                      THEN 'frequent_outages'
    WHEN previous_balance > 300                                      THEN 'payment_plan_request'
    WHEN r_cat < 0.20                                                THEN 'rude_agent'
    WHEN r_cat < 0.55                                                THEN 'long_hold_time'
    WHEN r_cat < 0.75                                                THEN 'voltage_fluctuation'
    WHEN r_cat < 0.85                                                THEN 'brownout'
    WHEN r_cat < 0.93                                                THEN 'dsm_rebate_delay'
    ELSE                                                                  'ev_program_enrollment'
  END                                                                AS sub_category,

  -- Severity:
  --   high   bill_shock > 50%, extended outage, critical_care during outage
  --   medium otherwise causal
  --   low    random / general service-quality
  CASE
    WHEN critical_care_flag AND outage_minutes_30d > 60              THEN 'high'
    WHEN bill_shock_pct > 0.50                                       THEN 'high'
    WHEN max_outage_minutes_30d > 720                                THEN 'high'
    WHEN bill_shock_pct > 0.30                                       THEN 'medium'
    WHEN max_outage_minutes_30d > 240                                THEN 'medium'
    WHEN outages_count_30d >= 3                                      THEN 'medium'
    ELSE                                                                  'low'
  END                                                                AS severity,

  -- Sentiment label.
  CASE
    WHEN archetype = 'cost_stressed' AND bill_shock_pct > 0.30       THEN 'very_negative'
    WHEN max_outage_minutes_30d > 720                                THEN 'very_negative'
    WHEN bill_shock_pct > 0.50                                       THEN 'very_negative'
    WHEN bill_shock_pct > 0.15
      OR max_outage_minutes_30d > 120                                THEN 'negative'
    ELSE                                                                  'mixed'
  END                                                                AS sentiment_label,

  -- Driver back-references.
  CASE
    WHEN bill_shock_pct > 0.15 OR previous_balance > 300
      THEN bill_id
    ELSE CAST(NULL AS STRING)
  END                                                                AS driver_bill_id,

  CASE
    WHEN max_outage_minutes_30d > 60 OR outages_count_30d >= 2
      THEN most_recent_outage_id
    ELSE CAST(NULL AS STRING)
  END                                                                AS driver_outage_id,

  -- Synthetic agent ID. ~200 agents in the call center.
  CONCAT('AGT-', LPAD(CAST(1 + CAST(r_agent * 200 AS INT) AS STRING), 4, '0'))
                                                                     AS assigned_agent_id,

  -- Resolution lifecycle.
  --   60% resolved (within 1-5 days)
  --   25% resolved later (5-30 days)
  --   10% escalated (still open or 30+ days)
  --   5% still open at end of demo period
  CASE
    WHEN r_resolve < 0.60 THEN 'resolved'
    WHEN r_resolve < 0.85 THEN 'resolved'
    WHEN r_resolve < 0.95 THEN 'escalated'
    ELSE                       'open'
  END                                                                AS resolution_status,

  CASE
    WHEN r_resolve < 0.60 THEN CAST(60 + r_resolve / 0.60 * 4380 AS INT)       -- 1-5 days in mins
    WHEN r_resolve < 0.85 THEN CAST(4380 + (r_resolve - 0.60) / 0.25 * 36420 AS INT)  -- 5-30 days
    WHEN r_resolve < 0.95 THEN CAST(36420 + (r_resolve - 0.85) / 0.10 * 100000 AS INT) -- escalated
    ELSE CAST(NULL AS INT)
  END                                                                AS resolution_minutes,

  -- Diagnostic fields useful for the curated layer / persona views
  ROUND(current_charges,                  2)                         AS triggering_bill_amount,
  ROUND(trailing_12_avg_charges,          2)                         AS trailing_12_avg_bill,
  ROUND(bill_shock_pct,                   3)                         AS bill_shock_pct,
  outages_count_30d,
  outage_minutes_30d,
  max_outage_minutes_30d,
  language_preference,

  current_timestamp()                                                AS _ingested_at
FROM complaining;
