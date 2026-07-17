-- Service Event fact — the occurrence log that opens/closes the effective-dated
-- relationships: move-in & move-out (account_premise_link), rate switch
-- (service_agreement seq-2), and meter swap (meter_installation). Small fact,
-- one row per discrete event. Powers the CSR journey timeline alongside bills,
-- outages and complaints, and is the demo's visible proof of the temporal model.
--
-- Grain: one row per (event_type, source relationship row). Keys are populated
-- per event type (a meter swap has no account/customer; a move has no
-- service_agreement/meter), so several FK columns are nullable by design.

CREATE OR REFRESH MATERIALIZED VIEW fact_service_event (
  service_event_id     BIGINT NOT NULL PRIMARY KEY,
  event_type           STRING NOT NULL,
  event_date           DATE,
  account_id           BIGINT,
  customer_id          BIGINT,
  premise_id           BIGINT,
  service_point_id     BIGINT,
  service_agreement_id BIGINT,
  meter_id             BIGINT,
  detail               STRING,
  _ingested_at         TIMESTAMP,
  CONSTRAINT fk_fse_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fse_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fse_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fse_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fse_service_agreement FOREIGN KEY (service_agreement_id) REFERENCES dim_service_agreement (service_agreement_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fse_meter FOREIGN KEY (meter_id) REFERENCES dim_meter (meter_id) NOT ENFORCED RELY
)
COMMENT 'Service Event fact — occurrence log of move-in / move-out / rate switch / meter swap. One row per discrete event, sourced from the effective-dated bridges (account_premise_link, service_agreement, meter_installation). FK columns are populated per event type and nullable by design. Powers the CSR journey timeline.'
AS
-- Move-in: every link start is a move-in occurrence.
WITH move_in AS (
  SELECT
    abs(xxhash64(CONCAT(apl.account_premise_link_id, '|move_in')))  AS service_event_id,
    'move_in'                                                  AS event_type,
    apl.link_start_date                                        AS event_date,
    abs(xxhash64(apl.account_id))                                   AS account_id,
    abs(xxhash64(apl.customer_id))                                  AS customer_id,
    abs(xxhash64(apl.premise_id))                                   AS premise_id,
    CAST(NULL AS BIGINT)                                       AS service_point_id,
    CAST(NULL AS BIGINT)                                       AS service_agreement_id,
    CAST(NULL AS BIGINT)                                       AS meter_id,
    CONCAT('occupancy=', apl.occupancy_type)                   AS detail
  FROM ${customer_master_schema}.raw_account_premise_link apl
),
move_out AS (
  SELECT
    abs(xxhash64(CONCAT(apl.account_premise_link_id, '|move_out'))) AS service_event_id,
    'move_out'                                                 AS event_type,
    apl.link_end_date                                          AS event_date,
    abs(xxhash64(apl.account_id))                                   AS account_id,
    abs(xxhash64(apl.customer_id))                                  AS customer_id,
    abs(xxhash64(apl.premise_id))                                   AS premise_id,
    CAST(NULL AS BIGINT)                                       AS service_point_id,
    CAST(NULL AS BIGINT)                                       AS service_agreement_id,
    CAST(NULL AS BIGINT)                                       AS meter_id,
    CONCAT('reason=', COALESCE(apl.link_termination_reason, 'n/a')) AS detail
  FROM ${customer_master_schema}.raw_account_premise_link apl
  WHERE apl.link_end_date IS NOT NULL
),
-- Rate switch: the new (seq-2) agreement's effective_date is the switch event.
rate_switch AS (
  SELECT
    abs(xxhash64(CONCAT(sa.service_agreement_id, '|rate_switch')))  AS service_event_id,
    'rate_switch'                                              AS event_type,
    sa.effective_date                                          AS event_date,
    abs(xxhash64(sa.account_id))                                    AS account_id,
    abs(xxhash64(sa.customer_id))                                   AS customer_id,
    abs(xxhash64(sa.premise_id))                                    AS premise_id,
    abs(xxhash64(sa.usage_point_id))                                AS service_point_id,
    abs(xxhash64(sa.service_agreement_id))                          AS service_agreement_id,
    CAST(NULL AS BIGINT)                                       AS meter_id,
    CONCAT('to_rate=', sa.rate_schedule)                       AS detail
  FROM ${customer_master_schema}.raw_service_agreement sa
  WHERE sa.agreement_seq = 2
),
-- Meter swap: the removal of a superseded meter is the swap event.
meter_swap AS (
  SELECT
    abs(xxhash64(CONCAT(mi.meter_installation_id, '|meter_swap')))  AS service_event_id,
    'meter_swap'                                               AS event_type,
    mi.removal_date                                            AS event_date,
    CAST(NULL AS BIGINT)                                       AS account_id,
    CAST(NULL AS BIGINT)                                       AS customer_id,
    abs(xxhash64(mi.premise_id))                                    AS premise_id,
    abs(xxhash64(mi.usage_point_id))                                AS service_point_id,
    CAST(NULL AS BIGINT)                                       AS service_agreement_id,
    abs(xxhash64(mi.end_device_asset_id))                           AS meter_id,
    CONCAT('to_meter=', COALESCE(mi.to_end_device_asset_id, 'n/a')) AS detail
  FROM ${customer_master_schema}.raw_meter_installation mi
  WHERE mi.to_end_device_asset_id IS NOT NULL AND mi.removal_date IS NOT NULL
)
SELECT service_event_id, event_type, event_date, account_id, customer_id, premise_id,
       service_point_id, service_agreement_id, meter_id, detail,
       current_timestamp() AS _ingested_at
FROM (
  SELECT * FROM move_in
  UNION ALL SELECT * FROM move_out
  UNION ALL SELECT * FROM rate_switch
  UNION ALL SELECT * FROM meter_swap
);
