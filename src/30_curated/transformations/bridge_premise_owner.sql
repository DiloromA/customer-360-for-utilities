-- Ownership edge — CIM-ish, deliberately sparse, dated, account-backed
-- owner->premise edge (entity-grain-design.md §4.2). NOT a separate owner
-- dimension: an owner is always a party (dim_customer), because the utility
-- only knows owners who bill somewhere. Populated for exactly the three
-- cases a real utility can observe:
--   • owner_pays        — a multi-site chain's consolidated-billing account
--     holder owns the site outright (derived from dim_account.account_group
--     ='consolidated_billing'; no new raw data).
--   • owner_occupied    — the current occupant owns the home they live in
--     (derived from bridge_account_premise.occupancy_type='owner_occupied';
--     no new raw data).
--   • landlord_agreement — the one case where the owner is NOT the current
--     account holder: the single landlord-hero party from
--     raw_landlord_portfolio, who owns 10 premises a tenant currently pays
--     for (new raw data — see that file, and its vacancy episode threaded
--     through raw_customer.sql / raw_customer_account.sql /
--     raw_account_premise_link.sql).
-- Every row here is currently owned (is_current=true, owns_to=NULL) —
-- nothing in this synthetic dataset models a property changing hands.
--
-- display_name is a small, deliberately sparse readable label for the two
-- "hero" rows the demo narrative calls for (§5): the landlord portfolio and
-- one representative chain. NULL everywhere else — dim_customer itself
-- carries no name field by design (profile-only, no PII), so this is the one
-- place a readable label lives.

CREATE OR REFRESH MATERIALIZED VIEW bridge_premise_owner (
  premise_owner_link_id BIGINT NOT NULL PRIMARY KEY RELY,
  party_id              BIGINT,
  premise_id            BIGINT,
  basis                 STRING,
  display_name          STRING,
  owns_from             DATE,
  owns_to               DATE,
  is_current            BOOLEAN,
  _ingested_at          TIMESTAMP,
  CONSTRAINT fk_bpo_party   FOREIGN KEY (party_id)   REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_bpo_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id)   NOT ENFORCED RELY
)
COMMENT 'Ownership edge — sparse, dated, account-backed owner->premise edge. basis: owner_pays (multi-site chain consolidated billing) | owner_occupied (account holder owns the home they live in) | landlord_agreement (tenant pays, owner on file for reversion). Not a separate owner dimension — party_id is always a dim_customer party. display_name is a readable label populated only for a few showcase parties; NULL elsewhere. PK: premise_owner_link_id. FK: party_id -> dim_customer.customer_id, premise_id -> dim_premise.premise_id.'
AS

WITH owner_pays AS (
  SELECT
    a.customer_id      AS party_id,
    a.premise_id,
    'owner_pays'        AS basis,
    a.account_opened_date AS owns_from
  FROM dim_account a
  WHERE a.account_group = 'consolidated_billing' AND a.premise_id IS NOT NULL
),

owner_occupied AS (
  SELECT
    b.customer_id      AS party_id,
    b.premise_id,
    'owner_occupied'    AS basis,
    b.link_start_date  AS owns_from
  FROM bridge_account_premise b
  WHERE b.occupancy_type = 'owner_occupied' AND b.is_current
),

landlord_agreement AS (
  SELECT
    abs(xxhash64(lp.owner_customer_id)) AS party_id,
    abs(xxhash64(lp.premise_id))        AS premise_id,
    'landlord_agreement'                AS basis,
    DATE'2010-01-01'                    AS owns_from
  FROM ${customer_master_schema}.raw_landlord_portfolio lp
),

-- Hero display names (§5 "fictional-but-evocative" naming): the landlord
-- portfolio always gets one; ONE representative owner_pays chain — the
-- biggest by premise count, deterministic tie-break on party_id — gets the
-- other, so most chains stay unnamed (display_name NULL).
hero_chain AS (
  SELECT party_id
  FROM owner_pays
  GROUP BY party_id
  ORDER BY COUNT(*) DESC, party_id
  LIMIT 1
),

unioned AS (
  SELECT party_id, premise_id, basis, owns_from FROM owner_pays
  UNION ALL
  SELECT party_id, premise_id, basis, owns_from FROM owner_occupied
  UNION ALL
  SELECT party_id, premise_id, basis, owns_from FROM landlord_agreement
)

SELECT
  abs(xxhash64(CONCAT(CAST(u.party_id AS STRING), '_', CAST(u.premise_id AS STRING), '_', u.basis))) AS premise_owner_link_id,
  u.party_id,
  u.premise_id,
  u.basis,
  CASE
    WHEN u.basis = 'landlord_agreement'                        THEN 'Summit Residential Holdings'
    WHEN u.basis = 'owner_pays' AND u.party_id = hc.party_id    THEN 'Sunbelt Burger Co.'
    ELSE NULL
  END                  AS display_name,
  u.owns_from,
  CAST(NULL AS DATE)   AS owns_to,
  true                 AS is_current,
  current_timestamp()  AS _ingested_at
FROM unioned u
LEFT JOIN hero_chain hc ON true;
