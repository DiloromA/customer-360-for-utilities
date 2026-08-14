-- Field-service work orders at this premise, newest-first. customer_number is
-- nullable — orders on premises with no active customer at the time of the
-- order have no resolved customer. Degrades cleanly when no rows exist.
-- Keyed by premise_number (STRING natural key).

-- @param premise_number STRING

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
)
SELECT
  wo.work_order_id,
  wo.work_type,
  wo.status,
  wo.priority,
  wo.created_at,
  wo.scheduled_at,
  wo.completed_at,
  c.customer_number
FROM prem
JOIN {{catalog}}.{{schema}}.fact_work_order wo   ON wo.premise_id = prem.premise_id
LEFT JOIN {{catalog}}.{{schema}}.dim_customer c  ON c.customer_id = wo.customer_id
ORDER BY wo.created_at DESC
LIMIT 20
