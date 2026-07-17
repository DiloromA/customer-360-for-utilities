-- Customer complaint history with LLM verbatim text.
--
-- Filtered by CUSTOMER, not account. Complaints carry account_id, but a
-- customer's complaints may sit under a prior account (the curated re-key
-- left the current billing link on a different account_id for the same
-- person). The map dot + "Key signals" use the customer-grain
-- dim_customer.recent_complaint_count_90d, so the list must match that grain —
-- otherwise a dot showing "2 complaints" opens a drill that says "none".

-- @param account_number STRING

WITH cust AS (
  SELECT customer_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
)
SELECT
  fc.complaint_id,
  fc.complaint_date,
  fc.channel,
  fc.category,
  fc.sub_category,
  fc.severity,
  fc.sentiment_label,
  fc.resolution_status,
  fc.resolution_minutes,
  fc.triggering_bill_amount,
  fc.trailing_12_avg_bill,
  fc.bill_shock_pct,
  fc.outage_minutes_30d,
  fc.verbatim_language,
  fc.verbatim_text,
  fc.driver_bill_id,
  fc.driver_outage_id
FROM cust
JOIN {{catalog}}.{{schema}}.fact_customer_complaints fc
  ON fc.customer_id = cust.customer_id
ORDER BY fc.complaint_date DESC
LIMIT 20
