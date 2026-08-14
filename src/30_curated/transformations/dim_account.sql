-- Account dimension — the billing account, a first-class entity separate
-- from the customer. ~58K rows (one per premise account + corporate
-- parents + prior-customer closed accounts). customer -> account is 1:many
-- (commercial chains hold many accounts under a corporate_parent).
--
-- KEYS: account_id is the durable BIGINT key (xxhash64 of the raw account
-- string); account_number is the natural key (the md5 string the app
-- deep-links by, /csr/:account_number). customer_id is the BIGINT FK into
-- dim_customer; parent_account_id is the BIGINT consolidated-billing parent.
--
-- NOTE: current_status here is the CURRENT account status. The Type-2 history
-- of status transitions lives in dim_account_history (AUTO CDC SCD2).
--
-- Premise placement is NOT a column here: an account can move, so a dimension row
-- must not imply an undated permanent placement. The dated history is in
-- bridge_account_premise; account_current_premise is the current-state seam.
--
-- account_tenure_years/_band anchor to curated_demo_config.as_of_date, not a
-- hardcoded date literal.

CREATE OR REFRESH MATERIALIZED VIEW dim_account (
  account_id           BIGINT NOT NULL PRIMARY KEY RELY,
  account_number       STRING NOT NULL,
  customer_id          BIGINT,
  customer_number      STRING,
  parent_account_id    BIGINT,
  account_group        STRING,
  customer_class       STRING,
  rate_schedule        STRING,
  rate_category        STRING,
  rate_display_name    STRING,
  autopay_enrolled     BOOLEAN,
  paperless_enrolled   BOOLEAN,
  marketing_consent    BOOLEAN,
  preferred_channel    STRING,
  account_opened_date  DATE,
  current_status       STRING,
  account_tenure_years INT,
  account_tenure_band  STRING,
  _ingested_at         TIMESTAMP,
  CONSTRAINT fk_da_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY
)
COMMENT 'Account dimension. One row per billing account. account_id is the durable BIGINT key; account_number is the natural key the app searches and deep-links by. customer_id joins dim_customer; parent_account_id is the consolidated-billing parent. account_group: standard | consolidated_billing (a chain site account) | corporate_parent (the chain consolidated bill, no premise assignment). Premise placement is dated and lives in bridge_account_premise; account_current_premise provides the current assignment. current_status is the present status; status-transition history lives in dim_account_history (SCD Type 2).'
AS
SELECT
  abs(xxhash64(a.account_id))                                              AS account_id,
  a.account_id                                                        AS account_number,
  abs(xxhash64(a.customer_id))                                             AS customer_id,
  a.customer_id                                                       AS customer_number,
  CASE WHEN a.parent_account_id IS NOT NULL THEN abs(xxhash64(a.parent_account_id)) END AS parent_account_id,
  a.account_group,
  a.customer_class,
  a.rate_schedule,
  CASE
    WHEN a.rate_schedule LIKE 'res_%' THEN 'Residential'
    WHEN a.rate_schedule LIKE 'com_%' THEN 'Commercial'
    ELSE                                    'Other'
  END                                                                 AS rate_category,
  CASE a.rate_schedule
    WHEN 'res_d1'    THEN 'Standard'
    WHEN 'res_d1_2'  THEN 'Medical Baseline'
    WHEN 'res_d3'    THEN 'Low Income'
    WHEN 'res_d8_ev' THEN 'EV Time-of-Use'
    WHEN 'com_d3'    THEN 'Small Commercial'
    WHEN 'com_d4'    THEN 'Medium Commercial'
    WHEN 'com_d6'    THEN 'Industrial'
    ELSE                  'Other'
  END                                                                 AS rate_display_name,
  a.autopay_enrolled,
  a.paperless_enrolled,
  a.marketing_consent,
  a.preferred_channel,
  a.account_opened_date,
  a.current_status,
  CAST(DATEDIFF(cfg.as_of_date, a.account_opened_date) / 365 AS INT)  AS account_tenure_years,
  CASE
    WHEN DATEDIFF(cfg.as_of_date, a.account_opened_date) < 365       THEN 'new_<1yr'
    WHEN DATEDIFF(cfg.as_of_date, a.account_opened_date) < 365 * 3  THEN '1-3yr'
    WHEN DATEDIFF(cfg.as_of_date, a.account_opened_date) < 365 * 10 THEN '3-10yr'
    ELSE                                                                    '10+yr'
  END                                                                 AS account_tenure_band,
  current_timestamp()                                                 AS _ingested_at
FROM ${customer_master_schema}.raw_customer_account a
CROSS JOIN curated_demo_config cfg;
