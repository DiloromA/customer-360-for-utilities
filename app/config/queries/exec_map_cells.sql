-- Executive map — per-H3-cell metrics for the choropleth layers.
-- One row per H3 cell at the requested resolution within the viewport
-- bounds. Returns all metrics so the client can swap layers without a
-- new round-trip.
--
-- Customers are the CURRENT customer per premise: each premise is joined to its
-- current billing link (bridge_account_premise where is_current) and then to the
-- customer's profile (dim_customer). Prior customers are excluded automatically.
--
-- The "Complaint volume" layer can be focused on a single complaint
-- sub-category via :complaint_theme — when set, the whole map filters to
-- customers who filed a complaint of that sub-category, so cells/dots/KPIs all
-- narrow to that theme. "" = all complaints (the default).

-- @param resolution INTEGER     -- H3 resolution 5-9
-- @param south STRING  -- lat/lon bounds passed as strings, CAST to DOUBLE
-- @param north STRING  -- (sql.number binds DECIMAL(38,0) and truncates them)
-- @param west STRING
-- @param east STRING
-- @param customer_classes STRING  -- comma list; "" = no filter
-- @param usage_bands      STRING
-- @param engagement_tiers STRING
-- @param issue_flags      STRING  -- payment_stress, churn_high, critical_care, frequent_outages, high_complaints, liheap
-- @param complaint_theme  STRING  -- "" = all complaints; else a fact_customer_complaints.sub_category to isolate
-- @param session_id       STRING  -- "" = no cohort filter; else scope to this session's app_focus_set cohort
-- @param grain            STRING  -- 'premise' | 'customer' | 'owner'; default 'customer' (customer grain = today's output)

WITH premises_in_view AS (
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

filter_lists AS (
  SELECT
    split(:customer_classes, ',') AS class_list,
    split(:usage_bands,       ',') AS usage_list,
    split(:engagement_tiers,  ',') AS eng_list,
    split(:issue_flags,       ',') AS flag_list
),

customers_in_view AS (
  -- Same multi-dim filter the customer rail uses (see
  -- filters.tsx). All-empty params = no filtering, so the map behaves as
  -- before when the rail is untouched. One row per premise = current customer.
  SELECT
    p.h3_index_long,
    p.premise_id,
    c.customer_id,
    c.customer_class,
    c.payment_stressed_flag,
    c.churn_risk_band,
    c.critical_care_flag,
    c.liheap_eligible,
    c.engagement_tier,
    c.high_user_flag,
    c.digital_adoption_score,
    c.recent_outage_minutes_90d,
    c.recent_complaint_count_90d,
    -- Predicted 30-day complaint risk (ml_complaint_predictor, latest cycle).
    -- LEFT JOIN: a customer with no score row contributes NULL (excluded from
    -- AVG) rather than dragging the cell toward zero.
    s.p_complaint_30d,
    s.risk_tier
  FROM premises_in_view p
  JOIN {{catalog}}.{{schema}}.bridge_account_premise b
    ON b.premise_id = p.premise_id AND b.is_current
  JOIN {{catalog}}.{{schema}}.dim_customer c
    ON c.customer_id = b.customer_id
  LEFT JOIN {{catalog}}.{{schema}}.ml_complaint_risk_scores s
    ON s.customer_id = c.customer_id
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
    -- Complaint-theme focus: restrict to customers who filed a complaint of the
    -- selected sub-category in the window, so the whole map filters to that theme.
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
    -- Focus-group cohort: when a session cohort is active, scope the whole
    -- choropleth to its customers so the cells recolor to cohort-only
    -- aggregates (same legend scale) instead of a separate footprint overlay.
    -- The premise guard keeps a spatial (hex/box) cohort premise-grained: a
    -- multi-site customer lights only the premise that's actually in the
    -- cohort, not every premise they hold elsewhere. Customer-grained cohorts
    -- (sql/filters/accountNumbers/customerIds) carry premise_id = NULL and are
    -- unaffected.
    AND (
      :session_id = ''
      OR EXISTS (
        SELECT 1 FROM {{catalog}}.{{schema}}.app_focus_set fs
        WHERE fs.session_id = :session_id AND fs.customer_id = c.customer_id
          AND (fs.premise_id IS NULL OR fs.premise_id = p.premise_id)
      )
    )
),

cell_customer_metrics AS (
  SELECT
    h3_index_long,
    COUNT(*)                                                            AS n_customers,
    SUM(CASE WHEN customer_class = 'Residential' THEN 1 ELSE 0 END)     AS n_residential,
    SUM(CASE WHEN customer_class = 'Commercial'  THEN 1 ELSE 0 END)     AS n_commercial,
    SUM(CASE WHEN payment_stressed_flag        THEN 1 ELSE 0 END)        AS n_payment_stressed,
    SUM(CASE WHEN churn_risk_band = 'high'     THEN 1 ELSE 0 END)        AS n_churn_high,
    SUM(CASE WHEN critical_care_flag           THEN 1 ELSE 0 END)        AS n_critical_care,
    SUM(CASE WHEN liheap_eligible              THEN 1 ELSE 0 END)        AS n_liheap,
    SUM(CASE WHEN engagement_tier = 'high'     THEN 1 ELSE 0 END)        AS n_engagement_high,
    SUM(CASE WHEN high_user_flag               THEN 1 ELSE 0 END)        AS n_high_usage,
    SUM(digital_adoption_score)                                          AS sum_digital_adoption,
    SUM(recent_outage_minutes_90d)                                       AS sum_outage_minutes_90d,
    SUM(recent_complaint_count_90d)                                      AS sum_complaints_90d,
    AVG(p_complaint_30d)                                                  AS avg_p_complaint_30d,
    SUM(CASE WHEN risk_tier IN ('high', 'elevated') THEN 1 ELSE 0 END)    AS n_risk_elevated_plus,
    SUM(CASE WHEN risk_tier = 'high' THEN 1 ELSE 0 END)                   AS n_risk_high
  FROM customers_in_view
  GROUP BY h3_index_long
),

cell_themes AS (
  -- Dominant complaint theme per cell over the 90-day window.
  SELECT h3_index_long, sub_category AS dominant_theme, n_complaints
  FROM (
    SELECT
      civ.h3_index_long,
      cc.sub_category,
      COUNT(*) AS n_complaints,
      ROW_NUMBER() OVER (PARTITION BY civ.h3_index_long ORDER BY COUNT(*) DESC) AS rn
    FROM {{catalog}}.{{schema}}.fact_customer_complaints cc
    JOIN customers_in_view civ ON civ.customer_id = cc.customer_id
    CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
    WHERE cc.complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date
    GROUP BY civ.h3_index_long, cc.sub_category
  )
  WHERE rn = 1
),

cell_enrollment AS (
  -- Total active program enrollments (any program) per cell.
  SELECT
    civ.h3_index_long,
    COUNT(DISTINCT fpe.customer_id) AS n_enrolled_any_program
  FROM {{catalog}}.{{schema}}.fact_program_enrollment fpe
  JOIN customers_in_view civ ON civ.customer_id = fpe.customer_id
  WHERE fpe.enrollment_status IN ('active', 'completed')
  GROUP BY civ.h3_index_long
),

cell_premise_complaints AS (
  -- Premise-pinned complaint count for premise grain (matches premise_complaints.sql join path).
  -- Only complaints with a resolved premise_id are counted here; unmapped ones go to
  -- cell_unmapped_complaints below for the legend footnote.
  SELECT
    civ.h3_index_long,
    COUNT(fc.complaint_id) AS n_complaints_pinned
  FROM customers_in_view civ
  CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
  JOIN {{catalog}}.{{schema}}.fact_customer_complaints fc
    ON  fc.premise_id    = civ.premise_id
    AND fc.complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date
    AND (:complaint_theme = '' OR fc.sub_category = :complaint_theme)
  GROUP BY civ.h3_index_long
),

cell_unmapped_complaints AS (
  -- Complaints for cell customers with no premise attribution; used by the client
  -- to show a "~N% couldn't be pinned to a premise" legend footnote at premise grain.
  SELECT
    civ.h3_index_long,
    COUNT(DISTINCT fc.complaint_id) AS n_complaints_unmapped
  FROM customers_in_view civ
  CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
  JOIN {{catalog}}.{{schema}}.fact_customer_complaints fc
    ON  fc.customer_id   = civ.customer_id
    AND fc.premise_id    IS NULL
    AND fc.complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date
    AND (:complaint_theme = '' OR fc.sub_category = :complaint_theme)
  GROUP BY civ.h3_index_long
),

cell_premise_outages AS (
  -- Outage minutes aggregated by premise (fact_outage_customer_impact has premise_id 100%).
  -- 90-day window mirrors the customer-rollup window used at customer grain.
  SELECT
    civ.h3_index_long,
    SUM(oi.minutes_out) AS sum_outage_minutes_premise
  FROM customers_in_view civ
  CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
  JOIN {{catalog}}.{{schema}}.fact_outage_customer_impact oi
    ON  oi.premise_id    = civ.premise_id
    AND oi.affected_start >= DATE_SUB(cfg.as_of_date, 90)
    AND oi.affected_start <= cfg.as_of_date
  GROUP BY civ.h3_index_long
)

SELECT
  h3_h3tostring(m.h3_index_long)                                          AS h3_index,
  m.n_customers,
  m.n_residential,
  m.n_commercial,
  m.n_payment_stressed,
  ROUND(100.0 * m.n_payment_stressed / m.n_customers, 1)                  AS pct_payment_stressed,
  m.n_churn_high,
  ROUND(100.0 * m.n_churn_high / m.n_customers, 1)                        AS pct_churn_high,
  m.n_critical_care,
  ROUND(100.0 * m.n_critical_care / m.n_customers, 1)                     AS pct_critical_care,
  m.n_liheap,
  ROUND(100.0 * m.n_liheap / m.n_customers, 1)                            AS pct_liheap,
  m.n_engagement_high,
  ROUND(100.0 * m.n_engagement_high / m.n_customers, 1)                   AS pct_engagement_high,
  m.n_high_usage,
  ROUND(100.0 * m.n_high_usage / m.n_customers, 1)                        AS pct_high_usage,
  ROUND(1.0 * m.sum_digital_adoption / m.n_customers, 0)                  AS avg_digital_adoption,
  CASE WHEN :grain = 'premise'
    THEN COALESCE(po.sum_outage_minutes_premise, 0)
    ELSE m.sum_outage_minutes_90d
  END                                                                        AS sum_outage_minutes_90d,
  CASE WHEN :grain = 'premise'
    THEN ROUND(1.0 * COALESCE(po.sum_outage_minutes_premise, 0) / m.n_customers, 1)
    ELSE ROUND(1.0 * m.sum_outage_minutes_90d / m.n_customers, 1)
  END                                                                        AS avg_outage_min_per_customer_90d,
  CASE WHEN :grain = 'premise'
    THEN COALESCE(pc.n_complaints_pinned, 0)
    ELSE m.sum_complaints_90d
  END                                                                        AS sum_complaints_90d,
  CASE WHEN :grain = 'premise'
    THEN ROUND(1000.0 * COALESCE(pc.n_complaints_pinned, 0) / m.n_customers, 1)
    ELSE ROUND(1000.0 * m.sum_complaints_90d / m.n_customers, 1)
  END                                                                        AS complaints_per_1k_90d,
  CASE WHEN :grain = 'premise'
    THEN COALESCE(uc.n_complaints_unmapped, 0)
    ELSE 0
  END                                                                        AS n_complaints_unmapped,
  ROUND(100.0 * m.avg_p_complaint_30d, 1)                                 AS avg_complaint_risk_pct,
  m.n_risk_high,
  ROUND(100.0 * m.n_risk_high / m.n_customers, 1)                         AS pct_risk_high,
  m.n_risk_elevated_plus,
  ROUND(100.0 * m.n_risk_elevated_plus / m.n_customers, 1)                AS pct_risk_elevated_plus,
  COALESCE(t.dominant_theme, 'none')                                      AS dominant_theme,
  COALESCE(e.n_enrolled_any_program, 0)                                   AS n_enrolled_any_program,
  ROUND(100.0 * COALESCE(e.n_enrolled_any_program, 0) / m.n_customers, 1) AS pct_enrolled_any_program
FROM cell_customer_metrics m
LEFT JOIN cell_themes                t   USING (h3_index_long)
LEFT JOIN cell_enrollment            e   USING (h3_index_long)
LEFT JOIN cell_premise_complaints    pc  USING (h3_index_long)
LEFT JOIN cell_unmapped_complaints   uc  USING (h3_index_long)
LEFT JOIN cell_premise_outages       po  USING (h3_index_long)
