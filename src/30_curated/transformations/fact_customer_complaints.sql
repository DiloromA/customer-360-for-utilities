-- Customer complaints fact. Joins the complaint event with the
-- LLM-generated verbatim text (1:1) so demo views can read both in
-- one query.
--
-- One row per complaint. ~32K rows.

CREATE OR REFRESH MATERIALIZED VIEW fact_customer_complaints (
  complaint_id           STRING,
  customer_id            BIGINT,
  account_id             BIGINT,
  complaint_date         DATE,
  date_key               INT,
  channel                STRING,
  category               STRING,
  sub_category           STRING,
  severity               STRING,
  sentiment_label        STRING,
  driver_bill_id         STRING,
  driver_outage_id       STRING,
  assigned_agent_id      STRING,
  resolution_status      STRING,
  resolution_minutes     INT,
  triggering_bill_amount DOUBLE,
  trailing_12_avg_bill   DOUBLE,
  bill_shock_pct         DOUBLE,
  outages_count_30d      BIGINT,
  outage_minutes_30d     BIGINT,
  verbatim_language      STRING,
  verbatim_text          STRING,
  _ingested_at           TIMESTAMP,
  CONSTRAINT non_null_complaint_id EXPECT (complaint_id IS NOT NULL),
  CONSTRAINT non_null_customer_id  EXPECT (customer_id IS NOT NULL),
  CONSTRAINT fk_fcc_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fcc_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fcc_date FOREIGN KEY (date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY,
  CONSTRAINT fk_fcc_agent FOREIGN KEY (assigned_agent_id) REFERENCES dim_agent (agent_id) NOT ENFORCED RELY
)
COMMENT 'Customer complaints fact. Complaint event joined with LLM verbatim text. Drives the CSR view sentiment timeline and the CCO complaint-rate KPI. Key columns (customer_id, account_id) are durable BIGINT keys.'
AS

SELECT
  e.complaint_id,
  abs(xxhash64(e.customer_id))                                             AS customer_id,
  abs(xxhash64(e.account_id))                                              AS account_id,
  e.complaint_date,
  CAST(DATE_FORMAT(e.complaint_date, 'yyyyMMdd') AS INT)             AS date_key,
  e.channel,
  e.category,
  e.sub_category,
  e.severity,
  e.sentiment_label,
  e.driver_bill_id,
  e.driver_outage_id,
  e.assigned_agent_id,
  e.resolution_status,
  e.resolution_minutes,
  e.triggering_bill_amount,
  e.trailing_12_avg_bill,
  e.bill_shock_pct,
  e.outages_count_30d,
  e.outage_minutes_30d,

  t.language                                                         AS verbatim_language,
  t.verbatim_text,

  current_timestamp() AS _ingested_at
FROM ${complaints_schema}.raw_customer_complaint_event e
LEFT JOIN ${complaints_schema}.raw_customer_complaint_text t USING (complaint_id);
