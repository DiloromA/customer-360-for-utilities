-- DER adoption — one row per premise / usage_point (the PHYSICAL spine) with
-- EV, PV, BESS, heat pump, and smart-thermostat ownership flags + device-
-- specific attributes. DER is a physical install on the premise, so it is keyed
-- to the usage_point, NOT the customer: a multi-site commercial chain
-- customer gets independent DER per site. The current occupant (via
-- premise_customer_map) supplies the archetype that biases adoption.
--
-- Adoption rates are archetype-biased:
--   tech_forward             very high (EV+PV+BESS heavy)
--   efficient_engaged        moderate (HP + smart-tstat focus)
--   comfortable_indifferent  baseline (mostly smart-tstat only)
--   cost_stressed            very low (capital-constrained)
--   inefficient_unaware      low
--   senior_fixed_income      none (HP/EV) / minimal (PV/smart-tstat)
--
-- Eligibility gates that prevent unrealistic combinations:
--   PV    : tenure=own + sqft >= 800  (renters can't host rooftop;
--                                       tiny units have insufficient roof)
--   BESS  : requires PV               (storage adopters layer onto solar)
--   EV L2 : amperage >= 200A          (100A panels get PHEV-only)
--   HP    : NOT senior_fixed_income   (low retrofit propensity at fixed income)
--   commercial: only PV + smart-tstat (no EV/BESS/HP modeled)
--
-- Tract-level draws yield neighborhood-effect clustering: one tract's
-- random tilts EV/PV/BESS adoption a bit higher or lower for everyone in it.
--
-- DER draws are seeded by premise_id (physical install, stable across
-- occupant turnover), so a sub-metered premise's 2-5 usage_points
-- (temporal-realism §5.3) would otherwise all see IDENTICAL draws and clone
-- the same "install" N times. DER is physically one system per building, so
-- adopt_flags below gates every has_* flag to is_der_host = true — the
-- usage_point with the smallest id at that premise. Siblings still get a row
-- (PK is usage_point_id) but with every has_* flag false, same idiom
-- raw_dsm_enrollment.sql already uses to collapse multi-row DER back to one
-- customer/building.

CREATE OR REFRESH MATERIALIZED VIEW raw_der_customer (
  CONSTRAINT non_null_premise_id     EXPECT (premise_id IS NOT NULL),
  CONSTRAINT non_null_usage_point_id EXPECT (usage_point_id IS NOT NULL),
  CONSTRAINT bess_requires_pv        EXPECT (NOT has_bess OR has_pv),
  CONSTRAINT pv_requires_residential EXPECT (NOT has_pv OR customer_class = 'Residential' OR customer_class = 'Commercial')
)
COMMENT 'DER adoption — one row per premise / usage_point with EV / PV / BESS / heat pump / smart thermostat ownership flags + device-specific attributes. DER is a PHYSICAL install on the premise, so it is keyed to the physical spine (usage_point), not the customer — a multi-site commercial chain customer gets independent DER per site. customer_id is the current occupant (denormalized; biases adoption via archetype). Wide schema for AMI-synthesis convenience. Adoption is archetype-biased with realistic eligibility gates (PV requires own + sqft>=800; BESS requires PV; EV L2 requires >=200A panel) plus tract-level neighborhood-effect clustering. PK: usage_point_id. FK: usage_point_id -> raw_usage_point; premise_id -> raw_premises; customer_id -> raw_customer.'
AS

WITH base AS (
  SELECT
    p.premise_id,
    up.usage_point_id,
    m.current_customer_id                                            AS customer_id,
    c.customer_class,
    c.archetype,
    c.income_band,
    c.tenure,
    p.sqft,
    p.year_built,
    p.heating_fuel,
    p.census_tract,
    up.amperage_service_size,

    -- Independent uniform draws per DER type, seeded by the PHYSICAL premise
    -- (DER installs are physical; seeding by premise_id keeps them stable across
    -- occupant turnover and unique per site for multi-site commercial chains).
    abs(xxhash64(p.premise_id, 'ev_adopt',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_ev,
    abs(xxhash64(p.premise_id, 'pv_adopt',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_pv,
    abs(xxhash64(p.premise_id, 'bess_adopt',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_bess,
    abs(xxhash64(p.premise_id, 'hp_adopt',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_hp,
    abs(xxhash64(p.premise_id, 'tstat_adopt',  ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_tstat,

    -- Tract-level draws for neighborhood-effect tilt (-0.4 to +0.4 multiplier
    -- on adoption rates). Seeded by census_tract so all premises in a tract
    -- SHARE the tilt -> early-adopter clustering (visible on the map).
    (abs(xxhash64(p.census_tract, 'tract_ev_tilt',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) - 0.5) * 0.8 AS tract_ev_tilt,
    (abs(xxhash64(p.census_tract, 'tract_pv_tilt',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) - 0.5) * 0.8 AS tract_pv_tilt,
    (abs(xxhash64(p.census_tract, 'tract_hp_tilt',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) - 0.5) * 0.8 AS tract_hp_tilt,

    -- Attribute draws (used only when the device is adopted), seeded by premise.
    abs(xxhash64(p.premise_id, 'ev_class',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_ev_class,
    abs(xxhash64(p.premise_id, 'ev_pattern',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_ev_pattern,
    abs(xxhash64(p.premise_id, 'ev_install',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_ev_install,
    abs(xxhash64(p.premise_id, 'pv_size',      ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_pv_size,
    abs(xxhash64(p.premise_id, 'pv_tilt',      ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_pv_tilt,
    abs(xxhash64(p.premise_id, 'pv_azimuth',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_pv_azimuth,
    abs(xxhash64(p.premise_id, 'pv_install',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_pv_install,
    abs(xxhash64(p.premise_id, 'bess_size',    ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_bess_size,
    abs(xxhash64(p.premise_id, 'bess_dispatch',${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_bess_dispatch,
    abs(xxhash64(p.premise_id, 'hp_type',      ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_hp_type,
    abs(xxhash64(p.premise_id, 'hp_install',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_hp_install,
    abs(xxhash64(p.premise_id, 'tstat_brand',  ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_tstat_brand,
    abs(xxhash64(p.premise_id, 'tstat_dr',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_tstat_dr,
    abs(xxhash64(p.premise_id, 'tstat_install',${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_tstat_install,

    -- One usage_point per premise is the DER host; siblings (sub-metered
    -- commercial only) get has_* = false below.
    (ROW_NUMBER() OVER (PARTITION BY p.premise_id ORDER BY up.usage_point_id) = 1) AS is_der_host
  FROM ${customer_master_schema}.raw_premises p
  JOIN ${customer_master_schema}.raw_service_location sl ON sl.premise_id = p.premise_id
  JOIN ${customer_master_schema}.raw_usage_point up ON up.service_location_id = sl.service_location_id
  JOIN ${customer_master_schema}.raw_premise_customer_map m ON m.premise_id = p.premise_id
  JOIN ${customer_master_schema}.raw_customer c ON c.customer_id = m.current_customer_id
),

-- Compute baseline adoption thresholds per archetype, then tilt by tract.
adopt_thresholds AS (
  SELECT
    *,
    -- EV adoption base rates by archetype.
    CASE
      WHEN customer_class = 'Commercial' THEN 0.0
      WHEN archetype = 'tech_forward'            THEN 0.35
      WHEN archetype = 'efficient_engaged'       THEN 0.05
      WHEN archetype = 'comfortable_indifferent' THEN 0.005
      WHEN archetype = 'inefficient_unaware'     THEN 0.003
      WHEN archetype = 'cost_stressed'           THEN 0.001
      WHEN archetype = 'senior_fixed_income'     THEN 0.0
      ELSE 0.0
    END                                                              AS ev_base_rate,
    -- PV
    CASE
      WHEN customer_class = 'Commercial'         THEN 0.05
      WHEN archetype = 'tech_forward'            THEN 0.40
      WHEN archetype = 'efficient_engaged'       THEN 0.08
      WHEN archetype = 'comfortable_indifferent' THEN 0.003
      WHEN archetype = 'inefficient_unaware'     THEN 0.002
      WHEN archetype = 'cost_stressed'           THEN 0.001
      WHEN archetype = 'senior_fixed_income'     THEN 0.005
      ELSE 0.0
    END                                                              AS pv_base_rate,
    -- BESS — multiplicative on PV (only PV adopters consider BESS).
    CASE
      WHEN archetype = 'tech_forward'            THEN 0.25  -- 25% of PV adopters add BESS
      WHEN archetype = 'efficient_engaged'       THEN 0.18
      ELSE 0.0
    END                                                              AS bess_rate_given_pv,
    -- Heat pump
    CASE
      WHEN customer_class = 'Commercial'         THEN 0.0
      WHEN archetype = 'senior_fixed_income'     THEN 0.0
      WHEN archetype = 'tech_forward'            THEN 0.25
      WHEN archetype = 'efficient_engaged'       THEN 0.20
      WHEN archetype = 'comfortable_indifferent' THEN 0.05
      WHEN archetype = 'inefficient_unaware'     THEN 0.03
      WHEN archetype = 'cost_stressed'           THEN 0.02
      ELSE 0.0
    END                                                              AS hp_base_rate,
    -- Smart thermostat (the broadest by far)
    CASE
      WHEN customer_class = 'Commercial'         THEN 0.30
      WHEN archetype = 'tech_forward'            THEN 0.88
      WHEN archetype = 'efficient_engaged'       THEN 0.65
      WHEN archetype = 'comfortable_indifferent' THEN 0.30
      WHEN archetype = 'inefficient_unaware'     THEN 0.12
      WHEN archetype = 'cost_stressed'           THEN 0.08
      WHEN archetype = 'senior_fixed_income'     THEN 0.05
      ELSE 0.0
    END                                                              AS tstat_base_rate
  FROM base
),

adopt_flags AS (
  SELECT
    *,
    -- Apply tract tilt and eligibility gates.

    -- EV: requires panel >= 200A for full L2; 150A allows PHEV; 100A rules out.
    -- AND is_der_host: physical installs attach to one meter per building
    -- (sub-metered siblings never independently adopt).
    is_der_host
      AND r_ev < (ev_base_rate * (1 + tract_ev_tilt))
      AND amperage_service_size >= 150
      AND customer_class = 'Residential'                                   AS has_ev,

    -- PV: requires own + sqft >= 800 for residential. Commercial baseline allowed.
    is_der_host
      AND r_pv < (pv_base_rate * (1 + tract_pv_tilt))
      AND (customer_class = 'Commercial' OR (tenure = 'own' AND sqft >= 800)) AS has_pv,

    -- HP: archetype gate plus customer_class=Residential
    is_der_host
      AND r_hp < (hp_base_rate * (1 + tract_hp_tilt))
      AND customer_class = 'Residential'                                   AS has_heat_pump,

    -- Smart thermostat: no eligibility constraints beyond archetype/class
    is_der_host AND r_tstat < tstat_base_rate                              AS has_smart_thermostat
  FROM adopt_thresholds
)

SELECT
  premise_id,
  usage_point_id,
  customer_id,
  customer_class,

  -- =============================
  -- EV
  -- =============================
  has_ev,
  CASE WHEN has_ev THEN
    -- Vehicle class: BEV (70%) vs PHEV (30%)
    CASE WHEN r_ev_class < 0.70 THEN 'BEV' ELSE 'PHEV' END
  END                                                                AS ev_vehicle_class,

  CASE WHEN has_ev THEN
    -- Battery capacity kWh
    CASE
      WHEN r_ev_class < 0.70 THEN
        -- BEV: 60-85 kWh typical 2018-era (Model 3, Bolt, Leaf SV)
        CAST(60 + r_ev_class / 0.70 * 25 AS INT)
      ELSE
        -- PHEV: 8-18 kWh (Volt, Prius Prime, Energi)
        CAST(8 + (r_ev_class - 0.70) / 0.30 * 10 AS INT)
    END
  END                                                                AS ev_battery_kwh,

  CASE WHEN has_ev THEN
    -- Charging pattern (drives the 8760-hr template in AMI synthesis)
    CASE
      WHEN r_ev_pattern < 0.75 THEN 'overnight_home_l2'
      WHEN r_ev_pattern < 0.90 THEN 'daytime_workplace'
      ELSE                          'mixed_dcfc'
    END
  END                                                                AS ev_charging_pattern,

  CASE WHEN has_ev THEN
    -- ToU enrollment among EV households: tech_forward heavily enrolled
    CASE
      WHEN archetype = 'tech_forward'      THEN r_ev_pattern < 0.85
      WHEN archetype = 'efficient_engaged' THEN r_ev_pattern < 0.60
      ELSE                                      r_ev_pattern < 0.30
    END
  END                                                                AS ev_is_tou_enrolled,

  CASE WHEN has_ev THEN
    -- Install date: roughly uniform 2015 to today, biased newer
    DATE_ADD(MAKE_DATE(2015, 1, 1), CAST(r_ev_install * 365 * 11 AS INT))
  END                                                                AS ev_install_date,

  -- =============================
  -- PV (rooftop solar)
  -- =============================
  has_pv,
  CASE WHEN has_pv THEN
    -- System size kW DC. Residential 4-12 kW; commercial 25-200 kW.
    CASE
      WHEN customer_class = 'Commercial' THEN ROUND(25.0 + r_pv_size * 175, 1)
      ELSE                                    ROUND(4.0  + r_pv_size *  8, 1)
    END
  END                                                                AS pv_system_kw_dc,

  CASE WHEN has_pv THEN
    -- Tilt: typically 15-40 degrees for fixed rooftop
    CAST(15 + r_pv_tilt * 25 AS INT)
  END                                                                AS pv_tilt_degrees,

  CASE WHEN has_pv THEN
    -- Azimuth: 90 (east) to 270 (west) where 180 is south. Skewed to ~180 (south).
    CAST(90 + r_pv_azimuth * 180 AS INT)
  END                                                                AS pv_azimuth_degrees,

  CASE WHEN has_pv THEN
    -- Inverter type
    CASE
      WHEN r_pv_size < 0.75 THEN 'string_inverter'
      ELSE                       'microinverter'
    END
  END                                                                AS pv_inverter_type,

  CASE WHEN has_pv THEN
    -- Install date: 2010-today (PV got accessible after 2010 federal credit + cost drops)
    DATE_ADD(MAKE_DATE(2010, 1, 1), CAST(r_pv_install * 365 * 16 AS INT))
  END                                                                AS pv_install_date,

  CASE WHEN has_pv THEN true END                                     AS pv_net_metered,

  -- =============================
  -- BESS (battery storage; only if has_pv)
  -- =============================
  has_pv AND r_bess < bess_rate_given_pv                             AS has_bess,
  CASE WHEN has_pv AND r_bess < bess_rate_given_pv THEN
    -- Capacity 10-27 kWh (Powerwall 2 era and successors)
    ROUND(10.0 + r_bess_size * 17, 1)
  END                                                                AS bess_capacity_kwh,

  CASE WHEN has_pv AND r_bess < bess_rate_given_pv THEN
    -- Power rating kW (continuous discharge)
    ROUND(5.0 + r_bess_size * 5, 1)
  END                                                                AS bess_power_kw,

  CASE WHEN has_pv AND r_bess < bess_rate_given_pv THEN 0.90 END     AS bess_round_trip_efficiency,

  CASE WHEN has_pv AND r_bess < bess_rate_given_pv THEN
    CASE
      WHEN r_bess_dispatch < 0.55 THEN 'tou_arbitrage'
      WHEN r_bess_dispatch < 0.85 THEN 'peak_shave'
      ELSE                             'backup_only'
    END
  END                                                                AS bess_dispatch_mode,

  -- =============================
  -- Heat pump
  -- =============================
  has_heat_pump,
  CASE WHEN has_heat_pump THEN
    -- Type: ASHP (95%) vs GSHP (5%)
    CASE WHEN r_hp_type < 0.95 THEN 'air_source' ELSE 'ground_source' END
  END                                                                AS hp_type,

  CASE WHEN has_heat_pump THEN
    -- Nominal heating capacity BTU/hr — sized to sqft.
    -- Rule of thumb: ~30-35 BTU/hr per sqft for MI climate zone 5A.
    CAST(sqft * (30 + r_hp_type * 10) AS INT)
  END                                                                AS hp_nominal_heating_btuh,

  CASE WHEN has_heat_pump THEN
    -- COP at 47F (rated condition): modern ASHP ~3.5; GSHP ~4.0
    CASE WHEN r_hp_type < 0.95 THEN 3.0 + r_hp_install * 1.0  -- 3.0-4.0 for ASHP
         ELSE                        3.8 + r_hp_install * 0.7  -- 3.8-4.5 for GSHP
    END
  END                                                                AS hp_cop_at_47f,

  CASE WHEN has_heat_pump THEN
    -- COP at 5F (low-temp performance): big drop for older ASHPs, smaller for cold-climate models
    CASE WHEN r_hp_type < 0.95 THEN 1.6 + r_hp_install * 1.0  -- 1.6-2.6 for ASHP
         ELSE                        2.5 + r_hp_install * 0.8  -- 2.5-3.3 for GSHP (less affected)
    END
  END                                                                AS hp_cop_at_5f,

  CASE WHEN has_heat_pump THEN
    -- Backup heating strips: nearly all MI ASHPs have them (cold climate);
    -- GSHPs rarely need them.
    CASE WHEN r_hp_type < 0.95 THEN true ELSE r_hp_install < 0.20 END
  END                                                                AS hp_has_backup_strip,

  CASE WHEN has_heat_pump THEN
    -- Install date: 2010-today (modern heat pump availability + IRA incentives)
    DATE_ADD(MAKE_DATE(2010, 1, 1), CAST(r_hp_install * 365 * 16 AS INT))
  END                                                                AS hp_install_date,

  -- Did this HP replace a different heating system? (Useful narrative
  -- for the EE Marketing persona — "your gas furnace went to a heat pump")
  CASE WHEN has_heat_pump THEN heating_fuel END                      AS hp_replaced_heating_fuel,

  -- =============================
  -- Smart thermostat
  -- =============================
  has_smart_thermostat,
  CASE WHEN has_smart_thermostat THEN
    -- Brand mix: Nest 45%, Ecobee 28%, Honeywell 18%, other 9%
    CASE
      WHEN r_tstat_brand < 0.45 THEN 'Nest'
      WHEN r_tstat_brand < 0.73 THEN 'Ecobee'
      WHEN r_tstat_brand < 0.91 THEN 'Honeywell'
      ELSE                           'Other'
    END
  END                                                                AS tstat_brand,

  CASE WHEN has_smart_thermostat THEN
    -- DR enrollment (the utility's bring-your-own-thermostat program). Higher for engaged archetypes.
    CASE
      WHEN archetype = 'tech_forward'            THEN r_tstat_dr < 0.55
      WHEN archetype = 'efficient_engaged'       THEN r_tstat_dr < 0.45
      WHEN archetype = 'comfortable_indifferent' THEN r_tstat_dr < 0.20
      ELSE                                            r_tstat_dr < 0.10
    END
  END                                                                AS tstat_dr_enrolled,

  CASE WHEN has_smart_thermostat THEN
    -- Install date: 2014-today (Nest hit market 2011, mainstream by 2014)
    DATE_ADD(MAKE_DATE(2014, 1, 1), CAST(r_tstat_install * 365 * 12 AS INT))
  END                                                                AS tstat_install_date,

  current_timestamp()                                                AS _ingested_at
FROM adopt_flags;
