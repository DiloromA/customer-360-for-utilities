-- Digital Engagement fact. Combines portal sessions + discrete digital
-- events into a unified events table (UNION ALL with type discriminator).
-- Drives the CSR view "last digital activity" strip.

CREATE OR REFRESH MATERIALIZED VIEW fact_digital_engagement (
  event_id              STRING NOT NULL,
  event_type            STRING,
  customer_id           BIGINT,
  account_id            BIGINT,
  event_timestamp       TIMESTAMP,
  event_date_key        INT,
  platform              STRING,
  duration_seconds      INT,
  entry_page_or_subtype STRING,
  outcome               STRING,
  success_flag          BOOLEAN,
  failure_reason        STRING,
  bill_id               STRING,
  _ingested_at          TIMESTAMP,
  CONSTRAINT fk_fde_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fde_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fde_date FOREIGN KEY (event_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Digital engagement fact - unified portal sessions + digital events. Key columns (customer_id, account_id) are durable BIGINT keys.'
AS

-- Portal sessions as one event_type.
SELECT
  s.session_id                                                        AS event_id,
  'portal_session'                                                    AS event_type,
  abs(xxhash64(s.customer_id))                                             AS customer_id,
  CASE WHEN s.account_id IS NOT NULL THEN abs(xxhash64(s.account_id)) END  AS account_id,
  s.started_at                                                        AS event_timestamp,
  CAST(DATE_FORMAT(s.started_at, 'yyyyMMdd') AS INT)                  AS event_date_key,
  s.platform,
  CAST(s.duration_seconds AS INT)                                     AS duration_seconds,
  s.entry_page                                                        AS entry_page_or_subtype,
  s.session_outcome                                                   AS outcome,
  true                                                                AS success_flag,
  CAST(NULL AS STRING)                                                AS failure_reason,
  CAST(NULL AS STRING)                                                AS bill_id,
  current_timestamp() AS _ingested_at
FROM ${digital_schema}.raw_portal_session s

UNION ALL

-- Discrete digital events.
SELECT
  de.event_id,
  de.event_type,
  abs(xxhash64(de.customer_id))                                            AS customer_id,
  CAST(NULL AS BIGINT)                                                AS account_id,
  de.event_timestamp,
  CAST(DATE_FORMAT(de.event_timestamp, 'yyyyMMdd') AS INT)            AS event_date_key,
  CAST(NULL AS STRING)                                                AS platform,
  CAST(NULL AS INT)                                                   AS duration_seconds,
  de.payment_method                                                   AS entry_page_or_subtype,
  CAST(NULL AS STRING)                                                AS outcome,
  de.success_flag,
  de.failure_reason,
  de.bill_id,
  current_timestamp() AS _ingested_at
FROM ${digital_schema}.raw_digital_event de;
