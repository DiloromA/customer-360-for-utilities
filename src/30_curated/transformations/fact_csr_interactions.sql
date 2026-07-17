-- CSR Interactions fact. Genesys session-level interactions joined to
-- complaints (when applicable) for filter convenience. The event timeline
-- (per-state transitions) stays in raw_interaction_event;
-- curated stops at the session level for the persona views.

CREATE OR REFRESH MATERIALIZED VIEW fact_csr_interactions (
  interaction_id             STRING NOT NULL,
  customer_id                BIGINT,
  account_id                 BIGINT,
  complaint_id               STRING,
  media_type                 STRING,
  direction                  STRING,
  started_at                 TIMESTAMP,
  started_date_key           INT,
  queue                      STRING,
  wait_time_seconds          INT,
  talk_time_seconds          INT,
  hold_time_seconds          INT,
  acw_seconds                INT,
  transfer_count             INT,
  handle_time_seconds        INT,
  abandoned_flag             BOOLEAN,
  disposition_code           STRING,
  ivr_path                   STRING,
  agent_id                   STRING,
  csat_score_1_5             INT,
  interaction_source         STRING,
  first_call_resolution_flag BOOLEAN,
  _ingested_at               TIMESTAMP,
  CONSTRAINT fk_fci_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fci_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fci_date FOREIGN KEY (started_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY,
  CONSTRAINT fk_fci_agent FOREIGN KEY (agent_id) REFERENCES dim_agent (agent_id) NOT ENFORCED RELY
)
COMMENT 'CSR Interactions fact. Genesys session-level rows with complaint linkage. Key columns (customer_id, account_id) are durable BIGINT keys; agent_id keeps its natural string code.'
AS

SELECT
  interaction_id,
  abs(xxhash64(customer_id))                                              AS customer_id,
  abs(xxhash64(account_id))                                               AS account_id,
  complaint_id,
  media_type,
  direction,
  started_at,
  CAST(DATE_FORMAT(started_at, 'yyyyMMdd') AS INT)                    AS started_date_key,
  queue,
  wait_time_seconds,
  talk_time_seconds,
  hold_time_seconds,
  acw_seconds,
  transfer_count,
  handle_time_seconds,
  abandoned_flag,
  disposition_code,
  ivr_path,
  agent_id,
  csat_score_1_5,
  source_kind                                                         AS interaction_source,
  -- FCR flag: same logic as SQM (no transfer + resolved disposition).
  CASE
    WHEN transfer_count = 0
     AND disposition_code IN ('resolved_first_call','inquiry_resolved','information_provided',
                              'service_request_created','program_enrolled')
      THEN true
    ELSE false
  END                                                                AS first_call_resolution_flag,
  current_timestamp() AS _ingested_at
FROM ${cx_genesys_schema}.raw_interaction;
