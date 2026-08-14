-- Service Point dimension — the point of delivery ONLY. ~50K rows.
-- The meter asset lives in dim_meter and the meter<->service_point
-- relationship over time lives in meter_installation. This dim carries the
-- durable physical service point (CIM UsagePoint) + its service location.
--
-- KEYS: service_point_id is the durable BIGINT key (xxhash64 of the raw
-- service point string); service_point_number is the natural key (service_point_id).
-- premise_id is the BIGINT FK into dim_premise.

CREATE OR REFRESH MATERIALIZED VIEW dim_service_point (
  service_point_id        BIGINT  NOT NULL PRIMARY KEY RELY,
  service_point_number    STRING  NOT NULL,
  premise_id              BIGINT,
  service_location_number STRING,
  commodity               STRING,
  service_point_type      STRING,
  phase_code              STRING,
  nominal_service_voltage INT,
  amperage_service_size   INT,
  is_smart_meter          BOOLEAN,
  service_address         STRING,
  service_city            STRING,
  service_state           STRING,
  service_zip             STRING,
  in_service_date         DATE,
  service_status          STRING,
  _ingested_at            TIMESTAMP,
  CONSTRAINT fk_dsp_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY
)
COMMENT 'Service Point dimension — CIM UsagePoint (point of delivery) plus its service location. One row per metered service point. commodity=electric (this model covers electric service only; gas is out of scope). Meter attributes are split into dim_meter (joined over time via meter_installation). service_point_id is the durable BIGINT key; service_point_number is the natural service_point id.'
AS
SELECT
  abs(xxhash64(up.service_point_id))        AS service_point_id,
  up.service_point_id                  AS service_point_number,
  abs(xxhash64(up.premise_id))            AS premise_id,
  up.service_location_id             AS service_location_number,
  'electric'                         AS commodity,
  up.service_point_type,
  up.phase_code,
  up.nominal_service_voltage,
  up.amperage_service_size,
  up.is_smart_meter,
  sl.service_address_line_1          AS service_address,
  sl.service_city,
  sl.service_state,
  sl.service_zip,
  sl.in_service_date,
  sl.service_status,
  current_timestamp()                AS _ingested_at
FROM ${customer_master_schema}.raw_service_point up
LEFT JOIN ${customer_master_schema}.raw_premise_service_attrs sl USING (service_location_id);
