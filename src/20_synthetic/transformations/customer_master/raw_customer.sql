-- Customer — a distinct customer PARTY (CIM Customer), decoupled from premise.
-- Customer is deliberately not 1:1 with premise.
--   • Residential premises  -> one household customer each (the occupant IS the
--     customer; we do not model landlord-holds-the-meter — see design §5.8).
--   • Commercial premises   -> ~20% belong to a MULTI-SITE CHAIN customer (one
--     customer owns several sites in a county); the rest are standalone.
--   • ~15% of residential premises additionally have a PRIOR-OCCUPANT customer
--     whose tenancy ended before the current occupant's move-in (pre-window for
--     most, in-window for relocations and ~40% of ordinary turnover — see
--     design §5.8 + §9.3, temporal-realism §5.2).
-- The premise relationship lives in customer_account / account_premise_link /
-- service_agreement, NOT here. Demographics describe the household at the
-- customer's anchor premise (NULL for commercial).
--
-- ARCHETYPE (latent, drives correlated downstream behaviour) — values:
--   efficient_engaged, comfortable_indifferent, cost_stressed, tech_forward,
--   inefficient_unaware, senior_fixed_income. Distribution biased by income band.
--
-- All dates anchor to ${as_of_date} (the demo's "now"), NOT CURRENT_DATE.
-- Determinism via hash(customer_id / census_tract, '<purpose>', seed).

CREATE OR REFRESH MATERIALIZED VIEW raw_customer (
  CONSTRAINT non_null_customer_id EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_customer_type EXPECT (
    customer_type IN ('residential','commercial_standalone','commercial_chain','landlord_portfolio')
  ),
  CONSTRAINT valid_archetype EXPECT (
    archetype IN ('efficient_engaged','comfortable_indifferent','cost_stressed',
                  'tech_forward','inefficient_unaware','senior_fixed_income')
  )
)
COMMENT 'Customer — a distinct customer party (CIM Customer), decoupled from premise. Residential premises map 1:1 to a household customer; ~20% of commercial premises are grouped under a multi-site chain customer (one customer owns several sites); ~15% of residential premises also have a prior-occupant customer whose tenancy ended before the current occupant''s move-in (pre-window for most, in-window for relocations and some ordinary turnover). The premise relationship lives in customer_account / account_premise_link / service_agreement, not here. n_premises_owned > 1 only for chains. INTERNAL: the archetype column drives downstream synth behaviour and must be dropped before exposing to demo personas. PK: customer_id.'
AS

-- Collapse the shared assignment map to distinct customers (chains have many
-- premises -> one customer). The anchor premise (MIN premise_id) supplies
-- representative demographic attributes.
WITH cust_anchor AS (
  SELECT
    current_customer_id AS customer_id,
    customer_type,
    MIN(premise_id)     AS anchor_premise_id,
    COUNT(*)            AS n_premises_owned
  FROM raw_premise_customer_map
  GROUP BY current_customer_id, customer_type
),

-- Current customers, joined to their anchor premise for demographics.
current_customers AS (
  SELECT
    ca.customer_id,
    ca.anchor_premise_id AS premise_id,
    ca.customer_type,
    ca.n_premises_owned,
    false             AS is_prior_occupant,
    p.occupancy_class,
    p.sqft,
    p.census_tract,
    p.year_built
  FROM cust_anchor ca
  JOIN raw_premises p ON ca.anchor_premise_id = p.premise_id
),

-- Prior-occupant customers (residential turnover). Distinct customer_id via the
-- '_prior_customer' salt so their archetype/demographic draws differ from the
-- current occupant of the same premise.
--
-- EXCLUDES a relocation's mover identity (temporal-realism §5.1): a mover's
-- prior_customer_id at their origin premise is deliberately the SAME
-- customer_id as their current_customer_id at the destination premise (the
-- whole point of a relocation — one person, two tenancies). Without this
-- filter, that identity would get TWO rows here (one via current_customers at
-- the destination, one via prior_customers at the origin) — a real PK
-- collision. Correct behavior: the mover is anchored ONLY at their current
-- (destination) premise via current_customers, which is also the right
-- customer_since_date semantics — the prior_customers branch's date formula
-- below assumes the relationship "pre-dates the fact window," which is false for a mover
-- who relocated in-window.
prior_customers AS (
  SELECT
    m.prior_customer_id AS customer_id,
    m.premise_id,
    'residential'       AS customer_type,
    1                   AS n_premises_owned,
    true                AS is_prior_occupant,
    p.occupancy_class,
    p.sqft,
    p.census_tract,
    p.year_built
  FROM raw_premise_customer_map m
  JOIN raw_premises p ON m.premise_id = p.premise_id
  WHERE m.has_prior_occupant
    AND NOT EXISTS (
      SELECT 1 FROM raw_premise_customer_map m2
      WHERE m2.current_customer_id = m.prior_customer_id
    )
),

-- The landlord-hero party (entity-grain-design.md §5) — a single new
-- business-like party who owns (but does not occupy) the 10 premises in
-- raw_landlord_portfolio. occupancy_class='Commercial' deliberately, so
-- every existing "commercial gets no household demographics" NULL-guard
-- below applies to it for free without adding new CASE branches.
landlord_parties AS (
  SELECT
    md5('LANDLORD_HERO_PARTY')                    AS customer_id,
    CAST(NULL AS STRING)                          AS premise_id,
    'landlord_portfolio'                          AS customer_type,
    (SELECT COUNT(*) FROM raw_landlord_portfolio)  AS n_premises_owned,
    false                                          AS is_prior_occupant,
    'Commercial'                                   AS occupancy_class,
    CAST(NULL AS INT)                             AS sqft,
    CAST(NULL AS STRING)                          AS census_tract,
    CAST(NULL AS INT)                             AS year_built
),

all_customers AS (
  SELECT * FROM current_customers
  UNION ALL
  SELECT * FROM prior_customers
  UNION ALL
  SELECT * FROM landlord_parties
),

draws AS (
  SELECT
    *,
    abs(xxhash64(customer_id,   'archetype',     ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_archetype,
    abs(xxhash64(customer_id,   'age',           ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_age,
    abs(xxhash64(customer_id,   'hhsize',        ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_hh,
    abs(xxhash64(customer_id,   'tenure',        ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_tenure,
    abs(xxhash64(customer_id,   'critical',      ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_critical,
    abs(xxhash64(customer_id,   'cust_since',    ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_since,
    abs(xxhash64(census_tract,  'tract_income',  ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_tract_income,
    abs(xxhash64(census_tract,  'tract_lang',    ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_tract_lang
  FROM all_customers
),

with_income AS (
  SELECT
    *,
    CASE
      WHEN r_tract_income * 0.75 + CAST(LEAST(sqft, 5000) AS DOUBLE) / 5000.0 * 0.25 < 0.18 THEN 'under_25k'
      WHEN r_tract_income * 0.75 + CAST(LEAST(sqft, 5000) AS DOUBLE) / 5000.0 * 0.25 < 0.42 THEN '25k_50k'
      WHEN r_tract_income * 0.75 + CAST(LEAST(sqft, 5000) AS DOUBLE) / 5000.0 * 0.25 < 0.70 THEN '50k_100k'
      WHEN r_tract_income * 0.75 + CAST(LEAST(sqft, 5000) AS DOUBLE) / 5000.0 * 0.25 < 0.90 THEN '100k_200k'
      ELSE                                                                                       'over_200k'
    END AS income_band
  FROM draws
)

SELECT
  customer_id,
  customer_type,
  n_premises_owned,

  CASE occupancy_class
    WHEN 'Residential' THEN 'Residential'
    WHEN 'Commercial'  THEN 'Commercial'
    ELSE                    'Other'
  END                                                              AS customer_class,

  -- ARCHETYPE (latent). Commercial uses a simpler mix; residential biased by income.
  CASE
    WHEN occupancy_class = 'Commercial' THEN
      CASE
        WHEN r_archetype < 0.30 THEN 'efficient_engaged'
        WHEN r_archetype < 0.75 THEN 'comfortable_indifferent'
        WHEN r_archetype < 0.92 THEN 'cost_stressed'
        ELSE                         'inefficient_unaware'
      END
    WHEN income_band IN ('under_25k', '25k_50k') THEN
      CASE
        WHEN r_archetype < 0.08 THEN 'efficient_engaged'
        WHEN r_archetype < 0.30 THEN 'comfortable_indifferent'
        WHEN r_archetype < 0.65 THEN 'cost_stressed'
        WHEN r_archetype < 0.70 THEN 'tech_forward'
        WHEN r_archetype < 0.85 THEN 'inefficient_unaware'
        ELSE                         'senior_fixed_income'
      END
    WHEN income_band IN ('100k_200k', 'over_200k') THEN
      CASE
        WHEN r_archetype < 0.28 THEN 'efficient_engaged'
        WHEN r_archetype < 0.62 THEN 'comfortable_indifferent'
        WHEN r_archetype < 0.72 THEN 'cost_stressed'
        WHEN r_archetype < 0.90 THEN 'tech_forward'
        WHEN r_archetype < 0.98 THEN 'inefficient_unaware'
        ELSE                         'senior_fixed_income'
      END
    ELSE
      CASE
        WHEN r_archetype < 0.18 THEN 'efficient_engaged'
        WHEN r_archetype < 0.50 THEN 'comfortable_indifferent'
        WHEN r_archetype < 0.72 THEN 'cost_stressed'
        WHEN r_archetype < 0.81 THEN 'tech_forward'
        WHEN r_archetype < 0.95 THEN 'inefficient_unaware'
        ELSE                         'senior_fixed_income'
      END
  END                                                              AS archetype,

  income_band,

  CASE
    WHEN occupancy_class = 'Commercial' THEN CAST(NULL AS INT)
    ELSE
      CASE
        WHEN r_hh < 0.25 AND sqft < 1500 THEN 1
        WHEN r_hh < 0.55                  THEN 2
        WHEN r_hh < 0.80                  THEN 3
        WHEN r_hh < 0.93                  THEN 4
        WHEN r_hh < 0.98                  THEN 5
        ELSE                                   6
      END
  END                                                              AS household_size,

  CASE
    WHEN occupancy_class = 'Commercial' THEN CAST(NULL AS STRING)
    WHEN year_built < 1960 THEN
      CASE
        WHEN r_age < 0.10 THEN '18_34'
        WHEN r_age < 0.25 THEN '35_44'
        WHEN r_age < 0.45 THEN '45_54'
        WHEN r_age < 0.70 THEN '55_64'
        ELSE                   '65_plus'
      END
    WHEN year_built > 2000 THEN
      CASE
        WHEN r_age < 0.18 THEN '18_34'
        WHEN r_age < 0.48 THEN '35_44'
        WHEN r_age < 0.74 THEN '45_54'
        WHEN r_age < 0.92 THEN '55_64'
        ELSE                   '65_plus'
      END
    ELSE
      CASE
        WHEN r_age < 0.13 THEN '18_34'
        WHEN r_age < 0.35 THEN '35_44'
        WHEN r_age < 0.58 THEN '45_54'
        WHEN r_age < 0.80 THEN '55_64'
        ELSE                   '65_plus'
      END
  END                                                              AS age_band_hoh,

  CASE
    WHEN r_tract_lang < 0.93 THEN 'EN'
    WHEN r_tract_lang < 0.97 THEN 'ES'
    ELSE                           'OTHER'
  END                                                              AS language_preference,

  CASE
    -- Landlord-hero premises (entity-grain-design.md §5) are always rented —
    -- the whole point of the ownership edge is a party who owns but doesn't
    -- occupy. Checked first so it wins regardless of the sqft/hash draw below.
    WHEN lp.premise_id IS NOT NULL THEN 'rent'
    WHEN occupancy_class = 'Commercial' THEN 'rent'
    WHEN sqft < 1200 AND r_tenure < 0.55 THEN 'rent'
    WHEN sqft < 1800 AND r_tenure < 0.35 THEN 'rent'
    WHEN sqft >= 1800 AND r_tenure < 0.15 THEN 'rent'
    ELSE                                       'own'
  END                                                              AS tenure,

  CASE
    WHEN occupancy_class = 'Commercial' THEN false
    WHEN r_critical < 0.015 + CASE WHEN year_built < 1970 THEN 0.01 ELSE 0 END THEN true
    ELSE false
  END                                                              AS critical_care_flag,

  CASE
    WHEN occupancy_class = 'Commercial' THEN false
    WHEN income_band = 'under_25k' THEN true
    WHEN income_band = '25k_50k' AND CASE
        WHEN r_hh < 0.55 THEN 2 WHEN r_hh < 0.80 THEN 3 WHEN r_hh < 0.93 THEN 4
        WHEN r_hh < 0.98 THEN 5 ELSE 6 END >= 3 THEN true
    ELSE false
  END                                                              AS liheap_eligible,

  -- Customer-since date anchored to as_of_date. Current customers: 1-25 yrs
  -- before as_of. Prior occupants: a historical span ending well before the
  -- fact window (their relationship pre-dates 2017).
  CASE
    WHEN is_prior_occupant
      THEN DATE_SUB(DATE'2017-01-01', CAST(365 + r_since * 365 * 12 AS INT))
    ELSE DATE_SUB(DATE'${as_of_date}', CAST(365 + r_since * 365 * 24 AS INT))
  END                                                              AS customer_since_date,

  is_prior_occupant,

  current_timestamp()                                              AS _ingested_at
FROM with_income wi
LEFT JOIN raw_landlord_portfolio lp ON lp.premise_id = wi.premise_id;
