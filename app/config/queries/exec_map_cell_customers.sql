-- Top customers inside a single H3 cell, ordered by "interesting-ness"
-- so the drill-down panel shows the cases most worth a customer conversation.
-- Returns the human account_number as the selectable identity (one row per
-- premise = current occupant, via bridge_account_premise where is_current).

-- @param h3_index   STRING
-- @param resolution INTEGER

WITH
-- One row per premise for address display. A large sub-metered commercial
-- premise (temporal-realism §5.3) has 2-5 dim_service_point rows sharing the
-- same address, so a naive join would duplicate that account's row in the
-- drill-down list — any one sibling is a fine representative since the
-- address fields are identical across siblings.
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
),
cell AS (
  SELECT a.account_number, c.customer_class,
         c.payment_stressed_flag, c.high_user_flag, c.churn_risk_band,
         c.critical_care_flag, c.liheap_eligible, c.engagement_tier,
         c.recent_complaint_count_90d, c.recent_outage_minutes_90d,
         sp.service_address, sp.service_city, pr.county
  FROM {{catalog}}.{{schema}}.dim_premise_h3 h3
  JOIN {{catalog}}.{{schema}}.bridge_account_premise b
    ON b.premise_id = h3.premise_id AND b.is_current
  JOIN {{catalog}}.{{schema}}.dim_account a       ON a.account_id = b.account_id
  JOIN {{catalog}}.{{schema}}.dim_customer c      ON c.customer_id = b.customer_id
  JOIN primary_sp sp                              ON sp.premise_id = h3.premise_id
  JOIN {{catalog}}.{{schema}}.dim_premise pr      ON pr.premise_id = h3.premise_id
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
  account_number,
  customer_class,
  service_address,
  service_city,
  county,
  engagement_tier,
  payment_stressed_flag,
  high_user_flag,
  churn_risk_band,
  critical_care_flag,
  liheap_eligible,
  recent_complaint_count_90d,
  recent_outage_minutes_90d
FROM cell
ORDER BY
  (CASE WHEN payment_stressed_flag       THEN 4 ELSE 0 END
   + CASE WHEN churn_risk_band = 'high'  THEN 3 ELSE 0 END
   + LEAST(recent_complaint_count_90d, 5)
   + CASE WHEN recent_outage_minutes_90d >= 180 THEN 2 ELSE 0 END
   + CASE WHEN critical_care_flag         THEN 2 ELSE 0 END) DESC,
  account_number
LIMIT 50
