-- Executive map — per-cell metrics for a single selected program.
-- Used by the "Program enrollment" and "Underserved by program" map
-- layers. Returns:
--   pct_enrolled    — % of customers in cell currently enrolled
--   n_eligible      — count of customers whose customer_class matches
--                     the program's target segment
--   n_not_enrolled_eligible — eligible but not enrolled
--   pct_gap         — % of eligible customers not yet enrolled
--                     (the "underserved" metric)
--
-- Customers are the current customer per premise (bridge_account_premise where
-- is_current → dim_customer).

-- @param program_id  STRING
-- @param resolution  INTEGER
-- @param south       STRING  -- lat/lon bounds as strings, CAST to DOUBLE
-- @param north       STRING
-- @param west        STRING
-- @param east        STRING
-- @param customer_classes STRING  -- comma list; "" = no filter
-- @param usage_bands      STRING
-- @param engagement_tiers STRING
-- @param issue_flags      STRING
-- @param grain            STRING  -- 'premise' | 'customer'; default 'customer'

WITH program AS (
  SELECT program_id, customer_segment
  FROM {{catalog}}.{{schema}}.dim_program
  WHERE program_id = :program_id
),

premises_in_view AS (
  SELECT
    h3.premise_id,
    h3.latitude,
    h3.longitude,
    CASE :resolution
      WHEN 5 THEN h3.h3_res5
      WHEN 6 THEN h3.h3_res6
      WHEN 7 THEN h3.h3_res7
      WHEN 8 THEN h3.h3_res8
      WHEN 9 THEN h3.h3_res9
      ELSE        h3.h3_res7
    END AS h3_index_long
  FROM {{catalog}}.{{schema}}.dim_premise_h3 h3
  WHERE h3.latitude  BETWEEN CAST(:south AS DOUBLE) AND CAST(:north AS DOUBLE)
    AND h3.longitude BETWEEN CAST(:west AS DOUBLE) AND CAST(:east AS DOUBLE)
),

enrolled_customers AS (
  SELECT DISTINCT customer_id
  FROM {{catalog}}.{{schema}}.fact_program_enrollment
  WHERE program_id = :program_id
    AND enrollment_status IN ('active', 'completed')
),

enrolled_premises AS (
  SELECT DISTINCT premise_id
  FROM {{catalog}}.{{schema}}.fact_program_enrollment
  WHERE program_id = :program_id
    AND enrollment_status IN ('active', 'completed')
),

filter_lists AS (
  SELECT
    split(:customer_classes, ',') AS class_list,
    split(:usage_bands,       ',') AS usage_list,
    split(:engagement_tiers,  ',') AS eng_list,
    split(:issue_flags,       ',') AS flag_list
),

cell_rollup AS (
  -- Same multi-dim filter the map rail uses; "" = no filter.
  SELECT
    p.h3_index_long,
    COUNT(*)                                          AS n_customers,
    SUM(CASE WHEN LOWER(c.customer_class) = LOWER(pr.customer_segment) THEN 1 ELSE 0 END)
                                                       AS n_eligible,
    SUM(CASE
          WHEN :grain = 'premise' THEN (CASE WHEN ep.premise_id  IS NOT NULL THEN 1 ELSE 0 END)
          ELSE                         (CASE WHEN ec.customer_id IS NOT NULL THEN 1 ELSE 0 END)
        END)                                            AS n_enrolled,
    SUM(CASE
          WHEN LOWER(c.customer_class) = LOWER(pr.customer_segment)
           AND (CASE WHEN :grain = 'premise' THEN ep.premise_id  IS NULL
                     ELSE                         ec.customer_id IS NULL END)
          THEN 1 ELSE 0
        END)                                            AS n_not_enrolled_eligible,
    AVG(p.latitude)                                     AS centroid_lat,
    AVG(p.longitude)                                    AS centroid_lon
  FROM premises_in_view p
  JOIN {{catalog}}.{{schema}}.bridge_account_premise b
    ON b.premise_id = p.premise_id AND b.is_current
  JOIN {{catalog}}.{{schema}}.dim_customer c ON c.customer_id = b.customer_id
  CROSS JOIN program pr
  CROSS JOIN filter_lists f
  LEFT JOIN enrolled_customers ec ON ec.customer_id = c.customer_id
  LEFT JOIN enrolled_premises  ep ON ep.premise_id  = p.premise_id
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
  GROUP BY p.h3_index_long
)

SELECT
  h3_h3tostring(h3_index_long)                                                          AS h3_index,
  n_customers,
  n_eligible,
  n_enrolled,
  n_not_enrolled_eligible,
  ROUND(100.0 * n_enrolled              / NULLIF(n_customers, 0), 1)                    AS pct_enrolled,
  ROUND(100.0 * n_not_enrolled_eligible / NULLIF(n_eligible,  0), 1)                    AS pct_gap,
  centroid_lat,
  centroid_lon
FROM cell_rollup
WHERE n_customers > 0
