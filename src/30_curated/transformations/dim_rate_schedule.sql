-- Rate schedule dimension. Small lookup of the 7 rate codes used in the demo,
-- with pricing and description. Materialized as a static VALUES list (not
-- synthesized from data). rate_schedule_id is the natural code key (kept as the
-- durable key — a tiny, stable catalog; no BIGINT surrogate needed).

CREATE OR REFRESH MATERIALIZED VIEW dim_rate_schedule (
  rate_schedule_id      STRING NOT NULL PRIMARY KEY RELY,
  rate_display_name     STRING,
  rate_category         STRING,
  is_time_of_use        BOOLEAN,
  is_medical_baseline   BOOLEAN,
  service_charge_usd    DOUBLE,
  energy_charge_per_kwh DOUBLE,
  demand_charge_per_kw  DOUBLE,
  description           STRING
)
COMMENT 'Rate Schedule dimension. Static catalog of the rate codes used in the demo with pricing details that match the rate math in raw_customer_billing. rate_schedule_id is the natural-code key (res_d1, res_d8_ev, com_d4, ...).'
AS
SELECT
  rate_schedule_id,
  rate_display_name,
  rate_category,
  is_time_of_use,
  is_medical_baseline,
  CAST(service_charge_usd    AS DOUBLE) AS service_charge_usd,
  CAST(energy_charge_per_kwh AS DOUBLE) AS energy_charge_per_kwh,
  CAST(demand_charge_per_kw  AS DOUBLE) AS demand_charge_per_kw,
  description
FROM VALUES
  ('res_d1',    'Residential Standard', 'Residential', false, false,   7.50, 0.156,  0.0,  'Standard residential flat-rate service.'),
  ('res_d1_2',  'Medical Baseline',     'Residential', false, true,    7.50, 0.142,  0.0,  'Reduced residential rate for medical-equipment-dependent customers (critical care).'),
  ('res_d3',    'Low-Income Reduced',   'Residential', false, false,   5.00, 0.098,  0.0,  'Reduced residential rate for income-qualified customers.'),
  ('res_d8_ev', 'EV Time-of-Use',       'Residential', true,  false,   9.00, 0.225,  0.0,  'Residential time-of-use rate optimized for EV charging. Peak rate $0.225 / off-peak $0.085.'),
  ('com_d3',    'Small Commercial',     'Commercial',  false, false,  12.00, 0.124,  0.0,  'Small commercial flat-rate service.'),
  ('com_d4',    'Medium Commercial',    'Commercial',  false, false,  75.00, 0.092, 12.50, 'Medium commercial rate with demand charge.'),
  ('com_d6',    'Industrial',           'Commercial',  false, false, 350.00, 0.068, 18.00, 'Industrial rate with demand charge.')
AS t(
  rate_schedule_id, rate_display_name, rate_category, is_time_of_use,
  is_medical_baseline, service_charge_usd, energy_charge_per_kwh,
  demand_charge_per_kw, description
);
