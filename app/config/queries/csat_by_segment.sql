-- CSAT view — Row 4a segmentation. Residential vs commercial, by county,
-- and by account tenure band.
--
-- Reads metric_csat (see docs/metric-views-foundation-design.md §8). County
-- and Account Tenure Band come from the view; County resolves premise-aware
-- through dim_account.premise_id inside the view. Filters on
-- `Interaction Month` (month-truncated), not raw started_at — safe because
-- the app's date_from/date_to are always full-year-aligned (CsatView.tsx
-- RANGE_BOUNDS).
--
-- metric_csat resolves county as a non-filtering correlated subquery, so
-- corporate_parent commercial interactions (multi-site accounts with no
-- single premise_id) still count in the customer_class and tenure_band
-- breakdowns; they're excluded only from the county breakdown (via the
-- explicit NULL filter below), where no single county is resolvable.
--
-- Deliberately not scoped by the :segment filter (this panel IS the
-- segmentation breakdown); only the shared time-range params apply.

-- @param date_from STRING
-- @param date_to STRING

SELECT 'customer_class' AS dim_type, `Customer Class` AS dim_value,
  MEASURE(`Response Count`)                 AS n,
  ROUND(100.0 * MEASURE(`Top2Box Rate`), 1) AS top2box_pct,
  ROUND(MEASURE(`Avg CSAT 1-5`), 2)         AS mean_score
FROM {{catalog}}.{{schema}}.metric_csat
WHERE `Interaction Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
GROUP BY `Customer Class`

UNION ALL

SELECT 'tenure_band', `Account Tenure Band`,
  MEASURE(`Response Count`),
  ROUND(100.0 * MEASURE(`Top2Box Rate`), 1),
  ROUND(MEASURE(`Avg CSAT 1-5`), 2)
FROM {{catalog}}.{{schema}}.metric_csat
WHERE `Interaction Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
GROUP BY `Account Tenure Band`

UNION ALL

SELECT 'county', `County`,
  MEASURE(`Response Count`),
  ROUND(100.0 * MEASURE(`Top2Box Rate`), 1),
  ROUND(MEASURE(`Avg CSAT 1-5`), 2)
FROM {{catalog}}.{{schema}}.metric_csat
WHERE `Interaction Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
  AND `County` IS NOT NULL
GROUP BY `County`

ORDER BY dim_type, n DESC
