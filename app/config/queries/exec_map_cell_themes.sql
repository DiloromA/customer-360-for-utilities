-- Top 5 complaint sub-categories in a single H3 cell over the 90-day
-- window. Split out from exec_map_cell_detail because ARRAY<STRUCT>
-- columns get returned as JSON strings by the analytics plugin —
-- separate scalar-column queries are simpler to consume.
-- Cell customers = current customer per premise (bridge is_current).

-- @param h3_index   STRING
-- @param resolution INTEGER

WITH cell_customers AS (
  SELECT b.customer_id
  FROM {{catalog}}.{{schema}}.dim_premise_h3 h3
  JOIN {{catalog}}.{{schema}}.bridge_account_premise b
    ON b.premise_id = h3.premise_id AND b.is_current
  WHERE
    CASE :resolution
      WHEN 5 THEN h3.h3_res5
      WHEN 6 THEN h3.h3_res6
      WHEN 7 THEN h3.h3_res7
      WHEN 8 THEN h3.h3_res8
      WHEN 9 THEN h3.h3_res9
    END = h3_stringtoh3(:h3_index)
)
SELECT
  cc.sub_category,
  COUNT(*) AS n
FROM {{catalog}}.{{schema}}.fact_customer_complaints cc
JOIN cell_customers cust ON cust.customer_id = cc.customer_id
CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
WHERE cc.complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date
GROUP BY cc.sub_category
ORDER BY n DESC
LIMIT 5
