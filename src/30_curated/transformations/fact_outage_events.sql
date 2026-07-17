-- Outage events fact. Pass-through with date_key.

CREATE OR REFRESH MATERIALIZED VIEW fact_outage_events (
  outage_id                STRING  NOT NULL PRIMARY KEY,
  circuit_id                INT,
  started_at                TIMESTAMP,
  ended_at                  TIMESTAMP,
  started_date_key          INT,
  duration_minutes          INT,
  duration_bucket           STRING,
  cause_code                STRING,
  weather_category          STRING,
  affected_customer_count   BIGINT,
  is_major_event_day        BOOLEAN,
  _ingested_at              TIMESTAMP,
  CONSTRAINT fk_foe_date FOREIGN KEY (started_date_key) REFERENCES dim_date (date_key) NOT ENFORCED RELY
)
COMMENT 'Outage events fact. CIM Outage. PK: outage_id.'
AS

SELECT
  outage_id,
  circuit_id,
  started_at,
  ended_at,
  CAST(DATE_FORMAT(started_at, 'yyyyMMdd') AS INT)                    AS started_date_key,
  duration_minutes,
  -- Duration buckets useful for filter / SAIDI exclusion.
  CASE
    WHEN duration_minutes <= 30   THEN 'short_<=30m'
    WHEN duration_minutes <= 120  THEN 'medium_31_120m'
    WHEN duration_minutes <= 360  THEN 'long_2_6h'
    WHEN duration_minutes <= 1440 THEN 'extended_6_24h'
    ELSE                                'major_24h_plus'
  END                                                                AS duration_bucket,
  cause_code,
  weather_category,
  affected_customer_count,
  is_major_event_day,
  current_timestamp() AS _ingested_at
FROM ${outages_schema}.raw_outage_event;
