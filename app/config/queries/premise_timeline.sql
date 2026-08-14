-- Service-event log for this premise (address): move-in / move-out / rate
-- switch / meter swap. Premise-native version of customer_timeline.sql —
-- no account_number resolution step, since fact_service_event is already
-- premise-keyed. Events not belonging to the current customer's account
-- are flagged is_current_account = false so the UI can label them
-- "(previous customer)". Keyed by premise_number (STRING) — see
-- premise_header.sql's note on why the client never carries the raw
-- BIGINT premise_id.

-- @param premise_number STRING

WITH prem AS (
  SELECT premise_id
  FROM {{catalog}}.{{schema}}.dim_premise
  WHERE premise_number = :premise_number
),
cur AS (
  SELECT b.account_id
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN prem ON prem.premise_id = b.premise_id
  WHERE b.is_current
  LIMIT 1
)
SELECT
  se.service_event_id,
  se.event_type,
  se.event_date,
  se.detail,
  se.account_id,
  se.meter_id,
  se.service_agreement_id,
  COALESCE(se.account_id = cur.account_id, false) AS is_current_account
FROM prem
JOIN {{catalog}}.{{schema}}.fact_service_event se ON se.premise_id = prem.premise_id
LEFT JOIN cur ON true
ORDER BY se.event_date DESC, se.service_event_id DESC
LIMIT 40
