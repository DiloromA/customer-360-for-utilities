-- Interaction — Genesys-shaped contact-center session export. One row per
-- customer contact event. ~200-300K interactions over 2017+2018.
--
-- Sources of interactions:
--   (a) Complaint-linked: every phone / online_chat / email complaint
--       has a corresponding inbound interaction.
--   (b) Non-complaint inquiry: routine calls (~3-4x complaint volume)
--       for billing questions, service moves, program enrollments, etc.
--       Volume scales with archetype (cost_stressed call more, engaged
--       less) and follows monthly seasonality (bills land -> calls rise).
--
-- Genesys fields we model: media_type, direction, queue, wait_time,
-- talk_time, hold_time, acw_seconds, handle_time, transfer_count,
-- agent_id, disposition_code, ivr_path, abandon_flag, csat_score.
--
-- Disposition codes use Genesys-style snake_case classifications.

CREATE OR REFRESH MATERIALIZED VIEW raw_interaction (
  CONSTRAINT non_null_interaction_id EXPECT (interaction_id IS NOT NULL),
  CONSTRAINT non_null_customer_id    EXPECT (customer_id IS NOT NULL),
  CONSTRAINT non_null_started_at     EXPECT (started_at IS NOT NULL),
  CONSTRAINT valid_media_type EXPECT (media_type IN ('voice','chat','email','sms')),
  CONSTRAINT valid_direction  EXPECT (direction IN ('inbound','outbound'))
)
COMMENT 'Interaction — Genesys Cloud-shaped contact center session export. ~200-300K rows over 2017+2018. Complaint-linked interactions plus routine inquiry traffic at 3-4x complaint volume (current customers only; prior-customer customers excluded, joined to the customer''s single primary account). PK: interaction_id. FK: customer_id -> raw_customer. complaint_id -> raw_customer_complaint_event when applicable.'
AS

WITH

-- ────────────────────────────────────────────────────────────────────────
-- 1. Complaint-linked interactions: every phone / chat / email complaint
--    that landed via a contact-center channel gets an inbound interaction.
-- ────────────────────────────────────────────────────────────────────────
complaint_linked AS (
  SELECT
    e.complaint_id,
    e.customer_id,
    e.account_id,
    e.channel,
    e.complaint_date,
    e.category,
    e.sub_category,
    e.severity,
    e.sentiment_label,
    e.assigned_agent_id,
    e.resolution_status,
    e.resolution_minutes,
    abs(xxhash64(e.complaint_id, 'session_offset', ${random_seed})) % 86400 AS r_second_offset,
    abs(xxhash64(e.complaint_id, 'wait', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_wait,
    abs(xxhash64(e.complaint_id, 'talk', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_talk,
    abs(xxhash64(e.complaint_id, 'hold', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_hold,
    abs(xxhash64(e.complaint_id, 'xfer', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_xfer,
    abs(xxhash64(e.complaint_id, 'csat', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_csat,
    abs(xxhash64(e.complaint_id, 'aban', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_aban,
    'complaint'                                                      AS source_kind
  FROM ${complaints_schema}.raw_customer_complaint_event e
  WHERE e.channel IN ('phone','online_chat','email','social_media')
),

-- ────────────────────────────────────────────────────────────────────────
-- 2. Non-complaint inquiry traffic. Generate by EXPLODE'ing a per-customer
--    per-month sequence of inquiries. Rate varies by archetype.
-- ────────────────────────────────────────────────────────────────────────
years AS (
  SELECT DISTINCT YEAR(d) AS year
  FROM (SELECT EXPLODE(SEQUENCE(
    DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
    DATE'${as_of_date}',
    INTERVAL 1 MONTH
  )) AS d)
),

months AS (
  SELECT EXPLODE(SEQUENCE(1, 12)) AS month
),

-- Per-customer-month inquiry count drawn from a Poisson-ish distribution.
customer_months AS (
  SELECT
    c.customer_id,
    c.archetype,
    a.account_id,
    a.preferred_channel,
    y.year,
    m.month,
    abs(xxhash64(c.customer_id, y.year, m.month, 'inq_count', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_count
  FROM ${customer_master_schema}.raw_customer c
  JOIN ${customer_master_schema}.raw_customer_account a
    ON a.customer_id = c.customer_id
   AND a.account_group IN ('standard','corporate_parent')   -- exactly one account per current customer (no chain fan-out)
  CROSS JOIN years y
  CROSS JOIN months m
  WHERE NOT c.is_prior_customer                              -- current customers only
),

-- Inquiries per (customer, month). Base rate ~0.15 baseline, biased by archetype.
inq_with_count AS (
  SELECT *,
    CAST(
      CASE archetype
        WHEN 'cost_stressed'            THEN
          CASE WHEN r_count < 0.65 THEN 0
               WHEN r_count < 0.90 THEN 1
               WHEN r_count < 0.98 THEN 2
               ELSE                       3
          END
        WHEN 'inefficient_unaware' THEN
          CASE WHEN r_count < 0.80 THEN 0
               WHEN r_count < 0.96 THEN 1
               ELSE                       2
          END
        WHEN 'senior_fixed_income' THEN
          CASE WHEN r_count < 0.78 THEN 0
               WHEN r_count < 0.96 THEN 1
               ELSE                       2
          END
        WHEN 'comfortable_indifferent' THEN
          CASE WHEN r_count < 0.85 THEN 0
               WHEN r_count < 0.98 THEN 1
               ELSE                       2
          END
        WHEN 'tech_forward'        THEN
          CASE WHEN r_count < 0.88 THEN 0 ELSE 1 END
        WHEN 'efficient_engaged'   THEN
          CASE WHEN r_count < 0.92 THEN 0 ELSE 1 END
        ELSE
          CASE WHEN r_count < 0.85 THEN 0 ELSE 1 END
      END
      AS INT
    )                                                                AS n_inquiries
  FROM customer_months
),

inquiry_seq AS (
  SELECT
    cm.customer_id, cm.account_id, cm.archetype, cm.preferred_channel,
    cm.year, cm.month,
    inq.idx AS inq_idx
  FROM (SELECT * FROM inq_with_count WHERE n_inquiries > 0) cm
  LATERAL VIEW EXPLODE(SEQUENCE(1, cm.n_inquiries)) inq AS idx
),

non_complaint_inquiries AS (
  SELECT
    -- Synthetic interaction_id for non-complaint rows (distinct from
    -- the complaint-derived ones).
    md5(CONCAT('inq_', customer_id, '_', CAST(year AS STRING),
               '_', LPAD(CAST(month AS STRING), 2, '0'),
               '_', CAST(inq_idx AS STRING)))                       AS inq_synthetic_id,
    customer_id,
    account_id,
    archetype,
    preferred_channel,
    year,
    month,
    inq_idx,
    abs(xxhash64(customer_id, year, month, inq_idx, 'second_offset', ${random_seed}))
      % (86400 * 28)                                                 AS r_second_in_month,
    abs(xxhash64(customer_id, year, month, inq_idx, 'channel', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_channel,
    abs(xxhash64(customer_id, year, month, inq_idx, 'wait', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_wait,
    abs(xxhash64(customer_id, year, month, inq_idx, 'talk', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_talk,
    abs(xxhash64(customer_id, year, month, inq_idx, 'hold', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_hold,
    abs(xxhash64(customer_id, year, month, inq_idx, 'xfer', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_xfer,
    abs(xxhash64(customer_id, year, month, inq_idx, 'topic', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_topic,
    abs(xxhash64(customer_id, year, month, inq_idx, 'csat', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_csat,
    abs(xxhash64(customer_id, year, month, inq_idx, 'aban', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_aban,
    abs(xxhash64(customer_id, year, month, inq_idx, 'agent', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_agent
  FROM inquiry_seq
)

-- ────────────────────────────────────────────────────────────────────────
-- 3. Final SELECT — union complaint-linked and non-complaint inquiries.
--    Genesys handle-time math:
--      handle_time = talk + hold + acw  (post-call work)
--      wait_time is queue time before connect (separate from handle)
-- ────────────────────────────────────────────────────────────────────────
SELECT
  -- For complaint-linked rows.
  md5(CONCAT('cmpl_', complaint_id))                                 AS interaction_id,
  customer_id,
  account_id,
  complaint_id,
  channel                                                            AS source_channel_raw,
  CASE channel
    WHEN 'phone'        THEN 'voice'
    WHEN 'online_chat'  THEN 'chat'
    WHEN 'email'        THEN 'email'
    WHEN 'social_media' THEN 'chat'
    ELSE                     'voice'
  END                                                                AS media_type,
  'inbound'                                                          AS direction,

  -- Timestamps. Anchor to complaint_date (the day it landed) and pick a
  -- time-of-day deterministically; durations sum from talk + hold + acw.
  TIMESTAMPADD(SECOND,
    CAST(r_second_offset AS INT),
    MAKE_TIMESTAMP(YEAR(complaint_date), MONTH(complaint_date), DAY(complaint_date), 0, 0, 0, 'UTC')
  )                                                                  AS started_at,

  -- Queue: route by sub_category (Genesys typically has named queues).
  CASE category
    WHEN 'billing'         THEN 'BIL_INBOUND'
    WHEN 'billing_process' THEN 'BIL_PAYMENT_PLAN'
    WHEN 'outage'          THEN 'OUT_RESTORATION'
    WHEN 'service_quality' THEN 'TECH_FIELD'
    WHEN 'program'         THEN 'PRG_DSM'
    ELSE                        'CSR_GENERAL'
  END                                                                AS queue,

  -- Wait time (queue): higher for high-volume queues + during demand
  -- spikes (we approximate with severity).
  CAST(
    CASE
      WHEN severity = 'high'    THEN 60  + r_wait * 480     -- 60-540s
      WHEN severity = 'medium'  THEN 30  + r_wait * 270     -- 30-300s
      ELSE                            10  + r_wait * 110     -- 10-120s
    END
    AS INT)                                                          AS wait_time_seconds,

  -- Talk time (lognormal-ish; high severity = longer calls)
  CAST(
    CASE
      WHEN severity = 'high'    THEN 240 + r_talk * 1080    -- 4-22 min
      WHEN severity = 'medium'  THEN 180 + r_talk * 600     -- 3-13 min
      ELSE                            90  + r_talk * 270     -- 1.5-6 min
    END
    AS INT)                                                          AS talk_time_seconds,

  -- Hold time (often 0; nonzero when need to look up info)
  CAST(
    CASE WHEN r_hold < 0.45 THEN 0
         ELSE                   CAST(20 + (r_hold - 0.45) / 0.55 * 220 AS INT)  -- 20-240s
    END
    AS INT)                                                          AS hold_time_seconds,

  -- After-call work
  CAST(20 + r_xfer * 150 AS INT)                                     AS acw_seconds,

  -- Transfer count (most are 0, some are 1, rare 2)
  CAST(CASE WHEN r_xfer < 0.78 THEN 0
            WHEN r_xfer < 0.96 THEN 1
            ELSE 2 END AS INT)                                       AS transfer_count,

  -- handle_time = talk + hold + acw (Genesys convention)
  CAST(
    (CASE WHEN severity = 'high' THEN 240 + r_talk * 1080
          WHEN severity = 'medium' THEN 180 + r_talk * 600
          ELSE 90 + r_talk * 270 END)
    +
    (CASE WHEN r_hold < 0.45 THEN 0
          ELSE CAST(20 + (r_hold - 0.45) / 0.55 * 220 AS INT) END)
    +
    (20 + r_xfer * 150)
    AS INT)                                                          AS handle_time_seconds,

  -- Abandonment: long wait + complaint = some customers hang up.
  CASE WHEN r_aban < 0.05 AND severity = 'high' THEN true
       WHEN r_aban < 0.02                       THEN true
       ELSE                                          false
  END                                                                AS abandoned_flag,

  -- Disposition code — Genesys-style snake_case.
  CASE
    WHEN resolution_status = 'resolved' AND severity = 'high'  THEN 'resolved_first_call'
    WHEN resolution_status = 'resolved'                         THEN 'resolved_first_call'
    WHEN resolution_status = 'escalated'                        THEN 'escalated_supervisor'
    WHEN resolution_status = 'open'                             THEN 'callback_scheduled'
    ELSE                                                              'transferred_followup'
  END                                                                AS disposition_code,

  -- IVR path that the customer navigated before reaching an agent.
  CASE category
    WHEN 'billing'         THEN 'IVR>billing>dispute'
    WHEN 'billing_process' THEN 'IVR>billing>payment_plan'
    WHEN 'outage'          THEN 'IVR>outage>report'
    WHEN 'service_quality' THEN 'IVR>service>technical'
    WHEN 'program'         THEN 'IVR>programs>main'
    ELSE                        'IVR>main>agent'
  END                                                                AS ivr_path,

  assigned_agent_id                                                  AS agent_id,

  -- CSAT score collected at end of call (1-5, biased by resolution).
  CASE
    WHEN resolution_status = 'resolved' AND r_csat < 0.75    THEN 5
    WHEN resolution_status = 'resolved'                       THEN 4
    WHEN resolution_status = 'escalated'                      THEN 2
    WHEN resolution_status = 'open'                           THEN 2
    ELSE                                                            3
  END                                                                AS csat_score_1_5,

  source_kind,
  current_timestamp()                                                AS _ingested_at

FROM complaint_linked

UNION ALL

SELECT
  inq_synthetic_id                                                   AS interaction_id,
  customer_id,
  account_id,
  CAST(NULL AS STRING)                                               AS complaint_id,
  CAST(NULL AS STRING)                                               AS source_channel_raw,

  -- For non-complaint inquiry: media_type biased by preferred_channel.
  CASE
    WHEN preferred_channel = 'email' AND r_channel < 0.45 THEN 'chat'
    WHEN preferred_channel = 'email' AND r_channel < 0.85 THEN 'email'
    WHEN preferred_channel = 'email'                       THEN 'voice'
    WHEN preferred_channel = 'sms'   AND r_channel < 0.55 THEN 'chat'
    WHEN preferred_channel = 'sms'   AND r_channel < 0.90 THEN 'voice'
    WHEN preferred_channel = 'sms'                         THEN 'sms'
    ELSE                                                        'voice'
  END                                                                AS media_type,
  'inbound'                                                          AS direction,

  TIMESTAMPADD(SECOND,
    CAST(r_second_in_month AS INT),
    MAKE_TIMESTAMP(year, month, 1, 0, 0, 0, 'UTC')
  )                                                                  AS started_at,

  -- Queue by topic.
  CASE
    WHEN r_topic < 0.40 THEN 'BIL_INBOUND'           -- bill questions
    WHEN r_topic < 0.55 THEN 'CSR_GENERAL'           -- general info
    WHEN r_topic < 0.70 THEN 'MOVE_START_STOP'       -- move-in/out
    WHEN r_topic < 0.82 THEN 'PRG_DSM'               -- program enrollment
    WHEN r_topic < 0.92 THEN 'TECH_FIELD'            -- technical
    ELSE                     'OUT_RESTORATION'       -- outage check
  END                                                                AS queue,

  -- Inquiry calls have shorter waits than complaints.
  CAST(15 + r_wait * 150 AS INT)                                     AS wait_time_seconds,
  -- Shorter talk for routine inquiries.
  CAST(120 + r_talk * 380 AS INT)                                    AS talk_time_seconds,
  CAST(CASE WHEN r_hold < 0.70 THEN 0
            ELSE CAST(10 + (r_hold - 0.70) / 0.30 * 80 AS INT)
       END AS INT)                                                   AS hold_time_seconds,
  CAST(15 + r_xfer * 90 AS INT)                                      AS acw_seconds,
  CAST(CASE WHEN r_xfer < 0.85 THEN 0
            WHEN r_xfer < 0.97 THEN 1
            ELSE                   2 END AS INT)                     AS transfer_count,
  CAST(
    (120 + r_talk * 380)
    + (CASE WHEN r_hold < 0.70 THEN 0
            ELSE CAST(10 + (r_hold - 0.70) / 0.30 * 80 AS INT) END)
    + (15 + r_xfer * 90)
    AS INT)                                                          AS handle_time_seconds,

  CASE WHEN r_aban < 0.015 THEN true ELSE false END                  AS abandoned_flag,

  CASE
    WHEN r_topic < 0.40 THEN 'inquiry_resolved'
    WHEN r_topic < 0.55 THEN 'information_provided'
    WHEN r_topic < 0.70 THEN 'service_request_created'
    WHEN r_topic < 0.82 THEN 'program_enrolled'
    WHEN r_topic < 0.92 THEN 'tech_dispatched'
    ELSE                     'outage_acknowledged'
  END                                                                AS disposition_code,

  CASE
    WHEN r_topic < 0.40 THEN 'IVR>billing>general'
    WHEN r_topic < 0.55 THEN 'IVR>main>agent'
    WHEN r_topic < 0.70 THEN 'IVR>service>move'
    WHEN r_topic < 0.82 THEN 'IVR>programs>main'
    WHEN r_topic < 0.92 THEN 'IVR>service>technical'
    ELSE                     'IVR>outage>report'
  END                                                                AS ivr_path,

  CONCAT('AGT-', LPAD(CAST(1 + CAST(r_agent * 200 AS INT) AS STRING), 4, '0'))
                                                                     AS agent_id,

  -- CSAT for inquiries: mostly satisfied (4-5).
  CASE WHEN r_csat < 0.55 THEN 5
       WHEN r_csat < 0.85 THEN 4
       WHEN r_csat < 0.95 THEN 3
       ELSE                    2 END                                 AS csat_score_1_5,

  'inquiry'                                                          AS source_kind,
  current_timestamp()                                                AS _ingested_at

FROM non_complaint_inquiries;
