-- DSM Enrollment — per-customer enrollments derived from der_adoption,
-- liheap_eligible, archetype, and sqft. One row per (customer, program).
--
-- Volume: ~30-50K enrollments. Some customers enroll in multiple programs
-- (a tech_forward customer might have BYOT + LED + Audit + HP Rebate).
--
-- The enrollment is FACT-DRIVEN: if a customer has has_smart_thermostat AND
-- tstat_dr_enrolled, they have a BYOT enrollment. If has_heat_pump, they
-- had an HP rebate at the install_date. Etc.

CREATE OR REFRESH MATERIALIZED VIEW raw_dsm_enrollment (
  CONSTRAINT non_null_enrollment_id EXPECT (enrollment_id IS NOT NULL),
  CONSTRAINT non_null_customer_id   EXPECT (customer_id IS NOT NULL),
  CONSTRAINT non_null_program_id    EXPECT (program_id IS NOT NULL),
  CONSTRAINT valid_status EXPECT (enrollment_status IN ('enrolled','completed','cancelled','pending'))
)
COMMENT 'DSM Enrollment — per-customer program enrollments. Derived deterministically from der_adoption (BYOT/EV/HP/HPWH rebates), liheap_eligible (LMI weatherization), and archetype-driven uptake of optional programs (LED/appliance/audit). Current occupants only (prior-occupant customers excluded); der_adoption is deduped to one row per customer before joining (a commercial chain''s customer_id spans many usage points). PK: enrollment_id. FK: customer_id -> raw_customer; program_id -> dsm_program.'
AS

WITH

-- der_adoption is now keyed per premise/usage_point (PK usage_point_id), so a
-- single customer_id (especially a commercial chain) appears on many rows.
-- Collapse to one row per customer before joining so enrollment stays 1:1 with
-- the customer's DER facts and does not fan out.
der_by_customer AS (
  SELECT * FROM (
    SELECT d.*, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY usage_point_id) AS _rn
    FROM ${der_adoption_schema}.raw_der_customer d
  ) WHERE _rn = 1
),

customer_base AS (
  SELECT
    c.customer_id, c.archetype, c.customer_class, c.income_band,
    c.liheap_eligible, c.tenure, c.language_preference,
    d.has_smart_thermostat, d.tstat_dr_enrolled, d.tstat_install_date,
    d.has_heat_pump, d.hp_install_date,
    d.has_ev, d.ev_install_date, d.ev_is_tou_enrolled,
    d.has_pv, d.pv_install_date,
    abs(xxhash64(c.customer_id, 'dsm_led', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_led,
    abs(xxhash64(c.customer_id, 'dsm_appl', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_appl,
    abs(xxhash64(c.customer_id, 'dsm_audit', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_audit,
    abs(xxhash64(c.customer_id, 'dsm_insul', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_insul,
    abs(xxhash64(c.customer_id, 'dsm_wx', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_wx,
    abs(xxhash64(c.customer_id, 'dsm_comm_audit', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_comm_audit,
    abs(xxhash64(c.customer_id, 'dsm_comm_dr', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_comm_dr,
    abs(xxhash64(c.customer_id, 'dsm_date', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_date
  FROM ${customer_master_schema}.raw_customer c
  LEFT JOIN der_by_customer d USING (customer_id)
  WHERE NOT c.is_prior_occupant                              -- current occupants only
),

byot_enrollments AS (
  SELECT customer_id, 'PRG-BYOT' AS program_id,
    COALESCE(tstat_install_date, DATE'2017-06-01') AS enrollment_date,
    35.00 AS rebate_paid_usd, 150 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base WHERE has_smart_thermostat AND tstat_dr_enrolled
),

tstat_rebate_enrollments AS (
  SELECT customer_id, 'PRG-SMART-TSTAT' AS program_id,
    tstat_install_date AS enrollment_date,
    75.00 AS rebate_paid_usd, 200 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base WHERE has_smart_thermostat AND tstat_install_date IS NOT NULL
),

hp_rebate_enrollments AS (
  SELECT customer_id, 'PRG-HP-REBATE' AS program_id,
    hp_install_date AS enrollment_date,
    1500.00 AS rebate_paid_usd, 4500 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base WHERE has_heat_pump AND hp_install_date IS NOT NULL
),

ev_charger_enrollments AS (
  -- NOT every EV owner claims the charger rebate: pre-program EVs, DIY/installer
  -- installs, low program awareness, or simply never applying. Capture rate is
  -- ~50-72%, tilted by engagement (efficient/tech archetypes chase rebates more),
  -- so the AMI-detected EV population and the rebate roster differ — the
  -- "EV detected, no rebate" gap the map's program-adoption comparison surfaces.
  SELECT customer_id, 'PRG-EV-CHARGER' AS program_id,
    ev_install_date AS enrollment_date,
    500.00 AS rebate_paid_usd, 2200 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base
  WHERE has_ev AND ev_install_date IS NOT NULL
    AND abs(xxhash64(customer_id, 'dsm_ev_charger', ${random_seed}))
          / CAST(9223372036854775807 AS DOUBLE) <
        CASE archetype
          WHEN 'efficient_engaged' THEN 0.72
          WHEN 'tech_forward'      THEN 0.65
          ELSE                          0.50
        END
),

ev_tou_enrollments AS (
  SELECT customer_id, 'PRG-TOU-EV' AS program_id,
    ev_install_date AS enrollment_date,
    0.00 AS rebate_paid_usd, 1100 AS kwh_saved_estimate, 'enrolled' AS enrollment_status
  FROM customer_base WHERE has_ev AND ev_is_tou_enrolled
),

solar_incentive_enrollments AS (
  SELECT customer_id, 'PRG-SOLAR-INCENTIVE' AS program_id,
    pv_install_date AS enrollment_date,
    0.00 AS rebate_paid_usd, 7500 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base WHERE has_pv AND pv_install_date < DATE'2017-01-01'
),

led_enrollments AS (
  SELECT customer_id, 'PRG-LED-DISCOUNT' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_date * 700 AS INT)) AS enrollment_date,
    5.00 AS rebate_paid_usd, 90 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base
  WHERE customer_class = 'Residential' AND r_led <
    CASE archetype
      WHEN 'efficient_engaged'        THEN 0.55
      WHEN 'tech_forward'             THEN 0.62
      WHEN 'comfortable_indifferent'  THEN 0.18
      WHEN 'inefficient_unaware'      THEN 0.10
      WHEN 'senior_fixed_income'      THEN 0.20
      WHEN 'cost_stressed'            THEN 0.12
      ELSE                                 0.20
    END
),

appliance_enrollments AS (
  SELECT customer_id,
    CASE WHEN r_appl < 0.50 THEN 'PRG-APPL-WASHER' ELSE 'PRG-APPL-FRIDGE' END AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_date * 700 AS INT)) AS enrollment_date,
    CASE WHEN r_appl < 0.50 THEN 50.00 ELSE 75.00 END AS rebate_paid_usd,
    CASE WHEN r_appl < 0.50 THEN 150 ELSE 250 END AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM customer_base
  WHERE customer_class = 'Residential' AND r_appl <
    CASE archetype
      WHEN 'efficient_engaged'        THEN 0.35
      WHEN 'tech_forward'             THEN 0.40
      WHEN 'comfortable_indifferent'  THEN 0.10
      WHEN 'inefficient_unaware'      THEN 0.06
      WHEN 'senior_fixed_income'      THEN 0.08
      WHEN 'cost_stressed'            THEN 0.04
      ELSE                                 0.10
    END
),

audit_enrollments AS (
  SELECT customer_id, 'PRG-HEA-AUDIT' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_date * 700 AS INT)) AS enrollment_date,
    0.00 AS rebate_paid_usd, 1200 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base
  WHERE customer_class = 'Residential' AND r_audit <
    CASE archetype
      WHEN 'efficient_engaged'        THEN 0.22
      WHEN 'tech_forward'             THEN 0.25
      WHEN 'comfortable_indifferent'  THEN 0.05
      WHEN 'inefficient_unaware'      THEN 0.10  -- inefficient_unaware audits often follow high-bill complaints
      WHEN 'senior_fixed_income'      THEN 0.03
      WHEN 'cost_stressed'            THEN 0.04
      ELSE                                 0.06
    END
),

insulation_enrollments AS (
  SELECT customer_id, 'PRG-INSULATION' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_date * 700 AS INT)) AS enrollment_date,
    350.00 AS rebate_paid_usd, 3500 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base
  WHERE customer_class = 'Residential' AND tenure = 'own' AND r_insul <
    CASE archetype
      WHEN 'efficient_engaged'        THEN 0.10
      WHEN 'tech_forward'             THEN 0.08
      WHEN 'comfortable_indifferent'  THEN 0.03
      WHEN 'inefficient_unaware'      THEN 0.04
      ELSE                                 0.02
    END
),

wx_lmi_enrollments AS (
  SELECT customer_id, 'PRG-WX-LMI' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_date * 700 AS INT)) AS enrollment_date,
    0.00 AS rebate_paid_usd, 3200 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base
  WHERE liheap_eligible AND tenure = 'own' AND r_wx < 0.18
),

comm_audit_enrollments AS (
  SELECT customer_id, 'PRG-COMM-AUDIT' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_date * 700 AS INT)) AS enrollment_date,
    0.00 AS rebate_paid_usd, 12000 AS kwh_saved_estimate, 'completed' AS enrollment_status
  FROM customer_base
  WHERE customer_class = 'Commercial' AND r_comm_audit < 0.30
),

comm_dr_enrollments AS (
  SELECT customer_id, 'PRG-COMM-DR' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_date * 700 AS INT)) AS enrollment_date,
    0.00 AS rebate_paid_usd, 8500 AS kwh_saved_estimate, 'enrolled' AS enrollment_status
  FROM customer_base
  WHERE customer_class = 'Commercial' AND r_comm_dr < 0.15
),

all_enrollments AS (
  SELECT * FROM byot_enrollments              UNION ALL
  SELECT * FROM tstat_rebate_enrollments      UNION ALL
  SELECT * FROM hp_rebate_enrollments         UNION ALL
  SELECT * FROM ev_charger_enrollments        UNION ALL
  SELECT * FROM ev_tou_enrollments            UNION ALL
  SELECT * FROM solar_incentive_enrollments   UNION ALL
  SELECT * FROM led_enrollments               UNION ALL
  SELECT * FROM appliance_enrollments         UNION ALL
  SELECT * FROM audit_enrollments             UNION ALL
  SELECT * FROM insulation_enrollments        UNION ALL
  SELECT * FROM wx_lmi_enrollments            UNION ALL
  SELECT * FROM comm_audit_enrollments        UNION ALL
  SELECT * FROM comm_dr_enrollments
)

SELECT
  md5(CONCAT(customer_id, '_', program_id))                          AS enrollment_id,
  customer_id,
  program_id,
  enrollment_date,
  -- Completion date — 14-90 days after enrollment for completed; NULL for active/pending.
  CASE WHEN enrollment_status = 'completed'
       THEN DATE_ADD(enrollment_date, CAST(14 + abs(xxhash64(customer_id, program_id, 'days')) % 76 AS INT))
       ELSE CAST(NULL AS DATE)
  END                                                                AS completion_date,
  rebate_paid_usd,
  kwh_saved_estimate,
  enrollment_status,
  current_timestamp()                                                AS _ingested_at
FROM all_enrollments;
