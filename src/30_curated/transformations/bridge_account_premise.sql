-- Account <-> Premise effective-dated bridge (industry-model
-- customer.account_premise_link). Which account was billing-responsible for a
-- premise during which window — the mechanism for move-in/move-out and tenant
-- turnover over time. One open link per premise for the current occupant;
-- premises with turnover history also carry closed prior-occupant links that
-- end on the successor's move-in date — a link window that overlaps the fact
-- window is what splits a premise's facts across occupants.
--
-- KEYS: account_premise_link_id BIGINT durable key; account_id -> dim_account.

CREATE OR REFRESH MATERIALIZED VIEW bridge_account_premise (
  account_premise_link_id     BIGINT NOT NULL PRIMARY KEY,
  account_premise_link_number STRING NOT NULL,
  account_id                  BIGINT,
  account_number              STRING,
  premise_id                  BIGINT,
  customer_id                 BIGINT,
  link_start_date             DATE,
  link_end_date               DATE,
  is_current                  BOOLEAN,
  link_status                 STRING,
  billing_responsibility_flag BOOLEAN,
  occupancy_type              STRING,
  link_termination_reason     STRING,
  _ingested_at                TIMESTAMP,
  CONSTRAINT fk_bap_account  FOREIGN KEY (account_id)  REFERENCES dim_account (account_id)   NOT ENFORCED RELY,
  CONSTRAINT fk_bap_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_bap_premise  FOREIGN KEY (premise_id)  REFERENCES dim_premise (premise_id)   NOT ENFORCED RELY
)
COMMENT 'Account<->Premise effective-dated bridge. Captures which account was billing-responsible for a premise during which [link_start_date, link_end_date) window — i.e. move-in/move-out and tenant turnover. is_current marks the live link; closed links carry a prior occupant''s tenancy window. account_premise_link_id is the durable BIGINT key.'
AS
SELECT
  abs(xxhash64(apl.account_premise_link_id)) AS account_premise_link_id,
  apl.account_premise_link_id           AS account_premise_link_number,
  abs(xxhash64(apl.account_id))              AS account_id,
  apl.account_id                        AS account_number,
  abs(xxhash64(apl.premise_id))              AS premise_id,
  abs(xxhash64(apl.customer_id))             AS customer_id,
  apl.link_start_date,
  apl.link_end_date,
  apl.is_current,
  apl.link_status,
  apl.billing_responsibility_flag,
  apl.occupancy_type,
  apl.link_termination_reason,
  current_timestamp()                   AS _ingested_at
FROM ${customer_master_schema}.raw_account_premise_link apl;
