-- Meter installation history (incl. removed originals from meter swaps) for
-- every premise this customer has ever held a tenancy at. Premise/service-
-- point keyed, not account-keyed — same reasoning as customer_timeline.sql:
-- a meter swap carries no account_id. ~7% of service points carry two rows
-- (original removed + replacement current).
--
-- @param account_number STRING

WITH acct AS (
  SELECT customer_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
),
customer_premises AS (
  SELECT DISTINCT b.premise_id
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN {{catalog}}.{{schema}}.dim_account a ON a.account_id = b.account_id
  JOIN acct ON acct.customer_id = a.customer_id
)
SELECT
  m.premise_id,
  sp.service_address,
  m.meter_number,
  m.installation_date,
  m.removal_date,
  m.removal_reason_code,
  m.is_current,
  m.installation_status
FROM {{catalog}}.{{schema}}.meter_installation m
JOIN customer_premises cp ON cp.premise_id = m.premise_id
LEFT JOIN {{catalog}}.{{schema}}.dim_service_point sp ON sp.premise_id = m.premise_id
ORDER BY m.premise_id, m.installation_date
