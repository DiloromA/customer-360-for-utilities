-- Meter dimension — the physical meter asset ONLY (CIM EndDeviceAsset).
-- One row per meter asset,
-- including swap-replacement meters (so a historical reading can resolve to
-- the meter that was installed at read time). The
-- meter <-> service_point relationship OVER TIME lives in meter_installation.
--
-- KEYS: meter_id is the durable BIGINT key (xxhash64 of the raw meter string);
-- meter_number is the natural key (the serial-bearing meter id).
-- The meter<->service_point relationship OVER TIME lives in meter_installation
-- (not a placement column on the dim — a meter can be moved).

CREATE OR REFRESH MATERIALIZED VIEW dim_meter (
  meter_id               BIGINT  NOT NULL PRIMARY KEY,
  meter_number           STRING  NOT NULL,
  commodity              STRING,
  meter_seq              INT,
  is_replacement         BOOLEAN,
  serial_number          STRING,
  manufacturer           STRING,
  model_number           STRING,
  install_date           DATE,
  communication_protocol STRING,
  firmware_version       STRING,
  status                 STRING,
  _ingested_at           TIMESTAMP
)
COMMENT 'Meter dimension — physical meter asset (CIM EndDeviceAsset). One row per meter, including swap replacements. meter_id is the durable BIGINT key; meter_number is the natural meter id. commodity=electric (this model covers electric service only; gas is out of scope). The time-bounded meter<->service_point relationship lives in meter_installation (not a placement column here — a meter can be moved). status=replaced marks the original of a swapped pair. CIM: EndDeviceAsset.'
AS
SELECT
  abs(xxhash64(m.meter_number))      AS meter_id,
  m.meter_number,
  'electric'                         AS commodity,
  m.meter_seq,
  m.is_replacement,
  m.serial_number,
  m.manufacturer,
  m.model_number,
  m.install_date,
  m.communication_protocol,
  m.firmware_version,
  m.status,
  current_timestamp()                AS _ingested_at
FROM ${customer_master_schema}.raw_meter m;
