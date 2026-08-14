-- Top 5 program enrollments in a single H3 cell. Counts active +
-- completed enrollments per program for the current customer of each
-- premise (bridge_account_premise where is_current) inside the cell.

-- @param h3_index   STRING
-- @param resolution INTEGER
-- @param grain      STRING  -- 'premise' | 'customer'; default 'customer'

WITH cell_premises AS (
  SELECT h3.premise_id, b.customer_id
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
  CASE WHEN :grain = 'premise'
    THEN COUNT(DISTINCT fpe.premise_id)
    ELSE COUNT(DISTINCT fpe.customer_id)
  END AS n_enrolled
FROM {{catalog}}.{{schema}}.fact_program_enrollment fpe
JOIN cell_premises cp
  ON (  :grain = 'premise'  AND fpe.premise_id  = cp.premise_id  )
  OR (  :grain != 'premise' AND fpe.customer_id = cp.customer_id )
JOIN {{catalog}}.{{schema}}.dim_program p ON p.program_id = fpe.program_id
WHERE fpe.enrollment_status IN ('active', 'completed')
GROUP BY p.program_name, p.program_type
ORDER BY n_enrolled DESC
LIMIT 5
