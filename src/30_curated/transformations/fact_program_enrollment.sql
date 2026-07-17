-- Program Enrollment fact. Pass-through from raw with date_key, plus a
-- status normalization (see enrollment_status below).

CREATE OR REFRESH MATERIALIZED VIEW fact_program_enrollment (
  enrollment_id       STRING NOT NULL,
  customer_id         BIGINT,
  program_id          STRING,
  enrollment_date     DATE,
  enrollment_date_key INT,
  completion_date     DATE,
  rebate_paid_usd     DECIMAL(6,2),
  kwh_saved_estimate  INT,
  enrollment_status   STRING,
  _ingested_at        TIMESTAMP,
  CONSTRAINT fk_fpe_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fpe_program FOREIGN KEY (program_id) REFERENCES dim_program (program_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fpe_date FOREIGN KEY (enrollment_date_key) REFERENCES dim_date (date_key) NOT ENFORCED
)
COMMENT 'DSM Program Enrollment fact. customer_id is a durable BIGINT key; program_id keeps its natural string code. enrollment_status normalized to the demo contract: raw "enrolled" (ongoing programs) -> "active"; "completed" unchanged.'
AS

SELECT
  enrollment_id,
  abs(xxhash64(customer_id))                                               AS customer_id,
  program_id,
  enrollment_date,
  CAST(DATE_FORMAT(enrollment_date, 'yyyyMMdd') AS INT)               AS enrollment_date_key,
  completion_date,
  rebate_paid_usd,
  kwh_saved_estimate,
  -- Normalize the raw source vocabulary to the demo contract. The DSM source
  -- emits 'enrolled' for ongoing programs (EV TOU rate, Commercial DR) and
  -- 'completed' for one-time rebates; downstream demos/Genie filter on
  -- 'active'/'completed', so an unmapped 'enrolled' would silently hide every
  -- ongoing-program enrollment. Map 'enrolled' -> 'active' here, once.
  CASE WHEN enrollment_status = 'enrolled' THEN 'active' ELSE enrollment_status END
                                                                     AS enrollment_status,
  current_timestamp() AS _ingested_at
FROM ${dsm_programs_schema}.raw_dsm_enrollment;
