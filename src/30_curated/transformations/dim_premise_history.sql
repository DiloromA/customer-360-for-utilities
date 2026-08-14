-- Premise attribute history — selective SCD Type 2.
-- GRAIN: one row per (premise_id, valid_from). Tracks only operationally
-- meaningful changes: service status, service class, and building
-- classification. Does NOT version geometry, source-refresh timestamps,
-- or every enriched attribute — those change when a reference dataset is
-- reprocessed, not because a utility relationship changed.
--
-- This table is deliberately NOT joined into hierarchy_version. Its purpose
-- is point-in-time premise-attribute lookup; adding it to hierarchy_version
-- would multiply that spine's rows by every premise attribute change. That
-- isolation is guaranteed at any scale by the hierarchy_version uniqueness
-- contract assertions (pk_unique_hierarchy_version + hv_natural_key_unique):
-- a premise-history join would fan the spine into duplicate natural keys,
-- which those checks catch.
--
-- The synthetic fixture produces two change categories:
--   • service_status change (one premise goes from 'active' to 'inactive',
--     then back — e.g., a vacancy or build/tear-down). The re-activation
--     opens a new row (valid_from = reactivation_date) so the history carries
--     three rows: original active, inactive interval, current active.
--   • classification change (one premise changes primary_occupancy, e.g.,
--     a residential property converted to small commercial).
-- These two premises are chosen deterministically and land within the display
-- window so the history is visible to demo queries.
--
-- KEYS:
--   premise_history_id   BIGINT durable surrogate (xxhash64 of
--                        premise_id + valid_from).
--   premise_id           BIGINT FK into dim_premise.

CREATE OR REFRESH MATERIALIZED VIEW dim_premise_history (
  premise_history_id  BIGINT    NOT NULL PRIMARY KEY,
  premise_id          BIGINT    NOT NULL,
  valid_from          DATE      NOT NULL,
  valid_to            DATE,
  is_current          BOOLEAN   NOT NULL,
  -- Service status change category: 'active' | 'inactive' | 'demolished'
  service_status      STRING,
  service_class       STRING,
  primary_occupancy   STRING,
  building_subtype    STRING,
  _ingested_at        TIMESTAMP,
  CONSTRAINT fk_dph_premise FOREIGN KEY (premise_id) REFERENCES dim_premise (premise_id) NOT ENFORCED RELY
)
COMMENT 'Premise attribute history — selective SCD Type 2. One row per (premise_id, valid_from). Tracks service status, service class, and building classification changes only; geometry and enrichment attributes are NOT versioned. Use for point-in-time premise attribute lookup; does NOT join into hierarchy_version. PK: premise_history_id. FK: premise_id -> dim_premise.premise_id.'
AS

WITH

-- ── Fixture: service_status change ───────────────────────────────────────────
--
-- One deterministic residential premise goes inactive for a period in the
-- middle third of the display window, then re-activates. Produces three rows:
-- (1) original active from 1900 to inactivation_date
-- (2) inactive from inactivation_date to reactivation_date
-- (3) current active from reactivation_date
--
-- Dates derived from ${as_of_date} / ${history_months} — never hardcoded.

status_showcase_premise AS (
  SELECT
    abs(xxhash64(premise_id))                                              AS premise_id,
    -- Inactivation date: first third of the display window, on day 1 of a month.
    TRUNC(
      DATE_ADD(
        DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
        CAST(
          DATEDIFF(
            DATE'${as_of_date}',
            DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
          ) / 5 AS INT)
      ),
      'MM'
    )                                                                      AS inactivation_date,
    -- Reactivation date: second third of the display window.
    TRUNC(
      DATE_ADD(
        DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
        CAST(
          DATEDIFF(
            DATE'${as_of_date}',
            DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
          ) * 2 / 5 AS INT)
      ),
      'MM'
    )                                                                      AS reactivation_date,
    primary_occupancy,
    building_subtype
  FROM (
    SELECT
      p.premise_id,
      p.primary_occupancy,
      CASE
        WHEN p.occupancy_class = 'Residential' THEN
          CASE
            WHEN UPPER(p.primary_occupancy) LIKE '%MANUFACTURED%'
              OR UPPER(p.primary_occupancy) LIKE '%MOBILE%'              THEN 'Mobile Home'
            WHEN UPPER(p.primary_occupancy) LIKE '%MULTI%'
              OR UPPER(p.primary_occupancy) LIKE '%APARTMENT%'           THEN
              CASE WHEN p.sqft < 5000 THEN 'Multi-Family with 2 - 4 Units'
                                      ELSE 'Multi-Family with 5+ Units' END
            WHEN UPPER(p.primary_occupancy) LIKE '%TOWN%'
              OR UPPER(p.primary_occupancy) LIKE '%ROW%'
              OR UPPER(p.primary_occupancy) LIKE '%ATTACHED%'            THEN 'Single-Family Attached'
            ELSE                                                              'Single-Family Detached'
          END
        ELSE
          CASE
            WHEN p.sqft < 5000  THEN 'SmallOffice'
            WHEN p.sqft < 25000 THEN 'MediumOffice'
            ELSE                     'LargeOffice'
          END
      END                                                                 AS building_subtype,
      ROW_NUMBER() OVER (
        ORDER BY abs(xxhash64(CONCAT(CAST(premise_id AS STRING), 'status_history_pick')))
      )                                                                   AS rn
    FROM ${customer_master_schema}.raw_premises p
    WHERE p.occupancy_class = 'Residential'
  )
  WHERE rn = 1
),

status_rows AS (
  -- Row 1: original active interval.
  SELECT
    premise_id,
    DATE'1900-01-01'    AS valid_from,
    inactivation_date   AS valid_to,
    false               AS is_current,
    'active'            AS service_status,
    'Residential'       AS service_class,
    primary_occupancy,
    building_subtype
  FROM status_showcase_premise
  UNION ALL
  -- Row 2: inactive interval.
  SELECT
    premise_id,
    inactivation_date   AS valid_from,
    reactivation_date   AS valid_to,
    false               AS is_current,
    'inactive'          AS service_status,
    'Residential'       AS service_class,
    primary_occupancy,
    building_subtype
  FROM status_showcase_premise
  UNION ALL
  -- Row 3: current active interval (open-ended).
  SELECT
    premise_id,
    reactivation_date   AS valid_from,
    CAST(NULL AS DATE)  AS valid_to,
    true                AS is_current,
    'active'            AS service_status,
    'Residential'       AS service_class,
    primary_occupancy,
    building_subtype
  FROM status_showcase_premise
),

-- ── Fixture: classification change ───────────────────────────────────────────
--
-- One deterministic residential premise transitions to small commercial
-- mid-window (e.g., a home converted to a professional office). Produces two
-- rows: original residential, then current commercial. The changeover date
-- lands in the latter half of the display window.

classification_showcase_premise AS (
  SELECT
    abs(xxhash64(premise_id))                                              AS premise_id,
    TRUNC(
      DATE_ADD(
        DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
        CAST(
          DATEDIFF(
            DATE'${as_of_date}',
            DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
          ) * 3 / 5 AS INT)
      ),
      'MM'
    )                                                                      AS conversion_date
  FROM (
    SELECT
      p.premise_id,
      ROW_NUMBER() OVER (
        ORDER BY abs(xxhash64(CONCAT(CAST(premise_id AS STRING), 'class_history_pick')))
      )                                                                    AS rn
    FROM ${customer_master_schema}.raw_premises p
    WHERE p.occupancy_class = 'Residential'
  )
  WHERE rn = 2  -- different premise from status showcase
),

classification_rows AS (
  -- Row 1: original residential classification.
  SELECT
    premise_id,
    DATE'1900-01-01'    AS valid_from,
    conversion_date     AS valid_to,
    false               AS is_current,
    'active'            AS service_status,
    'Residential'       AS service_class,
    'Single-Family Detached' AS primary_occupancy,
    'Single-Family Detached' AS building_subtype
  FROM classification_showcase_premise
  UNION ALL
  -- Row 2: reclassified as small commercial (open-ended).
  SELECT
    premise_id,
    conversion_date     AS valid_from,
    CAST(NULL AS DATE)  AS valid_to,
    true                AS is_current,
    'active'            AS service_status,
    'Commercial'        AS service_class,
    'SmallOffice'       AS primary_occupancy,
    'SmallOffice'       AS building_subtype
  FROM classification_showcase_premise
),

-- ── Default: one current row for every other premise ─────────────────────────
--
-- Every premise not in a fixture set gets a single open-ended active row so
-- queries can always find a current premise-history record without a gap.

fixture_premise_ids AS (
  SELECT premise_id FROM status_showcase_premise
  UNION ALL
  SELECT premise_id FROM classification_showcase_premise
),

default_rows AS (
  SELECT
    dp.premise_id,
    DATE'1900-01-01'                                                       AS valid_from,
    CAST(NULL AS DATE)                                                     AS valid_to,
    true                                                                   AS is_current,
    'active'                                                               AS service_status,
    CASE
      WHEN p.occupancy_class = 'Residential' THEN 'Residential'
      ELSE 'Commercial'
    END                                                                    AS service_class,
    p.primary_occupancy,
    CASE
      WHEN p.occupancy_class = 'Residential' THEN
        CASE
          WHEN UPPER(p.primary_occupancy) LIKE '%MANUFACTURED%'
            OR UPPER(p.primary_occupancy) LIKE '%MOBILE%'                 THEN 'Mobile Home'
          WHEN UPPER(p.primary_occupancy) LIKE '%MULTI%'
            OR UPPER(p.primary_occupancy) LIKE '%APARTMENT%'              THEN
            CASE WHEN p.sqft < 5000 THEN 'Multi-Family with 2 - 4 Units'
                                    ELSE 'Multi-Family with 5+ Units' END
          WHEN UPPER(p.primary_occupancy) LIKE '%TOWN%'
            OR UPPER(p.primary_occupancy) LIKE '%ROW%'
            OR UPPER(p.primary_occupancy) LIKE '%ATTACHED%'               THEN 'Single-Family Attached'
          ELSE                                                                  'Single-Family Detached'
        END
      ELSE
        CASE
          WHEN p.sqft < 5000  THEN 'SmallOffice'
          WHEN p.sqft < 25000 THEN 'MediumOffice'
          ELSE                     'LargeOffice'
        END
    END                                                                    AS building_subtype
  FROM dim_premise dp
  JOIN ${customer_master_schema}.raw_premises p ON p.premise_id = dp.premise_number
  WHERE dp.premise_id NOT IN (SELECT premise_id FROM fixture_premise_ids)
),

all_rows AS (
  SELECT premise_id, valid_from, valid_to, is_current, service_status, service_class, primary_occupancy, building_subtype FROM status_rows
  UNION ALL
  SELECT premise_id, valid_from, valid_to, is_current, service_status, service_class, primary_occupancy, building_subtype FROM classification_rows
  UNION ALL
  SELECT premise_id, valid_from, valid_to, is_current, service_status, service_class, primary_occupancy, building_subtype FROM default_rows
)

SELECT
  abs(xxhash64(CONCAT(
    CAST(premise_id AS STRING), '_',
    CAST(valid_from AS STRING)
  )))                                                                      AS premise_history_id,
  premise_id,
  valid_from,
  valid_to,
  is_current,
  service_status,
  service_class,
  primary_occupancy,
  building_subtype,
  current_timestamp()                                                      AS _ingested_at
FROM all_rows;
