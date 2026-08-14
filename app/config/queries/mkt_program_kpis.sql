-- Marketing: single-row headline KPIs for the selected program.
-- Counts, money, savings, and the eligibility "gap" (eligible-but-not-
-- enrolled). Eligibility is loosely defined as customer_class matching
-- the program's customer_segment — the same convention customer_recommendations uses.
--
-- Reads metric_customer_base (eligible half) + metric_dsm_uptake
-- (enrolled half).
-- The eligible denominator counts the CURRENT customer base
-- (metric_customer_base is already filtered to
-- bridge_account_premise.is_current), so prior-customer / chain-parent
-- profile rows don't inflate it. dim_program stays a plain app-side
-- lookup (small ref table, not an aggregate fact).

-- @param program_id STRING

WITH program AS (
  SELECT * FROM {{catalog}}.{{schema}}.dim_program WHERE program_id = :program_id
),

agg AS (
  SELECT
    MEASURE(`Distinct Customers Enrolled`) AS n_enrolled_total,
    MEASURE(`Active Count`)                AS n_active,
    MEASURE(`Completion Count`)             AS n_completed,
    MEASURE(`Dropped Count`)                AS n_dropped,
    MEASURE(`Total Rebates Paid`)            AS total_rebate_paid,
    MEASURE(`Total kWh Saved Estimate`)      AS total_kwh_saved
  FROM {{catalog}}.{{schema}}.metric_dsm_uptake
  WHERE `Program ID` = :program_id
),

eligible AS (
  SELECT MEASURE(`Service Locations Served`) AS n_eligible
  FROM {{catalog}}.{{schema}}.metric_customer_base
  WHERE LOWER(`Customer Class`) = LOWER((SELECT customer_segment FROM {{catalog}}.{{schema}}.dim_program WHERE program_id = :program_id))
)

SELECT
  pr.program_id,
  pr.program_name,
  pr.program_type,
  pr.customer_segment,
  pr.rebate_amount_usd,
  pr.avg_annual_kwh_saved,
  a.n_enrolled_total,
  a.n_active,
  a.n_completed,
  a.n_dropped,
  a.total_rebate_paid,
  a.total_kwh_saved,
  e.n_eligible,
  ROUND(100.0 * a.n_enrolled_total / NULLIF(e.n_eligible, 0), 1)         AS pct_adoption,
  GREATEST(e.n_eligible - a.n_enrolled_total, 0)                         AS n_eligible_not_enrolled,
  ROUND(100.0 * a.n_completed / NULLIF(a.n_enrolled_total, 0), 1)        AS pct_completion
FROM program pr
CROSS JOIN agg a
CROSS JOIN eligible e
