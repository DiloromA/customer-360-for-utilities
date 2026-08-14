-- Executive map — per-H3-cell "currently out of power" metrics for the
-- Active outages (live) layer. One row per H3 cell at the requested resolution
-- within the viewport. n_customers is the cell's current-customer base;
-- n_currently_out is how many of them are without power right now (from
-- fact_active_outage_customer_impact); pct_currently_out drives the
-- choropleth shade.

-- @param resolution INTEGER  -- H3 resolution 5-9
-- @param south STRING        -- viewport bounds (CAST to DOUBLE)
-- @param north STRING
-- @param west STRING
-- @param east STRING

WITH premises_in_view AS (
  SELECT
    h3.premise_id,
    CASE :resolution
      WHEN 5 THEN h3.h3_res5
      WHEN 6 THEN h3.h3_res6
      WHEN 7 THEN h3.h3_res7
      WHEN 8 THEN h3.h3_res8
      WHEN 9 THEN h3.h3_res9
      ELSE        h3.h3_res7
    END AS h3_index_long
  FROM {{catalog}}.{{schema}}.dim_premise_h3 h3
  WHERE h3.latitude  BETWEEN CAST(:south AS DOUBLE) AND CAST(:north AS DOUBLE)
    AND h3.longitude BETWEEN CAST(:west AS DOUBLE) AND CAST(:east AS DOUBLE)
),

-- Current customer per premise (one row per premise) + whether THIS PREMISE is
-- out now. Membership is keyed on premise_id, not customer_id: a customer can
-- occupy several premises (commercial chains), and only the premises actually on
-- a downed feeder are out — keying on customer_id would flag a chain's healthy
-- premises too, and disagree with the per-premise dots (exec_active_outage_points).
customers_in_view AS (
  SELECT
    p.h3_index_long,
    c.customer_id,
    (ao.premise_id IS NOT NULL) AS is_currently_out
  FROM premises_in_view p
  JOIN {{catalog}}.{{schema}}.bridge_account_premise b
    ON b.premise_id = p.premise_id AND b.is_current
  JOIN {{catalog}}.{{schema}}.dim_customer c
    ON c.customer_id = b.customer_id
  LEFT JOIN (
    SELECT DISTINCT premise_id
    FROM {{catalog}}.{{schema}}.fact_active_outage_customer_impact
    WHERE still_out
  ) ao ON ao.premise_id = p.premise_id
)

SELECT
  h3_h3tostring(h3_index_long)                                      AS h3_index,
  COUNT(*)                                                          AS n_customers,
  SUM(CASE WHEN is_currently_out THEN 1 ELSE 0 END)                 AS n_currently_out,
  ROUND(100.0 * SUM(CASE WHEN is_currently_out THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_currently_out
FROM customers_in_view
GROUP BY h3_index_long;
