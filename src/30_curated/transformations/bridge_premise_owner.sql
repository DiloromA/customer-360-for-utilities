-- Ownership edge — CIM-ish, deliberately sparse, dated, account-backed
-- owner->premise edge. NOT a separate owner
-- dimension: an owner is always a party (dim_customer), because the utility
-- only knows owners who bill somewhere. Populated for exactly the three
-- cases a real utility can observe:
--   • owner_pays        — a multi-site chain's consolidated-billing account
--     holder owns the site outright (derived from dim_account.account_group
--     ='consolidated_billing'; no new raw data).
--   • owner_occupied    — the current customer owns the home they live in
--     (derived from bridge_account_premise.tenancy_type='owner_occupied';
--     no new raw data).
--   • landlord_agreement — the one case where the owner is NOT the current
--     account holder: the single landlord-hero party from
--     raw_landlord_portfolio, who owns 10 premises a tenant currently pays
--     for (new raw data — see that file, and its vacancy episode threaded
--     through raw_customer.sql / raw_customer_account.sql /
--     raw_account_premise_link.sql).
-- For one showcase premise, the original landlord edge is closed
-- (is_current=false, owns_to set) and a successor edge is open
-- (is_current=true), modeling a property sale.
--
-- display_name is a small, deliberately sparse readable label for the two
-- "hero" rows the demo narrative calls for: the landlord portfolio and
-- one representative chain. NULL everywhere else — dim_customer itself
-- carries no name field by design (profile-only, no PII), so this is the one
-- place a readable label lives.
--
-- PK: premise_owner_link_id uses owns_from in the hash to handle the
-- divestiture case where two rows share the same (party_id, premise_id, basis).

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
COMMENT 'Ownership edge — sparse, dated, account-backed owner->premise edge. basis: owner_pays (multi-site chain consolidated billing) | owner_occupied (account holder owns the home they live in) | landlord_agreement (tenant pays, owner on file for reversion). Not a separate owner dimension — party_id is always a dim_customer party. display_name is a readable label populated only for a few showcase parties; NULL elsewhere. owns_to and is_current are live values: one landlord_agreement row is closed (is_current=false, owns_to set) and its successor row is open (is_current=true), representing a property sale. PK: premise_owner_link_id. FK: party_id -> dim_customer.customer_id, premise_id -> dim_premise.premise_id.'
AS

WITH owner_pays AS (
  SELECT
    a.customer_id      AS party_id,
    acp.premise_id,
    'owner_pays'        AS basis,
    a.account_opened_date AS owns_from,
    CAST(NULL AS DATE)  AS owns_to,
    true                AS is_current
  FROM dim_account a
  JOIN account_current_premise acp ON acp.account_id = a.account_id
  WHERE a.account_group = 'consolidated_billing'
),

owner_occupied AS (
  SELECT
    b.customer_id      AS party_id,
    b.premise_id,
    'owner_occupied'    AS basis,
    b.link_start_date  AS owns_from,
    CAST(NULL AS DATE)  AS owns_to,
    true                AS is_current
  FROM bridge_account_premise b
  WHERE b.tenancy_type = 'owner_occupied' AND b.is_current
),

-- The divestiture showcase premise: its landlord edge is closed and a new
-- buyer edge is opened at divestiture_date. All other landlord_agreement
-- premises get a single open-ended row (owns_to=NULL, is_current=true).
landlord_agreement AS (
  -- Non-divestiture landlord premises: open-ended ownership.
  SELECT
    abs(xxhash64(lp.owner_customer_id)) AS party_id,
    abs(xxhash64(lp.premise_id))        AS premise_id,
    'landlord_agreement'                AS basis,
    DATE'2010-01-01'                    AS owns_from,
    CAST(NULL AS DATE)                  AS owns_to,
    true                                AS is_current
  FROM ${customer_master_schema}.raw_landlord_portfolio lp
  WHERE NOT lp.is_divestiture_showcase
  UNION ALL
  -- Divestiture showcase: the original landlord edge (closed at divestiture_date).
  SELECT
    abs(xxhash64(lp.owner_customer_id)) AS party_id,
    abs(xxhash64(lp.premise_id))        AS premise_id,
    'landlord_agreement'                AS basis,
    DATE'2010-01-01'                    AS owns_from,
    lp.divestiture_date                 AS owns_to,
    false                               AS is_current
  FROM ${customer_master_schema}.raw_landlord_portfolio lp
  WHERE lp.is_divestiture_showcase
  UNION ALL
  -- Divestiture showcase: the buyer's successor edge (open from divestiture_date).
  SELECT
    -- Hash the md5 natural key, matching how raw_customer mints this party and
    -- how dim_customer derives customer_id (xxhash64 of the md5 string). Hashing
    -- the bare literal would produce a party_id absent from dim_customer and
    -- break fk_bpo_party.
    abs(xxhash64(md5('SUMMIT_BUYER_PARTY'))) AS party_id,
    abs(xxhash64(lp.premise_id))        AS premise_id,
    'landlord_agreement'                AS basis,
    lp.divestiture_date                 AS owns_from,
    CAST(NULL AS DATE)                  AS owns_to,
    true                                AS is_current
  FROM ${customer_master_schema}.raw_landlord_portfolio lp
  WHERE lp.is_divestiture_showcase
),

-- Hero display names: the landlord portfolio always gets one; ONE representative
-- owner_pays chain — the biggest by premise count, deterministic tie-break on
-- party_id — gets the other, so most chains stay unnamed (display_name NULL).
hero_chain AS (
  SELECT party_id
  FROM owner_pays
  GROUP BY party_id
  ORDER BY COUNT(*) DESC, party_id
  LIMIT 1
),

all_edges AS (
  SELECT party_id, premise_id, basis, owns_from, owns_to, is_current FROM owner_pays
  UNION ALL
  SELECT party_id, premise_id, basis, owns_from, owns_to, is_current FROM owner_occupied
  UNION ALL
  SELECT party_id, premise_id, basis, owns_from, owns_to, is_current FROM landlord_agreement
)

SELECT
  -- PK includes owns_from so two rows for the same (party, premise, basis) at
  -- different windows (divestiture case) produce distinct surrogate keys.
  abs(xxhash64(CONCAT(
    CAST(u.party_id   AS STRING), '_',
    CAST(u.premise_id AS STRING), '_',
    u.basis, '_',
    CAST(u.owns_from  AS STRING)
  )))                    AS premise_owner_link_id,
  u.party_id,
  u.premise_id,
  u.basis,
  CASE
    WHEN u.basis = 'landlord_agreement'
         AND u.party_id = abs(xxhash64(md5('LANDLORD_HERO_PARTY')))
                                                                 THEN 'Summit Residential Holdings'
    WHEN u.basis = 'landlord_agreement'
         AND u.party_id = abs(xxhash64(md5('SUMMIT_BUYER_PARTY'))) THEN 'Summit Buyer LLC'
    WHEN u.basis = 'owner_pays' AND u.party_id = hc.party_id    THEN 'Sunbelt Burger Co.'
    ELSE NULL
  END                    AS display_name,
  u.owns_from,
  u.owns_to,
  u.is_current,
  current_timestamp()    AS _ingested_at
FROM all_edges u
LEFT JOIN hero_chain hc ON true;
