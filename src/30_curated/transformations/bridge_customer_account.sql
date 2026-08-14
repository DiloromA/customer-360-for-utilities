-- Effective-dated customer↔account ownership edge.
-- GRAIN: one row per (account_id, valid_from). An account is held by
-- exactly one customer at any point in time.
--
-- For every account, the default state is a single open-ended row covering
-- [account_opened_date, NULL) under the account's current customer. The one
-- exception is the account chosen by the reassignment episode: that account
-- gets a CLOSED row for the original owner plus an OPEN successor row for
-- the incoming owner, producing exactly two rows for that account.
--
-- The is_current=true row's customer_id must agree with dim_account.customer_id.
-- (Verified by contract assertions.)
--
-- KEYS:
--   customer_account_link_id  BIGINT durable surrogate (xxhash64 of
--                             customer_id + account_id + valid_from).
--   customer_id               BIGINT FK into dim_customer.
--   account_id                BIGINT FK into dim_account.

CREATE OR REFRESH MATERIALIZED VIEW bridge_customer_account (
  customer_account_link_id BIGINT NOT NULL PRIMARY KEY RELY,
  customer_id              BIGINT,
  account_id               BIGINT,
  valid_from               DATE   NOT NULL,
  valid_to                 DATE,
  is_current               BOOLEAN NOT NULL,
  _ingested_at             TIMESTAMP,
  CONSTRAINT fk_bca_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_bca_account  FOREIGN KEY (account_id)  REFERENCES dim_account  (account_id)  NOT ENFORCED RELY
)
COMMENT 'Effective-dated customer ownership of an account. One row per validity window per account. valid_from/valid_to form a half-open interval [valid_from, valid_to); valid_to NULL = currently active. is_current=true where valid_to IS NULL. PK: customer_account_link_id. FK: customer_id -> dim_customer.customer_id, account_id -> dim_account.account_id.'
AS

WITH

-- The single reassignment episode (zero or one rows, always one in practice).
reassignment AS (
  SELECT
    da.account_id,
    abs(xxhash64(rar.from_customer_id))   AS from_customer_id,
    abs(xxhash64(rar.to_customer_id))     AS to_customer_id,
    da.account_opened_date,
    rar.transfer_date
  FROM ${customer_master_schema}.raw_account_reassignment rar
  JOIN dim_account da ON da.account_number = rar.account_id
),

-- Reassigned-account IDs (to exclude from the default base rows).
reassigned_account_ids AS (
  SELECT account_id FROM reassignment
),

-- Default: one open-ended row per account, no reassignment.
base_rows AS (
  SELECT
    da.customer_id,
    da.account_id,
    da.account_opened_date AS valid_from,
    CAST(NULL AS DATE)     AS valid_to,
    true                   AS is_current
  FROM dim_account da
  WHERE da.account_id NOT IN (SELECT account_id FROM reassigned_account_ids)
    AND da.account_group <> 'corporate_parent'
),

-- For the reassigned account: closed original row + open successor row.
reassignment_rows AS (
  -- Closed row: the original customer held the account from opened_date until transfer.
  SELECT
    r.from_customer_id                 AS customer_id,
    r.account_id,
    r.account_opened_date              AS valid_from,
    r.transfer_date                    AS valid_to,
    false                              AS is_current
  FROM reassignment r
  UNION ALL
  -- Open row: the new (prior) customer holds the account from transfer_date onwards.
  SELECT
    r.to_customer_id                   AS customer_id,
    r.account_id,
    r.transfer_date                    AS valid_from,
    CAST(NULL AS DATE)                 AS valid_to,
    true                               AS is_current
  FROM reassignment r
),

all_rows AS (
  SELECT customer_id, account_id, valid_from, valid_to, is_current FROM base_rows
  UNION ALL
  SELECT customer_id, account_id, valid_from, valid_to, is_current FROM reassignment_rows
)

SELECT
  abs(xxhash64(CONCAT(
    CAST(customer_id  AS STRING), '_',
    CAST(account_id   AS STRING), '_',
    CAST(valid_from   AS STRING)
  )))                          AS customer_account_link_id,
  customer_id,
  account_id,
  valid_from,
  valid_to,
  is_current,
  current_timestamp()          AS _ingested_at
FROM all_rows;
