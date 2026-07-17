-- Interaction Event — child state transitions within each interaction.
-- Genesys exports a per-session timeline of events: queue entry, agent
-- answer, hold start/end, transfer, wrap. We model 5-7 events per
-- interaction.
--
-- ~200-300K interactions x ~6 events = ~1.5M rows.
--
-- The event types we emit (in chronological order within a session):
--   queue_entered     when the interaction hits the queue
--   agent_answered    when an agent picks up (skipped if abandoned)
--   hold_started      first hold within the call (if hold_time > 0)
--   hold_ended        end of the first hold
--   transfer          warm/cold transfer to another queue (if transfer_count > 0)
--   acw_started       agent enters after-call work
--   wrap_completed    session ends

CREATE OR REFRESH MATERIALIZED VIEW raw_interaction_event (
  CONSTRAINT non_null_event_id        EXPECT (event_id IS NOT NULL),
  CONSTRAINT non_null_interaction_id  EXPECT (interaction_id IS NOT NULL),
  CONSTRAINT non_null_event_timestamp EXPECT (event_timestamp IS NOT NULL),
  CONSTRAINT valid_event_type EXPECT (event_type IN (
    'queue_entered','agent_answered','hold_started','hold_ended',
    'transfer','acw_started','wrap_completed'
  ))
)
COMMENT 'Interaction Event — Genesys interaction timeline rows. One row per state transition within an interaction. ~5-7 events per session. PK: event_id. FK: interaction_id -> interaction.interaction_id.'
AS

WITH

base AS (
  SELECT
    interaction_id,
    started_at,
    wait_time_seconds,
    talk_time_seconds,
    hold_time_seconds,
    acw_seconds,
    transfer_count,
    abandoned_flag,
    queue,
    agent_id,
    disposition_code
  FROM raw_interaction
),

-- For each interaction, compute the canonical event timestamps.
event_timestamps AS (
  SELECT
    interaction_id,
    started_at,
    queue,
    agent_id,
    transfer_count,
    abandoned_flag,
    -- queue_entered = session start
    started_at                                                       AS ts_queue_entered,
    -- agent_answered = start + wait
    TIMESTAMPADD(SECOND, wait_time_seconds, started_at)              AS ts_agent_answered,
    -- hold_started = agent answered + (talk_time × 0.30) -- typical mid-call
    CASE WHEN hold_time_seconds > 0
         THEN TIMESTAMPADD(
                SECOND,
                wait_time_seconds + CAST(talk_time_seconds * 0.30 AS INT),
                started_at)
         ELSE NULL END                                               AS ts_hold_started,
    CASE WHEN hold_time_seconds > 0
         THEN TIMESTAMPADD(
                SECOND,
                wait_time_seconds + CAST(talk_time_seconds * 0.30 AS INT) + hold_time_seconds,
                started_at)
         ELSE NULL END                                               AS ts_hold_ended,
    -- transfer event = mid-call after hold (if transferred)
    CASE WHEN transfer_count > 0
         THEN TIMESTAMPADD(
                SECOND,
                wait_time_seconds + CAST(talk_time_seconds * 0.60 AS INT) + hold_time_seconds,
                started_at)
         ELSE NULL END                                               AS ts_transfer,
    -- acw_started = end of talk
    TIMESTAMPADD(
      SECOND,
      wait_time_seconds + talk_time_seconds + hold_time_seconds,
      started_at)                                                    AS ts_acw_started,
    -- wrap_completed = end of acw
    TIMESTAMPADD(
      SECOND,
      wait_time_seconds + talk_time_seconds + hold_time_seconds + acw_seconds,
      started_at)                                                    AS ts_wrap_completed
  FROM base
),

-- Unpivot to one row per event. Use EXPLODE over a fixed event list
-- and pick the timestamp per type.
events_long AS (
  SELECT et.interaction_id,
         et.queue,
         et.agent_id,
         evt.event_type,
         CASE evt.event_type
           WHEN 'queue_entered'   THEN et.ts_queue_entered
           WHEN 'agent_answered'  THEN CASE WHEN et.abandoned_flag THEN NULL ELSE et.ts_agent_answered END
           WHEN 'hold_started'    THEN et.ts_hold_started
           WHEN 'hold_ended'      THEN et.ts_hold_ended
           WHEN 'transfer'        THEN et.ts_transfer
           WHEN 'acw_started'     THEN et.ts_acw_started
           WHEN 'wrap_completed'  THEN et.ts_wrap_completed
         END AS event_timestamp
  FROM event_timestamps et
  LATERAL VIEW EXPLODE(ARRAY(
    'queue_entered','agent_answered','hold_started','hold_ended',
    'transfer','acw_started','wrap_completed'
  )) evt AS event_type
)

SELECT
  md5(CONCAT(interaction_id, '_', event_type)) AS event_id,
  interaction_id,
  event_type,
  event_timestamp,
  queue,
  agent_id,
  current_timestamp() AS _ingested_at
FROM events_long
WHERE event_timestamp IS NOT NULL;
