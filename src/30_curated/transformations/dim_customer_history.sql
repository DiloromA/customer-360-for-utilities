-- Customer SCD Type 2 history — the showcase of Databricks AUTO CDC ...
-- STORED AS SCD TYPE 2. Built from the synthetic customer_changes feed (a plain
-- Delta table, written by the synthetic job's change_feeds notebook task so it
-- is streamable — AUTO CDC cannot stream from a materialized view). Each
-- customer has a baseline version and, for the critical-care registration
-- cohort, a second version, so the dimension preserves "what was true then"
-- (critical_care_flag = FALSE before registration, TRUE after).
--
--  1. dim_customer_scd2 — the AUTO CDC target STREAMING TABLE. KEYS (customer_id)
--     SEQUENCE BY change_ts; Databricks maintains __START_AT / __END_AT.
--  2. dim_customer_history — presentation MV adding the durable BIGINT
--     customer_id, the per-version surrogate customer_sk, and clean
--     effective_from / effective_to / is_current columns.
--
-- Run mode: triggered + full refresh. The synthetic feed is overwritten each
-- regen, so a full refresh reprocesses the whole feed and rebuilds identical
-- history.

CREATE OR REFRESH STREAMING TABLE dim_customer_scd2
COMMENT 'AUTO CDC SCD Type 2 target for customer profile history (internal mechanism; see dim_customer_history for the presentation view with BIGINT keys).';

CREATE FLOW dim_customer_scd2_flow AS AUTO CDC INTO dim_customer_scd2
FROM STREAM(${customer_master_schema}.raw_customer_changes)
KEYS (customer_id)
SEQUENCE BY change_ts
COLUMNS * EXCEPT (operation, _ingested_at)
STORED AS SCD TYPE 2;

CREATE OR REFRESH MATERIALIZED VIEW dim_customer_history (
  customer_sk         BIGINT  NOT NULL PRIMARY KEY,
  customer_id         BIGINT  NOT NULL,
  customer_number     STRING  NOT NULL,
  customer_type       STRING,
  n_premises_owned    BIGINT,
  customer_class      STRING,
  income_band         STRING,
  household_size      INT,
  age_band_hoh        STRING,
  language_preference STRING,
  tenure              STRING,
  liheap_eligible     BOOLEAN,
  customer_since_date DATE,
  critical_care_flag  BOOLEAN,
  is_prior_occupant   BOOLEAN,
  effective_from      TIMESTAMP,
  effective_to        TIMESTAMP,
  is_current          BOOLEAN,
  _ingested_at        TIMESTAMP,
  CONSTRAINT fk_dch_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY
)
COMMENT 'Customer SCD Type 2 history (built via AUTO CDC ... STORED AS SCD TYPE 2). One row per customer profile version with [effective_from, effective_to) validity (effective_to NULL = current). The tracked attribute is critical_care_flag (FALSE before a customer registers, TRUE after). customer_sk is the per-version surrogate; customer_id is the durable BIGINT key; customer_number is the natural key.'
AS
SELECT
  abs(xxhash64(CONCAT(customer_id, '|', CAST(__START_AT AS STRING)))) AS customer_sk,
  abs(xxhash64(customer_id))                                          AS customer_id,
  customer_id                                                    AS customer_number,
  customer_type,
  n_premises_owned,
  customer_class,
  income_band,
  household_size,
  age_band_hoh,
  language_preference,
  tenure,
  liheap_eligible,
  customer_since_date,
  critical_care_flag,
  is_prior_occupant,
  __START_AT                                                     AS effective_from,
  __END_AT                                                       AS effective_to,
  __END_AT IS NULL                                               AS is_current,
  current_timestamp()                                            AS _ingested_at
FROM dim_customer_scd2;
