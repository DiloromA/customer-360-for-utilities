-- SCD2 "profile changes" feed — the first UI consumer of dim_customer_history
-- / dim_account_history. Only one attribute is genuinely type-2 tracked per
-- table (customer.critical_care_flag, account.current_status); every other
-- column is carried through unchanged across versions, so we diff those two
-- columns across consecutive versions with LAG() rather than printing every
-- column of every version.
--
-- @param account_number STRING

WITH acct AS (
  SELECT customer_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
),
customer_accounts AS (
  SELECT a.account_id, a.account_number
  FROM {{catalog}}.{{schema}}.dim_account a
  JOIN acct ON acct.customer_id = a.customer_id
),
cust_versions AS (
  SELECT
    h.effective_from,
    h.critical_care_flag,
    LAG(h.critical_care_flag) OVER (PARTITION BY h.customer_id ORDER BY h.effective_from) AS prev_critical_care_flag
  FROM {{catalog}}.{{schema}}.dim_customer_history h
  JOIN acct ON acct.customer_id = h.customer_id
),
acct_versions AS (
  SELECT
    h.effective_from,
    ca.account_number,
    h.current_status,
    LAG(h.current_status) OVER (PARTITION BY h.account_id ORDER BY h.effective_from) AS prev_current_status
  FROM {{catalog}}.{{schema}}.dim_account_history h
  JOIN customer_accounts ca ON ca.account_id = h.account_id
)
SELECT
  effective_from,
  'customer'                                                                          AS entity,
  CAST(NULL AS STRING)                                                                AS account_number,
  CASE WHEN critical_care_flag THEN 'Critical care registered' ELSE 'Critical care removed' END AS change_label
FROM cust_versions
WHERE prev_critical_care_flag IS NOT NULL AND critical_care_flag != prev_critical_care_flag

UNION ALL

SELECT
  effective_from,
  'account'                       AS entity,
  account_number,
  CONCAT('Account ', current_status) AS change_label
FROM acct_versions
WHERE prev_current_status IS NOT NULL AND current_status != prev_current_status

ORDER BY effective_from DESC
