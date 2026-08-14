-- Premise → Customer assignment map (internal helper). The SINGLE source of
-- the premise→customer decoupling rules, read by customer / customer_account /
-- account_premise_link / service_agreement so the chain-grouping and turnover
-- logic is defined in exactly ONE place (not duplicated across files — cf. the
-- DER-mapping sync hazard).
--
-- One row per premise:
--   • chain_key            non-null for commercial premises grouped under a
--                          multi-site chain customer. Chains are formed by
--                          explicit seed+neighbour assignment (deterministic,
--                          guaranteed at any scale).
--   • current_customer_id  the party billed for this premise during the fact
--                          window. Residential & standalone-commercial: a
--                          per-premise customer. Chain: the shared chain customer.
--                          Second-home secondary: the primary household's customer.
--   • has_prior_customer   ~15% of residential premises; if true, prior_customer_id
--                          is the household that moved out — pre-window for most,
--                          in-window for relocation destinations (see below) and
--                          ~40% of ordinary turnover (temporal-realism, applied
--                          in account_premise_link.sql's move_in_date generation).
--   • mover_pair_premise_id / relocation_date — a ~5%
--     slice of residential premises are paired into relocations: an "origin"
--     premise (otherwise has_prior_customer=false) and a "destination"
--     premise (an existing turnover premise) share ONE customer identity — the
--     mover — who closes their link at the origin and opens one at the
--     destination on the same in-window date. mover_pair_premise_id holds the
--     other premise in the pair (symmetric); relocation_date is that shared
--     date, computed once per pair so both sides agree. Consumed by
--     account_premise_link.sql (overrides move_in_date) and
--     customer_account.sql / account_premise_link.sql (carries the mover's
--     account_id across both tenancies).
--   • second_home_primary_premise_id  non-null for a secondary premise in a
--     residential second-home pair. The secondary's current_customer_id is
--     overridden to the primary household's customer so one customer holds two
--     simultaneous current premises (customer grain < premise grain).
--
-- Determinism via hash(premise_id, '<purpose>', seed).

CREATE OR REFRESH MATERIALIZED VIEW raw_premise_customer_map (
  CONSTRAINT non_null_premise_id  EXPECT (premise_id IS NOT NULL),
  CONSTRAINT non_null_customer_id EXPECT (current_customer_id IS NOT NULL),
  CONSTRAINT valid_customer_type  EXPECT (
    customer_type IN ('residential','commercial_standalone','commercial_chain','commercial_subsidiary')
  )
)
COMMENT 'Internal helper — the single source of the premise→customer assignment (commercial-chain grouping + residential turnover + relocations + residential second homes). One row per premise. Read by customer, customer_account, account_premise_link and service_agreement so the decoupling rules live in one place. current_customer_id is the billed party during the display window; prior_customer_id (when has_prior_customer) is the household that moved out. mover_pair_premise_id/relocation_date identify the ~5% of premises paired into an in-window relocation. second_home_primary_premise_id is non-null for a second-home secondary — that premise shares its current_customer_id with the primary. is_hero_chain/hero_chain_ordinal: ~30% of chains are promoted to the two-tier hierarchy (commercial_parent → commercial_subsidiary); the rest remain commercial_chain. PK: premise_id. FK: premise_id -> premises.'
AS

-- ── Effective population counts (computed in-SQL so scale self-adjusts) ─────
-- n_chains  = GREATEST(floor, FLOOR(commercial × fraction))
-- n_second  = GREATEST(floor, FLOOR(residential × fraction))
-- These are scalar subqueries materialised once and referenced in the CTEs.

WITH pop_counts AS (
  SELECT
    COUNT(*) FILTER (WHERE occupancy_class = 'Commercial')    AS commercial_count,
    COUNT(*) FILTER (WHERE occupancy_class <> 'Commercial')   AS residential_count
  FROM raw_premises
),
effective_counts AS (
  SELECT
    GREATEST(
      CAST('${n_guaranteed_chains_floor}' AS INT),
      CAST(commercial_count * CAST('${chain_fraction}' AS DOUBLE) AS INT)
    )                                                          AS n_chains,
    GREATEST(
      CAST('${n_second_homes_floor}' AS INT),
      CAST(residential_count * CAST('${second_home_fraction}' AS DOUBLE) AS INT)
    )                                                          AS n_second_homes
  FROM pop_counts
),

-- ── Base turnover flags (all premises) ──────────────────────────────────────
assign_base AS (
  SELECT
    premise_id,
    occupancy_class,
    county_fips,
    (occupancy_class <> 'Commercial'
       AND abs(xxhash64(premise_id, 'turnover', ${random_seed})) % 100 < 15) AS has_prior_customer
  FROM raw_premises
),

-- ── Case A: explicit commercial chain seeds + neighbour assignment ───────────
--
-- 1. Rank all commercial premises by a stable hash.
-- 2. The first n_chains ranks are "seeds"; each seed s claims k_s neighbours
--    (k_s ∈ {2,3,4} deterministically from the seed's premise_id).
-- 3. Assign every claimed premise the same chain_key = seed_rank.
-- 4. Unclaimed commercial premises → chain_key = NULL (standalone).

commercial_ranked AS (
  SELECT
    premise_id,
    county_fips,
    ROW_NUMBER() OVER (
      ORDER BY abs(xxhash64(premise_id, 'chain_rank', ${random_seed}))
    )                                                          AS cr
  FROM assign_base
  WHERE occupancy_class = 'Commercial'
),
chain_seeds AS (
  -- Seeds: first n_chains by cr.
  -- k_s = 2 + (hash % 3) ∈ {2,3,4}; clamped so we don't overflow the pool.
  SELECT
    s.cr                                                       AS seed_cr,
    s.premise_id                                               AS seed_premise_id,
    s.county_fips,
    CAST(2 + abs(xxhash64(s.premise_id, 'chain_size', ${random_seed})) % 3 AS INT) AS k
  FROM commercial_ranked s
  CROSS JOIN effective_counts ec
  WHERE s.cr <= ec.n_chains
),
-- Expand each seed into its block of [seed_cr, seed_cr + k - 1].
-- If the block overlaps the next seed's range we just let it: the LEFT JOIN
-- below assigns each premise to the LOWEST seed_cr that claims it.
chain_blocks AS (
  SELECT seed_cr, seed_premise_id, county_fips, k,
         seed_cr + k - 1 AS block_end_cr
  FROM chain_seeds
),
-- Assign commercial premises to chain groups.
-- A premise is claimed if its cr falls within any seed's block.
-- Tie-break: lowest seed_cr wins (ensures no premise is double-assigned).
-- chain_key and all hero logic are keyed purely on claimed_by_seed_cr.
commercial_chain_assignment AS (
  SELECT
    cr.premise_id,
    MIN(cb.seed_cr) AS claimed_by_seed_cr
  FROM commercial_ranked cr
  LEFT JOIN chain_blocks cb
    ON cr.cr BETWEEN cb.seed_cr AND cb.block_end_cr
  GROUP BY cr.premise_id
),

-- ── Case B: residential second-home pairing ──────────────────────────────────
--
-- Eligible: residential premises that are NOT already special:
--   • not a mover origin or destination (selected deterministically below)
--   • not in raw_landlord_portfolio
-- We check mover eligibility via the same hash thresholds used below.

-- Relocation pairing — computed early so the
-- second-home pool can anti-join against both sides.
mover_origins_ids AS (
  SELECT premise_id
  FROM assign_base
  WHERE occupancy_class <> 'Commercial'
    AND NOT has_prior_customer
    AND abs(xxhash64(premise_id, 'is_mover_origin', ${random_seed})) % 100 < 6
),
mover_destinations_ids AS (
  SELECT premise_id
  FROM assign_base
  WHERE occupancy_class <> 'Commercial'
    AND has_prior_customer
    AND abs(xxhash64(premise_id, 'is_mover_destination', ${random_seed})) % 100 < 33
),
landlord_premises AS (
  SELECT premise_id FROM raw_landlord_portfolio
),

-- Eligible residential pool: not a mover, not a landlord-portfolio premise.
second_home_eligible AS (
  SELECT
    ab.premise_id,
    ROW_NUMBER() OVER (
      ORDER BY abs(xxhash64(ab.premise_id, 'second_home_primary', ${random_seed}))
    )                                                          AS sh_rank
  FROM assign_base ab
  WHERE ab.occupancy_class <> 'Commercial'
    AND NOT EXISTS (SELECT 1 FROM mover_origins_ids mo WHERE mo.premise_id = ab.premise_id)
    AND NOT EXISTS (SELECT 1 FROM mover_destinations_ids md WHERE md.premise_id = ab.premise_id)
    AND NOT EXISTS (SELECT 1 FROM landlord_premises lp WHERE lp.premise_id = ab.premise_id)
),

-- Primaries: top n_second_homes by sh_rank.
-- Secondaries: the next n_second_homes by sh_rank (never the same as a primary).
-- A premise is either primary or secondary, never both.
second_home_primaries AS (
  SELECT she.premise_id, she.sh_rank
  FROM second_home_eligible she
  CROSS JOIN effective_counts ec
  WHERE she.sh_rank <= ec.n_second_homes
),
second_home_secondaries AS (
  SELECT she.premise_id, she.sh_rank
  FROM second_home_eligible she
  CROSS JOIN effective_counts ec
  WHERE she.sh_rank > ec.n_second_homes
    AND she.sh_rank <= ec.n_second_homes * 2
),
-- Pair primary rank 1 → secondary rank (n_second_homes+1), etc.
second_home_pairs AS (
  SELECT
    p.premise_id AS primary_premise_id,
    s.premise_id AS secondary_premise_id
  FROM second_home_primaries p
  JOIN second_home_secondaries s
    ON s.sh_rank = p.sh_rank + (SELECT n_second_homes FROM effective_counts)
),

-- ── Relocation pairing ──────────────────────────────
mover_origins AS (
  SELECT premise_id, ROW_NUMBER() OVER (ORDER BY premise_id) AS rn
  FROM mover_origins_ids
),
mover_destinations AS (
  SELECT premise_id, ROW_NUMBER() OVER (ORDER BY premise_id) AS rn
  FROM mover_destinations_ids
),
mover_pairs AS (
  SELECT
    o.premise_id AS origin_premise_id,
    d.premise_id AS destination_premise_id,
    -- Shared in-window relocation date: computed once per pair (not per
    -- premise) so origin move-out and destination move-in agree exactly.
    DATE_ADD(
      DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
      CAST(abs(xxhash64(o.premise_id, d.premise_id, 'relocation_date', ${random_seed}))
           % DATEDIFF(
               DATE'${as_of_date}',
               DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
             ) AS INT)
    )                                                                AS relocation_date
  FROM mover_origins o
  JOIN mover_destinations d ON d.rn = o.rn
),
mover_lookup AS (
  SELECT origin_premise_id AS premise_id, destination_premise_id AS mover_pair_premise_id,
         'origin' AS mover_role, relocation_date
  FROM mover_pairs
  UNION ALL
  SELECT destination_premise_id AS premise_id, origin_premise_id AS mover_pair_premise_id,
         'destination' AS mover_role, relocation_date
  FROM mover_pairs
)

-- ── Final assembly ────────────────────────────────────────────────────────────
--
-- Hero-chain flags. ~30% of commercial multi-site chains are promoted
-- to the two-tier hierarchy (commercial_parent → commercial_subsidiary); the
-- remaining ~70% stay as commercial_chain. Hero ordinal (0, 1, or 2) drives
-- the parent org name mapping in raw_customer.sql.
SELECT
  a.premise_id,
  a.occupancy_class,
  a.county_fips,
  -- chain_key: non-null for chain members; keyed on seed ordinal so all
  -- premises in the same seed block share one customer.
  CASE
    WHEN cca.claimed_by_seed_cr IS NOT NULL
    THEN md5(CONCAT('CHAIN_SEED_', CAST(cca.claimed_by_seed_cr AS STRING)))
    ELSE CAST(NULL AS STRING)
  END                                                                AS chain_key,
  -- is_hero_chain: true for ~30% of chain premises (deterministic per chain_key).
  CASE
    WHEN cca.claimed_by_seed_cr IS NOT NULL
         AND abs(xxhash64(
               md5(CONCAT('CHAIN_SEED_', CAST(cca.claimed_by_seed_cr AS STRING))),
               'is_hero_chain', ${random_seed})) % 10 < 3
    THEN true
    ELSE false
  END                                                                AS is_hero_chain,
  -- hero_chain_ordinal: 0, 1, or 2 for hero chains; NULL otherwise.
  CASE
    WHEN cca.claimed_by_seed_cr IS NOT NULL
         AND abs(xxhash64(
               md5(CONCAT('CHAIN_SEED_', CAST(cca.claimed_by_seed_cr AS STRING))),
               'is_hero_chain', ${random_seed})) % 10 < 3
    THEN CAST(
           abs(xxhash64(
               md5(CONCAT('CHAIN_SEED_', CAST(cca.claimed_by_seed_cr AS STRING))),
               'hero_ordinal', ${random_seed})) % 3
           AS INT)
    ELSE CAST(NULL AS INT)
  END                                                                AS hero_chain_ordinal,
  -- current_customer_id:
  --   chain member           → shared chain customer
  --   relocation origin      → replacement customer (prior occupant takes the new id)
  --   relocation destination → mover's existing customer id
  --   second-home secondary  → primary household's customer id
  --   otherwise              → per-premise customer
  CASE
    WHEN cca.claimed_by_seed_cr IS NOT NULL
    THEN md5(CONCAT(
           md5(CONCAT('CHAIN_SEED_', CAST(cca.claimed_by_seed_cr AS STRING))),
           '_customer'))
    WHEN ml.mover_role = 'origin'
    THEN md5(CONCAT(a.premise_id, '_customer_replacement'))
    WHEN ml.mover_role = 'destination'
    THEN md5(CONCAT(ml.mover_pair_premise_id, '_customer'))
    WHEN shp.primary_premise_id IS NOT NULL
    THEN md5(CONCAT(shp.primary_premise_id, '_customer'))
    ELSE md5(CONCAT(a.premise_id, '_customer'))
  END                                                                AS current_customer_id,
  CASE
    WHEN cca.claimed_by_seed_cr IS NOT NULL
         AND abs(xxhash64(
               md5(CONCAT('CHAIN_SEED_', CAST(cca.claimed_by_seed_cr AS STRING))),
               'is_hero_chain', ${random_seed})) % 10 < 3
                                              THEN 'commercial_subsidiary'
    WHEN cca.claimed_by_seed_cr IS NOT NULL  THEN 'commercial_chain'
    WHEN a.occupancy_class = 'Commercial'    THEN 'commercial_standalone'
    ELSE                                          'residential'
  END                                                                AS customer_type,
  (a.has_prior_customer OR ml.mover_role = 'origin')                  AS has_prior_customer,
  CASE
    WHEN ml.mover_role = 'origin'  THEN md5(CONCAT(a.premise_id, '_customer'))
    WHEN a.has_prior_customer     THEN md5(CONCAT(a.premise_id, '_prior_customer'))
    ELSE                                CAST(NULL AS STRING)
  END                                                                AS prior_customer_id,
  ml.mover_pair_premise_id,
  ml.mover_role,
  ml.relocation_date,
  -- second_home_primary_premise_id: non-null for a secondary premise; the
  -- primary's premise_id (so downstream can verify the shared customer).
  shp.primary_premise_id                                             AS second_home_primary_premise_id,
  current_timestamp()                                                AS _ingested_at
FROM assign_base a
LEFT JOIN commercial_chain_assignment cca ON cca.premise_id = a.premise_id
LEFT JOIN mover_lookup ml ON ml.premise_id = a.premise_id
LEFT JOIN second_home_pairs shp ON shp.secondary_premise_id = a.premise_id;
