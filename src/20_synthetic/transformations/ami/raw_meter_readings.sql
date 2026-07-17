-- Meter Readings — hourly synthetic AMI for every (usage_point, hour) over
-- the display window (as_of_date minus history_months, trailing).
--
-- Base load PLUS five DER adders (EV / PV / BESS / Heat Pump / Smart
-- Thermostat DR). Pure SDP, single MV, multi-CTE pipeline:
--
--   1. hourly_total_per_unit       ResStock per-unit hourly kWh by bldg type
--   2. customer_full               premise + usage_point + current-occupant
--                                  customer (via premise_customer_map) + bldg
--                                  type + base-load multiplier (archetype x
--                                  envelope). Keyed by usage_point only; no
--                                  denormalized customer_id.
--   3. weather_calendar_map        display_date -> analog source_date
--                                  in the fixed 2018 library + kwh_scale.
--   4. base                        Join customer x ResStock x calendar map ->
--                                  baseline kwh_base (x kwh_scale)
--   5. weather                     EULP AMY2018 weather (temperature + GHI/
--                                  DNI/DHI) keyed by (county_fips, source-clock
--                                  hour). Each county has one cell.
--   6. pv_shape                    Fleet-average PV generation shape from the
--                                  ResStock by_state PV channel, normalized to
--                                  sum-to-one over the source year.
--   7. with_der (PV)               For PV adopters, kwh_pv = pv_system_kw_dc *
--                                  1150 kWh/kW-yr * pv_fraction.
--   8. with_der (EV)               EV charging template per (pattern, hour) ×
--                                  kwh_per_day; sharper overnight peak for TOU.
--   9. with_der (HP)               Heat pump heating from weather temp:
--                                  HDH * sqft * 0.0003 / COP(temp), backup
--                                  strip below -10C if hp_has_backup_strip.
--   10. with_der (BESS)            Scheduled BESS dispatch (TOU arb / peak shave
--                                  / backup only).
--   11. with_der (tstat)           -5% dampening of base during summer peak
--                                  (16-20 hr, May-Sep) for DR-enrolled tstats.
--   12. (final SELECT)             Sum all components -> kwh_delivered + kwh_received
--
-- Weather/PV physics joins run on the AMY source-clock hour (amy_timestamp_hour),
-- not the display timestamp — see the `weather` and `pv_shape` CTEs below. Only
-- the display stamp (MAKE_TIMESTAMP in `base`) is calendar-mapped. This means
-- base load, PV generation, and weather are consistent BY CONSTRUCTION at each
-- source hour (same EnergyPlus simulation vintage). weather_calendar_map maps
-- each display_date to its own day-of-week analog with its own kwh_scale, so
-- display years are not hour-for-hour identical weather/PV copies and YoY is
-- non-degenerate (temporal-realism-scoping §3).

CREATE OR REFRESH MATERIALIZED VIEW raw_meter_readings (
  CONSTRAINT non_null_usage_point_id EXPECT (usage_point_id IS NOT NULL),
  CONSTRAINT non_null_timestamp      EXPECT (timestamp_utc IS NOT NULL),
  CONSTRAINT non_negative_delivered  EXPECT (kwh_delivered >= 0),
  CONSTRAINT non_negative_received   EXPECT (kwh_received >= 0),
  CONSTRAINT non_negative_base       EXPECT (kwh_base >= 0)
)
COMMENT 'Hourly synthetic AMI meter readings — one row per (usage_point, hour) for 2017+2018. Includes base load (ResStock-derived) plus EV / PV / BESS / Heat Pump / Smart Thermostat DR adders. kwh_delivered is net of all DER (what billing sees); kwh_received is PV export; component channels (kwh_base, kwh_ev, kwh_pv, kwh_hp, kwh_bess, kwh_tstat_savings) provide ground-truth attribution for ML training and curated views. PK: (usage_point_id, timestamp_utc). FK: usage_point_id -> raw_usage_point.'
AS

WITH

-- ────────────────────────────────────────────────────────────────────────
-- 1. ResStock pre-aggregation.
-- ────────────────────────────────────────────────────────────────────────
hourly_total_per_unit AS (
  SELECT
    sector,
    COALESCE(in_geometry_building_type_recs, in_comstock_building_type) AS building_type,
    DATE_TRUNC('HOUR', timestamp) AS amy_timestamp_hour,
    SUM(value) / MIN(COALESCE(units_represented, floor_area_represented)) AS kwh_per_unit
  FROM ${load_shapes_table}
  WHERE state = '${target_state}'
    AND load_shape LIKE 'out_electricity_%'
    AND load_shape NOT IN (
      'out_electricity_total_energy_consumption_kwh',
      'out_electricity_net_energy_consumption_kwh',
      -- PV channel excluded from base load (it's generation, not consumption,
      -- and would otherwise net export out of the base) — consumed instead by
      -- the pv_shape CTE below to build the fleet-average generation shape.
      'out_electricity_pv_energy_consumption_kwh'
    )
  GROUP BY sector,
           COALESCE(in_geometry_building_type_recs, in_comstock_building_type),
           DATE_TRUNC('HOUR', timestamp)
),

-- ────────────────────────────────────────────────────────────────────────
-- 2. Customer with all attrs needed for the adders. Joins DER table so
--    EV/PV/BESS/HP/tstat fields are inlined (NULL when not adopted).
--
--    REPARTITION(512): this CTE is the fan-out source for the ~17,520-hour
--    explosion in `base`. Left alone it collapses to a handful of partitions
--    (it's only ~1 row per usage_point), serializing the explosion onto a
--    few tasks. The explicit partition count also stops AQE from coalescing
--    it back down.
-- ────────────────────────────────────────────────────────────────────────
customer_full AS (
  SELECT /*+ REPARTITION(512) */
    up.usage_point_id,
    c.customer_class,
    c.archetype,
    -- Load-scaling sqft: divided across sibling usage_points so a sub-metered
    -- large commercial premise's (temporal-realism §5.3) total load stays the
    -- building's true load instead of multiplying by meter count. A no-op for
    -- the ~everyone-else case (n_usage_points = 1). Building-type
    -- classification below intentionally keeps using the RAW p.sqft (the
    -- whole building's archetype doesn't change because it has more meters).
    p.sqft / up.n_usage_points                                      AS sqft,
    p.envelope_quality,
    p.primary_occupancy,
    p.county_fips,

    -- Building type that joins to ResStock.
    CASE
      WHEN c.customer_class = 'Residential' THEN
        CASE
          -- FEMA labels manufactured homes explicitly; a sqft threshold is NOT
          -- a valid proxy (footprint sqft sweeps ~20% of dense urban Detroit
          -- single-family houses into the Mobile Home load shape).
          WHEN UPPER(p.primary_occupancy) LIKE '%MANUFACTURED%'
            OR UPPER(p.primary_occupancy) LIKE '%MOBILE%'                    THEN 'Mobile Home'
          WHEN UPPER(p.primary_occupancy) LIKE '%MULTI%'
            OR UPPER(p.primary_occupancy) LIKE '%APARTMENT%'                 THEN
            CASE WHEN p.sqft < 5000 THEN 'Multi-Family with 2 - 4 Units'
                                    ELSE 'Multi-Family with 5+ Units' END
          WHEN UPPER(p.primary_occupancy) LIKE '%TOWN%'
            OR UPPER(p.primary_occupancy) LIKE '%ROW%'
            OR UPPER(p.primary_occupancy) LIKE '%ATTACHED%'                  THEN 'Single-Family Attached'
          ELSE                                                                    'Single-Family Detached'
        END
      ELSE
        CASE
          WHEN p.sqft < 5000  THEN 'SmallOffice'
          WHEN p.sqft < 25000 THEN 'MediumOffice'
          ELSE                     'LargeOffice'
        END
    END                                                              AS building_type,
    LOWER(c.customer_class)                                          AS sector_join_key,

    -- Base load multiplier: archetype x envelope.
    CASE c.archetype
      WHEN 'efficient_engaged'        THEN 0.80
      WHEN 'tech_forward'             THEN 0.95
      WHEN 'comfortable_indifferent'  THEN 1.00
      WHEN 'cost_stressed'            THEN 1.15
      WHEN 'inefficient_unaware'      THEN 1.30
      WHEN 'senior_fixed_income'      THEN 0.85
      ELSE                                 1.00
    END *
    CASE p.envelope_quality
      WHEN 'low'    THEN 1.20
      WHEN 'medium' THEN 1.00
      WHEN 'high'   THEN 0.85
      ELSE               1.00
    END                                                              AS load_multiplier,

    -- DER fields (LEFT JOIN — NULL when customer has no DER row, which
    -- shouldn't happen since der_adoption produces one row per customer).
    COALESCE(d.has_ev, false)                                        AS has_ev,
    d.ev_battery_kwh,
    d.ev_vehicle_class,
    d.ev_charging_pattern,
    COALESCE(d.ev_is_tou_enrolled, false)                            AS ev_is_tou_enrolled,

    COALESCE(d.has_pv, false)                                        AS has_pv,
    d.pv_system_kw_dc,

    COALESCE(d.has_bess, false)                                      AS has_bess,
    d.bess_power_kw,
    d.bess_dispatch_mode,

    COALESCE(d.has_heat_pump, false)                                 AS has_heat_pump,
    d.hp_cop_at_47f,
    d.hp_cop_at_5f,
    COALESCE(d.hp_has_backup_strip, false)                           AS hp_has_backup_strip,

    COALESCE(d.has_smart_thermostat, false)                          AS has_smart_thermostat,
    COALESCE(d.tstat_dr_enrolled, false)                             AS tstat_dr_enrolled
  FROM ${customer_master_schema}.raw_premises p
  JOIN ${customer_master_schema}.raw_service_location sl ON sl.premise_id = p.premise_id
  JOIN ${customer_master_schema}.raw_usage_point up ON up.service_location_id = sl.service_location_id
  JOIN ${customer_master_schema}.raw_premise_customer_map m ON m.premise_id = p.premise_id
  JOIN ${customer_master_schema}.raw_customer c ON c.customer_id = m.current_customer_id
  LEFT JOIN ${der_adoption_table} d ON d.usage_point_id = up.usage_point_id
),

-- ────────────────────────────────────────────────────────────────────────
-- 3. Weather calendar map: display_date -> analog source_date in
--    the fixed 2018 library + kwh_scale. See weather_calendar_map.sql.
-- ────────────────────────────────────────────────────────────────────────
weather_calendar_map AS (
  SELECT display_date, source_date, kwh_scale
  FROM ${weather_calendar_map_table}
),

-- ────────────────────────────────────────────────────────────────────────
-- 4. Base load: customer x ResStock x calendar-map join (one row per
--    display_date whose analog source_date matches this hour's source day).
--    Drags along the DER attributes so subsequent
--    CTEs can apply adders without re-joining customer_full.
-- ────────────────────────────────────────────────────────────────────────
-- BROADCAST hints: the join key (sector, building_type) has ~13 distinct
-- values and the premise mix is dominated by Single-Family Detached, so a
-- shuffle join here lands most of the multi-billion-row fan-out on a single
-- task (observed: ~90 GB spill, hours, at 100k premises). Both broadcast
-- sides are small (htp ≈ building_types × 8,760 hours; wcm ≈ 730 rows), so
-- broadcasting keeps the explosion streaming and partition-parallel with no
-- shuffle or sort of the exploded rows.
base AS (
  SELECT /*+ BROADCAST(htp), BROADCAST(wcm) */
    cf.usage_point_id,
    cf.customer_class,
    cf.sqft,
    cf.county_fips,
    cf.has_ev, cf.ev_battery_kwh, cf.ev_vehicle_class, cf.ev_charging_pattern, cf.ev_is_tou_enrolled,
    cf.has_pv, cf.pv_system_kw_dc,
    cf.has_bess, cf.bess_power_kw, cf.bess_dispatch_mode,
    cf.has_heat_pump, cf.hp_cop_at_47f, cf.hp_cop_at_5f, cf.hp_has_backup_strip,
    cf.has_smart_thermostat, cf.tstat_dr_enrolled,
    -- Carried through so weather/PV can join on the source clock (see the
    -- weather and pv_shape CTEs) instead of the calendar-mapped display
    -- timestamp below. Dropped in the final SELECT.
    htp.amy_timestamp_hour                                          AS amy_timestamp_hour,
    MAKE_TIMESTAMP(
      YEAR(wcm.display_date),
      MONTH(wcm.display_date),
      DAY(wcm.display_date),
      HOUR(htp.amy_timestamp_hour),
      0, 0, 'UTC'
    )                                                                AS timestamp_utc,
    (CASE
      WHEN cf.customer_class = 'Commercial'
        THEN htp.kwh_per_unit * cf.load_multiplier * cf.sqft
      ELSE htp.kwh_per_unit * cf.load_multiplier
    END) * wcm.kwh_scale                                             AS kwh_base
  FROM customer_full cf
  JOIN hourly_total_per_unit htp
    ON htp.sector = cf.sector_join_key
   AND htp.building_type = cf.building_type
  JOIN weather_calendar_map wcm
    ON wcm.source_date = DATE(htp.amy_timestamp_hour)
),

-- ────────────────────────────────────────────────────────────────────────
-- 5. EULP AMY2018 weather. One cell per county; (geoid, amy_timestamp_hour)
--    is unique. Used by HP (temperature -> COP); GHI/DNI/DHI land for future
--    per-county PV transposition but PV generation itself comes
--    from pv_shape below, not this table.
--
--    Joined on the AMY SOURCE-clock hour, not the display timestamp_utc —
--    weather only exists for source year 2018 (EULP is single-year AMY),
--    so a display-timestamp join would find no match for displayed-2017
--    rows and silently zero the HP adder for half the window.
-- ────────────────────────────────────────────────────────────────────────
weather AS (
  SELECT
    geoid,
    timestamp_utc AS amy_timestamp_hour,
    ghi_w_m2,
    temperature_c
  FROM ${weather_table}
),

-- ────────────────────────────────────────────────────────────────────────
-- 5b. PV generation shape: fleet-average residential rooftop-PV output from
--     the ResStock by_state PV channel (out_electricity_pv_energy_consumption_kwh,
--     negative = generation), normalized to sum-to-one over the source year.
--     Same source-clock join as weather, for the same reason. One
--     state-level shape; commercial adopters ride it too.
-- ────────────────────────────────────────────────────────────────────────
pv_shape AS (
  SELECT
    amy_timestamp_hour,
    GREATEST(pv_kwh, 0.0) / NULLIF(SUM(GREATEST(pv_kwh, 0.0)) OVER (), 0) AS pv_fraction
  FROM (
    SELECT
      DATE_TRUNC('HOUR', timestamp) AS amy_timestamp_hour,
      SUM(-value)                   AS pv_kwh
    FROM ${load_shapes_table}
    WHERE state = '${target_state}'
      AND sector = 'residential'
      AND load_shape = 'out_electricity_pv_energy_consumption_kwh'
    GROUP BY DATE_TRUNC('HOUR', timestamp)
  )
),

-- ────────────────────────────────────────────────────────────────────────
-- 6-10. DER adders. Each is computed as a column in a single big SELECT;
--       components default to 0 when the customer doesn't have that DER.
-- ────────────────────────────────────────────────────────────────────────
-- BROADCAST hints: same rationale as `base` — never shuffle the exploded
-- rows. weather ≈ counties × 8,760 hours; pv_shape ≈ 8,760 rows.
with_der AS (
  SELECT /*+ BROADCAST(weather), BROADCAST(ps) */
    b.*,
    weather.ghi_w_m2,
    weather.temperature_c,

    -- PV generation: EULP-simulated fleet-average shape (sum-to-one over the
    -- year) scaled to the system size. 1150 kWh per kW-DC per year is the
    -- Michigan fleet-average yield (typical range 1100-1200).
    CASE
      WHEN b.has_pv AND ps.pv_fraction IS NOT NULL
        THEN b.pv_system_kw_dc * 1150.0 * ps.pv_fraction
      ELSE 0.0
    END                                                              AS kwh_pv,

    -- EV charging adder.
    --   kwh_per_day  ≈ 0.15 × battery_kwh (BEV; ~10-13 kWh/day at typical 30 mi/day)
    --                ≈ 0.50 × battery_kwh (PHEV; smaller battery, fuller cycles)
    --   hourly_fraction depends on charging_pattern × is_tou_enrolled × hour-of-day
    CASE WHEN b.has_ev THEN
      (CASE b.ev_vehicle_class
         WHEN 'BEV'  THEN b.ev_battery_kwh * 0.15
         WHEN 'PHEV' THEN b.ev_battery_kwh * 0.50
         ELSE             10.0
       END)
      * CASE
          -- overnight_home_l2 with TOU enrollment: sharp 23-04 peak
          WHEN b.ev_charging_pattern = 'overnight_home_l2' AND b.ev_is_tou_enrolled THEN
            CASE WHEN HOUR(b.timestamp_utc) IN (23, 0, 1, 2, 3) THEN 0.18
                 WHEN HOUR(b.timestamp_utc) IN (4)              THEN 0.07
                 WHEN HOUR(b.timestamp_utc) IN (22)             THEN 0.03
                 ELSE                                                0.0
            END
          -- overnight_home_l2 without TOU: spread 22-06
          WHEN b.ev_charging_pattern = 'overnight_home_l2' THEN
            CASE WHEN HOUR(b.timestamp_utc) BETWEEN 22 AND 23 THEN 0.11
                 WHEN HOUR(b.timestamp_utc) BETWEEN 0  AND 5  THEN 0.10
                 WHEN HOUR(b.timestamp_utc) = 6                THEN 0.06
                 WHEN HOUR(b.timestamp_utc) BETWEEN 18 AND 21 THEN 0.04
                 ELSE                                                0.0
            END
          -- daytime_workplace: 8-17 weekdays-ish (we don't distinguish, so spread)
          WHEN b.ev_charging_pattern = 'daytime_workplace' THEN
            CASE WHEN HOUR(b.timestamp_utc) BETWEEN 8  AND 16 THEN 0.10
                 WHEN HOUR(b.timestamp_utc) = 17                THEN 0.04
                 WHEN HOUR(b.timestamp_utc) BETWEEN 18 AND 21 THEN 0.02
                 ELSE                                                0.0
            END
          -- mixed_dcfc: spread evenly across waking hours
          WHEN b.ev_charging_pattern = 'mixed_dcfc' THEN
            CASE WHEN HOUR(b.timestamp_utc) BETWEEN 6 AND 22 THEN 0.058
                 ELSE                                              0.0
            END
          ELSE 0.0
        END
    ELSE 0.0
    END                                                              AS kwh_ev,

    -- Heat-pump heating contribution.
    --   Heating-degree hour:  hdh = max(15.5 - temp_c, 0)
    --   COP at temperature:   linear interp between cop@47F (8.3C) and cop@5F (-15C)
    --   Cold-strip threshold: when temp_c < -10C and hp_has_backup_strip = true,
    --                         backup strip kicks in and the effective COP collapses
    --                         to 1.0 (resistance heat).
    --   heat_load_kwh =  sqft × hdh × 0.00008  (calibrated to target ~3-5K kWh/yr
    --                                            for typical MI HP customer; modern
    --                                            HP-eligible homes have better
    --                                            envelopes than the population avg)
    --   hp_kwh        =  heat_load_kwh / COP
    CASE WHEN b.has_heat_pump AND weather.temperature_c IS NOT NULL AND weather.temperature_c < 15.5 THEN
      (b.sqft * GREATEST(15.5 - weather.temperature_c, 0.0) * 0.00008)
      / GREATEST(
          CASE
            WHEN weather.temperature_c < -10.0 AND b.hp_has_backup_strip THEN 1.0
            ELSE GREATEST(
              b.hp_cop_at_5f
              + (b.hp_cop_at_47f - b.hp_cop_at_5f)
                * (weather.temperature_c - (-15.0)) / (8.3 - (-15.0)),
              1.0
            )
          END,
          1.0
        )
    ELSE 0.0
    END                                                              AS kwh_hp,

    -- BESS dispatch (signed: + draws from grid to charge, - delivers to home)
    CASE WHEN b.has_bess THEN
      CASE b.bess_dispatch_mode
        WHEN 'tou_arbitrage' THEN
          CASE
            WHEN HOUR(b.timestamp_utc) BETWEEN 23 AND 23 THEN  b.bess_power_kw * 0.7
            WHEN HOUR(b.timestamp_utc) BETWEEN 0  AND 4  THEN  b.bess_power_kw * 0.7
            WHEN HOUR(b.timestamp_utc) BETWEEN 17 AND 20 THEN -b.bess_power_kw * 0.7
            ELSE 0.0
          END
        WHEN 'peak_shave' THEN
          CASE
            WHEN HOUR(b.timestamp_utc) BETWEEN 10 AND 14 THEN  b.bess_power_kw * 0.5
            WHEN HOUR(b.timestamp_utc) BETWEEN 17 AND 20 THEN -b.bess_power_kw * 0.6
            ELSE 0.0
          END
        WHEN 'backup_only' THEN 0.0
        ELSE 0.0
      END
    ELSE 0.0
    END                                                              AS kwh_bess,

    -- Smart-thermostat DR dampening (summer peak hours only)
    CASE
      WHEN b.has_smart_thermostat AND b.tstat_dr_enrolled
        AND MONTH(b.timestamp_utc) BETWEEN 5 AND 9
        AND HOUR(b.timestamp_utc)  BETWEEN 16 AND 20
        THEN -b.kwh_base * 0.05
      ELSE 0.0
    END                                                              AS kwh_tstat_savings

  FROM base b
  LEFT JOIN weather
    ON weather.geoid              = b.county_fips
   AND weather.amy_timestamp_hour = b.amy_timestamp_hour
  LEFT JOIN pv_shape ps
    ON ps.amy_timestamp_hour = b.amy_timestamp_hour
)

SELECT
  usage_point_id,
  timestamp_utc,

  -- Final delivered (net): base + EV + HP + BESS + tstat_savings - PV.
  -- If net < 0 (PV exporting more than the home consumes), delivered = 0
  -- and the export goes into kwh_received.
  ROUND(
    GREATEST(
      kwh_base + kwh_ev + kwh_hp + kwh_bess + kwh_tstat_savings - kwh_pv,
      0.0
    ), 4
  )                                                                  AS kwh_delivered,

  ROUND(
    GREATEST(
      kwh_pv - (kwh_base + kwh_ev + kwh_hp + kwh_bess + kwh_tstat_savings),
      0.0
    ), 4
  )                                                                  AS kwh_received,

  ROUND(kwh_base,           4)                                       AS kwh_base,
  ROUND(kwh_ev,             4)                                       AS kwh_ev,
  ROUND(kwh_pv,             4)                                       AS kwh_pv,
  ROUND(kwh_hp,             4)                                       AS kwh_hp,
  ROUND(kwh_bess,           4)                                       AS kwh_bess,
  ROUND(kwh_tstat_savings,  4)                                       AS kwh_tstat_savings,

  YEAR(timestamp_utc)                                                AS year,
  MONTH(timestamp_utc)                                               AS month,
  current_timestamp()                                                AS _ingested_at
FROM with_der;
