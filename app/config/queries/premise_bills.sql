-- 24-month bill + usage chart data for this premise (address) — spans
-- occupants, since billed usage at a physical site persists across
-- tenancy. Premise-native version of customer_bills.sql. fact_customer_billing
-- carries only service_point_id (not premise_id directly), so join through
-- dim_service_point to scope by premise. A large sub-metered commercial
-- premise (temporal-realism §5.3) has 2-5 service_points, so this
-- legitimately returns multiple bill rows per month (one per meter) — only
-- one of them carries previous_balance/total_amount_due's shared arrears
-- (see raw_customer_billing.sql), so summing the column across a month's
-- sibling rows still gives the site's true total.
-- Keyed by premise_number (STRING) — see premise_header.sql's note on the
-- BIGINT/client boundary.

-- @param premise_number STRING

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
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
  -- Per-month peer benchmark, from this premise's own building type & size
  -- band (varies seasonally, so the comparison is honest month by month).
  pb.peer_avg_kwh,
  pb.peer_p75_kwh
FROM prem
JOIN {{catalog}}.{{schema}}.dim_service_point sp ON sp.premise_id = prem.premise_id
JOIN {{catalog}}.{{schema}}.fact_customer_billing cb
  ON cb.service_point_id = sp.service_point_id
LEFT JOIN {{catalog}}.{{schema}}.fact_payment_history ph
  ON cb.bill_id = ph.bill_id
LEFT JOIN {{catalog}}.{{schema}}.dim_premise dp
  ON dp.premise_id = prem.premise_id
LEFT JOIN {{catalog}}.{{schema}}.peer_monthly_usage_benchmark pb
  ON pb.peer_building_subtype = dp.building_subtype
 AND pb.peer_sqft_band        = dp.sqft_band
 AND pb.year                   = YEAR(cb.bill_period_end)
 AND pb.month                  = MONTH(cb.bill_period_end)
ORDER BY cb.bill_period_end
