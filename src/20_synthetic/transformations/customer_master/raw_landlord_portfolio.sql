-- Landlord portfolio (internal helper) — the single source of the
-- landlord-hero synthetic narrative: ONE
-- named landlord/portfolio party owning exactly 10 existing residential
-- premises, including one historical vacancy where the landlord itself was
-- briefly the billing party (basis='landlord_agreement' in the curated
-- bridge_premise_owner edge — see that file for the owner_pays/owner_occupied
-- edges, which are derived straight from already-curated tables and need no
-- new raw data).
--
-- Deliberately additive: reads only raw_premises (not raw_premise_customer_map
-- or raw_customer) so it slots into the DAG ahead of raw_customer with zero
-- risk of a cycle, and does not touch the current-customer assignment those
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
COMMENT 'Landlord portfolio (internal helper) — the 10 residential premises owned by the single landlord-hero party, plus which ones carry the showcase episodes. rn=1 is the vacancy showcase (landlord was briefly the billing party). rn=2 is the divestiture showcase (the property was sold; bridge_premise_owner closes the landlord edge at divestiture_date and opens a successor edge for the buyer). Read by raw_customer, raw_customer_account/raw_account_premise_link (vacancy episode), and bridge_premise_owner (curated, the landlord_agreement edges). PK: premise_id. FK: premise_id -> premises.'
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
  rn = 2                     AS is_divestiture_showcase,
  -- Divestiture (property sale) date. Derived from ${as_of_date} minus
  -- ${history_months}, NOT a hardcoded year: a literal anchor drifts past
  -- as_of_date whenever the window moves, which would leave the demo showing
  -- a sale in its own future. Placed in the middle third of the display
  -- window so both the closed landlord edge and the buyer's successor edge
  -- are visible inside the window.
  DATE_ADD(
    DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
    CAST(
      DATEDIFF(
        DATE'${as_of_date}',
        DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
      ) / 3
      + abs(xxhash64(premise_id, 'divestiture_date', ${random_seed}))
        % CAST(
            DATEDIFF(
              DATE'${as_of_date}',
              DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
            ) / 3 AS INT)
      AS INT)
  )                          AS divestiture_date,
  current_timestamp()        AS _ingested_at
FROM pool
WHERE rn <= 10;
