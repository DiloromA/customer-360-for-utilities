-- SAP CX History Snapshot — legacy SAP CRM extract.
-- The utility ran SAP CRM as its master customer-experience platform
-- until 2017, when Qualtrics + Genesys Cloud replaced it. The on-prem
-- SAP system was dumped to flat files monthly; this table represents
-- the "as-of" customer state at each quarterly extract.
--
-- Type 6 SCD pattern: same customer appears in many rows, one per
-- snapshot, with attribute values reflecting that point in time.
--
-- ~30K customer sample × 12 quarterly snapshots (2014 Q1 - 2016 Q4)
-- = ~360K rows.
--
-- Attributes mirror SAP CRM's customer record (segmentation, satisfaction
-- tier, churn risk score, LTV estimate, marketing flags).

CREATE OR REFRESH MATERIALIZED VIEW raw_sap_cx_history_snapshot (
  CONSTRAINT non_null_snapshot_id  EXPECT (snapshot_id IS NOT NULL),
  CONSTRAINT non_null_customer_id  EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_snapshot_date   EXPECT (snapshot_date BETWEEN DATE'2014-01-01' AND DATE'2016-12-31')
)
COMMENT 'SAP CX history snapshots, quarterly 2014-2016 (legacy era before Qualtrics). Type 6 SCD: same customer in many rows. ~360K rows. Demonstrates the lakehouse pattern of absorbing deprecated-platform data without forcing schema unification. PK: snapshot_id. FK: customer_id -> raw_customer (only includes customers in the demo population).'
AS

WITH

-- Cross-join customers × quarterly snapshot dates.
quarter_dates AS (
  SELECT DATE'2014-03-31' AS snapshot_date UNION ALL SELECT DATE'2014-06-30' UNION ALL
  SELECT DATE'2014-09-30' UNION ALL SELECT DATE'2014-12-31' UNION ALL
  SELECT DATE'2015-03-31' UNION ALL SELECT DATE'2015-06-30' UNION ALL
  SELECT DATE'2015-09-30' UNION ALL SELECT DATE'2015-12-31' UNION ALL
  SELECT DATE'2016-03-31' UNION ALL SELECT DATE'2016-06-30' UNION ALL
  SELECT DATE'2016-09-30' UNION ALL SELECT DATE'2016-12-31'
),

-- ~60% of customers existed in the SAP era. Sample by hash.
-- historical era: prior occupants WERE real customers then; intentionally NOT filtered
customer_sample AS (
  SELECT
    c.customer_id, c.archetype, c.customer_class, c.income_band, c.tenure
  FROM ${customer_master_schema}.raw_customer c
  WHERE abs(xxhash64(c.customer_id, 'sap_active', ${random_seed})) % 100 < 60
),

base AS (
  SELECT
    cs.customer_id,
    cs.archetype,
    cs.customer_class,
    cs.income_band,
    cs.tenure,
    qd.snapshot_date,
    abs(xxhash64(cs.customer_id, qd.snapshot_date, 'seg', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_seg,
    abs(xxhash64(cs.customer_id, qd.snapshot_date, 'sat', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_sat,
    abs(xxhash64(cs.customer_id, qd.snapshot_date, 'ltv', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_ltv,
    abs(xxhash64(cs.customer_id, qd.snapshot_date, 'churn', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_churn,
    abs(xxhash64(cs.customer_id, qd.snapshot_date, 'last_ct', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_last
  FROM customer_sample cs
  CROSS JOIN quarter_dates qd
)

SELECT
  md5(CONCAT(customer_id, '_sap_', CAST(snapshot_date AS STRING)))   AS snapshot_id,
  customer_id,
  snapshot_date,

  -- Marketing segmentation per SAP convention.
  CASE
    WHEN customer_class = 'Commercial' THEN
      CASE WHEN r_seg < 0.35 THEN 'COMM_SMB'
           WHEN r_seg < 0.85 THEN 'COMM_MIDMARKET'
           ELSE                    'COMM_KEY_ACCT' END
    WHEN income_band IN ('100k_200k','over_200k') THEN
      CASE WHEN r_seg < 0.65 THEN 'RES_PREMIUM'
           ELSE                    'RES_GOLD' END
    WHEN income_band IN ('under_25k','25k_50k') THEN
      CASE WHEN r_seg < 0.55 THEN 'RES_VALUE'
           ELSE                    'RES_BUDGET' END
    ELSE 'RES_STANDARD'
  END                                                                AS marketing_segment,

  -- Satisfaction tier (SAP-internal). Reflects archetype +/- drift.
  CASE
    WHEN archetype = 'efficient_engaged'        AND r_sat < 0.80 THEN 'TIER_DELIGHTED'
    WHEN archetype = 'efficient_engaged'                          THEN 'TIER_SATISFIED'
    WHEN archetype = 'tech_forward'             AND r_sat < 0.65 THEN 'TIER_SATISFIED'
    WHEN archetype = 'tech_forward'                               THEN 'TIER_NEUTRAL'
    WHEN archetype = 'senior_fixed_income'      AND r_sat < 0.60 THEN 'TIER_SATISFIED'
    WHEN archetype = 'senior_fixed_income'                        THEN 'TIER_NEUTRAL'
    WHEN archetype = 'comfortable_indifferent'  AND r_sat < 0.40 THEN 'TIER_SATISFIED'
    WHEN archetype = 'comfortable_indifferent'  AND r_sat < 0.80 THEN 'TIER_NEUTRAL'
    WHEN archetype = 'comfortable_indifferent'                    THEN 'TIER_DISSATISFIED'
    WHEN archetype = 'inefficient_unaware'      AND r_sat < 0.25 THEN 'TIER_NEUTRAL'
    WHEN archetype = 'inefficient_unaware'                        THEN 'TIER_DISSATISFIED'
    WHEN archetype = 'cost_stressed'            AND r_sat < 0.15 THEN 'TIER_DISSATISFIED'
    WHEN archetype = 'cost_stressed'                              THEN 'TIER_AT_RISK'
    ELSE                                                               'TIER_NEUTRAL'
  END                                                                AS satisfaction_tier,

  -- Estimated lifetime value (SAP's internal LTV model, $).
  CAST(
    CASE customer_class
      WHEN 'Commercial' THEN 25000 + r_ltv * 175000
      ELSE                   3000  + r_ltv * 12000
    END
    AS INT)                                                          AS lifetime_value_usd,

  -- Churn risk score (SAP's 0-100 internal scoring).
  CAST(
    CASE archetype
      WHEN 'cost_stressed'            THEN 50 + r_churn * 40   -- 50-90
      WHEN 'inefficient_unaware'      THEN 30 + r_churn * 35   -- 30-65
      WHEN 'comfortable_indifferent'  THEN 15 + r_churn * 30   -- 15-45
      WHEN 'senior_fixed_income'      THEN  5 + r_churn * 15   --  5-20
      WHEN 'tech_forward'             THEN 10 + r_churn * 25   -- 10-35
      WHEN 'efficient_engaged'        THEN  5 + r_churn * 15   --  5-20
      ELSE                                  20 + r_churn * 30
    END
    AS INT)                                                          AS churn_risk_score_0_100,

  -- Last contact date (days before snapshot).
  DATE_SUB(snapshot_date, CAST(r_last * 180 AS INT))                 AS last_contact_date,

  -- Marketing consent and channels (SAP boolean fields).
  CASE WHEN abs(xxhash64(customer_id, 'sap_email_opt', ${random_seed})) % 100 < 78
       THEN true ELSE false END                                      AS email_marketing_consent,
  CASE WHEN abs(xxhash64(customer_id, 'sap_phone_opt', ${random_seed})) % 100 < 35
       THEN true ELSE false END                                      AS phone_marketing_consent,
  CASE WHEN abs(xxhash64(customer_id, 'sap_mail_opt',  ${random_seed})) % 100 < 92
       THEN true ELSE false END                                      AS direct_mail_consent,

  'sap_crm_legacy'                                                   AS source_system,
  current_timestamp()                                                AS _ingested_at

FROM base;
