-- Active DSM programs for layer selectors and the Marketing view's
-- program picker. Includes enrollment counts so the UI can sort/show
-- adoption signal.

SELECT
  p.program_id,
  p.program_name,
  p.program_type,
  p.customer_segment,
  p.rebate_amount_usd,
  p.avg_annual_kwh_saved,
  COUNT(DISTINCT CASE WHEN e.enrollment_status IN ('active','completed') THEN e.customer_id END) AS n_enrolled
FROM {{catalog}}.{{schema}}.dim_program p
LEFT JOIN {{catalog}}.{{schema}}.fact_program_enrollment e USING (program_id)
WHERE p.program_status = 'Active'
GROUP BY p.program_id, p.program_name, p.program_type, p.customer_segment, p.rebate_amount_usd, p.avg_annual_kwh_saved
ORDER BY n_enrolled DESC
