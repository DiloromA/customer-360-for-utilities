-- Attributable complaints filed about this premise, with the filing customer
-- identified. Premise views show only complaints with a resolved premise_id —
-- unresolved complaints are excluded here (use customer_complaints.sql for all
-- complaints regardless of attribution). Each row carries the filing customer's
-- account_number so the UI can render a customer chip per row.
--
-- Keyed by the human premise_number (FEMA UUID string), not the BIGINT surrogate.

-- @param premise_number STRING

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
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
  fc.driver_outage_id,
  fc.premise_attribution_method,
  a.account_number                                                           AS filer_account_number,
  c.customer_number                                                          AS filer_customer_number
FROM prem
JOIN {{catalog}}.{{schema}}.fact_customer_complaints fc
  ON fc.premise_id = prem.premise_id
LEFT JOIN {{catalog}}.{{schema}}.dim_account a   ON a.account_id  = fc.account_id
LEFT JOIN {{catalog}}.{{schema}}.dim_customer c  ON c.customer_id = fc.customer_id
ORDER BY fc.complaint_date DESC
LIMIT 30
