-- Rate/service-agreement history for every account this customer holds.
-- Rate switchers (EV-TOU accounts, ~50% of res_d3) show the terminated prior
-- agreement (agreement_seq=1, is_current=false) alongside the current one
-- (agreement_seq=2, is_current=true) — dim_service_agreement is the as-of
-- resolution source elsewhere in the app; this is its first full-window view.
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
)
SELECT
  ca.account_number,
  sa.agreement_seq,
  r.rate_display_name,
  sa.rate_schedule,
  sa.effective_date,
  sa.termination_date,
  sa.is_current,
  sa.termination_reason
FROM {{catalog}}.{{schema}}.dim_service_agreement sa
JOIN customer_accounts ca ON ca.account_id = sa.account_id
LEFT JOIN {{catalog}}.{{schema}}.dim_rate_schedule r ON r.rate_schedule_id = sa.rate_schedule
ORDER BY ca.account_number, sa.effective_date
