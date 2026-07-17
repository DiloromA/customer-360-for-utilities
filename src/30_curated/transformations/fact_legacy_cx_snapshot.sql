-- Legacy CX Snapshot fact. Pass-through from SAP HANA history with
-- explicit snapshot_date_key. Type 6 SCD - same customer in many rows.

CREATE OR REFRESH MATERIALIZED VIEW fact_legacy_cx_snapshot (
  snapshot_id             STRING NOT NULL,
  customer_id             BIGINT,
  snapshot_date           DATE,
  snapshot_date_key       INT,
  marketing_segment       STRING,
  satisfaction_tier       STRING,
  lifetime_value_usd      INT,
  churn_risk_score_0_100  INT,
  churn_risk_band         STRING,
  last_contact_date       DATE,
  email_marketing_consent BOOLEAN,
  phone_marketing_consent BOOLEAN,
  direct_mail_consent     BOOLEAN,
  source_system           STRING,
  _ingested_at            TIMESTAMP,
  CONSTRAINT fk_flcs_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_flcs_date FOREIGN KEY (snapshot_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Legacy CX snapshot fact. Quarterly customer-state snapshots from the legacy SAP CRM era, before Qualtrics + Genesys replaced it. Type 6 SCD: same customer in many rows. customer_id is a durable BIGINT key.'
AS

SELECT
  snapshot_id,
  abs(xxhash64(customer_id))                                              AS customer_id,
  snapshot_date,
  CAST(DATE_FORMAT(snapshot_date, 'yyyyMMdd') AS INT)                 AS snapshot_date_key,
  marketing_segment,
  satisfaction_tier,
  lifetime_value_usd,
  churn_risk_score_0_100,
  -- Churn risk band so demo queries don't have to re-bucket.
  CASE
    WHEN churn_risk_score_0_100 >= 50 THEN 'high'
    WHEN churn_risk_score_0_100 >= 25 THEN 'medium'
    ELSE                                   'low'
  END                                                                AS churn_risk_band,
  last_contact_date,
  email_marketing_consent,
  phone_marketing_consent,
  direct_mail_consent,
  source_system,
  current_timestamp() AS _ingested_at
FROM ${cx_legacy_schema}.raw_sap_cx_history_snapshot;
