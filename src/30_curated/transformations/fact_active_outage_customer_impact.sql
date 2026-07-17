-- Active Outage Customer Impact fact — (active outage × currently-out customer)
-- fan-out. customer_id / service_point_id / premise_id are durable BIGINT keys
-- (matching dim_customer / dim_premise_h3), so the app can join
-- geography (dim_premise_h3) for map dots + H3 cells and identity (dim_account)
-- for deep links. This is the table the "who is out of power right now" layer
-- and the CSR "currently without power" banner read.

CREATE OR REFRESH MATERIALIZED VIEW fact_active_outage_customer_impact (
  impact_id                 STRING NOT NULL,
  active_outage_id          STRING,
  customer_id               BIGINT,
  service_point_id          BIGINT,
  premise_id                BIGINT,
  circuit_id                INT,
  snapshot_at               TIMESTAMP,
  out_since                 TIMESTAMP,
  estimated_restoration_at  TIMESTAMP,
  minutes_out_so_far        INT,
  priority_restoration_flag BOOLEAN,
  still_out                 BOOLEAN,
  _ingested_at              TIMESTAMP,
  CONSTRAINT fk_faoci_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_faoci_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_faoci_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY
)
COMMENT 'Active Outage Customer Impact fact — (active outage x customer) fan-out of the customers currently without power. Durable BIGINT keys; active_outage_id joins fact_active_outage_event.'
AS

SELECT
  i.impact_id,
  i.active_outage_id,
  abs(xxhash64(i.customer_id))                                       AS customer_id,
  abs(xxhash64(i.usage_point_id))                                    AS service_point_id,
  abs(xxhash64(i.premise_id))                                        AS premise_id,
  i.circuit_id,
  i.snapshot_at,
  i.out_since,
  i.estimated_restoration_at,
  i.minutes_out_so_far,
  i.priority_restoration_flag,
  i.still_out,
  current_timestamp()                                                AS _ingested_at
FROM ${outages_schema}.raw_active_outage_customer_impact i;
