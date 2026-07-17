-- CCO scorecard KPIs scoped to the current map context (viewport bounds +
-- active filters). Same metric definitions as exec_kpis, but restricted to
-- customers whose premise falls inside the bounding box and who match the
-- active filters. Powers the viewport-reactive KPI strip on the Executive map:
-- at the territory zoom the box covers everyone (= macro numbers); as you zoom
-- or pan, the metrics track the slice on screen. Complaint volume uses the same
-- recent_complaint_count_90d the map's complaint layer uses, so the strip and
-- the map agree.
--
-- Customers in view = current occupant per premise (bridge_account_premise where
-- is_current → dim_customer).

-- @param south STRING  -- viewport bounds, passed as strings, CAST to DOUBLE
-- @param north STRING
-- @param west STRING
-- @param east STRING
-- @param customer_classes STRING  -- comma list; "" = no filter
-- @param usage_bands      STRING
-- @param engagement_tiers STRING
-- @param issue_flags      STRING
-- @param complaint_theme  STRING  -- "" = all complaints; else filter to a sub_category

WITH premises_in_view AS (
  SELECT h3.premise_id
  FROM {{catalog}}.{{schema}}.dim_premise_h3 h3
  WHERE h3.latitude  BETWEEN CAST(:south AS DOUBLE) AND CAST(:north AS DOUBLE)
    AND h3.longitude BETWEEN CAST(:west AS DOUBLE) AND CAST(:east AS DOUBLE)
),

filter_lists AS (
  SELECT
    split(:customer_classes, ',') AS class_list,
    split(:usage_bands,       ',') AS usage_list,
    split(:engagement_tiers,  ',') AS eng_list,
    split(:issue_flags,       ',') AS flag_list
),

customers_in_view AS (
  SELECT c.*
  FROM premises_in_view p
  JOIN {{catalog}}.{{schema}}.bridge_account_premise b
    ON b.premise_id = p.premise_id AND b.is_current
  JOIN {{catalog}}.{{schema}}.dim_customer c ON c.customer_id = b.customer_id
  CROSS JOIN filter_lists f
  WHERE
    (:customer_classes = '' OR array_contains(f.class_list, c.customer_class))
    AND (:usage_bands       = '' OR array_contains(f.usage_list, c.usage_band))
    AND (:engagement_tiers  = '' OR array_contains(f.eng_list,   c.engagement_tier))
    AND (
      :issue_flags = ''
      OR (array_contains(f.flag_list, 'payment_stress')   AND c.payment_stressed_flag)
      OR (array_contains(f.flag_list, 'critical_care')    AND c.critical_care_flag)
      OR (array_contains(f.flag_list, 'churn_high')       AND c.churn_risk_band = 'high')
      OR (array_contains(f.flag_list, 'frequent_outages') AND c.recent_outage_minutes_90d >= 180)
      OR (array_contains(f.flag_list, 'liheap')           AND c.liheap_eligible)
      OR (array_contains(f.flag_list, 'high_complaints')  AND c.recent_complaint_count_90d >= 2)
    )
    AND (
      :complaint_theme = ''
      OR EXISTS (
        SELECT 1 FROM {{catalog}}.{{schema}}.fact_customer_complaints cc
        CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
        WHERE cc.customer_id = c.customer_id
          AND cc.sub_category = :complaint_theme
          AND cc.complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date
      )
    )
),

agg AS (
  SELECT
    COUNT(*)                                                       AS total_customers,
    SUM(CASE WHEN payment_stressed_flag THEN 1 ELSE 0 END)         AS payment_stressed_count,
    SUM(CASE WHEN churn_risk_band = 'high' THEN 1 ELSE 0 END)      AS churn_high_count,
    SUM(CASE WHEN critical_care_flag THEN 1 ELSE 0 END)            AS critical_care_count,
    ROUND(AVG(digital_adoption_score), 1)                         AS avg_digital_adoption,
    SUM(CASE WHEN engagement_tier = 'high' THEN 1 ELSE 0 END)      AS high_engagement_count,
    SUM(recent_outage_minutes_90d)                                AS total_outage_minutes_90d,
    SUM(recent_outage_events_90d)                                 AS total_outage_events_90d,
    SUM(recent_complaint_count_90d)                               AS total_complaints_90d
  FROM customers_in_view
)

SELECT
  total_customers,
  payment_stressed_count,
  ROUND(100.0 * payment_stressed_count / NULLIF(total_customers, 0), 1)  AS pct_payment_stressed,
  churn_high_count,
  ROUND(100.0 * churn_high_count / NULLIF(total_customers, 0), 1)        AS pct_churn_high,
  critical_care_count,
  COALESCE(avg_digital_adoption, 0)                                     AS avg_digital_adoption,
  ROUND(100.0 * high_engagement_count / NULLIF(total_customers, 0), 1)   AS pct_high_engagement,
  total_complaints_90d,
  ROUND(1000.0 * total_complaints_90d / NULLIF(total_customers, 0), 2)   AS complaints_per_1k_customers_90d,
  total_outage_minutes_90d,
  total_outage_events_90d,
  ROUND(total_outage_minutes_90d / NULLIF(total_customers, 0), 1)        AS avg_outage_minutes_per_customer_90d
FROM agg
