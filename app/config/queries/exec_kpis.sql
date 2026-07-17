-- CCO scorecard KPIs (single row).
-- 90-day window trailing curated_demo_config.as_of_date (the demo "current date").
--
-- Customer counts are the CURRENT customer base: one row per occupied premise
-- via bridge_account_premise (is_current) → dim_customer. Anchoring here (rather
-- than COUNT(*) dim_customer) excludes prior-occupant and chain-parent rows that
-- now live in the profile dimension, so the denominator is today's customers.

WITH customers AS (
  SELECT
    COUNT(*) AS total_customers,
    SUM(CASE WHEN c.payment_stressed_flag THEN 1 ELSE 0 END) AS payment_stressed_count,
    SUM(CASE WHEN c.churn_risk_band = 'high' THEN 1 ELSE 0 END) AS churn_high_count,
    SUM(CASE WHEN c.critical_care_flag THEN 1 ELSE 0 END) AS critical_care_count,
    ROUND(AVG(c.digital_adoption_score), 1) AS avg_digital_adoption,
    SUM(CASE WHEN c.engagement_tier = 'high' THEN 1 ELSE 0 END) AS high_engagement_count,
    SUM(c.recent_outage_minutes_90d) AS total_outage_minutes_90d,
    SUM(c.recent_outage_events_90d) AS total_outage_events_90d
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN {{catalog}}.{{schema}}.dim_customer c ON c.customer_id = b.customer_id
  WHERE b.is_current
),
complaints AS (
  SELECT
    COUNT(*) AS total_complaints_90d,
    ROUND(AVG(resolution_minutes), 0) AS avg_resolution_minutes,
    SUM(CASE WHEN sentiment_label IN ('negative', 'very_negative') THEN 1 ELSE 0 END) AS negative_sentiment_count,
    SUM(CASE WHEN severity = 'high' THEN 1 ELSE 0 END) AS high_severity_count,
    SUM(CASE WHEN resolution_status = 'escalated' THEN 1 ELSE 0 END) AS escalated_count
  FROM {{catalog}}.{{schema}}.fact_customer_complaints
  CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
  WHERE complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date
)
SELECT
  c.total_customers,
  c.payment_stressed_count,
  ROUND(100.0 * c.payment_stressed_count / c.total_customers, 1) AS pct_payment_stressed,
  c.churn_high_count,
  ROUND(100.0 * c.churn_high_count / c.total_customers, 1) AS pct_churn_high,
  c.critical_care_count,
  c.avg_digital_adoption,
  ROUND(100.0 * c.high_engagement_count / c.total_customers, 1) AS pct_high_engagement,
  cc.total_complaints_90d,
  ROUND(1000.0 * cc.total_complaints_90d / c.total_customers, 2) AS complaints_per_1k_customers_90d,
  cc.avg_resolution_minutes,
  cc.negative_sentiment_count,
  cc.high_severity_count,
  cc.escalated_count,
  c.total_outage_minutes_90d,
  c.total_outage_events_90d,
  ROUND(c.total_outage_minutes_90d / c.total_customers, 1) AS avg_outage_minutes_per_customer_90d
FROM customers c
CROSS JOIN complaints cc
