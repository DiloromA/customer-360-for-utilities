-- Program dimension. Pass-through from raw dsm_program with explicit
-- alias for clarity (program_id is the natural key from raw).

CREATE OR REFRESH MATERIALIZED VIEW dim_program (
  program_id           STRING NOT NULL PRIMARY KEY,
  program_name         STRING,
  program_type         STRING,
  customer_segment     STRING,
  rebate_amount_usd    DOUBLE,
  avg_annual_kwh_saved INT,
  program_status       STRING,
  _ingested_at         TIMESTAMP
)
COMMENT 'DSM/EE (demand-side management / energy-efficiency) program dimension. Pass-through catalog from raw_dsm_program. program_id is the natural-code key.'
AS

SELECT
  program_id,
  program_name,
  program_type,
  customer_segment,
  CAST(rebate_amount_usd AS DOUBLE) AS rebate_amount_usd,
  avg_annual_kwh_saved,
  program_status,
  current_timestamp() AS _ingested_at
FROM ${dsm_programs_schema}.raw_dsm_program;
