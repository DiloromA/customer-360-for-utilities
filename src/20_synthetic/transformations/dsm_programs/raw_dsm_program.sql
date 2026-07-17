-- DSM Program Catalog — the utility's energy-optimization programs.
-- 15 programs reflecting a typical utility EE / DR portfolio (anonymized but
-- structurally accurate). One row per program.

CREATE OR REFRESH MATERIALIZED VIEW raw_dsm_program
COMMENT 'DSM/EE Program Catalog. ~15 of the utility''s energy-optimization programs. PK: program_id.'
AS

SELECT * FROM VALUES
  ('PRG-SMART-TSTAT',    'Smart Thermostat Rebate',        'EE_rebate',     'residential',  75.00,    200, 'Active'),
  ('PRG-BYOT',           'BYOT - Bring Your Own Thermostat','DR_enrollment','residential',  35.00,    150, 'Active'),
  ('PRG-LED-DISCOUNT',   'LED Bulb Discount',              'EE_rebate',     'residential',  5.00,      90, 'Active'),
  ('PRG-INSULATION',     'Insulation Rebate',              'EE_rebate',     'residential',  350.00,  3500, 'Active'),
  ('PRG-APPL-WASHER',    'ENERGY STAR Washer Rebate',      'EE_rebate',     'residential',  50.00,    150, 'Active'),
  ('PRG-APPL-FRIDGE',    'ENERGY STAR Fridge Rebate',      'EE_rebate',     'residential',  75.00,    250, 'Active'),
  ('PRG-HEA-AUDIT',      'Home Energy Assessment',         'audit',         'residential',  0.00,    1200, 'Active'),
  ('PRG-HP-REBATE',      'Heat Pump Installation Rebate',  'EE_rebate',     'residential',  1500.00, 4500, 'Active'),
  ('PRG-HPWH',           'Heat Pump Water Heater Rebate',  'EE_rebate',     'residential',  600.00,  1800, 'Active'),
  ('PRG-EV-CHARGER',     'EV Charger Installation Rebate', 'EE_rebate',     'residential',  500.00,  2200, 'Active'),
  ('PRG-SOLAR-INCENTIVE','Solar PV Incentive (legacy)',    'DER_incentive', 'residential',  0.00,    7500, 'Closed'),
  ('PRG-TOU-EV',         'EV Time-of-Use Rate Enrollment', 'rate_program',  'residential',  0.00,    1100, 'Active'),
  ('PRG-WX-LMI',         'Low-Income Weatherization',      'EE_grant',      'residential',  0.00,    3200, 'Active'),
  ('PRG-COMM-AUDIT',     'Commercial EE Audit',            'audit',         'commercial',   0.00,   12000, 'Active'),
  ('PRG-COMM-DR',        'Commercial Demand Response',     'DR_enrollment', 'commercial',   0.00,    8500, 'Active')
AS t(
  program_id,
  program_name,
  program_type,
  customer_segment,
  rebate_amount_usd,
  avg_annual_kwh_saved,
  program_status
);
