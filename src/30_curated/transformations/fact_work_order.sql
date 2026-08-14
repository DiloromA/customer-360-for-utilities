-- Work order fact — one row per field-service work order.
-- GRAIN: one row per work_order_id.
--
-- Bounded initial shape: durable work-order identity + source key; work
-- type, status, priority; created/scheduled/completed timestamps; and
-- nullable FKs to premise, service point, and meter according to the
-- evidence in the source.
--
-- Customer and account attribution are resolved as of the work timestamp
-- (completed_at when present, created_at otherwise) through hierarchy_version
-- — not stamped from the current hierarchy. This is the correct pattern for
-- any time-varying fact: which customer was responsible for this address at
-- the time the order was executed?
--
-- Crew dispatch, skills, inventory, procurement, detailed task steps, and
-- asset maintenance planning are out of scope.
--
-- KEYS:
--   work_order_id     STRING natural key (from source).
--   premise_id        BIGINT FK into dim_premise (always populated).
--   service_point_id  BIGINT FK into dim_service_point (nullable).
--   meter_id          BIGINT FK into dim_meter (nullable).
--   customer_id       BIGINT FK into dim_customer (nullable — resolved via HV).
--   account_id        BIGINT FK into dim_account (nullable — resolved via HV).

CREATE OR REFRESH MATERIALIZED VIEW fact_work_order (
  work_order_id      STRING  NOT NULL,
  premise_id         BIGINT  NOT NULL,
  service_point_id   BIGINT,
  meter_id           BIGINT,
  customer_id        BIGINT,
  account_id         BIGINT,
  work_type          STRING,
  status             STRING,
  priority           STRING,
  created_at         TIMESTAMP,
  scheduled_at       TIMESTAMP,
  completed_at       TIMESTAMP,
  created_date_key   INT,
  _ingested_at       TIMESTAMP,
  CONSTRAINT pk_fwo EXPECT (work_order_id IS NOT NULL),
  CONSTRAINT fk_fwo_premise       FOREIGN KEY (premise_id)       REFERENCES dim_premise       (premise_id)       NOT ENFORCED RELY,
  CONSTRAINT fk_fwo_service_point FOREIGN KEY (service_point_id) REFERENCES dim_service_point (service_point_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fwo_customer      FOREIGN KEY (customer_id)      REFERENCES dim_customer      (customer_id)      NOT ENFORCED RELY,
  CONSTRAINT fk_fwo_account       FOREIGN KEY (account_id)       REFERENCES dim_account       (account_id)       NOT ENFORCED RELY,
  CONSTRAINT fk_fwo_date          FOREIGN KEY (created_date_key) REFERENCES dim_date          (date_key)         NOT ENFORCED RELY
)
COMMENT 'Work order fact. One row per field-service work order. premise_id is always non-NULL; service_point_id and meter_id are NULL for premise-only orders. customer_id and account_id are resolved as-of the work timestamp through hierarchy_version (nullable when the premise had no active customer at that time). Out of scope: crew, skills, inventory, detailed task steps. PK: work_order_id. FK: premise_id -> dim_premise, service_point_id -> dim_service_point (nullable), customer_id -> dim_customer (nullable), account_id -> dim_account (nullable).'
AS

WITH

-- Resolve the work timestamp: prefer completed_at; fall back to created_at.
work_ts AS (
  SELECT
    wo.work_order_id,
    abs(xxhash64(wo.premise_id))                                         AS premise_id,
    CASE WHEN wo.service_point_id IS NOT NULL
         THEN abs(xxhash64(wo.service_point_id)) END                     AS service_point_id,
    CASE WHEN wo.meter_id IS NOT NULL
         THEN abs(xxhash64(wo.meter_id)) END                             AS meter_id,
    wo.work_type,
    wo.status,
    wo.priority,
    wo.created_at,
    wo.scheduled_at,
    wo.completed_at,
    CAST(DATE_FORMAT(CAST(wo.created_at AS DATE), 'yyyyMMdd') AS INT)    AS created_date_key,
    COALESCE(CAST(wo.completed_at AS DATE), CAST(wo.created_at AS DATE)) AS attribution_date
  FROM ${customer_master_schema}.raw_work_order wo
),

-- Resolve customer and account as-of the attribution date.
-- LEFT JOIN so orders on premises with no active customer at that time
-- still land in the fact (with NULL customer_id / account_id).
attributed AS (
  SELECT
    wt.*,
    hv.customer_id,
    hv.account_id
  FROM work_ts wt
  LEFT JOIN hierarchy_version hv
         ON hv.premise_id    = wt.premise_id
        AND hv.valid_from   <= wt.attribution_date
        AND (hv.valid_to IS NULL OR wt.attribution_date < hv.valid_to)
        -- If multiple service paths are open (sub-metered), use the one
        -- matching the order's service point when known; otherwise take
        -- the lowest-surrogate path as a stable tiebreak.
        AND (wt.service_point_id IS NULL OR hv.service_point_id = wt.service_point_id)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY wt.work_order_id
    ORDER BY
      CASE WHEN wt.service_point_id IS NOT NULL
                AND hv.service_point_id = wt.service_point_id THEN 0 ELSE 1 END,
      hv.hierarchy_version_id
  ) = 1
)

SELECT
  work_order_id,
  premise_id,
  service_point_id,
  meter_id,
  customer_id,
  account_id,
  work_type,
  status,
  priority,
  created_at,
  scheduled_at,
  completed_at,
  created_date_key,
  current_timestamp() AS _ingested_at
FROM attributed;
