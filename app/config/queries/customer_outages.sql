-- Outage history across all of the customer's own premises (last 24 months).
-- Resolves the account_number to its customer, then fans out to every premise
-- that customer held at the time of each outage via a PIT join through
-- hierarchy_version (direct scope — hv.customer_id, the customer's own service
-- paths). One row per outage×premise; each row carries premise_number so the UI
-- can label which site was affected.
-- Covers single-premise customers, relocated customers (prior-premise history),
-- and multi-site commercial customers. This is an account-keyed CSR screen, so
-- it uses direct scope, not the parent portfolio roll-up (a commercial_parent
-- holds no account and is never reached here).

-- @param account_number STRING

WITH acct AS (
  SELECT a.customer_id
  FROM {{catalog}}.{{schema}}.dim_account a
  WHERE a.account_number = :account_number
),
customer_premises AS (
  -- Distinct premise validity windows for this customer's own service paths.
  -- DISTINCT on (premise_id, valid_from, valid_to) collapses the multiple
  -- service-point/meter rows that hierarchy_version holds per premise interval,
  -- preventing fan-out when joining to fact_outage_customer_impact.
  SELECT DISTINCT
    hv.premise_id,
    hv.valid_from,
    hv.valid_to
  FROM acct
  JOIN {{catalog}}.{{schema}}.hierarchy_version hv
    ON hv.customer_id = acct.customer_id
)
SELECT
  ci.impact_id,
  ci.outage_id,
  ci.affected_start,
  ci.affected_end,
  ci.minutes_out,
  ci.priority_restoration_flag,
  o.cause_code,
  o.weather_category,
  o.is_major_event_day,
  o.duration_bucket,
  o.affected_customer_count                                           AS circuit_affected_count,
  p.premise_number
FROM customer_premises cp
JOIN {{catalog}}.{{schema}}.fact_outage_customer_impact ci
  ON ci.premise_id = cp.premise_id
 AND ci.affected_start >= cp.valid_from
 AND (cp.valid_to IS NULL OR ci.affected_start < cp.valid_to)
JOIN {{catalog}}.{{schema}}.fact_outage_events o USING (outage_id)
JOIN {{catalog}}.{{schema}}.dim_premise p ON p.premise_id = cp.premise_id
ORDER BY ci.affected_start DESC
LIMIT 30
