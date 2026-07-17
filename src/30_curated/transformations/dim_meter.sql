-- Meter dimension — the physical meter asset ONLY (CIM EndDeviceAsset).
-- One row per meter asset,
-- including swap-replacement meters (so a historical reading can resolve to
-- the meter that was installed at read time). The
-- meter <-> service_point relationship OVER TIME lives in meter_installation.
--
-- KEYS: meter_id is the durable BIGINT key (xxhash64 of the raw meter string);
-- meter_number is the natural key (end_device_asset serial-bearing id).
-- service_point_id is the BIGINT FK into dim_service_point (the usage point
-- this meter is associated with).

CREATE OR REFRESH MATERIALIZED VIEW dim_meter (
  meter_id               BIGINT  NOT NULL PRIMARY KEY,
  meter_number           STRING  NOT NULL,
  service_point_id       BIGINT,
  meter_seq              INT,
  is_replacement         BOOLEAN,
  serial_number          STRING,
  manufacturer           STRING,
  model_number           STRING,
  install_date           DATE,
  communication_protocol STRING,
  firmware_version       STRING,
  status                 STRING,
  _ingested_at           TIMESTAMP,
  CONSTRAINT fk_dm_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY
)
COMMENT 'Meter dimension — physical meter asset (CIM EndDeviceAsset). One row per meter, including swap replacements. meter_id is the durable BIGINT key; meter_number is the natural meter id. The time-bounded meter<->service_point relationship lives in meter_installation; status replaced marks the original of a swapped service point.'
AS
SELECT
  abs(xxhash64(eda.end_device_asset_id))  AS meter_id,
  eda.end_device_asset_id            AS meter_number,
  abs(xxhash64(eda.usage_point_id))       AS service_point_id,
  eda.meter_seq,
  eda.is_replacement,
  eda.serial_number,
  eda.manufacturer,
  eda.model_number,
  eda.install_date,
  eda.communication_protocol,
  eda.firmware_version,
  eda.status,
  current_timestamp()                AS _ingested_at
FROM ${customer_master_schema}.raw_end_device_asset eda;
