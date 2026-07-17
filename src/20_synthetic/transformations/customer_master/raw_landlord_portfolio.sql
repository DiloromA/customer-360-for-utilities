-- Landlord portfolio (internal helper) — the single source of the
-- landlord-hero synthetic narrative (entity-grain-design.md §4.2/§5): ONE
-- named landlord/portfolio party owning exactly 10 existing residential
-- premises, including one historical vacancy where the landlord itself was
-- briefly the billing party (basis='landlord_agreement' in the curated
-- bridge_premise_owner edge — see that file for the owner_pays/owner_occupied
-- edges, which are derived straight from already-curated tables and need no
-- new raw data).
--
-- Deliberately additive: reads only raw_premises (not raw_premise_customer_map
-- or raw_customer) so it slots into the DAG ahead of raw_customer with zero
-- risk of a cycle, and does not touch the current-occupant assignment those
-- files already make — it only adds a parallel ownership fact for premises
-- the map is already generating as ordinary residential premises.
--
-- Selection is deterministic top-10 by hash rank (not a % threshold) so the
-- portfolio size is exactly 10 regardless of sample size or re-runs with the
-- same seed. rn = 1 is arbitrarily but deterministically the vacancy showcase.

CREATE OR REFRESH MATERIALIZED VIEW raw_landlord_portfolio (
  CONSTRAINT non_null_premise_id EXPECT (premise_id IS NOT NULL),
  CONSTRAINT non_null_owner_id   EXPECT (owner_customer_id IS NOT NULL)
)
COMMENT 'Landlord portfolio (internal helper) — the 10 residential premises owned by the single landlord-hero party, plus which one carries the historical vacancy-billing episode. Read by raw_customer (creates the landlord party + forces those premises'' occupants to rent), raw_customer_account/raw_account_premise_link (the vacancy episode), and bridge_premise_owner (curated, the landlord_agreement edges). PK: premise_id. FK: premise_id -> premises.'
AS

WITH pool AS (
  SELECT
    premise_id,
    ROW_NUMBER() OVER (ORDER BY abs(xxhash64(premise_id, 'landlord_hero_pick', ${random_seed}))) AS rn
  FROM raw_premises
  WHERE occupancy_class = 'Residential'
)

SELECT
  premise_id,
  md5('LANDLORD_HERO_PARTY') AS owner_customer_id,
  rn = 1                     AS is_vacancy_showcase,
  current_timestamp()        AS _ingested_at
FROM pool
WHERE rn <= 10;
