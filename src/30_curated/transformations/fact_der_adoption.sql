-- DER Adoption fact. Pivots the wide raw der_customer table into a
-- normalized (premise, device_type) shape.
-- Only rows where the premise has that DER type appear.
--
-- GRAIN: DER is a PHYSICAL install on the premise (raw_der_customer is keyed to
-- the usage_point / premise, NOT the customer), so a multi-site commercial-chain
-- customer gets independent DER per site. We therefore carry premise_id and the
-- durable customer_id (current occupant) — consumers scoping to a single premise
-- (the CSR right rail) MUST filter on premise_id, not customer_id, or the DER of
-- a customer's other premises leaks in and fans the cards out.

CREATE OR REFRESH MATERIALIZED VIEW fact_der_adoption (
  customer_id           BIGINT,
  premise_id            BIGINT,
  device_type           STRING NOT NULL,
  install_date_alt      DATE,
  install_date          DATE,
  system_size_kwh_or_dc DOUBLE,
  device_subtype        STRING,
  extra_attr            STRING,
  _ingested_at          TIMESTAMP,
  CONSTRAINT fk_fda_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fda_premise  FOREIGN KEY (premise_id)  REFERENCES dim_premise  (premise_id)  NOT ENFORCED RELY
)
COMMENT 'DER Adoption fact - normalized per (premise, device_type). Pivoted from the wide raw der_customer table. DER is a physical install on the premise, so premise_id is the physical grain (a multi-site customer gets independent DER per site); customer_id is the durable current-occupant key. Both are durable BIGINT keys.'
AS

WITH base AS (
  SELECT * FROM ${der_adoption_schema}.raw_der_customer
)

SELECT abs(xxhash64(customer_id)) AS customer_id, abs(xxhash64(premise_id)) AS premise_id, 'EV' AS device_type,
  CAST(NULL AS DATE)             AS install_date_alt,  -- placeholder for unioning
  ev_install_date                AS install_date,
  ev_battery_kwh                 AS system_size_kwh_or_dc,
  ev_vehicle_class               AS device_subtype,
  CAST(ev_is_tou_enrolled AS STRING) AS extra_attr,
  current_timestamp() AS _ingested_at
FROM base WHERE has_ev

UNION ALL

SELECT abs(xxhash64(customer_id)) AS customer_id, abs(xxhash64(premise_id)) AS premise_id, 'PV',
  CAST(NULL AS DATE), pv_install_date, pv_system_kw_dc,
  pv_inverter_type, CAST(pv_net_metered AS STRING), current_timestamp()
FROM base WHERE has_pv

UNION ALL

SELECT abs(xxhash64(customer_id)) AS customer_id, abs(xxhash64(premise_id)) AS premise_id, 'BESS',
  CAST(NULL AS DATE), CAST(NULL AS DATE), bess_capacity_kwh,
  bess_dispatch_mode, CAST(bess_power_kw AS STRING), current_timestamp()
FROM base WHERE has_bess

UNION ALL

SELECT abs(xxhash64(customer_id)) AS customer_id, abs(xxhash64(premise_id)) AS premise_id, 'HEAT_PUMP',
  CAST(NULL AS DATE), hp_install_date, CAST(hp_nominal_heating_btuh / 12000 AS DOUBLE),  -- tons
  hp_type, CAST(hp_cop_at_47f AS STRING), current_timestamp()
FROM base WHERE has_heat_pump

UNION ALL

SELECT abs(xxhash64(customer_id)) AS customer_id, abs(xxhash64(premise_id)) AS premise_id, 'SMART_TSTAT',
  CAST(NULL AS DATE), tstat_install_date, CAST(NULL AS DOUBLE),
  tstat_brand, CAST(tstat_dr_enrolled AS STRING), current_timestamp()
FROM base WHERE has_smart_thermostat;
