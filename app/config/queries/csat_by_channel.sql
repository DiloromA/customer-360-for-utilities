-- CSAT view — Row 3a channel breakdown. Contact-center channels only
-- (voice/chat/email/sms) — web/app/field-service CSAT isn't instrumented yet,
-- the view labels this panel honestly rather than implying omni-channel
-- coverage.
--
-- Reads metric_csat. Filters on `Interaction Month`
-- (month-truncated), not raw started_at — equivalent for this app's
-- actual date_from/date_to values (always full-year-aligned, see
-- CsatView.tsx RANGE_BOUNDS). A day-level partial-month range would silently
-- drop the boundary months; don't repurpose this query for a free-form date
-- picker without adding a raw-date dimension to metric_csat first.

-- @param date_from STRING
-- @param date_to STRING
-- @param segment STRING  -- all | residential | commercial

SELECT
  `Media Type`                              AS media_type,
  MEASURE(`Response Count`)                  AS n,
  ROUND(100.0 * MEASURE(`Top2Box Rate`), 1)  AS top2box_pct,
  ROUND(MEASURE(`Avg CSAT 1-5`), 2)          AS mean_score
FROM {{catalog}}.{{schema}}.metric_csat
WHERE `Interaction Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
  AND (:segment = 'all' OR LOWER(`Customer Class`) = :segment)
GROUP BY ALL
ORDER BY n DESC
