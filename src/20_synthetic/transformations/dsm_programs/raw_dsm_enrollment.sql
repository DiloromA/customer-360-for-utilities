-- DSM Enrollment — PREMISE-GRAINED program enrollments. One row per
-- (customer, program, premise). Derived from der_adoption, liheap_eligible,
-- archetype, and tenure.
--
-- Every DSM program is a PHYSICAL install/service at a specific meter/building
-- (thermostat, heat pump, EV charger, solar, insulation, audit, appliance...),
-- so enrollment carries premise_id. The premise is resolved three ways
--:
--
--   Rule A — DER-driven programs (BYOT / smart-tstat / HP / EV-charger /
--     EV-TOU / solar): the premise is DETERMINISTIC — the one carrying the
--     device flag in raw_der_customer (is_der_host = one meter per building).
--     A customer with the device at N premises gets N enrollments (N installs).
--   Rule B — residential non-device programs (LED / appliance / audit /
--     insulation / LMI-weatherization): archetype-probability draws with no
--     device fact. Stay ONE per customer, attached to a SEEDED-PICK premise
--     among the customer's premises (deterministic hash). Single-premise
--     residential (≈all) resolves to their one premise exactly.
--   Rule C — commercial DR / audit: contracted PER FACILITY, so a per-premise
--     probability draw (seeded by premise_id) — a chain shows partial portfolio
--     adoption (some sites in, some out).
--
-- Volume: rises above the old customer-grained count via the Rule A / Rule C
-- multi-site fan-out (a PV chain at 5 sites → 5 solar enrollments, not 1).

CREATE OR REFRESH MATERIALIZED VIEW raw_dsm_enrollment (
  CONSTRAINT non_null_enrollment_id EXPECT (enrollment_id IS NOT NULL),
  CONSTRAINT non_null_customer_id   EXPECT (customer_id IS NOT NULL),
  CONSTRAINT non_null_premise_id    EXPECT (premise_id IS NOT NULL),
  CONSTRAINT non_null_program_id    EXPECT (program_id IS NOT NULL),
  CONSTRAINT valid_status EXPECT (enrollment_status IN ('enrolled','completed','cancelled','pending'))
)
COMMENT 'DSM Enrollment — premise-grained program enrollments, one row per (customer, program, premise). Every program is a physical install/service, so premise_id is carried. DER-driven programs attach to the premise holding the device (raw_der_customer, is_der_host); residential non-device programs stay one per customer at a seeded-pick premise; commercial DR/audit are a per-premise partial draw. Derived deterministically from der_adoption, liheap_eligible, and archetype-driven uptake. Current customers only. PK: enrollment_id. FK: customer_id -> raw_customer; program_id -> dsm_program; premise_id -> raw_premises.'
AS

WITH

-- One row per PREMISE = the DER host (smallest service_point per premise). The
-- has_* device flags in raw_der_customer are already gated to the host, so the
-- host row is the premise's DER truth; sub-metered commercial siblings are
-- dropped here. Replaces the old der_by_customer collapse, which discarded the
-- premise by keeping one row per CUSTOMER.
premise_der AS (
  SELECT * FROM (
    SELECT d.*,
      ROW_NUMBER() OVER (PARTITION BY d.premise_id ORDER BY d.service_point_id) AS _rn
    FROM ${der_adoption_schema}.raw_der_customer d
  ) WHERE _rn = 1
),

-- Premise-grained base for Rules A & C: DER truth + the customer's archetype
-- (for capture-rate/eligibility) + per-PREMISE random draws. Current customers
-- only.
premise_base AS (
  SELECT
    pd.premise_id,
    pd.customer_id,
    c.customer_class,
    c.archetype,
    c.tenure,
    c.liheap_eligible,
    pd.has_smart_thermostat, pd.tstat_dr_enrolled, pd.tstat_install_date,
    pd.has_heat_pump, pd.hp_install_date,
    pd.has_ev, pd.ev_install_date, pd.ev_is_tou_enrolled,
    pd.has_pv, pd.pv_install_date,
    abs(xxhash64(pd.premise_id, 'dsm_ev_charger', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_ev_charger,
    abs(xxhash64(pd.premise_id, 'dsm_comm_audit', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_comm_audit,
    abs(xxhash64(pd.premise_id, 'dsm_comm_dr',    ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_comm_dr,
    abs(xxhash64(pd.premise_id, 'dsm_comm_date',  ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE) AS r_comm_date
  FROM premise_der pd
  JOIN ${customer_master_schema}.raw_customer c ON c.customer_id = pd.customer_id
  WHERE NOT c.is_prior_customer
),

-- Per-customer base for Rule B: archetype-driven uptake draws, seeded by
-- customer_id (one draw per customer -> one enrollment per customer).
customer_base AS (
  SELECT
    c.customer_id, c.archetype, c.customer_class, c.liheap_eligible, c.tenure,
    abs(xxhash64(c.customer_id, 'dsm_led',   ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_led,
    abs(xxhash64(c.customer_id, 'dsm_appl',  ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_appl,
    abs(xxhash64(c.customer_id, 'dsm_audit', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_audit,
    abs(xxhash64(c.customer_id, 'dsm_insul', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_insul,
    abs(xxhash64(c.customer_id, 'dsm_wx',    ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_wx,
    abs(xxhash64(c.customer_id, 'dsm_date',  ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_date
  FROM ${customer_master_schema}.raw_customer c
  WHERE NOT c.is_prior_customer
),

-- Rule B premise attachment: one seeded-pick premise per customer. Deterministic
-- hash order on premise_id; single-premise customers resolve to their only
-- premise. Inner join to premise_der drops (rare) premise-less customers.
customer_premise_pick AS (
  SELECT customer_id, premise_id FROM (
    SELECT customer_id, premise_id,
      ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY abs(xxhash64(premise_id, 'dsm_premise_pick', ${random_seed}))
      ) AS _rn
    FROM premise_der
  ) WHERE _rn = 1
),

-- ── Rule A: DER-driven, deterministic premise ─────────────────────────────
byot_enrollments AS (
  SELECT customer_id, premise_id, 'PRG-BYOT' AS program_id,
    COALESCE(tstat_install_date, DATE'2017-06-01') AS enrollment_date,
    CAST(35.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 150 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM premise_base WHERE has_smart_thermostat AND tstat_dr_enrolled
),

tstat_rebate_enrollments AS (
  SELECT customer_id, premise_id, 'PRG-SMART-TSTAT' AS program_id,
    tstat_install_date AS enrollment_date,
    CAST(75.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 200 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM premise_base WHERE has_smart_thermostat AND tstat_install_date IS NOT NULL
),

hp_rebate_enrollments AS (
  SELECT customer_id, premise_id, 'PRG-HP-REBATE' AS program_id,
    hp_install_date AS enrollment_date,
    CAST(1500.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 4500 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM premise_base WHERE has_heat_pump AND hp_install_date IS NOT NULL
),

ev_charger_enrollments AS (
  -- NOT every EV owner claims the charger rebate: pre-program EVs, DIY/installer
  -- installs, low awareness, or never applying. Capture ~50-72%, tilted by
  -- engagement — the "EV detected, no rebate" gap the program-adoption layer
  -- surfaces. Draw is per-premise (per install) so multi-site fleets are
  -- captured independently.
  SELECT customer_id, premise_id, 'PRG-EV-CHARGER' AS program_id,
    ev_install_date AS enrollment_date,
    CAST(500.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 2200 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM premise_base
  WHERE has_ev AND ev_install_date IS NOT NULL
    AND r_ev_charger <
        CASE archetype
          WHEN 'efficient_engaged' THEN 0.72
          WHEN 'tech_forward'      THEN 0.65
          ELSE                          0.50
        END
),

ev_tou_enrollments AS (
  SELECT customer_id, premise_id, 'PRG-TOU-EV' AS program_id,
    ev_install_date AS enrollment_date,
    CAST(0.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 1100 AS kwh_saved_estimate,
    'enrolled' AS enrollment_status
  FROM premise_base WHERE has_ev AND ev_is_tou_enrolled
),

solar_incentive_enrollments AS (
  SELECT customer_id, premise_id, 'PRG-SOLAR-INCENTIVE' AS program_id,
    pv_install_date AS enrollment_date,
    CAST(0.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 7500 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM premise_base WHERE has_pv AND pv_install_date < DATE'2017-01-01'
),

-- ── Rule B: residential non-device, one per customer @ seeded-pick premise ─
led_enrollments AS (
  SELECT cb.customer_id, pp.premise_id, 'PRG-LED-DISCOUNT' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(cb.r_date * 700 AS INT)) AS enrollment_date,
    CAST(5.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 90 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM customer_base cb
  JOIN customer_premise_pick pp USING (customer_id)
  WHERE cb.customer_class = 'Residential' AND cb.r_led <
    CASE cb.archetype
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
  SELECT cb.customer_id, pp.premise_id,
    CASE WHEN cb.r_appl < 0.50 THEN 'PRG-APPL-WASHER' ELSE 'PRG-APPL-FRIDGE' END AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(cb.r_date * 700 AS INT)) AS enrollment_date,
    CAST(CASE WHEN cb.r_appl < 0.50 THEN 50.00 ELSE 75.00 END AS DECIMAL(6,2)) AS rebate_paid_usd,
    CASE WHEN cb.r_appl < 0.50 THEN 150 ELSE 250 END AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM customer_base cb
  JOIN customer_premise_pick pp USING (customer_id)
  WHERE cb.customer_class = 'Residential' AND cb.r_appl <
    CASE cb.archetype
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
  SELECT cb.customer_id, pp.premise_id, 'PRG-HEA-AUDIT' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(cb.r_date * 700 AS INT)) AS enrollment_date,
    CAST(0.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 1200 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM customer_base cb
  JOIN customer_premise_pick pp USING (customer_id)
  WHERE cb.customer_class = 'Residential' AND cb.r_audit <
    CASE cb.archetype
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
  SELECT cb.customer_id, pp.premise_id, 'PRG-INSULATION' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(cb.r_date * 700 AS INT)) AS enrollment_date,
    CAST(350.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 3500 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM customer_base cb
  JOIN customer_premise_pick pp USING (customer_id)
  WHERE cb.customer_class = 'Residential' AND cb.tenure = 'own' AND cb.r_insul <
    CASE cb.archetype
      WHEN 'efficient_engaged'        THEN 0.10
      WHEN 'tech_forward'             THEN 0.08
      WHEN 'comfortable_indifferent'  THEN 0.03
      WHEN 'inefficient_unaware'      THEN 0.04
      ELSE                                 0.02
    END
),

wx_lmi_enrollments AS (
  SELECT cb.customer_id, pp.premise_id, 'PRG-WX-LMI' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(cb.r_date * 700 AS INT)) AS enrollment_date,
    CAST(0.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 3200 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM customer_base cb
  JOIN customer_premise_pick pp USING (customer_id)
  WHERE cb.liheap_eligible AND cb.tenure = 'own' AND cb.r_wx < 0.18
),

-- ── Rule C: commercial DR / audit, per-premise partial ────────────────────
comm_audit_enrollments AS (
  SELECT customer_id, premise_id, 'PRG-COMM-AUDIT' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_comm_date * 700 AS INT)) AS enrollment_date,
    CAST(0.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 12000 AS kwh_saved_estimate,
    'completed' AS enrollment_status
  FROM premise_base
  WHERE customer_class = 'Commercial' AND r_comm_audit < 0.30
),

comm_dr_enrollments AS (
  SELECT customer_id, premise_id, 'PRG-COMM-DR' AS program_id,
    DATE_ADD(DATE'2017-01-01', CAST(r_comm_date * 700 AS INT)) AS enrollment_date,
    CAST(0.00 AS DECIMAL(6,2)) AS rebate_paid_usd, 8500 AS kwh_saved_estimate,
    'enrolled' AS enrollment_status
  FROM premise_base
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
  -- PK is (customer, premise, program) — a premise enrolls a given program once.
  md5(CONCAT_WS('_', CAST(customer_id AS STRING), CAST(premise_id AS STRING), program_id))
                                                                     AS enrollment_id,
  customer_id,
  premise_id,
  program_id,
  enrollment_date,
  -- Completion date — 14-90 days after enrollment for completed; NULL otherwise.
  CASE WHEN enrollment_status = 'completed'
       THEN DATE_ADD(enrollment_date, CAST(14 + abs(xxhash64(customer_id, premise_id, program_id, 'days')) % 76 AS INT))
       ELSE CAST(NULL AS DATE)
  END                                                                AS completion_date,
  rebate_paid_usd,
  kwh_saved_estimate,
  enrollment_status,
  current_timestamp()                                                AS _ingested_at
FROM all_enrollments;
