-- Customer complaints fact. Joins the complaint event with the
-- LLM-generated verbatim text (1:1) so demo views can read both in
-- one query.
--
-- One row per complaint. ~32K rows.
--
-- PREMISE ATTRIBUTION: premise_id is resolved via an ordered evidence chain
-- and is nullable (NULL when no evidence conclusively points to one premise).
-- premise_attribution_method records which step resolved it:
--
--   1. driver_outage_id + customer_id -> fact_outage_customer_impact.premise_id
--      (customer predicate required: FOCI is outage×customer fan-out, one
--      customer can span premises, so outage_id alone is not unique)
--   2. driver_bill_id -> fact_customer_billing.service_point_id ->
--      dim_service_point.premise_id  (two hops)
--   3. unique account↔premise link valid on complaint_date
--      (bridge_account_premise half-open [link_start_date, link_end_date))
--   4. else NULL / 'unresolved'
--
-- Ambiguous evidence stays unresolved — never duplicate a complaint across
-- candidate premises or pick MIN(premise_id).

CREATE OR REFRESH MATERIALIZED VIEW fact_customer_complaints (
  complaint_id              STRING,
  customer_id               BIGINT,
  account_id                BIGINT,
  premise_id                BIGINT,
  premise_attribution_method STRING,
  complaint_date            DATE,
  date_key                  INT,
  channel                   STRING,
  category                  STRING,
  sub_category              STRING,
  severity                  STRING,
  sentiment_label           STRING,
  driver_bill_id            STRING,
  driver_outage_id          STRING,
  assigned_agent_id         STRING,
  resolution_status         STRING,
  resolution_minutes        INT,
  triggering_bill_amount    DOUBLE,
  trailing_12_avg_bill      DOUBLE,
  bill_shock_pct            DOUBLE,
  outages_count_30d         BIGINT,
  outage_minutes_30d        BIGINT,
  verbatim_language         STRING,
  verbatim_text             STRING,
  _ingested_at              TIMESTAMP,
  CONSTRAINT non_null_complaint_id EXPECT (complaint_id IS NOT NULL),
  CONSTRAINT non_null_customer_id  EXPECT (customer_id IS NOT NULL),
  CONSTRAINT valid_attribution_method EXPECT (
    premise_attribution_method IN (
      'driver_outage', 'driver_bill', 'unique_account_link', 'unresolved'
    )
  ),
  CONSTRAINT fk_fcc_customer FOREIGN KEY (customer_id)  REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fcc_account  FOREIGN KEY (account_id)   REFERENCES dim_account  (account_id)  NOT ENFORCED RELY,
  CONSTRAINT fk_fcc_date     FOREIGN KEY (date_key)     REFERENCES dim_date     (date_key)     NOT ENFORCED RELY,
  CONSTRAINT fk_fcc_agent    FOREIGN KEY (assigned_agent_id) REFERENCES dim_agent (agent_id)  NOT ENFORCED RELY,
  CONSTRAINT fk_fcc_premise  FOREIGN KEY (premise_id)   REFERENCES dim_premise  (premise_id)  NOT ENFORCED RELY
)
COMMENT 'Customer complaints fact. Complaint event joined with LLM verbatim text. premise_id is nullable: resolved via ordered evidence chain (driver_outage > driver_bill > unique_account_link; else unresolved). premise_attribution_method records the step used. premise views show attributable complaints only; customer views show all. Drives the CSR view sentiment timeline and the CCO complaint-rate KPI. Key columns (customer_id, account_id) are durable BIGINT keys.'
AS

WITH

-- ── Base event + verbatim join ────────────────────────────────────────────────
base AS (
  SELECT
    e.complaint_id,
    abs(xxhash64(e.customer_id))                                           AS customer_id,
    abs(xxhash64(e.account_id))                                            AS account_id,
    e.complaint_date,
    CAST(DATE_FORMAT(e.complaint_date, 'yyyyMMdd') AS INT)           AS date_key,
    e.channel,
    e.category,
    e.sub_category,
    e.severity,
    e.sentiment_label,
    e.driver_bill_id,
    e.driver_outage_id,
    e.assigned_agent_id,
    e.resolution_status,
    e.resolution_minutes,
    e.triggering_bill_amount,
    e.trailing_12_avg_bill,
    e.bill_shock_pct,
    e.outages_count_30d,
    e.outage_minutes_30d,
    t.language                                                         AS verbatim_language,
    t.verbatim_text
  FROM ${complaints_schema}.raw_customer_complaint_event e
  LEFT JOIN ${complaints_schema}.raw_customer_complaint_text t USING (complaint_id)
),

-- ── Step 1: driver_outage_id attribution ─────────────────────────────────────
--
-- JOIN on (outage_id AND complaint's customer_id) to avoid the fan-out
-- from multi-premise customers: one customer can span several premises in
-- fact_outage_customer_impact, so joining on outage_id alone would return
-- every impacted premise for that customer.
-- Only use this if the join resolves to EXACTLY ONE premise for this complaint.
outage_attribution AS (
  SELECT
    b.complaint_id,
    foci.premise_id,
    COUNT(*) OVER (PARTITION BY b.complaint_id) AS candidate_count
  FROM base b
  JOIN fact_outage_customer_impact foci
    ON foci.outage_id   = b.driver_outage_id
   AND foci.customer_id = b.customer_id
  WHERE b.driver_outage_id IS NOT NULL
),

outage_resolved AS (
  SELECT complaint_id, premise_id
  FROM outage_attribution
  WHERE candidate_count = 1
),

-- ── Step 2: driver_bill_id attribution ───────────────────────────────────────
--
-- fact_customer_billing carries service_point_id, not premise_id, so this
-- is a two-hop resolution: bill_id -> service_point_id -> premise_id.
bill_attribution AS (
  SELECT
    b.complaint_id,
    dsp.premise_id,
    COUNT(*) OVER (PARTITION BY b.complaint_id) AS candidate_count
  FROM base b
  JOIN fact_customer_billing fcb ON fcb.bill_id = b.driver_bill_id
  JOIN dim_service_point dsp     ON dsp.service_point_id = fcb.service_point_id
  WHERE b.driver_bill_id IS NOT NULL
),

bill_resolved AS (
  SELECT complaint_id, premise_id
  FROM bill_attribution
  WHERE candidate_count = 1
),

-- ── Step 3: unique account↔premise link valid on complaint_date ───────────────
--
-- Use bridge_account_premise with a half-open predicate. Only emit a premise
-- when exactly one active link exists for the account on complaint_date.
account_link_attribution AS (
  SELECT
    b.complaint_id,
    bap.premise_id,
    COUNT(*) OVER (PARTITION BY b.complaint_id) AS candidate_count
  FROM base b
  JOIN bridge_account_premise bap
    ON bap.account_id      = b.account_id
   AND bap.link_start_date <= b.complaint_date
   AND (bap.link_end_date IS NULL OR b.complaint_date < bap.link_end_date)
),

account_link_resolved AS (
  SELECT complaint_id, premise_id
  FROM account_link_attribution
  WHERE candidate_count = 1
),

-- ── Merge attribution steps (priority order) ─────────────────────────────────
attributed AS (
  SELECT
    b.complaint_id,
    COALESCE(
      or_.premise_id,
      br_.premise_id,
      al_.premise_id
    )                                                                      AS premise_id,
    CASE
      WHEN or_.premise_id IS NOT NULL THEN 'driver_outage'
      WHEN br_.premise_id IS NOT NULL THEN 'driver_bill'
      WHEN al_.premise_id IS NOT NULL THEN 'unique_account_link'
      ELSE                                 'unresolved'
    END                                                                    AS premise_attribution_method
  FROM base b
  LEFT JOIN outage_resolved   or_ ON or_.complaint_id = b.complaint_id
  LEFT JOIN bill_resolved     br_ ON br_.complaint_id = b.complaint_id
  LEFT JOIN account_link_resolved al_ ON al_.complaint_id = b.complaint_id
)

SELECT
  b.complaint_id,
  b.customer_id,
  b.account_id,
  a.premise_id,
  a.premise_attribution_method,
  b.complaint_date,
  b.date_key,
  b.channel,
  b.category,
  b.sub_category,
  b.severity,
  b.sentiment_label,
  b.driver_bill_id,
  b.driver_outage_id,
  b.assigned_agent_id,
  b.resolution_status,
  b.resolution_minutes,
  b.triggering_bill_amount,
  b.trailing_12_avg_bill,
  b.bill_shock_pct,
  b.outages_count_30d,
  b.outage_minutes_30d,
  b.verbatim_language,
  b.verbatim_text,
  current_timestamp() AS _ingested_at
FROM base b
JOIN attributed a ON a.complaint_id = b.complaint_id;
