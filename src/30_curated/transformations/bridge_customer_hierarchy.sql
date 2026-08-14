-- Customer Hierarchy Bridge — two-tier commercial_parent → commercial_subsidiary
-- relationships. ~30% of commercial chains are promoted to named parent organisations.
--
-- GRAIN: one row per (parent, child) pair. Every chain uses a single open-ended
-- window (valid_from = 1900-01-01, valid_to = NULL, is_current = true): these are
-- established corporate structures with no modelled splits or mergers. The window
-- columns exist so a dated restructuring can be represented without a schema change.
--
-- KEYS:
--   hierarchy_link_id  — deterministic md5 surrogate for the (parent, child) pair.
--   parent_customer_id — BIGINT key matching dim_customer.customer_id.
--   child_customer_id  — BIGINT key matching dim_customer.customer_id.
--
-- DESIGN RULES:
--   • Two tiers only (parent → subsidiary). No deeper nesting; depth > 1 is
--     rejected by the contract assertions.
--   • One active parent per child (no overlapping windows for one child).
--   • commercial_parent rows are premise-less parties (premise_id = NULL in
--     dim_customer / raw_customer).
--   • Direct scope = facts whose customer_id equals the selected customer.
--   • Portfolio scope = selected customer + every descendant connected by a
--     'subsidiary' edge valid at the fact/as-of date.
--
-- ══════════════════════════════════════════════════════════════════════════════
-- PORTFOLIO RESOLVER PATTERN
-- ══════════════════════════════════════════════════════════════════════════════
-- Use the following CTE pattern wherever a query needs to resolve a customer's
-- full portfolio (direct facts + all subsidiary facts) as of a given date:
--
--   WITH portfolio AS (
--     -- Direct member: the root customer itself.
--     SELECT
--       :root_customer_id                       AS root_customer_id,
--       :root_customer_id                       AS member_customer_id,
--       DATE'1900-01-01'                        AS valid_from,
--       CAST(NULL AS DATE)                      AS valid_to,
--       0                                       AS depth
--     UNION ALL
--     -- Subsidiaries of the root (depth = 1).  Extend this UNION if a third
--     -- tier is ever introduced.
--     SELECT
--       :root_customer_id                       AS root_customer_id,
--       bch.child_customer_id                   AS member_customer_id,
--       bch.valid_from,
--       bch.valid_to,
--       1                                       AS depth
--     FROM {{catalog}}.{{schema}}.bridge_customer_hierarchy bch
--     WHERE bch.parent_customer_id = :root_customer_id
--       AND bch.valid_from          <= :as_of_date
--       AND COALESCE(bch.valid_to, '9999-12-31') > :as_of_date
--   )
--   SELECT f.*
--   FROM some_fact_table f
--   JOIN portfolio p ON p.member_customer_id = f.customer_id;
--
-- Columns resolved:
--   root_customer_id    — the top of the hierarchy requested
--   member_customer_id  — every customer whose facts belong to the portfolio
--   valid_from / valid_to — interval during which the membership is active
--   depth               — 0 = the root itself, 1 = direct subsidiary
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REFRESH MATERIALIZED VIEW bridge_customer_hierarchy (
  hierarchy_link_id   STRING  NOT NULL PRIMARY KEY RELY,
  parent_customer_id  BIGINT  NOT NULL,
  child_customer_id   BIGINT  NOT NULL,
  relationship_type   STRING,   -- 'subsidiary'; extensible for franchise/JV/managed-by
  valid_from          DATE    NOT NULL,
  valid_to            DATE,     -- NULL = still current / open-ended
  is_current          BOOLEAN NOT NULL,
  CONSTRAINT fk_bch_parent FOREIGN KEY (parent_customer_id) REFERENCES dim_customer (customer_id) RELY,
  CONSTRAINT fk_bch_child  FOREIGN KEY (child_customer_id)  REFERENCES dim_customer (customer_id) RELY
)
COMMENT 'Customer hierarchy bridge — one row per (parent, child) commercial-party relationship. A subset of multi-site chains are promoted to named parent organisations: each gets a premise-less commercial_parent customer while its existing chain customer becomes commercial_subsidiary. valid_from/valid_to record the relationship window (half-open; valid_to NULL = currently active). is_current=true where valid_to IS NULL. FK both sides into dim_customer. See the file header for the reusable portfolio resolver CTE pattern.'
AS

SELECT
  -- Deterministic surrogate: md5 of the concatenated raw customer_id strings
  md5(CONCAT(parent_customer_id_str, '_', child_customer_id_str)) AS hierarchy_link_id,
  -- Convert raw md5 string keys to the same BIGINT formula used by dim_customer
  abs(xxhash64(parent_customer_id_str))  AS parent_customer_id,
  abs(xxhash64(child_customer_id_str))   AS child_customer_id,
  'subsidiary'                           AS relationship_type,
  DATE'1900-01-01'                       AS valid_from,
  CAST(NULL AS DATE)                     AS valid_to,
  true                                   AS is_current
FROM (
  SELECT DISTINCT
    md5(CONCAT(chain_key, '_parent_customer')) AS parent_customer_id_str,
    md5(CONCAT(chain_key, '_customer'))        AS child_customer_id_str
  FROM ${customer_master_schema}.raw_premise_customer_map
  WHERE chain_key IS NOT NULL
    AND is_hero_chain = true
) pairs;
