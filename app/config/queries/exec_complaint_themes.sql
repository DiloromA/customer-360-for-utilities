-- Top complaint themes — category × severity in the trailing 90 days.
-- Each row is one (category, sub_category) bucket with counts split by
-- sentiment so the exec view can render stacked bars or a treemap.

SELECT
  category,
  sub_category,
  COUNT(*)                                                          AS n_complaints,
  SUM(CASE WHEN severity = 'high' THEN 1 ELSE 0 END)                AS n_high_severity,
  SUM(CASE WHEN sentiment_label IN ('negative', 'very_negative') THEN 1 ELSE 0 END)
                                                                    AS n_negative,
  SUM(CASE WHEN sentiment_label = 'very_negative' THEN 1 ELSE 0 END) AS n_very_negative,
  SUM(CASE WHEN resolution_status = 'escalated' THEN 1 ELSE 0 END)  AS n_escalated,
  ROUND(AVG(resolution_minutes), 0)                                 AS avg_resolution_minutes,
  COUNT(DISTINCT customer_id)                                       AS unique_customers
FROM {{catalog}}.{{schema}}.fact_customer_complaints
CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
WHERE complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date
GROUP BY category, sub_category
ORDER BY n_complaints DESC
LIMIT 20
