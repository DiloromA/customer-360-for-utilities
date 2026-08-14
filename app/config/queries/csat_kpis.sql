-- CSAT view — Row 1 KPI band. One row: headline CSAT (top-2-box + mean),
-- NPS, FCR, AHT, each with its ref_cx_targets target for the delta chip.
--
-- Reads metric_csat / metric_nps / metric_fcr. CSAT/FCR/AHT source
-- fact_csr_interactions.csat_score_1_5 directly (complete series, not a
-- ~10% survey sample); NPS comes from fact_survey_responses. metric_nps
-- joins dim_customer (not dim_account) by customer_id, which is already
-- 1:1 — that join shape structurally avoids multi-account fan-out, so no
-- account_group guard is needed. All three views filter on their
-- month-truncated date dims, not raw timestamps — safe because the app's
-- date_from/date_to are always full-year-aligned
-- (CsatView.tsx RANGE_BOUNDS). ref_cx_targets stays
-- a plain app-side join (not a metric view — it's a small ref table, not an
-- aggregate fact).

-- @param date_from STRING  -- inclusive, e.g. 2017-01-01
-- @param date_to STRING    -- inclusive, e.g. 2018-12-31
-- @param segment STRING    -- all | residential | commercial

WITH csat_agg AS (
  SELECT
    MEASURE(`Response Count`)                 AS csat_n,
    ROUND(100.0 * MEASURE(`Top2Box Rate`), 1) AS csat_top2box_pct,
    ROUND(MEASURE(`Avg CSAT 1-5`), 2)         AS csat_mean
  FROM {{catalog}}.{{schema}}.metric_csat
  WHERE `Interaction Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
    AND (:segment = 'all' OR LOWER(`Customer Class`) = :segment)
),
nps_agg AS (
  SELECT
    MEASURE(`Response Count`)   AS nps_n,
    ROUND(MEASURE(`NPS Score`), 1) AS nps_score
  FROM {{catalog}}.{{schema}}.metric_nps
  WHERE `Survey Type` = 'nps_relationship'
    AND `Response Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
    AND (:segment = 'all' OR LOWER(`Customer Class`) = :segment)
),
fcr_agg AS (
  SELECT
    MEASURE(`Interaction Count`)              AS fcr_n,
    ROUND(100.0 * MEASURE(`FCR Rate`), 1)     AS fcr_pct,
    ROUND(MEASURE(`Avg Handle Time Seconds`), 0) AS aht_seconds
  FROM {{catalog}}.{{schema}}.metric_fcr
  WHERE `Interaction Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
    AND (:segment = 'all' OR LOWER(`Customer Class`) = :segment)
),
targets AS (
  SELECT metric, target_value, jdpower_value, acsi_value
  FROM {{catalog}}.{{schema}}.ref_cx_targets
  WHERE year = YEAR(CAST(:date_to AS DATE)) AND segment = :segment
)
SELECT
  csat_agg.csat_n,
  csat_agg.csat_top2box_pct,
  csat_agg.csat_mean,
  (SELECT target_value FROM targets WHERE metric = 'csat')  AS csat_target,
  (SELECT jdpower_value FROM targets WHERE metric = 'csat') AS csat_jdpower,
  (SELECT acsi_value FROM targets WHERE metric = 'csat')    AS csat_acsi,

  nps_agg.nps_n,
  nps_agg.nps_score,
  (SELECT target_value FROM targets WHERE metric = 'nps')   AS nps_target,

  fcr_agg.fcr_n,
  fcr_agg.fcr_pct,
  (SELECT target_value FROM targets WHERE metric = 'fcr')   AS fcr_target,

  fcr_agg.aht_seconds,
  (SELECT target_value FROM targets WHERE metric = 'aht')   AS aht_target
FROM csat_agg
CROSS JOIN nps_agg
CROSS JOIN fcr_agg
