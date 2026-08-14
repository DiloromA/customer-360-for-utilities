-- Customer account timeline — service-event log across all of the customer's
-- own premises. Scoped by PREMISE (not account) so meter swaps, rate switches,
-- and prior-customer move-in/out events at the same address all appear.
--
-- Direct scope (hv.customer_id — the customer's own service paths): covers
-- every premise ever held by this customer, including prior premises after a
-- relocation. Events belonging to one of the customer's own accounts are flagged
-- is_current_account = true so the UI can label prior-customer events.

-- @param account_number STRING

WITH acct AS (
  SELECT a.customer_id
  FROM {{catalog}}.{{schema}}.dim_account a
  WHERE a.account_number = :account_number
),
customer_account_ids AS (
  -- All account IDs ever held by this customer.
  SELECT DISTINCT hv.account_id
  FROM acct
  JOIN {{catalog}}.{{schema}}.hierarchy_version hv
    ON hv.customer_id = acct.customer_id
),
customer_premises AS (
  -- All premises ever held by this customer.
  SELECT DISTINCT hv.premise_id
  FROM acct
  JOIN {{catalog}}.{{schema}}.hierarchy_version hv
    ON hv.customer_id = acct.customer_id
),
-- One row per premise for address display. This timeline spans EVERY premise
-- the customer has held, so each event must carry its own site address — a
-- second-home or relocated customer legitimately shows move-ins at two
-- different addresses, and without the address a reader can't tell them apart.
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
)
SELECT
  se.service_event_id,
  se.event_type,
  se.event_date,
  se.detail,
  se.account_id,
  se.meter_id,
  se.service_agreement_id,
  sp.service_address,
  sp.service_city,
  -- TRUE only for events on one of THIS customer's own accounts. Physical,
  -- account-less events (meter swaps carry no account_id — see
  -- fact_service_event.sql) come back NULL here, not FALSE — the UI must not
  -- read them as a "previous customer" (they belong to no customer at all).
  (se.account_id IN (SELECT account_id FROM customer_account_ids)) AS is_current_account
FROM customer_premises cp
JOIN {{catalog}}.{{schema}}.fact_service_event se
  ON se.premise_id = cp.premise_id
LEFT JOIN primary_sp sp ON sp.premise_id = se.premise_id
ORDER BY se.event_date DESC, se.service_event_id DESC
LIMIT 40
