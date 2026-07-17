-- Premise → Customer assignment map (internal helper). The SINGLE source of
-- the premise→customer decoupling rules, read by customer / customer_account /
-- account_premise_link / service_agreement so the chain-grouping and turnover
-- logic is defined in exactly ONE place (not duplicated across files — cf. the
-- DER-mapping sync hazard).
--
-- One row per premise:
--   • chain_key            non-null for the ~20% of commercial premises grouped
--                          under a multi-site chain customer (≤30 chains/county).
--   • current_customer_id  the party billed for this premise during the fact
--                          window. Residential & standalone-commercial: a
--                          per-premise customer. Chain: the shared chain customer.
--   • has_prior_occupant   ~15% of residential premises; if true, prior_customer_id
--                          is the household that moved out — pre-window for most,
--                          in-window for relocation destinations (see below) and
--                          ~40% of ordinary turnover (temporal-realism §5.2, applied
--                          in account_premise_link.sql's move_in_date generation).
--   • mover_pair_premise_id / relocation_date (temporal-realism §5.1) — a ~5%
--     slice of residential premises are paired into relocations: an "origin"
--     premise (otherwise has_prior_occupant=false) and a "destination"
--     premise (an existing turnover premise) share ONE customer identity — the
--     mover — who closes their link at the origin and opens one at the
--     destination on the same in-window date. mover_pair_premise_id holds the
--     other premise in the pair (symmetric); relocation_date is that shared
--     date, computed once per pair so both sides agree. Consumed by
--     account_premise_link.sql (overrides move_in_date) and
--     customer_account.sql / account_premise_link.sql (carries the mover's
--     account_id across both tenancies).
--
-- Determinism via hash(premise_id, '<purpose>', seed).

CREATE OR REFRESH MATERIALIZED VIEW raw_premise_customer_map (
  CONSTRAINT non_null_premise_id  EXPECT (premise_id IS NOT NULL),
  CONSTRAINT non_null_customer_id EXPECT (current_customer_id IS NOT NULL),
  CONSTRAINT valid_customer_type  EXPECT (
    customer_type IN ('residential','commercial_standalone','commercial_chain')
  )
)
COMMENT 'Internal helper — the single source of the premise→customer assignment (commercial-chain grouping + residential turnover + relocations). One row per premise. Read by customer, customer_account, account_premise_link and service_agreement so the decoupling rules live in one place. current_customer_id is the billed party during the display window; prior_customer_id (when has_prior_occupant) is the household that moved out. mover_pair_premise_id/relocation_date identify the ~5% of premises paired into an in-window relocation: the SAME customer identity is current_customer_id at the destination and prior_customer_id at the origin. PK: premise_id. FK: premise_id -> premises.'
AS

WITH assign AS (
  SELECT
    premise_id,
    occupancy_class,
    county_fips,
    CASE
      WHEN occupancy_class = 'Commercial'
           AND abs(xxhash64(premise_id, 'is_chain', ${random_seed})) % 100 < 20
      THEN md5(CONCAT(county_fips, '_CHAIN_',
                      CAST(abs(xxhash64(premise_id, 'chain_bucket', ${random_seed})) % 30 AS STRING)))
      ELSE CAST(NULL AS STRING)
    END                                                              AS chain_key,
    (occupancy_class <> 'Commercial'
       AND abs(xxhash64(premise_id, 'turnover', ${random_seed})) % 100 < 15) AS has_prior_occupant
  FROM raw_premises
),

-- Relocation pairing (temporal-realism §5.1). Origins are drawn from the
-- ~85% eternal-occupant pool at ~6%; destinations from the ~15% turnover pool
-- at ~33% — both thresholds are sized so each yields roughly 5% of all
-- residential premises, keeping the two pools comparable so the pairing join
-- below uses most of both sides rather than truncating one against a much
-- larger other. Any leftover unpaired candidates on the larger side are
-- simply unused (they keep their unmodified, non-mover behavior).
mover_origins AS (
  SELECT premise_id, ROW_NUMBER() OVER (ORDER BY premise_id) AS rn
  FROM assign
  WHERE occupancy_class <> 'Commercial'
    AND NOT has_prior_occupant
    AND abs(xxhash64(premise_id, 'is_mover_origin', ${random_seed})) % 100 < 6
),
mover_destinations AS (
  SELECT premise_id, ROW_NUMBER() OVER (ORDER BY premise_id) AS rn
  FROM assign
  WHERE occupancy_class <> 'Commercial'
    AND has_prior_occupant
    AND abs(xxhash64(premise_id, 'is_mover_destination', ${random_seed})) % 100 < 33
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

SELECT
  a.premise_id,
  a.occupancy_class,
  a.county_fips,
  a.chain_key,
  CASE
    WHEN a.chain_key IS NOT NULL        THEN md5(CONCAT(a.chain_key, '_customer'))
    WHEN ml.mover_role = 'origin'        THEN md5(CONCAT(a.premise_id, '_customer_replacement'))
    WHEN ml.mover_role = 'destination'   THEN md5(CONCAT(ml.mover_pair_premise_id, '_customer'))
    ELSE                                      md5(CONCAT(a.premise_id, '_customer'))
  END                                                                AS current_customer_id,
  CASE
    WHEN a.chain_key IS NOT NULL          THEN 'commercial_chain'
    WHEN a.occupancy_class = 'Commercial' THEN 'commercial_standalone'
    ELSE                                       'residential'
  END                                                                AS customer_type,
  (a.has_prior_occupant OR ml.mover_role = 'origin')                  AS has_prior_occupant,
  CASE
    WHEN ml.mover_role = 'origin'  THEN md5(CONCAT(a.premise_id, '_customer'))
    WHEN a.has_prior_occupant     THEN md5(CONCAT(a.premise_id, '_prior_customer'))
    ELSE                                CAST(NULL AS STRING)
  END                                                                AS prior_customer_id,
  ml.mover_pair_premise_id,
  ml.mover_role,
  ml.relocation_date,
  current_timestamp()                                                AS _ingested_at
FROM assign a
LEFT JOIN mover_lookup ml ON ml.premise_id = a.premise_id;
