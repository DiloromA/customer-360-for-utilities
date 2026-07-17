-- Social Mentions fact. Joins the mention with its match-confidence band.
-- Demo views can filter by confidence (high for CSR drill-down; any
-- band for CCO sentiment aggregation).

CREATE OR REFRESH MATERIALIZED VIEW fact_social_mentions (
  mention_id            STRING NOT NULL,
  customer_id           BIGINT,
  platform              STRING,
  posted_at             TIMESTAMP,
  posted_date_key       INT,
  source_complaint_id   STRING,
  source_outage_id      STRING,
  post_driver           STRING,
  category              STRING,
  sub_category          STRING,
  sentiment_label       STRING,
  reach_estimate        INT,
  engagement_count      INT,
  mention_text          STRING,
  match_confidence_band STRING,
  match_score           DOUBLE,
  matching_method       STRING,
  _ingested_at          TIMESTAMP,
  CONSTRAINT fk_fsm_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id) NOT ENFORCED RELY,
  CONSTRAINT fk_fsm_date FOREIGN KEY (posted_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Social Mentions fact - public posts from demo-territory customers joined with fuzzy-match confidence. customer_id is a durable BIGINT key.'
AS

SELECT
  m.mention_id,
  abs(xxhash64(m.customer_id))                                             AS customer_id,
  m.platform,
  m.posted_at,
  CAST(DATE_FORMAT(m.posted_at, 'yyyyMMdd') AS INT)                   AS posted_date_key,
  m.source_complaint_id,
  m.source_outage_id,
  m.post_driver,
  m.category,
  m.sub_category,
  m.sentiment_label,
  m.reach_estimate,
  m.engagement_count,
  m.mention_text,
  sm.confidence_band                                                  AS match_confidence_band,
  sm.match_score,
  sm.matching_method,
  current_timestamp()                                                 AS _ingested_at
FROM ${social_schema}.raw_social_mention m
LEFT JOIN ${social_schema}.raw_social_match sm USING (mention_id);
