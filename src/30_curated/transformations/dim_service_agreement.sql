-- Service Agreement dimension — THE CONTRACT (CIM ServiceAgreement /
-- industry-model customer_service_agreement). Effective-dated: one row per
-- (account x service_point x rate x validity window). This is the pivot that
-- binds the commercial overlay (customer -> account) to the physical spine
-- (service_point -> premise) over time, and the carrier of rate-switch
-- history (a switcher has agreement_seq=1 on res_d1 terminated at the switch,
-- and agreement_seq=2 on the new rate, is_current=true).
--
-- It is also the as-of resolution source for facts: a meter reading keyed only
-- by service point resolves its account/customer/rate via the agreement whose
-- [effective_date, termination_date) window contains the reading timestamp.
--
-- KEYS: service_agreement_id BIGINT durable key; service_agreement_number the
-- natural key. account_id -> dim_account, service_point_id -> dim_service_point,
-- rate_schedule -> dim_rate_schedule.

CREATE OR REFRESH MATERIALIZED VIEW dim_service_agreement (
  service_agreement_id     BIGINT NOT NULL PRIMARY KEY RELY,
  service_agreement_number STRING NOT NULL,
  account_id               BIGINT,
  account_number           STRING,
  customer_id              BIGINT,
  premise_id               BIGINT,
  service_point_id         BIGINT,
  rate_schedule            STRING,
  effective_date           DATE,
  termination_date         DATE,
  status                   STRING,
  is_current               BOOLEAN,
  agreement_seq            INT,
  termination_reason       STRING,
  _ingested_at             TIMESTAMP,
  CONSTRAINT fk_dsa_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_dsa_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_dsa_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY,
  CONSTRAINT fk_dsa_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY
)
COMMENT 'Service Agreement dimension — the effective-dated contract binding an account to a service point under a rate schedule (CIM ServiceAgreement). One row per validity window; rate switchers carry a terminated res_d1 agreement (seq 1) plus the current new-rate agreement (seq 2). is_current marks the live agreement. This is the as-of source that resolves a usage-point-keyed fact to its account/customer/rate via the [effective_date, termination_date) window. service_agreement_id is the durable BIGINT key.'
AS
SELECT
  abs(xxhash64(sa.service_agreement_id))  AS service_agreement_id,
  sa.service_agreement_id            AS service_agreement_number,
  abs(xxhash64(sa.account_id))            AS account_id,
  sa.account_id                      AS account_number,
  abs(xxhash64(sa.customer_id))           AS customer_id,
  abs(xxhash64(sa.premise_id))            AS premise_id,
  abs(xxhash64(sa.service_point_id))        AS service_point_id,
  sa.rate_schedule,
  sa.effective_date,
  sa.termination_date,
  sa.status,
  sa.is_current,
  sa.agreement_seq,
  sa.termination_reason,
  current_timestamp()                AS _ingested_at
FROM ${customer_master_schema}.raw_service_agreement sa;
