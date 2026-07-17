-- Top 5 program enrollments in a single H3 cell. Counts active +
-- completed enrollments per program for the current occupant of each
-- premise (bridge_account_premise where is_current) inside the cell.

-- @param h3_index   STRING
-- @param resolution INTEGER

WITH cell_customers AS (
  SELECT b.customer_id
  FROM {{catalog}}.{{schema}}.dim_premise_h3 h3
  JOIN {{catalog}}.{{schema}}.bridge_account_premise b
    ON b.premise_id = h3.premise_id AND b.is_current
  WHERE
    CASE :resolution
      WHEN 5 THEN h3.h3_res5
      WHEN 6 THEN h3.h3_res6
      WHEN 7 THEN h3.h3_res7
      WHEN 8 THEN h3.h3_res8
      WHEN 9 THEN h3.h3_res9
    END = h3_stringtoh3(:h3_index)
)
SELECT
  p.program_name,
  p.program_type,
  COUNT(DISTINCT fpe.customer_id) AS n_enrolled
FROM {{catalog}}.{{schema}}.fact_program_enrollment fpe
JOIN cell_customers cust ON cust.customer_id = fpe.customer_id
JOIN {{catalog}}.{{schema}}.dim_program p ON p.program_id = fpe.program_id
WHERE fpe.enrollment_status IN ('active', 'completed')
GROUP BY p.program_name, p.program_type
ORDER BY n_enrolled DESC
LIMIT 5
