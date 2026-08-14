-- Work Orders — thin synthetic fixture for field-service events.
-- One row per work order. Produces three fixture classes:
--
--   • completed (meter_related) — ~60% of rows: orders closed within the
--     display window, each tied to a service point (via service_point_id)
--     and its parent meter (via meter_id). Work type: meter_exchange or
--     meter_investigation. Customer/account attribution must be resolved
--     as-of the completed timestamp through hierarchy_version.
--
--   • completed (premise_only)  — ~20% of rows: orders closed within the
--     window, tied to a premise but with no service_point_id (e.g., a
--     property inspection). premise_id is populated; service_point_id and
--     meter_id are NULL.
--
--   • open — ~20% of rows: orders still in-progress as of ${as_of_date},
--     scheduled but not yet completed. completed_at is NULL.
--
-- All dates and assignments are derived from ${as_of_date} /
-- ${history_months} — never hardcoded to a literal year.
--
-- GRAIN: one row per work_order_id (a natural STRING key).
-- Scale: ~1 order per 25 premises (small utility field-services volume).

CREATE OR REFRESH MATERIALIZED VIEW raw_work_order (
  CONSTRAINT non_null_work_order_id EXPECT (work_order_id IS NOT NULL),
  CONSTRAINT non_null_premise_id    EXPECT (premise_id IS NOT NULL),
  CONSTRAINT valid_work_type        EXPECT (work_type IN (
    'meter_exchange', 'meter_investigation', 'premise_inspection',
    'service_disconnect', 'service_reconnect', 'new_service', 'DER_inspection'
  )),
  CONSTRAINT valid_status           EXPECT (status IN ('open', 'completed', 'cancelled')),
  CONSTRAINT valid_priority         EXPECT (priority IN ('routine', 'urgent', 'emergency')),
  CONSTRAINT completed_implies_timestamp EXPECT (
    status != 'completed' OR completed_at IS NOT NULL
  )
)
COMMENT 'Work Orders synthetic fixture. One row per work order. Three fixture classes: meter_related completed orders (service_point_id + meter_id non-NULL), premise_only completed orders (service_point_id + meter_id NULL), and open orders (completed_at NULL). All timestamps within the display window. PK: work_order_id. FK: premise_id -> premises, service_point_id -> raw_service_point (nullable), meter_id -> raw_meter (nullable). Customer/account resolved as-of completed_at through hierarchy_version in the curated layer.'
AS

WITH

-- Display window boundaries.
window_start AS (
  SELECT DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1) AS wstart
),

-- Candidate premises for meter-related orders: those with at least one
-- service point and an active meter installation.
meter_candidates AS (
  SELECT
    sp.service_point_id,
    sp.premise_id,
    mi.meter_number,
    ROW_NUMBER() OVER (
      PARTITION BY sp.premise_id
      ORDER BY abs(xxhash64(sp.service_point_id, 'wo_meter_pick', ${random_seed}))
    )                                                                      AS rn_sp
  FROM ${customer_master_schema}.raw_service_point sp
  JOIN ${customer_master_schema}.raw_meter_installation mi ON mi.service_point_id = sp.service_point_id
                                              AND mi.removal_date IS NULL
),

-- One service point/meter per premise for the meter orders.
one_sp_per_premise AS (
  SELECT service_point_id, premise_id, meter_number
  FROM meter_candidates
  WHERE rn_sp = 1
),

-- All premises, ranked for fixture assignment.
ranked_premises AS (
  SELECT
    p.premise_id,
    ROW_NUMBER() OVER (
      ORDER BY abs(xxhash64(p.premise_id, 'wo_pick', ${random_seed}))
    )                                                                      AS rn
  FROM ${customer_master_schema}.raw_premises p
),

-- Take approximately 1 order per 25 premises.
premise_pool AS (
  SELECT premise_id, rn
  FROM ranked_premises
  WHERE rn <= CAST((SELECT COUNT(*) FROM ${customer_master_schema}.raw_premises) / 25 AS INT)
),

-- Join premise pool to service point info (LEFT — premise_only orders have no SP).
order_base AS (
  SELECT
    pp.premise_id,
    pp.rn,
    sp.service_point_id,
    sp.meter_number,
    -- Class assignment: last digit of hash drives the distribution.
    CASE
      WHEN abs(xxhash64(pp.premise_id, 'wo_class', ${random_seed})) % 5 < 3
        THEN 'meter_related'
      WHEN abs(xxhash64(pp.premise_id, 'wo_class', ${random_seed})) % 5 = 3
        THEN 'premise_only'
      ELSE 'open'
    END                                                                    AS order_class
  FROM premise_pool pp
  LEFT JOIN one_sp_per_premise sp ON sp.premise_id = pp.premise_id
)

SELECT
  -- Natural work order key.
  CONCAT('WO-', LPAD(CAST(rn AS STRING), 6, '0'))                         AS work_order_id,
  premise_id,
  -- Service point and meter: non-NULL only for meter_related orders.
  CASE WHEN order_class = 'meter_related' THEN service_point_id END        AS service_point_id,
  CASE WHEN order_class = 'meter_related' THEN meter_number END            AS meter_id,
  -- Work type derived from class.
  CASE
    WHEN order_class = 'meter_related' THEN
      CASE
        WHEN abs(xxhash64(premise_id, 'wo_type', ${random_seed})) % 2 = 0
          THEN 'meter_exchange'
        ELSE 'meter_investigation'
      END
    WHEN order_class = 'premise_only' THEN
      ELEMENT_AT(
        ARRAY('premise_inspection', 'service_disconnect', 'service_reconnect', 'new_service', 'DER_inspection'),
        CAST(1 + abs(xxhash64(premise_id, 'wo_type_p', ${random_seed})) % 5 AS INT)
      )
    ELSE 'premise_inspection'
  END                                                                       AS work_type,
  CASE WHEN order_class = 'open' THEN 'open' ELSE 'completed' END          AS status,
  CASE
    WHEN abs(xxhash64(premise_id, 'wo_priority', ${random_seed})) % 10 < 7 THEN 'routine'
    WHEN abs(xxhash64(premise_id, 'wo_priority', ${random_seed})) % 10 < 9 THEN 'urgent'
    ELSE 'emergency'
  END                                                                       AS priority,
  -- created_at: random date within the display window.
  CAST(
    TIMESTAMP_SECONDS(
      UNIX_TIMESTAMP((SELECT wstart FROM window_start)) +
      CAST(
        abs(xxhash64(premise_id, 'wo_created', ${random_seed})) %
        DATEDIFF(DATE'${as_of_date}', (SELECT wstart FROM window_start))
        AS BIGINT) * 86400
    )
  AS TIMESTAMP)                                                             AS created_at,
  -- scheduled_at: created_at + 1 to 7 days.
  CAST(
    TIMESTAMP_SECONDS(
      UNIX_TIMESTAMP((SELECT wstart FROM window_start)) +
      CAST(
        abs(xxhash64(premise_id, 'wo_created', ${random_seed})) %
        DATEDIFF(DATE'${as_of_date}', (SELECT wstart FROM window_start))
        AS BIGINT) * 86400
      + (1 + CAST(abs(xxhash64(premise_id, 'wo_sched', ${random_seed})) % 7 AS BIGINT)) * 86400
    )
  AS TIMESTAMP)                                                             AS scheduled_at,
  -- completed_at: scheduled_at + 0 to 3 days (NULL for open orders).
  CASE
    WHEN order_class != 'open' THEN
      CAST(
        TIMESTAMP_SECONDS(
          UNIX_TIMESTAMP((SELECT wstart FROM window_start)) +
          CAST(
            abs(xxhash64(premise_id, 'wo_created', ${random_seed})) %
            DATEDIFF(DATE'${as_of_date}', (SELECT wstart FROM window_start))
            AS BIGINT) * 86400
          + (1 + CAST(abs(xxhash64(premise_id, 'wo_sched', ${random_seed})) % 7 AS BIGINT)) * 86400
          + CAST(abs(xxhash64(premise_id, 'wo_complete', ${random_seed})) % 3 AS BIGINT) * 86400
        )
      AS TIMESTAMP)
  END                                                                       AS completed_at,
  current_timestamp()                                                       AS _ingested_at
FROM order_base;
