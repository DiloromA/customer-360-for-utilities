-- Customer dimension — the PERSON/ORG (CIM Customer), profile-only. The most
-- important table in the curated layer. ~58K rows (incl. prior customers
-- from closed tenancies, who carry profile but no fact activity in the 2017-2018 window).
--
-- The customer is decoupled from premise/account. This dim does not carry
-- account_id or premise_id — join through dim_account (customer_id FK)
-- and dim_service_agreement to reach the physical spine. The peer-group
-- benchmark signals resolve each customer's ANCHOR premise (their min premise
-- account) internally; they are not exposed as a baked FK.
--
-- KEYS: customer_id is the durable BIGINT key (xxhash64 of the raw customer
-- string); customer_number is the natural key. The Type-2 history of profile
-- changes (e.g. critical-care registration) lives in dim_customer_history
-- (AUTO CDC SCD2); this MV is the CURRENT-state snapshot.
--
-- CRITICAL DESIGN RULE: the raw customer.archetype column is INTERNAL and MUST
-- NOT appear here. Demo personas see only disclosed signals computed from
-- observable behaviour (payment_stressed_flag, high_user_flag, engagement_tier,
-- digital_adoption_score, churn_risk_band, recent outage/complaint exposure).

CREATE OR REFRESH MATERIALIZED VIEW dim_customer (
  customer_id                BIGINT  NOT NULL PRIMARY KEY RELY,
  customer_number            STRING  NOT NULL,
  customer_type              STRING,
  customer_name              STRING,   -- NULL for individuals; fictional org label for commercial_parent
  n_premises_owned           BIGINT,
  n_premises_portfolio       BIGINT,   -- for commercial_parent: total premises across all subsidiaries; else same as n_premises_owned
  is_prior_customer          BOOLEAN,
  customer_class             STRING,
  income_band                STRING,
  household_size             INT,
  age_band_hoh               STRING,
  language_preference        STRING,
  tenure                     STRING,
  critical_care_flag         BOOLEAN,
  liheap_eligible            BOOLEAN,
  customer_since_date        DATE,
  payment_stressed_flag      BOOLEAN,
  payment_late_flag          BOOLEAN,
  high_user_flag             BOOLEAN,
  usage_band                 STRING,
  engagement_tier            STRING,
  digital_adoption_score     INT,
  churn_risk_band            STRING,
  recent_outage_minutes_90d  BIGINT,
  recent_outage_events_90d   BIGINT,
  recent_complaint_count_90d BIGINT,
  avg_monthly_kwh_12mo       DOUBLE,
  peer_p75_avg_monthly_kwh   DOUBLE,
  peer_building_subtype      STRING,
  peer_sqft_band             STRING,
  _ingested_at               TIMESTAMP
)
COMMENT 'Customer dimension — the person/org party, profile-only and decoupled from premise/account (join via dim_account.customer_id). customer_id is the durable BIGINT key; customer_number is the natural key. customer_name holds a fictional org label for commercial_parent rows (NULL for all others — PII-free policy). n_premises_portfolio is the portfolio-wide count for parent organisations (total across all subsidiaries); equals n_premises_owned for non-parent types. The latent archetype from raw is INTENTIONALLY NOT exposed; personas see disclosed signals (payment_stressed_flag, high_user_flag, engagement_tier, etc.) computed from observable behaviour. Current-state snapshot; profile-change history is in dim_customer_history (SCD Type 2).'
AS

WITH

raw_customer AS (
  SELECT
    customer_id, customer_type, customer_name, n_premises_owned, is_prior_customer,
    customer_class, income_band, household_size, age_band_hoh,
    language_preference, tenure, critical_care_flag, liheap_eligible,
    customer_since_date
  FROM ${customer_master_schema}.raw_customer
),

-- Portfolio premise count for commercial_parent rows: sum of n_premises_owned
-- across all subsidiary customers linked to this parent via the same chain_key.
-- All other customer types get n_premises_owned unchanged.
parent_portfolio AS (
  SELECT
    p.customer_id                              AS parent_customer_id,
    COALESCE(SUM(s.n_premises_owned), 0)       AS n_premises_portfolio
  FROM ${customer_master_schema}.raw_customer p
  JOIN ${customer_master_schema}.raw_premise_customer_map pcm_p
    ON md5(CONCAT(pcm_p.chain_key, '_parent_customer')) = p.customer_id
   AND pcm_p.is_hero_chain
  JOIN ${customer_master_schema}.raw_customer s
    ON s.customer_id = pcm_p.current_customer_id
   AND s.customer_type = 'commercial_subsidiary'
  WHERE p.customer_type = 'commercial_parent'
  GROUP BY p.customer_id
),

-- Anchor premise per customer (their min premise-bearing account) — supplies
-- the building characteristics for the peer-group benchmark.
cust_premise AS (
  SELECT customer_id, MIN(premise_id) AS premise_id
  FROM ${customer_master_schema}.raw_customer_account
  WHERE premise_id IS NOT NULL
  GROUP BY customer_id
),

-- Payment-stressed signal from trailing 12 months of bills. Late/unpaid
-- counts and max_previous_balance stay at the raw bill-event grain (each
-- meter's own bill is its own late/unpaid event, including for a sub-metered
-- commercial account's concurrent service points, temporal-realism).
billing_signals AS (
  SELECT
    customer_id,
    SUM(CASE WHEN payment_status IN ('unpaid','paid_partial') THEN 1 ELSE 0 END) AS unpaid_or_partial_count_12mo,
    SUM(CASE WHEN payment_status = 'paid_late' THEN 1 ELSE 0 END)                AS late_count_12mo,
    MAX(previous_balance)                                                         AS max_previous_balance_12mo
  FROM ${billing_schema}.raw_customer_billing
  WHERE bill_period_end BETWEEN DATE'2017-12-31' AND DATE'2018-12-31'
  GROUP BY customer_id
),

-- avg_monthly_kwh_12mo (feeds high_user_flag, which powers the exec map &
-- Genie) needs sibling service points summed to a (customer, month) total
-- FIRST — a sub-metered commercial account bills one row PER service point
-- per month, so AVG over the raw rows would average per-METER kwh instead.
billing_kwh AS (
  SELECT customer_id, AVG(month_total_kwh) AS avg_monthly_kwh_12mo
  FROM (
    SELECT customer_id, bill_period_end, SUM(total_kwh) AS month_total_kwh
    FROM ${billing_schema}.raw_customer_billing
    WHERE bill_period_end BETWEEN DATE'2017-12-31' AND DATE'2018-12-31'
    GROUP BY customer_id, bill_period_end
  )
  GROUP BY customer_id
),

-- Peer-group benchmark for "high_user_flag". Peer = building_subtype x sqft_band.
customer_peer AS (
  SELECT
    bk.customer_id,
    bk.avg_monthly_kwh_12mo,
    CASE
      WHEN p.occupancy_class = 'Residential' THEN
        CASE
          -- Must stay in sync with the same CASE in raw_meter_readings.sql
          -- and dim_premise.sql (see comment there re: FEMA labels vs sqft).
          WHEN UPPER(p.primary_occupancy) LIKE '%MANUFACTURED%'
            OR UPPER(p.primary_occupancy) LIKE '%MOBILE%'                    THEN 'Mobile Home'
          WHEN UPPER(p.primary_occupancy) LIKE '%MULTI%'
            OR UPPER(p.primary_occupancy) LIKE '%APARTMENT%'                 THEN
            CASE WHEN p.sqft < 5000 THEN 'Multi-Family with 2 - 4 Units'
                                    ELSE 'Multi-Family with 5+ Units' END
          WHEN UPPER(p.primary_occupancy) LIKE '%TOWN%'
            OR UPPER(p.primary_occupancy) LIKE '%ROW%'
            OR UPPER(p.primary_occupancy) LIKE '%ATTACHED%'                  THEN 'Single-Family Attached'
          ELSE                                                                    'Single-Family Detached'
        END
      ELSE
        CASE
          WHEN p.sqft < 5000  THEN 'SmallOffice'
          WHEN p.sqft < 25000 THEN 'MediumOffice'
          ELSE                     'LargeOffice'
        END
    END                                                              AS building_subtype,
    CASE
      WHEN p.sqft < 1000  THEN '<1000'
      WHEN p.sqft < 1500  THEN '1000-1499'
      WHEN p.sqft < 2000  THEN '1500-1999'
      WHEN p.sqft < 2500  THEN '2000-2499'
      WHEN p.sqft < 3500  THEN '2500-3499'
      WHEN p.sqft < 5000  THEN '3500-4999'
      WHEN p.sqft < 15000 THEN '5000-14999'
      ELSE                     '15000+'
    END                                                              AS sqft_band
  FROM billing_kwh bk
  JOIN cust_premise cp USING (customer_id)
  JOIN ${customer_master_schema}.raw_premises p ON cp.premise_id = p.premise_id
),

peer_thresholds AS (
  SELECT
    building_subtype, sqft_band,
    percentile(avg_monthly_kwh_12mo, 0.25) AS p25_avg_monthly_kwh,
    percentile(avg_monthly_kwh_12mo, 0.75) AS p75_avg_monthly_kwh
  FROM customer_peer
  GROUP BY building_subtype, sqft_band
),

high_user_flag_cte AS (
  SELECT
    cp.customer_id,
    cp.avg_monthly_kwh_12mo > pt.p75_avg_monthly_kwh AS high_user_flag,
    CASE
      WHEN cp.avg_monthly_kwh_12mo > pt.p75_avg_monthly_kwh THEN 'high'
      WHEN cp.avg_monthly_kwh_12mo < pt.p25_avg_monthly_kwh THEN 'low'
      ELSE                                                       'medium'
    END                                              AS usage_band,
    pt.p75_avg_monthly_kwh AS peer_p75_avg_monthly_kwh,
    cp.building_subtype    AS peer_building_subtype,
    cp.sqft_band           AS peer_sqft_band
  FROM customer_peer cp
  JOIN peer_thresholds pt USING (building_subtype, sqft_band)
),

outage_signals AS (
  SELECT
    customer_id,
    SUM(minutes_out)          AS recent_outage_minutes_90d,
    COUNT(DISTINCT outage_id) AS recent_outage_events_90d
  FROM ${outages_schema}.raw_outage_customer_impact
  WHERE affected_start BETWEEN DATE'2018-10-02' AND DATE'2018-12-31'
  GROUP BY customer_id
),

complaint_signals AS (
  SELECT customer_id, COUNT(*) AS recent_complaint_count_90d
  FROM ${complaints_schema}.raw_customer_complaint_event
  WHERE complaint_date BETWEEN DATE'2018-10-02' AND DATE'2018-12-31'
  GROUP BY customer_id
),

digital_signals AS (
  SELECT
    s.customer_id,
    COUNT(*)                   AS portal_sessions_12mo,
    COUNT(DISTINCT s.platform) AS distinct_platforms_used
  FROM ${digital_schema}.raw_portal_session s
  WHERE s.started_at BETWEEN TIMESTAMP'2017-12-31 00:00:00' AND TIMESTAMP'2018-12-31 23:59:59'
  GROUP BY s.customer_id
),

app_installed AS (
  SELECT DISTINCT customer_id, true AS has_mobile_app
  FROM ${digital_schema}.raw_digital_event
  WHERE event_type = 'mobile_app_installed'
),

-- Energy-efficiency / DSM participation — a component of digital_adoption_score
-- (the EE -> digital link).
dsm_signals AS (
  SELECT DISTINCT customer_id, true AS is_ee_participant
  FROM ${dsm_programs_schema}.raw_dsm_enrollment
  WHERE enrollment_status IN ('enrolled','completed')
),

latest_sap AS (
  SELECT customer_id,
    MAX_BY(churn_risk_score_0_100, snapshot_date) AS sap_churn_risk_score
  FROM ${cx_legacy_schema}.raw_sap_cx_history_snapshot
  GROUP BY customer_id
),

-- Engagement signals need account flags (autopay/paperless). Resolve the
-- customer's primary standard account (1 per customer under the chain guard).
account_info AS (
  SELECT customer_id,
    MAX(autopay_enrolled)   AS autopay_enrolled,
    MAX(paperless_enrolled) AS paperless_enrolled
  FROM ${customer_master_schema}.raw_customer_account
  -- commercial_subsidiary customers hold consolidated_billing accounts; include
  -- that group so their autopay/paperless signals are not NULL.
  WHERE account_group IN ('standard','corporate_parent','consolidated_billing')
  GROUP BY customer_id
)

SELECT
  abs(xxhash64(rc.customer_id))                                            AS customer_id,
  rc.customer_id                                                      AS customer_number,
  rc.customer_type,
  rc.customer_name,
  rc.n_premises_owned,
  -- n_premises_portfolio: for commercial_parent, the sum of all subsidiaries'
  -- premise counts; for all other types, same as n_premises_owned.
  COALESCE(pp.n_premises_portfolio, rc.n_premises_owned)               AS n_premises_portfolio,
  rc.is_prior_customer,
  rc.customer_class,
  rc.income_band,
  rc.household_size,
  rc.age_band_hoh,
  rc.language_preference,
  rc.tenure,
  rc.critical_care_flag,
  rc.liheap_eligible,
  rc.customer_since_date,

  COALESCE(bs.unpaid_or_partial_count_12mo, 0) > 0
    OR COALESCE(bs.max_previous_balance_12mo, 0) > 200                AS payment_stressed_flag,
  COALESCE(bs.late_count_12mo, 0) > 0                                 AS payment_late_flag,
  COALESCE(hu.high_user_flag, false)                                 AS high_user_flag,
  COALESCE(hu.usage_band, 'medium')                                  AS usage_band,

  CASE
    WHEN ai.autopay_enrolled AND ai.paperless_enrolled
         AND COALESCE(ds.portal_sessions_12mo, 0) >= 30               THEN 'high'
    WHEN ai.autopay_enrolled OR ai.paperless_enrolled
         OR COALESCE(ds.portal_sessions_12mo, 0) >= 10                THEN 'medium'
    ELSE                                                                   'low'
  END                                                                AS engagement_tier,

  -- 0-100: autopay 25 + paperless 20 + mobile app 20 + portal frequency up to
  -- 20 + EE/DSM participation 15.
  CAST(
    CASE WHEN ai.autopay_enrolled    THEN 25 ELSE 0 END
    + CASE WHEN ai.paperless_enrolled THEN 20 ELSE 0 END
    + CASE WHEN COALESCE(app.has_mobile_app, false) THEN 20 ELSE 0 END
    + LEAST(20.0, COALESCE(ds.portal_sessions_12mo, 0) / 100.0 * 20.0)
    + CASE WHEN COALESCE(dsm.is_ee_participant, false) THEN 15 ELSE 0 END
    AS INT)                                                          AS digital_adoption_score,

  CASE
    WHEN COALESCE(ls.sap_churn_risk_score, 0) >= 50 THEN 'high'
    WHEN COALESCE(ls.sap_churn_risk_score, 0) >= 25 THEN 'medium'
    ELSE                                                  'low'
  END                                                                AS churn_risk_band,

  CAST(COALESCE(os.recent_outage_minutes_90d, 0) AS BIGINT)          AS recent_outage_minutes_90d,
  CAST(COALESCE(os.recent_outage_events_90d, 0) AS BIGINT)           AS recent_outage_events_90d,
  CAST(COALESCE(cs.recent_complaint_count_90d, 0) AS BIGINT)         AS recent_complaint_count_90d,

  ROUND(bk.avg_monthly_kwh_12mo, 0)                                  AS avg_monthly_kwh_12mo,
  ROUND(hu.peer_p75_avg_monthly_kwh, 0)                              AS peer_p75_avg_monthly_kwh,
  hu.peer_building_subtype,
  hu.peer_sqft_band,

  current_timestamp()                                                AS _ingested_at

FROM raw_customer rc
LEFT JOIN parent_portfolio   pp ON pp.parent_customer_id = rc.customer_id
LEFT JOIN account_info       ai USING (customer_id)
LEFT JOIN billing_signals    bs USING (customer_id)
LEFT JOIN billing_kwh        bk USING (customer_id)
LEFT JOIN high_user_flag_cte hu USING (customer_id)
LEFT JOIN outage_signals     os USING (customer_id)
LEFT JOIN complaint_signals  cs USING (customer_id)
LEFT JOIN digital_signals    ds USING (customer_id)
LEFT JOIN app_installed     app USING (customer_id)
LEFT JOIN dsm_signals       dsm USING (customer_id)
LEFT JOIN latest_sap         ls USING (customer_id);
