-- Customer Billing — one row per (account, service_agreement, usage_point,
-- monthly period). ~50K accounts x 24 months (2017+2018) ≈ 1.2M rows (a rate
-- switcher contributes two service_agreement_ids across the switch, still one
-- bill per month; a large sub-metered commercial account, temporal-realism
-- §5.3, contributes one bill PER usage_point every month, permanently).
--
-- Pipeline:
--   1. agr / reading_attr / usage_by_up / monthly_usage
--                        Attribute each HOURLY meter reading to the AS-OF
--                        service_agreement in force on its own date, THEN
--                        aggregate to (account, service_agreement, month) —
--                        not the reverse. This is what correctly splits a
--                        mid-month occupant transition's kWh across two
--                        agreements/accounts (temporal-realism §5.2) instead
--                        of assigning the whole month to whichever agreement
--                        wins a month-level pick. AMI is usage_point-keyed;
--                        account/rate are resolved here, not on AMI.
--   2. line_items        Apply rate-schedule-specific pricing
--                        -> service / energy / demand / pscr /
--                        net-metering credit -> current_charges.
--   3. with_payment_intent / classified
--                        Deterministically classify each bill into
--                        paid_on_time / paid_late / paid_partial / unpaid
--                        (same logic as raw_payment_history.sql; shared
--                        xxhash64 draw so both tables agree row-for-row).
--                        Computes row_unpaid_carry: 0 for paid_in_full
--                        / paid_late (paid eventually); (1 - fraction)
--                        of current_charges for partial; full charges
--                        for unpaid.
--   4. monthly_carry / monthly_running
--                        Collapse to (account, premise, month) before
--                        windowing the arrears ledger — a sub-metered
--                        premise's concurrent usage_points must share ONE
--                        ledger, not contaminate each other's "previous"
--                        balance every month. A relocation's transition
--                        month still keeps its two (different-premise) rows
--                        separate, preserving the deliberate departing ->
--                        arriving carry-forward chaining.
--   5. (final SELECT)    Joins the shared previous_balance back, attributed
--                        only to the carrier row (MIN usage_point_id that
--                        month) so summing a premise's sibling bills for the
--                        month never double-counts it. total_amount_due =
--                        current_charges + (previous_balance on the carrier
--                        row only).
--
-- TOU peak hours for res_d8_ev: M-F 14:00-19:00 UTC year-round.
--
-- Pricing reference (approximations of a 2018 Michigan investor-owned-utility's rates):
--   res_d1     $7.50/mo + $0.156/kWh
--   res_d1_2   $7.50/mo + $0.142/kWh
--   res_d3     $5.00/mo + $0.098/kWh
--   res_d8_ev  $9.00/mo + $0.225 peak / $0.085 off-peak
--   com_d3     $12.00/mo + $0.124/kWh
--   com_d4     $75.00/mo + $0.092/kWh + $12.50/kW demand
--   com_d6    $350.00/mo + $0.068/kWh + $18.00/kW demand
--   PSCR adjustment       +$0.013/kWh
--   Net-metering credit   residential $0.156, commercial $0.092

CREATE OR REFRESH MATERIALIZED VIEW raw_customer_billing (
  CONSTRAINT non_null_bill_id              EXPECT (bill_id IS NOT NULL),
  CONSTRAINT non_null_account_id           EXPECT (account_id IS NOT NULL),
  CONSTRAINT non_null_service_agreement_id EXPECT (service_agreement_id IS NOT NULL),
  CONSTRAINT non_null_period               EXPECT (bill_period_end IS NOT NULL),
  CONSTRAINT non_negative_total_kwh        EXPECT (total_kwh >= 0)
)
COMMENT 'Customer Billing — CIM CustomerBilling, one row per (account, service_agreement, monthly period). AMI is keyed by usage_point; each month is aggregated from hourly AMI and attributed to the billing account via the as-of service_agreement in force that month (so a rate switcher is billed res_d1 before the switch and the new rate after). Applies representative 2018 investor-owned-utility rate schedules with TOU split + peak demand, and carries forward the unpaid portion of prior bills (partial-pay residue + fully unpaid). PK: bill_id. FK: account_id -> raw_customer_account; service_agreement_id -> raw_service_agreement; usage_point_id -> raw_usage_point.'
AS

WITH

-- In-window agreements per usage_point. Prior-occupant agreements that
-- terminated before the display window are excluded so a reading never
-- resolves to a moved-out account. Window start derives from as_of_date/
-- history_months so this holds for any as_of_date, matching the convention
-- every other 20_synthetic generator uses.
agr AS (
  SELECT
    usage_point_id,
    account_id,
    premise_id,
    service_agreement_id,
    rate_schedule,
    effective_date,
    termination_date
  FROM ${customer_master_schema}.raw_service_agreement
  WHERE termination_date IS NULL
     OR termination_date > DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
),

-- Attribute each HOURLY reading to the as-of agreement in force on its own
-- date (temporal-realism §5.2) — this is what correctly splits a mid-month
-- occupant transition's kWh across two agreements/accounts instead of a
-- month-level "whichever agreement wins" pick. Agreement windows shouldn't
-- overlap by construction (each tenancy's effective_date is the prior one's
-- termination_date), so the ROW_NUMBER below is a defensive dedup only.
reading_attr AS (
  SELECT
    ami.usage_point_id,
    ami.timestamp_utc,
    ami.kwh_delivered,
    ami.kwh_received,
    a.account_id,
    a.premise_id,
    a.service_agreement_id,
    a.rate_schedule,
    a.effective_date,
    ROW_NUMBER() OVER (
      PARTITION BY ami.usage_point_id, ami.timestamp_utc
      ORDER BY a.effective_date DESC, a.service_agreement_id
    ) AS rn
  FROM ${ami_table} ami
  JOIN agr a
    ON a.usage_point_id = ami.usage_point_id
   AND a.effective_date <= CAST(ami.timestamp_utc AS DATE)
   AND (a.termination_date IS NULL OR CAST(ami.timestamp_utc AS DATE) < a.termination_date)
),

-- Aggregate the now-correctly-attributed readings to (account,
-- service_agreement, month). A transition month naturally produces two rows
-- (one per account/usage_point) instead of one; an ordinary month produces
-- exactly one.
usage_by_up AS (
  SELECT
    account_id,
    premise_id,
    service_agreement_id,
    usage_point_id,
    rate_schedule,
    MIN(effective_date)                                                AS agr_effective_date,
    YEAR(timestamp_utc)                                                 AS bill_year,
    MONTH(timestamp_utc)                                                AS bill_month,
    MAKE_DATE(YEAR(timestamp_utc), MONTH(timestamp_utc), 1)             AS bill_period_start,
    LAST_DAY(MAKE_DATE(YEAR(timestamp_utc), MONTH(timestamp_utc), 1))   AS bill_period_end,
    SUM(kwh_delivered)                                                  AS total_kwh,
    SUM(kwh_received)                                                   AS exported_kwh,
    SUM(CASE
          WHEN DAYOFWEEK(timestamp_utc) BETWEEN 2 AND 6
           AND HOUR(timestamp_utc)        BETWEEN 14 AND 18
            THEN kwh_delivered
          ELSE 0
        END)                                                           AS peak_kwh,
    SUM(CASE
          WHEN DAYOFWEEK(timestamp_utc) BETWEEN 2 AND 6
           AND HOUR(timestamp_utc)        BETWEEN 14 AND 18
            THEN 0
          ELSE kwh_delivered
        END)                                                           AS offpeak_kwh,
    MAX(kwh_delivered)                                                  AS peak_demand_kw
  FROM reading_attr
  WHERE rn = 1
  GROUP BY account_id, premise_id, service_agreement_id, usage_point_id, rate_schedule,
           YEAR(timestamp_utc), MONTH(timestamp_utc)
),
monthly_usage AS (
  SELECT * FROM usage_by_up
),

line_items AS (
  SELECT
    *,
    CASE rate_schedule
      WHEN 'res_d1'    THEN   7.50
      WHEN 'res_d1_2'  THEN   7.50
      WHEN 'res_d3'    THEN   5.00
      WHEN 'res_d8_ev' THEN   9.00
      WHEN 'com_d3'    THEN  12.00
      WHEN 'com_d4'    THEN  75.00
      WHEN 'com_d6'    THEN 350.00
      ELSE                    7.50
    END                                                              AS service_charge,
    CASE rate_schedule
      WHEN 'res_d1'    THEN total_kwh * 0.156
      WHEN 'res_d1_2'  THEN total_kwh * 0.142
      WHEN 'res_d3'    THEN total_kwh * 0.098
      WHEN 'res_d8_ev' THEN peak_kwh * 0.225 + offpeak_kwh * 0.085
      WHEN 'com_d3'    THEN total_kwh * 0.124
      WHEN 'com_d4'    THEN total_kwh * 0.092
      WHEN 'com_d6'    THEN total_kwh * 0.068
      ELSE                  total_kwh * 0.156
    END                                                              AS energy_charge,
    CASE rate_schedule
      WHEN 'com_d4' THEN peak_demand_kw * 12.50
      WHEN 'com_d6' THEN peak_demand_kw * 18.00
      ELSE 0.0
    END                                                              AS demand_charge,
    total_kwh * 0.013                                                AS pscr_adjustment,
    -1.0 * exported_kwh *
      CASE
        WHEN rate_schedule LIKE 'res_%' THEN 0.156
        ELSE                                 0.092
      END                                                            AS net_metering_credit,
    -- usage_point_id-qualified: a transition month's two rows share
    -- account_id/bill_year/bill_month but have different usage_point_id
    -- (temporal-realism §5.2) — without this, both rows would collide on the
    -- same bill_id. A no-op for every non-split account (still exactly one
    -- usage_point per account per month).
    md5(CONCAT(account_id, '_', usage_point_id, '_', CAST(bill_year AS STRING), '_', LPAD(CAST(bill_month AS STRING), 2, '0'))) AS bill_id,
    DATE_ADD(LAST_DAY(MAKE_DATE(bill_year, bill_month, 1)), 1)       AS bill_date,
    DATE_ADD(LAST_DAY(MAKE_DATE(bill_year, bill_month, 1)), 15)      AS due_date
  FROM monthly_usage
),

current_only AS (
  SELECT
    *,
    ROUND(service_charge + energy_charge + demand_charge + pscr_adjustment + net_metering_credit, 2)
                                                                     AS current_charges
  FROM line_items
),

-- Classify each bill (same logic as raw_payment_history.sql — both tables
-- consume the same xxhash64 draw so their statuses agree row-for-row).
with_payment_intent AS (
  SELECT
    co.*,
    a.customer_id,
    a.autopay_enrolled,
    c.archetype,
    abs(xxhash64(co.account_id, co.bill_id, 'pay_status', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_status
  FROM current_only co
  JOIN ${customer_master_schema}.raw_customer_account a USING (account_id)
  JOIN ${customer_master_schema}.raw_customer c ON c.customer_id = a.customer_id
),

classified AS (
  SELECT
    *,
    CASE
      WHEN autopay_enrolled AND r_status < 0.99                      THEN 'paid_on_time'
      WHEN autopay_enrolled                                           THEN 'paid_late'
      WHEN archetype = 'efficient_engaged'        AND r_status < 0.99 THEN 'paid_on_time'
      WHEN archetype = 'tech_forward'             AND r_status < 0.97 THEN 'paid_on_time'
      WHEN archetype = 'senior_fixed_income'      AND r_status < 0.96 THEN 'paid_on_time'
      WHEN archetype = 'comfortable_indifferent'  AND r_status < 0.90 THEN 'paid_on_time'
      WHEN archetype = 'inefficient_unaware'      AND r_status < 0.83 THEN 'paid_on_time'
      WHEN archetype = 'cost_stressed'            AND r_status < 0.55 THEN 'paid_on_time'
      WHEN archetype = 'cost_stressed'       AND r_status < 0.85      THEN 'paid_partial'
      WHEN archetype = 'inefficient_unaware' AND r_status < 0.93      THEN 'paid_partial'
      WHEN archetype = 'cost_stressed'                                THEN 'unpaid'
      ELSE                                                                  'paid_late'
    END                                                              AS payment_status,

    CASE
      WHEN archetype = 'cost_stressed'      AND r_status >= 0.55 AND r_status < 0.75 THEN 0.5
      WHEN archetype = 'cost_stressed'      AND r_status >= 0.75 AND r_status < 0.85 THEN 0.3
      WHEN archetype = 'inefficient_unaware' AND r_status >= 0.83 AND r_status < 0.93 THEN 0.6
      ELSE 1.0
    END                                                              AS pay_fraction_when_partial,

    -- This bill's own carry-forward (used by next month's previous_balance):
    --   paid_on_time / paid_late: 0  (paid eventually, no arrears)
    --   paid_partial:             current_charges × (1 - pay_fraction_when_partial)
    --   unpaid:                   current_charges
    CASE payment_status
      WHEN 'paid_on_time' THEN 0.0
      WHEN 'paid_late'    THEN 0.0
      WHEN 'paid_partial' THEN current_charges * (1.0 - pay_fraction_when_partial)
      WHEN 'unpaid'       THEN current_charges
    END                                                              AS row_unpaid_carry
  FROM with_payment_intent
),

-- Collapse to (account, premise, calendar month) before running the arrears
-- ledger. A large commercial premise's 2-5 concurrent usage_points
-- (temporal-realism §5.3) bill under the SAME account every month, not just
-- during a transition — without this collapse, the ROW-based "1 PRECEDING"
-- window below would misread a sibling meter's SAME-month charge as this
-- meter's prior-month balance. A relocation's transition month still
-- produces two rows here (different premise_id), preserving the existing,
-- deliberate cross-premise chaining below (carry-forward flows from the
-- departing tenancy's partial bill into the arriving tenancy's).
monthly_carry AS (
  SELECT
    account_id,
    premise_id,
    bill_period_end,
    MIN(agr_effective_date)   AS agr_effective_date,
    MIN(usage_point_id)       AS carrier_usage_point_id,
    SUM(row_unpaid_carry)     AS month_unpaid_carry
  FROM classified
  GROUP BY account_id, premise_id, bill_period_end
),

monthly_running AS (
  SELECT
    account_id,
    premise_id,
    bill_period_end,
    carrier_usage_point_id,
    COALESCE(SUM(month_unpaid_carry) OVER (
      PARTITION BY account_id
      -- agr_effective_date tiebreaks a transition month's two same-account,
      -- different-premise rows so carry-forward flows from the departing
      -- tenancy's partial bill into the arriving tenancy's, not arbitrarily.
      ORDER BY bill_period_end, agr_effective_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ), 0.0)                   AS previous_balance
  FROM monthly_carry
)

SELECT
  c.bill_id,
  c.account_id,
  c.service_agreement_id,
  c.usage_point_id,
  c.customer_id,
  c.rate_schedule,
  c.bill_period_start,
  c.bill_period_end,
  c.bill_date,
  c.due_date,

  -- Usage
  ROUND(c.total_kwh, 2)                                              AS total_kwh,
  ROUND(c.peak_kwh, 2)                                               AS peak_kwh,
  ROUND(c.offpeak_kwh, 2)                                            AS offpeak_kwh,
  ROUND(c.peak_demand_kw, 2)                                         AS peak_demand_kw,
  ROUND(c.exported_kwh, 2)                                           AS exported_kwh,

  -- Line items
  ROUND(c.service_charge, 2)                                         AS service_charge,
  ROUND(c.energy_charge, 2)                                          AS energy_charge,
  ROUND(c.demand_charge, 2)                                          AS demand_charge,
  ROUND(c.pscr_adjustment, 2)                                        AS pscr_adjustment,
  ROUND(c.net_metering_credit, 2)                                    AS net_metering_credit,
  c.current_charges,

  c.payment_status,
  ROUND(c.row_unpaid_carry, 2)                                       AS unpaid_carry,

  -- Previous balance is shared per (account, premise, month) — attributed
  -- only to the carrier row (MIN usage_point_id that month) so summing
  -- across a sub-metered premise's sibling bills never double-counts it.
  ROUND(
    CASE WHEN c.usage_point_id = mr.carrier_usage_point_id THEN mr.previous_balance ELSE 0.0 END,
  2)                                                                 AS previous_balance,

  ROUND(
    c.current_charges +
    CASE WHEN c.usage_point_id = mr.carrier_usage_point_id THEN mr.previous_balance ELSE 0.0 END,
  2)                                                                 AS total_amount_due,

  current_timestamp()                                                AS _ingested_at
FROM classified c
JOIN monthly_running mr
  ON mr.account_id = c.account_id
 AND mr.premise_id = c.premise_id
 AND mr.bill_period_end = c.bill_period_end;
