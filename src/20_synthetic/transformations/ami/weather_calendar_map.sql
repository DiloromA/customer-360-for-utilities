-- weather_calendar_map. Separates
-- the fixed SOURCE LIBRARY (one canonical year of AMY2018 shapes/weather/PV)
-- from the parameterized DISPLAY CALENDAR (as_of_date minus a
-- trailing history_months window). For every display_date this picks an
-- analog source_date in the 2018 library with the same month and the
-- nearest day-of-week (the TMY/load-forecasting "weather analog" method).
-- Leap days (Feb 29) explicitly borrow
-- Feb 28. kwh_scale is a small deterministic per-display-date YoY factor
-- (year trend + month noise, centered on 1.0) applied once at the AMI
-- projection step so billing/benchmarks/ML all stay reconciled.
--
-- Consulted by the generators that need a per-display-year calendar:
-- raw_meter_readings (base-load projection +
-- kwh_scale) and, for their own per-year event calendars, raw_outage_event,
-- raw_digital_event, raw_portal_session, cx_genesys/raw_interaction.

CREATE OR REFRESH MATERIALIZED VIEW weather_calendar_map (
  display_date  DATE NOT NULL PRIMARY KEY,
  source_date   DATE NOT NULL,
  kwh_scale     DOUBLE,
  _ingested_at  TIMESTAMP
)
COMMENT 'One row per display date in the demo''s display window (as_of_date minus history_months, trailing). Maps each display_date to an analog source_date in the fixed AMY2018 source library (same month, nearest day-of-week; Feb 29 borrows Feb 28) plus a deterministic kwh_scale YoY factor. Consulted by raw_meter_readings and the per-year event-calendar generators. PK: display_date.'
AS

WITH

-- ────────────────────────────────────────────────────────────────────────
-- 1. The display calendar: every date in the trailing history_months
--    window ending at as_of_date.
-- ────────────────────────────────────────────────────────────────────────
display_dates AS (
  SELECT EXPLODE(SEQUENCE(
    DATE_ADD(ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1),
    DATE'${as_of_date}',
    INTERVAL 1 DAY
  )) AS display_date
),

-- ────────────────────────────────────────────────────────────────────────
-- 2. The fixed 2018 source library (the one calendar year ResStock/
--    ComStock/EULP shapes were simulated against).
-- ────────────────────────────────────────────────────────────────────────
source_calendar AS (
  SELECT
    d                AS source_date,
    MONTH(d)         AS month,
    DAYOFWEEK(d)     AS dow,
    DAY(d)           AS day_of_month
  FROM (SELECT EXPLODE(SEQUENCE(DATE'2018-01-01', DATE'2018-12-31', INTERVAL 1 DAY)) AS d)
),

-- ────────────────────────────────────────────────────────────────────────
-- 3. Weather-analog match: same month + same day-of-week, nearest
--    day-of-month. Feb 29 has no dow match in a 28-day Feb — handled as an
--    explicit override below rather than relying on the join.
-- ────────────────────────────────────────────────────────────────────────
analog_matches AS (
  SELECT
    dd.display_date,
    sc.source_date,
    ROW_NUMBER() OVER (
      PARTITION BY dd.display_date
      ORDER BY ABS(sc.day_of_month - DAY(dd.display_date)) ASC, sc.source_date ASC
    ) AS rn
  FROM display_dates dd
  JOIN source_calendar sc
    ON sc.month = MONTH(dd.display_date)
   AND sc.dow   = DAYOFWEEK(dd.display_date)
  WHERE NOT (MONTH(dd.display_date) = 2 AND DAY(dd.display_date) = 29)
),
leap_days AS (
  SELECT display_date, DATE'2018-02-28' AS source_date
  FROM display_dates
  WHERE MONTH(display_date) = 2 AND DAY(display_date) = 29
),
day_map AS (
  SELECT display_date, source_date FROM analog_matches WHERE rn = 1
  UNION ALL
  SELECT display_date, source_date FROM leap_days
)

-- ────────────────────────────────────────────────────────────────────────
-- 4. kwh_scale: deterministic per-display-date YoY factor, centered on 1.0
--    — a gentle year-trend (~2%/yr away from as_of_date's year) plus
--    month-level noise (±3.5%). Seeded like every other generator
--    (abs(xxhash64(...)) / INT64_MAX -> uniform [0,1)).
-- ────────────────────────────────────────────────────────────────────────
SELECT
  display_date,
  source_date,
  ROUND(
    1.0
    + (YEAR(display_date) - YEAR(DATE'${as_of_date}')) * 0.02
    + (
        abs(xxhash64(display_date, 'yoy_scale', ${random_seed}))
        / CAST(9223372036854775807 AS DOUBLE) - 0.5
      ) * 0.07,
    4
  ) AS kwh_scale,
  current_timestamp() AS _ingested_at
FROM day_map;
