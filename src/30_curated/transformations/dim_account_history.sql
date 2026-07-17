-- Account SCD Type 2 history — the second AUTO CDC ... STORED AS SCD TYPE 2
-- showcase. Built from the synthetic account_changes feed (a plain Delta table
-- written by the synthetic change_feeds notebook task, so it is streamable).
-- Each account has a baseline active version and, when it later
-- suspended/closed, a second version, preserving the status timeline
-- ("account went active -> suspended on 2018-07-12").
--
--  1. dim_account_scd2 — AUTO CDC target STREAMING TABLE. KEYS (account_id)
--     SEQUENCE BY change_ts; Databricks maintains __START_AT / __END_AT.
--  2. dim_account_history — presentation MV adding durable BIGINT account_id,
--     the per-version surrogate account_sk, and effective_from/to/is_current.
--
-- Run mode: triggered + full refresh (the feed is overwritten each regen).

CREATE OR REFRESH STREAMING TABLE dim_account_scd2
COMMENT 'AUTO CDC SCD Type 2 target for account status history (internal mechanism; see dim_account_history for the presentation view with BIGINT keys).';

CREATE FLOW dim_account_scd2_flow AS AUTO CDC INTO dim_account_scd2
FROM STREAM(${customer_master_schema}.raw_account_changes)
KEYS (account_id)
SEQUENCE BY change_ts
COLUMNS * EXCEPT (operation, _ingested_at)
STORED AS SCD TYPE 2;

CREATE OR REFRESH MATERIALIZED VIEW dim_account_history (
  account_sk          BIGINT  NOT NULL PRIMARY KEY,
  account_id          BIGINT  NOT NULL,
  account_number      STRING  NOT NULL,
  customer_id         BIGINT,
  premise_id          BIGINT,
  parent_account_id   BIGINT,
  account_group       STRING,
  customer_class      STRING,
  rate_schedule       STRING,
  autopay_enrolled    BOOLEAN,
  paperless_enrolled  BOOLEAN,
  marketing_consent   BOOLEAN,
  preferred_channel   STRING,
  account_opened_date DATE,
  current_status      STRING,
  effective_from      TIMESTAMP,
  effective_to        TIMESTAMP,
  is_current          BOOLEAN,
  _ingested_at        TIMESTAMP,
  CONSTRAINT fk_dah_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_dah_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_dah_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY
)
COMMENT 'Account SCD Type 2 history (built via AUTO CDC ... STORED AS SCD TYPE 2). One row per account status version with [effective_from, effective_to) validity (effective_to NULL = current). The tracked attribute is current_status (active -> suspended/closed). account_sk is the per-version surrogate; account_id is the durable BIGINT key.'
AS
SELECT
  abs(xxhash64(CONCAT(account_id, '|', CAST(__START_AT AS STRING))))               AS account_sk,
  abs(xxhash64(account_id))                                                        AS account_id,
  account_id                                                                  AS account_number,
  abs(xxhash64(customer_id))                                                       AS customer_id,
  CASE WHEN premise_id IS NOT NULL THEN abs(xxhash64(premise_id)) END              AS premise_id,
  CASE WHEN parent_account_id IS NOT NULL THEN abs(xxhash64(parent_account_id)) END AS parent_account_id,
  account_group,
  customer_class,
  rate_schedule,
  autopay_enrolled,
  paperless_enrolled,
  marketing_consent,
  preferred_channel,
  account_opened_date,
  current_status,
  __START_AT                                                                  AS effective_from,
  __END_AT                                                                    AS effective_to,
  __END_AT IS NULL                                                            AS is_current,
  current_timestamp()                                                         AS _ingested_at
FROM dim_account_scd2;
