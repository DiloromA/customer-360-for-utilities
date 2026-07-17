-- Customer account timeline — the service-event log for this premise:
-- move-in / move-out / rate switch / meter swap, alongside the bills, outages
-- and complaints the other cards show. Sourced from fact_service_event, which
-- opens/closes the effective-dated bridges (the occurrence log of the model).
--
-- Keyed by account_number → premise. We filter by PREMISE (not account) so
-- meter swaps — which are premise/service-point events and carry no account_id
-- — show up, and so the rep sees the full history of the address (a prior
-- occupant's move-in/out included). Events not belonging to the current account
-- are flagged is_current_account = false so the UI can label them "(previous
-- occupant)".

-- @param account_number STRING

WITH acct AS (
  SELECT account_id, premise_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
)
SELECT
  se.service_event_id,
  se.event_type,
  se.event_date,
  se.detail,
  se.account_id,
  se.meter_id,
  se.service_agreement_id,
  (se.account_id = acct.account_id) AS is_current_account
FROM acct
JOIN {{catalog}}.{{schema}}.fact_service_event se
  ON se.premise_id = acct.premise_id
ORDER BY se.event_date DESC, se.service_event_id DESC
LIMIT 40
