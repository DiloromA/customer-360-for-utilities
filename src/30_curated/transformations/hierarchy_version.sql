-- Flattened hierarchy version — one row per operational service path per
-- validity interval.
--
-- GRAIN: one row per (root_customer_id, customer_id, account_id, premise_id,
-- service_point_id, meter_id, valid_from). Each row answers: "which customer
-- held this account, at which premise, served by which service point and meter,
-- during [valid_from, valid_to)".
--
-- The interval is formed by intersecting five independent validity windows:
--   1. bridge_customer_hierarchy (bch)  — parent-child relationship window
--      gap-filled so that spans without a parent get root_customer_id=customer_id.
--   2. bridge_customer_account (bca)    — customer↔account ownership window.
--   3. bridge_account_premise (bap)     — account↔premise tenancy window.
--   4. dim_service_agreement (sa)       — account×service_point contract window.
--   5. meter_installation (mi)          — meter↔service_point placement window
--      gap-filled so spans without a meter get meter_id=NULL.
--
-- valid_to=NULL means the path is currently active.
-- root_customer_id is the portfolio parent when the customer belongs to a
-- hierarchy during the interval; otherwise equals customer_id.
--
-- KEYS:
--   hierarchy_version_id  BIGINT durable surrogate (xxhash64 of full natural key).
--   root_customer_id      BIGINT FK into dim_customer.
--   customer_id           BIGINT FK into dim_customer.
--   account_id            BIGINT FK into dim_account.
--   premise_id            BIGINT FK into dim_premise.
--   service_point_id      BIGINT FK into dim_service_point.
--   meter_id              BIGINT FK into dim_meter (nullable).

CREATE OR REFRESH MATERIALIZED VIEW hierarchy_version (
  hierarchy_version_id BIGINT NOT NULL PRIMARY KEY RELY,
  root_customer_id     BIGINT NOT NULL,
  customer_id          BIGINT NOT NULL,
  account_id           BIGINT NOT NULL,
  premise_id           BIGINT NOT NULL,
  service_point_id     BIGINT NOT NULL,
  meter_id             BIGINT,
  valid_from           DATE   NOT NULL,
  valid_to             DATE,
  is_current           BOOLEAN NOT NULL,
  _ingested_at         TIMESTAMP,
  CONSTRAINT fk_hv_root_customer  FOREIGN KEY (root_customer_id) REFERENCES dim_customer      (customer_id)      NOT ENFORCED RELY,
  CONSTRAINT fk_hv_customer       FOREIGN KEY (customer_id)      REFERENCES dim_customer      (customer_id)      NOT ENFORCED RELY,
  CONSTRAINT fk_hv_account        FOREIGN KEY (account_id)       REFERENCES dim_account       (account_id)       NOT ENFORCED RELY,
  CONSTRAINT fk_hv_premise        FOREIGN KEY (premise_id)       REFERENCES dim_premise       (premise_id)       NOT ENFORCED RELY,
  CONSTRAINT fk_hv_service_point  FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY
)
COMMENT 'Flattened hierarchy version — one row per operational service path per validity interval. Each row answers "which customer held this account, at which premise, served by which service point and meter, during [valid_from, valid_to)". valid_to NULL = currently active. root_customer_id is the portfolio parent when the customer belongs to a hierarchy, otherwise equals customer_id. Resolve a point-in-time path with: valid_from <= :date AND (valid_to IS NULL OR :date < valid_to). PK: hierarchy_version_id. FK: root_customer_id/customer_id -> dim_customer, account_id -> dim_account, premise_id -> dim_premise, service_point_id -> dim_service_point.'
AS

WITH

-- ── 1. Gap-fill bridge_customer_hierarchy ─────────────────────────────────────
--
-- For each customer who holds at least one account, compute the intervals where
-- they have a parent (the parent window itself) and where they do not (gaps).
-- Customers with NO parent window at all get a single open-ended NULL-parent row.

bch_gap_filled AS (
  -- Parent intervals: emit bridge_customer_hierarchy rows as-is.
  --
  -- Read bridge_customer_hierarchy DIRECTLY — do not join through
  -- bridge_customer_account to "scope" this to account-holding customers. That
  -- join emits one duplicate copy of the parent interval per account the
  -- customer holds, and commercial subsidiaries hold many site accounts. The
  -- LEFT JOIN in `paths` below would then multiply each path by that count,
  -- producing byte-identical duplicate natural keys and failing
  -- hv_natural_key_unique. Scoping is unnecessary anyway: `paths` LEFT JOINs
  -- from bridge_customer_account, so unmatched hierarchy rows are simply unused.
  SELECT
    bch.child_customer_id  AS customer_id,
    bch.parent_customer_id,
    bch.valid_from         AS hier_from,
    bch.valid_to           AS hier_to
  FROM bridge_customer_hierarchy bch
  UNION ALL
  -- No-parent interval: customers not in bridge_customer_hierarchy as a child.
  SELECT DISTINCT
    bca.customer_id,
    CAST(NULL AS BIGINT) AS parent_customer_id,
    DATE'1900-01-01'     AS hier_from,
    CAST(NULL AS DATE)   AS hier_to
  FROM bridge_customer_account bca
  WHERE bca.customer_id NOT IN (
    SELECT DISTINCT child_customer_id FROM bridge_customer_hierarchy
  )
  UNION ALL
  -- Pre-parent gap: the span before a child's first parent window opens.
  SELECT
    bch.child_customer_id AS customer_id,
    CAST(NULL AS BIGINT)  AS parent_customer_id,
    DATE'1900-01-01'      AS hier_from,
    bch.valid_from        AS hier_to
  FROM bridge_customer_hierarchy bch
  WHERE bch.valid_from > DATE'1900-01-01'
  UNION ALL
  -- Post-parent gap: the span after a child's parent window closes.
  SELECT
    bch.child_customer_id AS customer_id,
    CAST(NULL AS BIGINT)  AS parent_customer_id,
    bch.valid_to          AS hier_from,
    CAST(NULL AS DATE)    AS hier_to
  FROM bridge_customer_hierarchy bch
  WHERE bch.valid_to IS NOT NULL
),

-- ── 2. Gap-fill meter_installation ────────────────────────────────────────────
--
-- For each service_point, add NULL-meter rows for spans not covered by any
-- meter installation, so the interval intersection never drops service-point
-- paths that exist before the first meter arrives.

mi_gap_filled AS (
  -- Real meter installation windows.
  SELECT
    service_point_id,
    meter_id,
    installation_date AS mi_from,
    removal_date      AS mi_to
  FROM meter_installation
  UNION ALL
  -- Pre-installation gap: before the earliest meter at a service point.
  SELECT
    sp.service_point_id,
    CAST(NULL AS BIGINT) AS meter_id,
    DATE'1900-01-01'     AS mi_from,
    MIN(mi.installation_date) AS mi_to
  FROM dim_service_point sp
  JOIN meter_installation mi ON mi.service_point_id = sp.service_point_id
  GROUP BY sp.service_point_id
  HAVING MIN(mi.installation_date) > DATE'1900-01-01'
  UNION ALL
  -- Inter-installation gap: between successive meter windows at a service point.
  -- Use LEAD to find the next installation_date — avoids a correlated subquery
  -- in a JOIN ON clause which Spark does not support.
  SELECT
    service_point_id,
    CAST(NULL AS BIGINT) AS meter_id,
    removal_date         AS mi_from,
    LEAD(installation_date) OVER (
      PARTITION BY service_point_id ORDER BY installation_date
    )                    AS mi_to
  FROM meter_installation
  WHERE removal_date IS NOT NULL
),

-- ── 3. Path intersection ───────────────────────────────────────────────────────
--
-- Join all five effective-dated edges and take the intersection of their windows.
-- NULL ends are replaced with DATE'9999-12-31' for the LEAST/GREATEST arithmetic,
-- then converted back to NULL in the final SELECT.

paths AS (
  SELECT
    COALESCE(bgh.parent_customer_id, bca.customer_id) AS root_customer_id,
    bca.customer_id,
    bca.account_id,
    bap.premise_id,
    sa.service_point_id,
    mf.meter_id,
    GREATEST(
      COALESCE(bgh.hier_from,    DATE'1900-01-01'),
      bca.valid_from,
      bap.link_start_date,
      sa.effective_date,
      COALESCE(mf.mi_from,       DATE'1900-01-01')
    ) AS valid_from,
    LEAST(
      COALESCE(bgh.hier_to,           DATE'9999-12-31'),
      COALESCE(bca.valid_to,          DATE'9999-12-31'),
      COALESCE(bap.link_end_date,     DATE'9999-12-31'),
      COALESCE(sa.termination_date,   DATE'9999-12-31'),
      COALESCE(mf.mi_to,              DATE'9999-12-31')
    ) AS valid_to_sentinel
  FROM bridge_customer_account bca
  LEFT JOIN bch_gap_filled bgh
         ON bgh.customer_id = bca.customer_id
  JOIN bridge_account_premise bap ON bap.account_id   = bca.account_id
  JOIN dim_service_agreement  sa  ON sa.account_id    = bca.account_id
                                 AND sa.service_point_id IS NOT NULL
  LEFT JOIN mi_gap_filled mf      ON mf.service_point_id = sa.service_point_id
)

SELECT
  abs(xxhash64(CONCAT(
    CAST(root_customer_id  AS STRING), '_',
    CAST(customer_id       AS STRING), '_',
    CAST(account_id        AS STRING), '_',
    CAST(premise_id        AS STRING), '_',
    CAST(service_point_id  AS STRING), '_',
    COALESCE(CAST(meter_id AS STRING), 'null'), '_',
    CAST(valid_from        AS STRING)
  )))                                                         AS hierarchy_version_id,
  root_customer_id,
  customer_id,
  account_id,
  premise_id,
  service_point_id,
  meter_id,
  valid_from,
  CASE WHEN valid_to_sentinel = DATE'9999-12-31'
       THEN CAST(NULL AS DATE) ELSE valid_to_sentinel END     AS valid_to,
  (valid_to_sentinel = DATE'9999-12-31')                      AS is_current,
  current_timestamp()                                         AS _ingested_at
FROM paths
WHERE valid_from < valid_to_sentinel;
