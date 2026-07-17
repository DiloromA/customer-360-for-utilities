-- Customer profile header. All the at-a-glance fields needed at session start:
-- account info, rate, key flags, recent exposure — plus occupant history.
--
-- The app searches and deep-links by the human account_number string; this
-- query resolves it once to the BIGINT account_id / customer_id / premise_id,
-- then joins the star by key:
--   account → customer (profile + behavioural signals)
--           → premise (building) → service_point (address).
-- "Customer since" = the current tenancy start from the effective-dated
-- bridge_account_premise; if a prior occupant held this premise before the
-- current one, we surface when their tenancy ended (tenant turnover).

-- @param account_number STRING

WITH acct AS (
  SELECT account_id, customer_id, premise_id
  FROM {{catalog}}.{{schema}}.dim_account
  WHERE account_number = :account_number
),
-- One row per premise for address display. A large sub-metered commercial
-- premise (temporal-realism §5.3) has 2-5 dim_service_point rows sharing the
-- same address, so a naive join would duplicate this single-row header —
-- any one of them is a fine representative since the address fields are
-- identical across siblings.
primary_sp AS (
  SELECT *
  FROM {{catalog}}.{{schema}}.dim_service_point
  QUALIFY ROW_NUMBER() OVER (PARTITION BY premise_id ORDER BY service_point_id) = 1
),
cur_link AS (
  -- The current billing-responsibility link for this account at its premise.
  SELECT b.account_id, b.premise_id, b.link_start_date AS tenant_since
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN acct ON acct.account_id = b.account_id AND acct.premise_id = b.premise_id
  WHERE b.is_current
),
prior_occ AS (
  -- Previous occupant(s) of this premise (closed links = tenant turnover).
  SELECT b.premise_id,
         MAX(b.link_end_date) AS previous_occupant_until,
         COUNT(*)             AS previous_occupant_count
  FROM {{catalog}}.{{schema}}.bridge_account_premise b
  JOIN acct ON acct.premise_id = b.premise_id
  WHERE NOT b.is_current
  GROUP BY b.premise_id
),
-- THIS account/site's own trailing-12mo average monthly billed kWh. The header
-- is scoped to the account the CSR pulled up, so usage must be measured at that
-- site — NOT rolled up across a multi-site customer's whole portfolio (which is
-- what dim_customer.avg_monthly_kwh_12mo does). Window matches dim_customer.
-- A sub-metered commercial account (temporal-realism §5.3) bills one row PER
-- usage_point per month, so sum to (account, month) first — AVG over the raw
-- bill rows would average per-METER kwh, not the site's true monthly total.
site_usage AS (
  SELECT AVG(monthly.total_kwh) AS avg_monthly_kwh_12mo
  FROM (
    SELECT cb.bill_period_end, SUM(cb.total_kwh) AS total_kwh
    FROM {{catalog}}.{{schema}}.fact_customer_billing cb
    JOIN acct ON acct.account_id = cb.account_id
    CROSS JOIN {{catalog}}.{{schema}}.curated_demo_config cfg
    WHERE cb.bill_period_end BETWEEN ADD_MONTHS(cfg.as_of_date, -cfg.billing_lookback_months) AND cfg.as_of_date
    GROUP BY cb.bill_period_end
  ) monthly
),
-- Peer p75 for THIS site's building type & size band, from the same premise-
-- grained monthly benchmark that draws the chart's peer line — averaged over
-- the window so the header number and the chart line can never disagree.
site_peer AS (
  SELECT AVG(pb.peer_p75_kwh) AS peer_p75_avg_monthly_kwh
  FROM {{catalog}}.{{schema}}.peer_monthly_usage_benchmark pb
  WHERE pb.peer_building_subtype = (SELECT p.building_subtype
                                    FROM acct JOIN {{catalog}}.{{schema}}.dim_premise p
                                      ON p.premise_id = acct.premise_id)
    AND pb.peer_sqft_band        = (SELECT p.sqft_band
                                    FROM acct JOIN {{catalog}}.{{schema}}.dim_premise p
                                      ON p.premise_id = acct.premise_id)
)
SELECT
  a.account_number,
  -- The STRING natural key (not the raw BIGINT premise_id) — this is the
  -- Location pivot chip's target; see premise_header.sql's note on why the
  -- client never carries a hashed BIGINT id.
  p.premise_number,
  c.customer_number,
  c.customer_class,
  c.language_preference,
  c.critical_care_flag,
  c.liheap_eligible,
  c.payment_stressed_flag,
  c.payment_late_flag,
  -- Site-grained: is THIS site above its own peer-group p75? (dim_customer's
  -- customer-grain high_user_flag still powers the exec map & Genie.)
  (su.avg_monthly_kwh_12mo > spb.peer_p75_avg_monthly_kwh)          AS high_user_flag,
  c.engagement_tier,
  c.digital_adoption_score,
  c.churn_risk_band,
  c.recent_outage_minutes_90d,
  c.recent_outage_events_90d,
  c.recent_complaint_count_90d,
  ROUND(su.avg_monthly_kwh_12mo, 0)                                 AS avg_monthly_kwh_12mo,
  ROUND(spb.peer_p75_avg_monthly_kwh, 0)                            AS peer_p75_avg_monthly_kwh,
  -- Peer group is THIS site's building type & size band (from its premise),
  -- not the customer's anchor premise.
  p.building_subtype                                                AS peer_building_subtype,
  p.sqft_band                                                       AS peer_sqft_band,
  c.customer_since_date,
  cl.tenant_since,
  po.previous_occupant_until,
  COALESCE(po.previous_occupant_count, 0)                            AS previous_occupant_count,
  a.rate_display_name,
  a.autopay_enrolled,
  a.paperless_enrolled,
  a.preferred_channel,
  a.account_tenure_band,
  a.current_status                                                   AS account_status,
  -- Predicted 30-day complaint risk (ml_complaint_predictor, scored on the
  -- customer's latest billing cycle). NULL when unscored.
  ROUND(100 * s.p_complaint_30d, 1)                                  AS complaint_risk_pct,
  s.risk_tier                                                        AS complaint_risk_tier,
  s.top_category                                                     AS complaint_risk_category,
  array_join(s.top_drivers, ' · ')                                   AS complaint_risk_drivers,
  s.recommended_action                                               AS complaint_risk_action,
  -- EV detection (ml_ev_detector, customer_id grain — EV moves with the
  -- person, unlike PV, which is physically a premise attribute and now
  -- lives on the Premise inspector's own header, premise_header.sql).
  -- has_ev_label is the ground truth (raw_der_customer.has_ev) denormalized
  -- onto the predictions row for eval — reused here as "on record" so the
  -- likely_flag-vs-on_record gap IS the unregistered-install signal.
  ROUND(100 * ev.ev_probability, 1)                                  AS ev_probability_pct,
  CAST(ev.ev_likely_flag AS BOOLEAN)                                 AS ev_likely_flag,
  CAST(ev.has_ev_label AS BOOLEAN)                                   AS ev_on_record,
  sp.service_address,
  sp.service_city,
  sp.service_state,
  sp.service_zip,
  p.county,
  p.building_subtype,
  p.sqft,
  p.year_built,
  p.heating_fuel,
  p.envelope_quality
FROM acct
JOIN {{catalog}}.{{schema}}.dim_account a        ON a.account_id = acct.account_id
JOIN {{catalog}}.{{schema}}.dim_customer c       ON c.customer_id = acct.customer_id
JOIN {{catalog}}.{{schema}}.dim_premise p        ON p.premise_id = acct.premise_id
JOIN primary_sp sp ON sp.premise_id = acct.premise_id
LEFT JOIN cur_link cl  ON cl.account_id = acct.account_id
LEFT JOIN prior_occ po ON po.premise_id = acct.premise_id
LEFT JOIN site_usage su ON true
LEFT JOIN site_peer  spb ON true
LEFT JOIN {{catalog}}.{{schema}}.ml_complaint_risk_scores s ON s.customer_id = acct.customer_id
LEFT JOIN {{catalog}}.{{schema}}.ml_ev_detection_predictions ev ON ev.customer_id = acct.customer_id
