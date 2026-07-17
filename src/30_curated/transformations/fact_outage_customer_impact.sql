-- Outage Customer Impact fact - (outage × customer) fan-out, with date_key.
-- customer_id / service_point_id / premise_id are durable BIGINT keys.
-- premise_id is resolved from the usage point (so geo/county reliability
-- metrics can join dim_premise directly on a source column).

CREATE OR REFRESH MATERIALIZED VIEW fact_outage_customer_impact (
  impact_id                 STRING NOT NULL,
  outage_id                 STRING,
  customer_id               BIGINT,
  service_point_id          BIGINT,
  premise_id                BIGINT,
  circuit_id                INT,
  affected_start             TIMESTAMP,
  affected_end               TIMESTAMP,
  affected_date_key          INT,
  minutes_out                INT,
  priority_restoration_flag  BOOLEAN,
  _ingested_at               TIMESTAMP,
  CONSTRAINT fk_foci_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_foci_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_foci_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY,
  CONSTRAINT fk_foci_date FOREIGN KEY (affected_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Outage Customer Impact fact - (outage x customer) fan-out. customer_id, service_point_id and premise_id are durable BIGINT keys; outage_id joins fact_outage_events.'
AS

SELECT
  o.impact_id,
  o.outage_id,
  abs(xxhash64(o.customer_id))                                           AS customer_id,
  abs(xxhash64(o.usage_point_id))                                        AS service_point_id,
  abs(xxhash64(up.premise_id))                                           AS premise_id,
  o.circuit_id,
  o.affected_start,
  o.affected_end,
  CAST(DATE_FORMAT(o.affected_start, 'yyyyMMdd') AS INT)            AS affected_date_key,
  o.minutes_out,
  o.priority_restoration_flag,
  current_timestamp() AS _ingested_at
FROM ${outages_schema}.raw_outage_customer_impact o
LEFT JOIN ${customer_master_schema}.raw_usage_point up
  ON up.usage_point_id = o.usage_point_id;
