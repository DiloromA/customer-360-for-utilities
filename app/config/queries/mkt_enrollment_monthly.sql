-- Marketing: monthly enrollment counts per program over the last
-- 24 months. Drives both the per-program enrollment trend chart and
-- the program-rail sparklines (one query returns data for all).
--
-- Reads metric_dsm_uptake.

SELECT
  `Program ID`                                        AS program_id,
  DATE_FORMAT(`Enrollment Month`, 'yyyy-MM')           AS year_month,
  MEASURE(`Enrollment Count`)                          AS n_enrolled
FROM {{catalog}}.{{schema}}.metric_dsm_uptake
WHERE `Enrollment Month` BETWEEN
  (SELECT DATE_ADD(ADD_MONTHS(as_of_date, -history_months), 1) FROM {{catalog}}.{{schema}}.curated_demo_config)
  AND (SELECT as_of_date FROM {{catalog}}.{{schema}}.curated_demo_config)
GROUP BY ALL
ORDER BY program_id, year_month
