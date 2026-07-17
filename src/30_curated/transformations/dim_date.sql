-- Date dimension. Covers 2014-2020 to encompass all demo data
-- (SAP legacy starts 2014, AMI runs 2017-2018, social goes to 2018).
-- ~2,500 rows.

CREATE OR REFRESH MATERIALIZED VIEW dim_date (
  date_key     INT NOT NULL PRIMARY KEY RELY,
  date_value   DATE,
  year         INT,
  quarter      INT,
  month        INT,
  day_of_month INT,
  day_of_week  INT,
  day_name     STRING,
  month_name   STRING,
  week_of_year INT,
  is_weekend   BOOLEAN,
  season       STRING,
  tou_day_type STRING,
  _ingested_at TIMESTAMP
)
COMMENT 'Date dimension covering 2014-2020 to span all demo data. date_key is the yyyymmdd integer natural key. One row per calendar day.'
AS

WITH date_seq AS (
  SELECT EXPLODE(SEQUENCE(DATE'2014-01-01', DATE'2020-12-31', INTERVAL 1 DAY)) AS d
)

SELECT
  CAST(DATE_FORMAT(d, 'yyyyMMdd') AS INT)         AS date_key,
  d                                                AS date_value,
  YEAR(d)                                          AS year,
  QUARTER(d)                                       AS quarter,
  MONTH(d)                                         AS month,
  DAY(d)                                           AS day_of_month,
  DAYOFWEEK(d)                                     AS day_of_week,
  DATE_FORMAT(d, 'EEEE')                           AS day_name,
  DATE_FORMAT(d, 'MMMM')                           AS month_name,
  WEEKOFYEAR(d)                                    AS week_of_year,
  CASE WHEN DAYOFWEEK(d) IN (1, 7) THEN true ELSE false END AS is_weekend,
  -- Heating / cooling season buckets (climate zone 5A, Michigan).
  CASE
    WHEN MONTH(d) IN (12, 1, 2)        THEN 'winter'
    WHEN MONTH(d) IN (3, 4, 5)         THEN 'spring'
    WHEN MONTH(d) IN (6, 7, 8)         THEN 'summer'
    ELSE                                    'fall'
  END                                              AS season,
  -- TOU bucket for the EV-TOU rate (M-F 14:00-19:00 peak; weekends all off-peak).
  CASE WHEN DAYOFWEEK(d) BETWEEN 2 AND 6 THEN 'weekday' ELSE 'weekend' END AS tou_day_type,
  current_timestamp() AS _ingested_at
FROM date_seq;
