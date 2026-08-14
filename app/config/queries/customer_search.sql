-- Broad customer search across the full current customer base. Used when the
-- user types into the sidebar search box. Returns up to 100 matches ranked by
-- relevance (exact account-number match first, then prefix, then contains on
-- account number / address / city / org name).
--
-- Two result branches:
--   1. Premise-bearing customers (residential, standalone-commercial,
--      commercial_chain, commercial_subsidiary): anchored on the current
--      billing link per premise (bridge is_current). Prior customers don't
--      surface. Result carries a service address and lat/lng.
--   2. commercial_parent org search: premise-less parties. When the user
--      types an org name fragment they find the parent org as a result with
--      a portfolio_premise_count and no fabricated address. The deep-link
--      key is customer_number (never a nullable account/premise key).

-- @param search_term STRING

WITH
-- One row per premise for address display. A large sub-metered commercial
-- premise has 2-5 dim_service_point rows sharing the
-- same address, so a naive join would duplicate that account's search
-- result — any one sibling is a fine representative since the address
-- fields are identical across siblings.
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
),

-- ── Branch 1: premise-bearing customers ──────────────────────────────────────
premise_base AS (
  SELECT
    a.account_number,
    c.customer_number,
    c.customer_class,
    c.customer_name,
    sp.service_address,
    sp.service_city,
    pr.county,
    c.engagement_tier,
    c.payment_stressed_flag,
    c.high_user_flag,
    c.churn_risk_band,
    c.recent_complaint_count_90d,
    c.recent_outage_minutes_90d,
    c.liheap_eligible,
    c.critical_care_flag,
    CAST(NULL AS BIGINT) AS portfolio_premise_count,
    h3.latitude,
    h3.longitude
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN {{catalog}}.{{schema}}.dim_account a        ON a.account_id = b.account_id
  JOIN {{catalog}}.{{schema}}.dim_customer c       ON c.customer_id = b.customer_id
  JOIN primary_sp sp                               ON sp.premise_id = b.premise_id
  JOIN {{catalog}}.{{schema}}.dim_premise pr       ON pr.premise_id = b.premise_id
  JOIN {{catalog}}.{{schema}}.dim_premise_h3 h3    ON h3.premise_id = b.premise_id
  WHERE b.is_current
),

-- ── Branch 2: commercial_parent org search ───────────────────────────────────
-- Premise-less parties. No account_number or address — the deep link is
-- customer_number. portfolio_premise_count comes from n_premises_portfolio.
parent_base AS (
  SELECT
    CAST(NULL AS STRING)  AS account_number,
    c.customer_number,
    c.customer_class,
    c.customer_name,
    CAST(NULL AS STRING)  AS service_address,
    CAST(NULL AS STRING)  AS service_city,
    CAST(NULL AS STRING)  AS county,
    c.engagement_tier,
    c.payment_stressed_flag,
    c.high_user_flag,
    c.churn_risk_band,
    c.recent_complaint_count_90d,
    c.recent_outage_minutes_90d,
    c.liheap_eligible,
    c.critical_care_flag,
    c.n_premises_portfolio AS portfolio_premise_count,
    CAST(NULL AS DOUBLE)  AS latitude,
    CAST(NULL AS DOUBLE)  AS longitude
  FROM {{catalog}}.{{schema}}.dim_customer c
  WHERE c.customer_type = 'commercial_parent'
    AND c.customer_name IS NOT NULL
),

all_base AS (
  SELECT * FROM premise_base
  UNION ALL
  SELECT * FROM parent_base
),

matched AS (
  SELECT *,
    CASE
      WHEN LOWER(account_number)    = LOWER(:search_term)                THEN 0
      WHEN LOWER(account_number) LIKE LOWER(:search_term || '%')         THEN 1
      WHEN LOWER(customer_name)     = LOWER(:search_term)                THEN 1
      WHEN LOWER(service_address) LIKE LOWER(:search_term || '%')        THEN 2
      WHEN LOWER(customer_name)  LIKE LOWER(:search_term || '%')         THEN 2
      WHEN LOWER(service_city)   LIKE LOWER(:search_term || '%')         THEN 3
      WHEN LOWER(service_address) LIKE LOWER('%' || :search_term || '%') THEN 4
      WHEN LOWER(customer_name)  LIKE LOWER('%' || :search_term || '%')  THEN 4
      WHEN LOWER(service_city)   LIKE LOWER('%' || :search_term || '%')  THEN 5
      ELSE 99
    END AS match_rank
  FROM all_base
  WHERE
    LOWER(COALESCE(account_number, ''))   LIKE LOWER('%' || :search_term || '%')
    OR LOWER(COALESCE(service_address, '')) LIKE LOWER('%' || :search_term || '%')
    OR LOWER(COALESCE(service_city, ''))    LIKE LOWER('%' || :search_term || '%')
    OR LOWER(COALESCE(customer_name, ''))   LIKE LOWER('%' || :search_term || '%')
)
SELECT
  account_number, customer_number, customer_class, customer_name,
  service_address, service_city, county,
  engagement_tier, payment_stressed_flag, high_user_flag,
  churn_risk_band, recent_complaint_count_90d, recent_outage_minutes_90d,
  portfolio_premise_count,
  latitude, longitude,
  'search-result' AS archetype
FROM matched
WHERE match_rank < 99
ORDER BY match_rank, COALESCE(account_number, customer_number)
LIMIT 100
