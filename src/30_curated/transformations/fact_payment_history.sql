-- Payment history fact. Pass-through from raw with date_key + lateness
-- bucketing for filter ergonomics.

CREATE OR REFRESH MATERIALIZED VIEW fact_payment_history (
  payment_id      STRING NOT NULL,
  bill_id         STRING,
  account_id      BIGINT,
  customer_id     BIGINT,
  payment_status  STRING,
  amount_paid     DOUBLE,
  days_late       INT,
  payment_date    DATE,
  payment_date_key INT,
  payment_method  STRING,
  lateness_bucket STRING,
  _ingested_at    TIMESTAMP,
  CONSTRAINT fk_fph_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fph_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fph_date FOREIGN KEY (payment_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Payment History fact. CIM PaymentTransaction. Grain: one row per payment (payment_id). bill_id is the natural-key string; account_id / customer_id are durable BIGINT keys joining dim_account / dim_customer.'
AS

SELECT
  payment_id,
  bill_id,
  abs(xxhash64(account_id))  AS account_id,
  abs(xxhash64(customer_id)) AS customer_id,
  payment_status,
  amount_paid,
  days_late,
  payment_date,
  CAST(DATE_FORMAT(payment_date, 'yyyyMMdd') AS INT)                  AS payment_date_key,
  payment_method,

  -- Bucketed lateness for filter ergonomics.
  CASE
    WHEN days_late IS NULL          THEN 'unpaid'
    WHEN days_late <= 0             THEN 'on_time_or_early'
    WHEN days_late <= 7             THEN 'late_1_7'
    WHEN days_late <= 30            THEN 'late_8_30'
    ELSE                                  'late_31_plus'
  END                                                                AS lateness_bucket,

  current_timestamp() AS _ingested_at
FROM ${billing_schema}.raw_payment_history;
