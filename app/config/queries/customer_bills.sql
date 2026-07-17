-- 24-month bill + usage chart data.
-- Keyed by the human account_number; billing is account-grain in the new model
-- (fact_customer_billing.account_id). The per-month peer benchmark joins through
-- the account's customer profile (peer_building_subtype / peer_sqft_band).

-- @param account_number STRING

WITH acct AS (
  SELECT account_id, customer_id, premise_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
)
SELECT
  cb.bill_id,
  cb.bill_period_start,
  cb.bill_period_end,
  cb.bill_date,
  cb.due_date,
  cb.total_kwh,
  cb.current_charges,
  cb.previous_balance,
  cb.total_amount_due,
  cb.payment_status,
  cb.yoy_kwh_change_pct,
  cb.yoy_bill_change_pct,
  cb.bill_shock_pct,
  ph.amount_paid,
  ph.days_late,
  ph.payment_method,
  ph.lateness_bucket,
  -- Per-month peer benchmark (varies seasonally — heating in winter,
  -- AC in summer — so the comparison is honest month by month).
  pb.peer_avg_kwh,
  pb.peer_p75_kwh
FROM acct
JOIN {{catalog}}.{{schema}}.fact_customer_billing cb
  ON cb.account_id = acct.account_id
LEFT JOIN {{catalog}}.{{schema}}.fact_payment_history ph
  ON cb.bill_id = ph.bill_id
-- Peer group is THIS account's own premise (building type & size band), so a
-- multi-site customer's individual site is compared to like sites — not to
-- whatever the customer's anchor premise happened to be.
LEFT JOIN {{catalog}}.{{schema}}.dim_premise dp
  ON dp.premise_id = acct.premise_id
LEFT JOIN {{catalog}}.{{schema}}.peer_monthly_usage_benchmark pb
  ON pb.peer_building_subtype = dp.building_subtype
 AND pb.peer_sqft_band        = dp.sqft_band
 AND pb.year                   = YEAR(cb.bill_period_end)
 AND pb.month                  = MONTH(cb.bill_period_end)
ORDER BY cb.bill_period_end
