-- Every premise this customer has ever held a tenancy at (current AND
-- closed), for the "Show all locations" map action. Chain customers light
-- this up today (N site premises; the corporate_parent account has no
-- premise of its own); residential movers light it up once relocations are
-- modeled.
--
-- @param account_number STRING

WITH acct AS (
  SELECT customer_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
)
SELECT DISTINCT
  h.premise_id,
  sp.service_address,
  h.latitude,
  h.longitude
FROM {{catalog}}.{{schema}}.bridge_account_premise b
JOIN {{catalog}}.{{schema}}.dim_account a ON a.account_id = b.account_id
JOIN acct ON acct.customer_id = a.customer_id
JOIN {{catalog}}.{{schema}}.dim_premise_h3 h ON h.premise_id = b.premise_id
LEFT JOIN {{catalog}}.{{schema}}.dim_service_point sp ON sp.premise_id = b.premise_id
ORDER BY sp.service_address
