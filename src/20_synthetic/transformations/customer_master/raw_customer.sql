-- Customer — a distinct customer PARTY (CIM Customer), decoupled from premise.
-- Customer is deliberately not 1:1 with premise.
--   • Residential premises  -> one household customer each (the customer IS the
--     customer; we do not model landlord-holds-the-meter — see design).
--   • Commercial premises   -> ~20% belong to a MULTI-SITE CHAIN customer (one
--     customer owns several sites in a county); the rest are standalone.
--   • ~15% of residential premises additionally have a PRIOR-CUSTOMER (closed tenancy)
--     whose tenancy ended before the current customer's move-in (pre-window for
--     most, in-window for relocations and ~40% of ordinary turnover — see
--     design +, temporal-realism).
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
    customer_type IN ('residential','commercial_standalone','commercial_chain',
                      'commercial_subsidiary','commercial_parent','landlord_portfolio')
  ),
  CONSTRAINT valid_archetype EXPECT (
    archetype IN ('efficient_engaged','comfortable_indifferent','cost_stressed',
                  'tech_forward','inefficient_unaware','senior_fixed_income')
    OR customer_type IN ('commercial_parent','landlord_portfolio')
  )
)
COMMENT 'Customer — a distinct customer party (CIM Customer), decoupled from premise. Residential premises map 1:1 to a household customer; ~20% of commercial premises are grouped under a multi-site chain customer (one customer owns several sites); ~15% of residential premises also have a prior-customer whose tenancy ended before the current customer''s move-in. A subset of chains are promoted to the two-tier hierarchy: their chain customer becomes commercial_subsidiary and a new premise-less commercial_parent party is minted (customer_name holds the fictional org label); the rest remain commercial_chain. The premise relationship lives in customer_account / account_premise_link / service_agreement, not here. n_premises_owned > 1 only for chains/subsidiaries/parents. INTERNAL: the archetype column drives downstream synth behaviour and must be dropped before exposing to demo personas. PK: customer_id.'
AS

-- Collapse the shared assignment map to distinct customers (chains have many
-- premises -> one customer). The anchor premise (MIN premise_id) supplies
-- representative demographic attributes.
-- hero_chain_ordinal: for hero-chain subsidiaries, carry the ordinal so the
-- commercial_parent row can map to a hero org name.
WITH cust_anchor AS (
  SELECT
    current_customer_id                                              AS customer_id,
    customer_type,
    chain_key,
    MIN(premise_id)                                                  AS anchor_premise_id,
    COUNT(*)                                                         AS n_premises_owned,
    -- hero_chain_ordinal is the same for every premise in a given chain
    MAX(hero_chain_ordinal)                                          AS hero_chain_ordinal
  FROM raw_premise_customer_map
  GROUP BY current_customer_id, customer_type, chain_key
),

-- Current customers, joined to their anchor premise for demographics.
current_customers AS (
  SELECT
    ca.customer_id,
    ca.anchor_premise_id AS premise_id,
    ca.customer_type,
    ca.n_premises_owned,
    ca.chain_key,
    ca.hero_chain_ordinal,
    false             AS is_prior_customer,
    p.occupancy_class,
    p.sqft,
    p.census_tract,
    p.year_built
  FROM cust_anchor ca
  JOIN raw_premises p ON ca.anchor_premise_id = p.premise_id
),

-- Prior-customer customers (residential turnover). Distinct customer_id via the
-- '_prior_customer' salt so their archetype/demographic draws differ from the
-- current customer of the same premise.
--
-- EXCLUDES a relocation's mover identity: a mover's
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
    m.prior_customer_id    AS customer_id,
    m.premise_id,
    'residential'          AS customer_type,
    1                      AS n_premises_owned,
    CAST(NULL AS STRING)   AS chain_key,
    CAST(NULL AS INT)      AS hero_chain_ordinal,
    true                   AS is_prior_customer,
    p.occupancy_class,
    p.sqft,
    p.census_tract,
    p.year_built
  FROM raw_premise_customer_map m
  JOIN raw_premises p ON m.premise_id = p.premise_id
  WHERE m.has_prior_customer
    AND NOT EXISTS (
      SELECT 1 FROM raw_premise_customer_map m2
      WHERE m2.current_customer_id = m.prior_customer_id
    )
),

-- The landlord-hero party — a single new
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
    CAST(NULL AS STRING)                          AS chain_key,
    CAST(NULL AS INT)                             AS hero_chain_ordinal,
    false                                          AS is_prior_customer,
    'Commercial'                                   AS occupancy_class,
    CAST(NULL AS INT)                             AS sqft,
    CAST(NULL AS STRING)                          AS census_tract,
    CAST(NULL AS INT)                             AS year_built
  UNION ALL
  -- The divestiture BUYER party. bridge_premise_owner opens a successor
  -- ownership edge for this party when the landlord sells its rn=2 premise, and
  -- that edge carries a real FK into dim_customer — so the party must exist
  -- here as a customer row, not only as a hash literal in the curated bridge.
  -- Same premise-less landlord_portfolio shape as the landlord above, so every
  -- "commercial gets no household demographics" NULL-guard applies for free.
  SELECT
    md5('SUMMIT_BUYER_PARTY')                     AS customer_id,
    CAST(NULL AS STRING)                          AS premise_id,
    'landlord_portfolio'                          AS customer_type,
    1                                              AS n_premises_owned,
    CAST(NULL AS STRING)                          AS chain_key,
    CAST(NULL AS INT)                             AS hero_chain_ordinal,
    false                                          AS is_prior_customer,
    'Commercial'                                   AS occupancy_class,
    CAST(NULL AS INT)                             AS sqft,
    CAST(NULL AS STRING)                          AS census_tract,
    CAST(NULL AS INT)                             AS year_built
),

-- commercial_parent parties — one per hero chain. Each is a premise-
-- less organisation holding its subsidiary's premises in portfolio.
--
-- Hero org names — generic and geography-neutral:
--   ordinal 0 → Meridian Hospitality Group
--   ordinal 1 → Cornerstone Retail Corp
--   ordinal 2 → Pinnacle Services Inc
-- Long-tail heroes (ordinal wraps via hash % 3) reuse the same three names;
-- that is fine because they are distinct chains with distinct customer_ids.
parent_customers AS (
  SELECT DISTINCT
    md5(CONCAT(chain_key, '_parent_customer'))   AS customer_id,
    CAST(NULL AS STRING)                         AS premise_id,
    'commercial_parent'                          AS customer_type,
    -- n_premises_owned for the parent = the count of premises across all
    -- subsidiary sites for this chain. COUNT(*) OVER (PARTITION BY chain_key)
    -- over the hero-filtered set is exact: the hero-chain hash filter (WHERE
    -- below) is deterministic on chain_key, so it keeps or drops a chain's
    -- rows as a whole, never partially — the window therefore counts every
    -- premise of a surviving chain. (Was a correlated per-row subquery that
    -- re-scanned the full map table for each row — O(chains x rows) at scale.)
    COUNT(*) OVER (PARTITION BY chain_key)       AS n_premises_owned,
    chain_key,
    hero_chain_ordinal,
    false                                        AS is_prior_customer,
    'Commercial'                                 AS occupancy_class,
    CAST(NULL AS INT)                            AS sqft,
    CAST(NULL AS STRING)                         AS census_tract,
    CAST(NULL AS INT)                            AS year_built
  FROM raw_premise_customer_map m
  WHERE chain_key IS NOT NULL
    AND abs(xxhash64(chain_key, 'is_hero_chain', ${random_seed})) % 10 < 3
),

all_customers AS (
  SELECT * FROM current_customers
  UNION ALL
  SELECT * FROM prior_customers
  UNION ALL
  SELECT * FROM landlord_parties
  UNION ALL
  SELECT * FROM parent_customers
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
-- Hero org name look-up: commercial_parent rows get a fictional org label
-- based on their hero_chain_ordinal. All other customer types get NULL.
-- No real brand names; no geographic references.
customer_names AS (
  SELECT
    customer_id,
    CASE
      WHEN customer_type = 'commercial_parent' THEN
        CASE hero_chain_ordinal
          WHEN 0 THEN 'Meridian Hospitality Group'
          WHEN 1 THEN 'Cornerstone Retail Corp'
          WHEN 2 THEN 'Pinnacle Services Inc'
          ELSE        CAST(NULL AS STRING)
        END
      ELSE CAST(NULL AS STRING)
    END AS customer_name
  FROM all_customers
),

with_income AS (
  SELECT
    *,
    CASE
      -- sqft is NULL for premise-less parties (commercial_parent, landlord_portfolio);
      -- treat as COALESCE 0 so the formula degrades to the income-only signal.
      WHEN r_tract_income * 0.75 + CAST(LEAST(COALESCE(sqft, 0), 5000) AS DOUBLE) / 5000.0 * 0.25 < 0.18 THEN 'under_25k'
      WHEN r_tract_income * 0.75 + CAST(LEAST(COALESCE(sqft, 0), 5000) AS DOUBLE) / 5000.0 * 0.25 < 0.42 THEN '25k_50k'
      WHEN r_tract_income * 0.75 + CAST(LEAST(COALESCE(sqft, 0), 5000) AS DOUBLE) / 5000.0 * 0.25 < 0.70 THEN '50k_100k'
      WHEN r_tract_income * 0.75 + CAST(LEAST(COALESCE(sqft, 0), 5000) AS DOUBLE) / 5000.0 * 0.25 < 0.90 THEN '100k_200k'
      ELSE                                                                                                     'over_200k'
    END AS income_band
  FROM draws
)

SELECT
  wi.customer_id,
  customer_type,
  n_premises_owned,
  cn.customer_name,

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
    -- Landlord-hero premises are always rented —
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
  -- before as_of. Prior customers: a historical span ending well before the
  -- fact window (their relationship pre-dates 2017).
  CASE
    WHEN is_prior_customer
      THEN DATE_SUB(DATE'2017-01-01', CAST(365 + r_since * 365 * 12 AS INT))
    ELSE DATE_SUB(DATE'${as_of_date}', CAST(365 + r_since * 365 * 24 AS INT))
  END                                                              AS customer_since_date,

  is_prior_customer,

  current_timestamp()                                              AS _ingested_at
FROM with_income wi
LEFT JOIN raw_landlord_portfolio lp ON lp.premise_id = wi.premise_id
LEFT JOIN customer_names cn ON cn.customer_id = wi.customer_id;
