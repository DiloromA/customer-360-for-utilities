-- CSAT view — Row 2 trend. Monthly CSAT (top-2-box % + mean) with the
-- year's target line from ref_cx_targets. Data is concentrated in the
-- demo history window, so the default view window is that full span
-- rather than a trailing-90d slice.
--
-- Reads metric_csat.
-- `Customer Class` on metric_csat comes from dim_customer, which matches
-- dim_account's class for every fact_csr_interactions row, so the segment
-- filter is unaffected. Filters on `Interaction Month` (month-truncated),
-- not raw started_at — equivalent for this app's actual date_from/date_to
-- values (always full-year-aligned, see CsatView.tsx RANGE_BOUNDS); a
-- day-level partial-month range would silently drop the boundary months.

-- @param date_from STRING
-- @param date_to STRING
-- @param segment STRING  -- all | residential | commercial

WITH monthly AS (
  SELECT
    YEAR(`Interaction Month`)                              AS year,
    MONTH(`Interaction Month`)                              AS month,
    DATE_FORMAT(`Interaction Month`, 'MMMM')                AS month_name,
    MEASURE(`Response Count`)                                AS n,
    ROUND(100.0 * MEASURE(`Top2Box Rate`), 1)                AS top2box_pct,
    ROUND(MEASURE(`Avg CSAT 1-5`), 2)                        AS mean_score
  FROM {{catalog}}.{{schema}}.metric_csat
  WHERE `Interaction Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
    AND (:segment = 'all' OR LOWER(`Customer Class`) = :segment)
  GROUP BY ALL
)
SELECT
  m.year,
  m.month,
  m.month_name,
  CONCAT(m.year, '-', LPAD(m.month, 2, '0')) AS year_month,
  m.n,
  m.top2box_pct,
  m.mean_score,
  t.target_value                             AS csat_target
FROM monthly m
LEFT JOIN {{catalog}}.{{schema}}.ref_cx_targets t
  ON t.metric = 'csat' AND t.year = m.year AND t.segment = :segment
ORDER BY m.year, m.month
