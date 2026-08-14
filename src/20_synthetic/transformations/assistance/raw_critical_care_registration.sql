-- Critical Care Registration — customers with medical equipment that
-- requires continuous power. Drives priority restoration in outages
-- and triggers a banner on the CSR view.
--
-- One row per critical_care_flag customer. ~1.5% of residential
-- customers have a registration on file.
--
-- Annual recertification: physician must sign off each year. Some
-- customers have lapsed (expiration_date in the past).

CREATE OR REFRESH MATERIALIZED VIEW raw_critical_care_registration (
  CONSTRAINT non_null_registration_id EXPECT (registration_id IS NOT NULL),
  CONSTRAINT non_null_customer_id     EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_equipment EXPECT (medical_equipment_type IN (
    'oxygen_concentrator','dialysis','ventilator','cpap','iv_pump','feeding_pump','other'
  ))
)
COMMENT 'Critical Care registration. One row per current customer with medical-equipment dependency on continuous power (prior-customer customers excluded). Drives priority_restoration_flag in outage_customer_impact and the CSR view critical-care banner. PK: registration_id. FK: customer_id -> raw_customer.'
AS

WITH

flagged AS (
  SELECT customer_id, archetype, age_band_hoh, language_preference
  FROM ${customer_master_schema}.raw_customer
  WHERE critical_care_flag = true
    AND NOT is_prior_customer                                          -- current customers only
),

with_attrs AS (
  SELECT
    f.*,
    abs(xxhash64(f.customer_id, 'cc_register_date', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_reg_date,
    abs(xxhash64(f.customer_id, 'cc_equipment', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_equip,
    abs(xxhash64(f.customer_id, 'cc_expiry', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_expiry,
    abs(xxhash64(f.customer_id, 'cc_physician', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_physician
  FROM flagged f
)

SELECT
  md5(CONCAT(customer_id, '_cc_registration'))                       AS registration_id,
  customer_id,

  -- Registration date: anywhere in the past 1-5 years.
  DATE_SUB(DATE'2018-12-31', CAST(180 + r_reg_date * 1640 AS INT))   AS registration_date,

  -- Medical equipment type, biased by age band.
  CASE
    WHEN age_band_hoh = '65_plus' THEN
      CASE
        WHEN r_equip < 0.45 THEN 'oxygen_concentrator'
        WHEN r_equip < 0.65 THEN 'cpap'
        WHEN r_equip < 0.80 THEN 'dialysis'
        WHEN r_equip < 0.90 THEN 'iv_pump'
        WHEN r_equip < 0.97 THEN 'feeding_pump'
        ELSE                     'other'
      END
    ELSE
      CASE
        WHEN r_equip < 0.30 THEN 'cpap'
        WHEN r_equip < 0.55 THEN 'oxygen_concentrator'
        WHEN r_equip < 0.70 THEN 'ventilator'
        WHEN r_equip < 0.82 THEN 'dialysis'
        WHEN r_equip < 0.92 THEN 'iv_pump'
        WHEN r_equip < 0.98 THEN 'feeding_pump'
        ELSE                     'other'
      END
  END                                                                AS medical_equipment_type,

  -- Physician sign-off (98%; the 2% are pending verification).
  r_physician < 0.98                                                 AS physician_signed_flag,

  -- Expiration date (annual recertification). Most current; ~12% are lapsed.
  CASE
    WHEN r_expiry < 0.88 THEN DATE_ADD(DATE'2018-12-31', CAST(r_expiry * 365 AS INT))
    ELSE                       DATE_SUB(DATE'2018-12-31', CAST(r_expiry * 180 AS INT))
  END                                                                AS expiration_date,

  -- Notification preferences for outages.
  CASE
    WHEN language_preference IN ('ES','OTHER') THEN 'text_and_phone'
    WHEN r_physician < 0.30                    THEN 'phone_only'
    WHEN r_physician < 0.65                    THEN 'text_and_phone'
    ELSE                                            'text_email_phone'
  END                                                                AS outage_notification_preference,

  current_timestamp()                                                AS _ingested_at
FROM with_attrs;
