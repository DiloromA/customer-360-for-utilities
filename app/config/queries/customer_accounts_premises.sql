-- Every account this customer holds, and every account<->premise tenancy
-- link for those accounts — CURRENT and CLOSED. The first UI consumer of the
-- full bridge_account_premise history rather than the `is_current`-filtered
-- view customer_header.sql/customer_search.sql use. Chain customers show N
-- site accounts + the corporate_parent consolidated bill (no premise of its
-- own); residential movers (a later synthetic-data phase) will show two
-- tenancies on one account here.
--
-- Keyed by account_number -> customer_id: the point of this query is showing
-- EVERY account/premise this customer has ever held, not just the one
-- deep-linked into.

-- @param account_number STRING

WITH acct AS (
  SELECT customer_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
),
customer_accounts AS (
  SELECT a.account_id, a.account_number, a.account_group, a.parent_account_id,
         a.current_status, a.rate_display_name
  FROM {{catalog}}.{{schema}}.dim_account a
  JOIN acct ON acct.customer_id = a.customer_id
),
-- One row per premise for address display. A large sub-metered commercial
-- premise (temporal-realism §5.3) has 2-5 dim_service_point rows sharing the
-- same address, so a naive join would duplicate this tenancy-link row —
-- any one sibling is a fine representative since the address fields are
-- identical across siblings.
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
)
SELECT
  ca.account_number,
  ca.account_group,
  parent.account_number AS parent_account_number,
  ca.current_status     AS account_status,
  ca.rate_display_name,
  b.account_premise_link_id,
  sp.service_address,
  sp.service_city,
  sp.service_state,
  b.link_start_date,
  b.link_end_date,
  b.is_current,
  b.occupancy_type,
  b.link_termination_reason
FROM customer_accounts ca
LEFT JOIN {{catalog}}.{{schema}}.dim_account parent
  ON parent.account_id = ca.parent_account_id
LEFT JOIN {{catalog}}.{{schema}}.bridge_account_premise b
  ON b.account_id = ca.account_id
LEFT JOIN primary_sp sp
  ON sp.premise_id = b.premise_id
ORDER BY ca.account_number, b.link_start_date
