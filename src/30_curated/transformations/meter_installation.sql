-- Meter Installation effective-dated bridge (industry-model
-- metering.meter_installation). Places a meter on a service_point/premise for
-- a date range — the mechanism for meter SWAPS at a stable service point. One
-- current row per single-meter service point; two rows (original removed +
-- replacement current) for the ~7% swap cohort. This is how a meter reading
-- resolves to the meter that was actually installed when the reading was taken.
--
-- KEYS: meter_installation_id BIGINT durable key; meter_id -> dim_meter,
-- service_point_id -> dim_service_point. to_meter_id is the BIGINT key of the
-- swap-in successor (NULL for the current meter).

CREATE OR REFRESH MATERIALIZED VIEW meter_installation (
  meter_installation_id     BIGINT NOT NULL PRIMARY KEY,
  meter_installation_number STRING NOT NULL,
  meter_id                  BIGINT,
  meter_number              STRING,
  service_point_id          BIGINT,
  premise_id                BIGINT,
  installation_date         DATE,
  removal_date              DATE,
  to_meter_id               BIGINT,
  removal_reason_code       STRING,
  is_current                BOOLEAN,
  installation_status       STRING,
  _ingested_at              TIMESTAMP,
  CONSTRAINT fk_mi_meter FOREIGN KEY (meter_id) REFERENCES dim_meter (meter_id) NOT ENFORCED RELY,
  CONSTRAINT fk_mi_to_meter FOREIGN KEY (to_meter_id) REFERENCES dim_meter (meter_id) NOT ENFORCED RELY,
  CONSTRAINT fk_mi_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_mi_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY
)
COMMENT 'Meter Installation effective-dated bridge. Places a meter on a service point for a [installation_date, removal_date) window — captures meter swaps at a stable service point. is_current marks the live install; to_meter_id is the swap-in successor. Resolves a usage-point-keyed reading to the meter installed at read time. meter_installation_id is the durable BIGINT key.'
AS
SELECT
  abs(xxhash64(mi.meter_installation_id))                                        AS meter_installation_id,
  mi.meter_installation_id                                                  AS meter_installation_number,
  abs(xxhash64(mi.meter_number))                                          AS meter_id,
  mi.meter_number                                                    AS meter_number,
  abs(xxhash64(mi.service_point_id))                                               AS service_point_id,
  abs(xxhash64(mi.premise_id))                                                   AS premise_id,
  mi.installation_date,
  mi.removal_date,
  CASE WHEN mi.to_meter_number IS NOT NULL THEN abs(xxhash64(mi.to_meter_number)) END AS to_meter_id,
  mi.removal_reason_code,
  mi.is_current,
  mi.installation_status,
  current_timestamp()                                                       AS _ingested_at
FROM ${customer_master_schema}.raw_meter_installation mi;
