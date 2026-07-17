-- Cell drill-down: a single H3 cell's aggregate stats vs the territory
-- average. Returns scalar columns only — top themes and top programs
-- are in separate queries (exec_map_cell_themes, exec_map_cell_programs)
-- because the appkit-ui analytics plugin returns SQL ARRAY<STRUCT>
-- columns as JSON strings, not parsed arrays.
--
-- Customers (cell + territory baseline) are the current occupant per premise
-- (bridge_account_premise where is_current → dim_customer), so the denominators
-- count today's customers, not historical/prior-occupant rows.
--
-- The h3_index is passed as the BIGINT-converted-to-string form
-- (h3_h3tostring). We convert back with h3_stringtoh3 for the join.

-- @param h3_index   STRING       -- the stringified H3 cell index
-- @param resolution INTEGER

WITH cell_customers AS (
  SELECT
    c.customer_id,
    c.customer_class,
    c.payment_stressed_flag,
    c.churn_risk_band,
    c.critical_care_flag,
    c.liheap_eligible,
    c.engagement_tier,
    c.high_user_flag,
    c.usage_band,
    c.recent_outage_minutes_90d,
    c.recent_complaint_count_90d,
    c.income_band,
    c.household_size,
    c.age_band_hoh
  FROM {{catalog}}.{{schema}}.dim_premise_h3 h3
  JOIN {{catalog}}.{{schema}}.bridge_account_premise b
    ON b.premise_id = h3.premise_id AND b.is_current
  JOIN {{catalog}}.{{schema}}.dim_customer c ON c.customer_id = b.customer_id
  WHERE
    CASE :resolution
      WHEN 5 THEN h3.h3_res5
      WHEN 6 THEN h3.h3_res6
      WHEN 7 THEN h3.h3_res7
      WHEN 8 THEN h3.h3_res8
      WHEN 9 THEN h3.h3_res9
    END = h3_stringtoh3(:h3_index)
),

aggregate AS (
  SELECT
    COUNT(*)                                                          AS n_customers,
    SUM(CASE WHEN customer_class = 'Residential' THEN 1 ELSE 0 END)   AS n_residential,
    SUM(CASE WHEN customer_class = 'Commercial'  THEN 1 ELSE 0 END)   AS n_commercial,
    SUM(CASE WHEN payment_stressed_flag THEN 1 ELSE 0 END)             AS n_payment_stressed,
    SUM(CASE WHEN churn_risk_band = 'high' THEN 1 ELSE 0 END)          AS n_churn_high,
    SUM(CASE WHEN critical_care_flag THEN 1 ELSE 0 END)                AS n_critical_care,
    SUM(CASE WHEN liheap_eligible THEN 1 ELSE 0 END)                   AS n_liheap,
    SUM(CASE WHEN engagement_tier = 'high' THEN 1 ELSE 0 END)          AS n_engagement_high,
    SUM(CASE WHEN high_user_flag THEN 1 ELSE 0 END)                    AS n_high_usage,
    SUM(recent_outage_minutes_90d)                                     AS sum_outage_minutes_90d,
    SUM(recent_complaint_count_90d)                                    AS sum_complaints_90d
  FROM cell_customers
),

territory AS (
  SELECT
    AVG(CASE WHEN c.payment_stressed_flag THEN 1.0 ELSE 0.0 END) * 100 AS terr_pct_payment_stressed,
    AVG(CASE WHEN c.churn_risk_band = 'high' THEN 1.0 ELSE 0.0 END) * 100 AS terr_pct_churn_high,
    AVG(CASE WHEN c.critical_care_flag THEN 1.0 ELSE 0.0 END) * 100 AS terr_pct_critical_care,
    AVG(CASE WHEN c.liheap_eligible THEN 1.0 ELSE 0.0 END) * 100 AS terr_pct_liheap,
    AVG(CASE WHEN c.engagement_tier = 'high' THEN 1.0 ELSE 0.0 END) * 100 AS terr_pct_engagement_high,
    AVG(CASE WHEN c.high_user_flag THEN 1.0 ELSE 0.0 END) * 100 AS terr_pct_high_usage,
    SUM(c.recent_outage_minutes_90d) * 1.0 / COUNT(*)                  AS terr_avg_outage_min,
    SUM(c.recent_complaint_count_90d) * 1000.0 / COUNT(*)              AS terr_complaints_per_1k
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN {{catalog}}.{{schema}}.dim_customer c ON c.customer_id = b.customer_id
  WHERE b.is_current
)

SELECT
  -- Aggregate metrics
  a.n_customers,
  a.n_residential,
  a.n_commercial,
  a.n_payment_stressed,
  ROUND(100.0 * a.n_payment_stressed / NULLIF(a.n_customers, 0), 1) AS pct_payment_stressed,
  a.n_churn_high,
  ROUND(100.0 * a.n_churn_high / NULLIF(a.n_customers, 0), 1)      AS pct_churn_high,
  a.n_critical_care,
  ROUND(100.0 * a.n_critical_care / NULLIF(a.n_customers, 0), 1)   AS pct_critical_care,
  a.n_liheap,
  ROUND(100.0 * a.n_liheap / NULLIF(a.n_customers, 0), 1)          AS pct_liheap,
  a.n_engagement_high,
  ROUND(100.0 * a.n_engagement_high / NULLIF(a.n_customers, 0), 1) AS pct_engagement_high,
  a.n_high_usage,
  ROUND(100.0 * a.n_high_usage / NULLIF(a.n_customers, 0), 1)      AS pct_high_usage,
  a.sum_outage_minutes_90d,
  ROUND(1.0 * a.sum_outage_minutes_90d / NULLIF(a.n_customers, 0), 1) AS avg_outage_min_per_customer,
  a.sum_complaints_90d,
  ROUND(1000.0 * a.sum_complaints_90d / NULLIF(a.n_customers, 0), 1) AS complaints_per_1k,
  -- Territory baselines for delta UI
  ROUND(t.terr_pct_payment_stressed, 1) AS terr_pct_payment_stressed,
  ROUND(t.terr_pct_churn_high, 1)       AS terr_pct_churn_high,
  ROUND(t.terr_pct_critical_care, 1)    AS terr_pct_critical_care,
  ROUND(t.terr_pct_liheap, 1)           AS terr_pct_liheap,
  ROUND(t.terr_pct_engagement_high, 1)  AS terr_pct_engagement_high,
  ROUND(t.terr_pct_high_usage, 1)       AS terr_pct_high_usage,
  ROUND(t.terr_avg_outage_min, 1)       AS terr_avg_outage_min,
  ROUND(t.terr_complaints_per_1k, 1)    AS terr_complaints_per_1k
FROM aggregate a
CROSS JOIN territory t
