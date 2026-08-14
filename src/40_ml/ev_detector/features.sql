-- EV detection feature table — one row per customer.
--
-- All features are derived from total kwh_delivered patterns; we
-- deliberately ignore the kwh_ev breakdown so the model has to
-- rediscover the EV signal from AMI alone (the actual use case for
-- a utility that doesn't have ground-truth EV registration data).
--
-- The label has_ev is joined from raw_der_customer.
-- This is the ONLY place we look at the label; production scoring
-- (score.py) consumes the feature side only.

CREATE OR REFRESH MATERIALIZED VIEW ml_ev_detection_features (
  CONSTRAINT non_null_customer_id EXPECT (customer_id IS NOT NULL)
)
COMMENT 'Customer-level features for EV detection. Derived from fact_meter_readings_daily. Labels joined from raw_der_customer.has_ev for training/validation only — inference does not use the label. PK: customer_id.'
AS

WITH agr AS (
  -- fact_meter_readings_daily is physical (service_point) grain, not
  -- customer-stamped (temporal-realism: an customer can change
  -- mid-window). Resolve customer_id per reading via the as-of agreement in
  -- force on that reading's own date.
  SELECT service_point_id, customer_id, effective_date, termination_date
  FROM ${curated_schema}.dim_service_agreement
),

daily_by_sp AS (
  SELECT
    a.customer_id,
    d.reading_date,
    d.kwh_delivered,
    d.peak_hour_kwh,
    d.peak_hour_of_day
  FROM ${curated_schema}.fact_meter_readings_daily d
  CROSS JOIN ${curated_schema}.curated_demo_config cfg
  JOIN agr a
    ON a.service_point_id = d.service_point_id
   AND a.effective_date <= d.reading_date
   AND (a.termination_date IS NULL OR d.reading_date < a.termination_date)
  WHERE d.reading_date BETWEEN ADD_MONTHS(cfg.as_of_date, -cfg.billing_lookback_months) AND cfg.as_of_date
)

, daily AS (
  -- Sum across sibling service_points per customer-day first. A sub-metered
  -- commercial customer has 2-5 CONCURRENT
  -- service_points, so without this collapse, the magnitude/seasonality
  -- features below would be computed over the distribution of per-METER
  -- daily values instead of the customer's true daily total. peak_hour_kwh /
  -- peak_hour_of_day take the single largest-peak meter's hour as a
  -- reasonable approximation (per-meter hourly detail isn't available here).
  SELECT
    customer_id,
    reading_date,
    SUM(kwh_delivered)                       AS kwh_delivered,
    MAX(peak_hour_kwh)                       AS peak_hour_kwh,
    MAX_BY(peak_hour_of_day, peak_hour_kwh)   AS peak_hour_of_day,
    EXTRACT(MONTH FROM reading_date)     AS month_num,
    EXTRACT(DAYOFWEEK FROM reading_date) AS dow,   -- 1=Sun, 7=Sat
    CASE
      WHEN EXTRACT(MONTH FROM reading_date) IN (6, 7, 8, 9)         THEN 'summer'
      WHEN EXTRACT(MONTH FROM reading_date) IN (12, 1, 2)           THEN 'winter'
      ELSE                                                               'shoulder'
    END                                  AS season
  FROM daily_by_sp
  GROUP BY customer_id, reading_date
)

, totals AS (
  SELECT
    customer_id,
    -- Energy magnitude
    AVG(kwh_delivered)                                              AS avg_daily_kwh,
    STDDEV_SAMP(kwh_delivered)                                       AS std_daily_kwh,
    PERCENTILE(kwh_delivered, 0.5)                                   AS median_daily_kwh,
    MAX(kwh_delivered)                                               AS max_daily_kwh,

    -- Peakiness — EVs add a sharp 5-7 kW load for 4-8 hours
    AVG(peak_hour_kwh)                                               AS avg_peak_hour_kwh,
    MAX(peak_hour_kwh)                                               AS max_peak_hour_kwh,
    AVG(peak_hour_kwh) / NULLIF(AVG(kwh_delivered) / 24.0, 0)        AS peak_to_mean_ratio,

    -- Variability — irregular EV use bumps day-to-day variance
    STDDEV_SAMP(kwh_delivered) / NULLIF(AVG(kwh_delivered), 0)        AS coef_of_variation
  FROM daily
  GROUP BY customer_id
)

, seasonality AS (
  SELECT
    customer_id,
    AVG(CASE WHEN season = 'summer'   THEN kwh_delivered END)        AS avg_summer_kwh,
    AVG(CASE WHEN season = 'winter'   THEN kwh_delivered END)        AS avg_winter_kwh,
    AVG(CASE WHEN season = 'shoulder' THEN kwh_delivered END)        AS avg_shoulder_kwh,
    -- Summer/winter ratio drops when EV adds year-round flat load
    AVG(CASE WHEN season = 'summer' THEN kwh_delivered END)
      / NULLIF(AVG(CASE WHEN season = 'winter' THEN kwh_delivered END), 0)
                                                                     AS summer_to_winter_ratio
  FROM daily
  GROUP BY customer_id
)

, weekly_pattern AS (
  SELECT
    customer_id,
    -- Weekday vs weekend kwh — EVs charge mostly weekdays after commute
    AVG(CASE WHEN dow IN (1, 7) THEN kwh_delivered END)              AS avg_weekend_kwh,
    AVG(CASE WHEN dow BETWEEN 2 AND 6 THEN kwh_delivered END)        AS avg_weekday_kwh,
    AVG(CASE WHEN dow BETWEEN 2 AND 6 THEN kwh_delivered END)
      / NULLIF(AVG(CASE WHEN dow IN (1, 7) THEN kwh_delivered END), 0)
                                                                     AS weekday_to_weekend_ratio
  FROM daily
  GROUP BY customer_id
)

, charging_window AS (
  SELECT
    customer_id,
    -- Fraction of days where peak hour falls in the overnight window
    -- (22:00-06:00). High = strong EV-overnight-charging signature.
    AVG(CASE WHEN peak_hour_of_day BETWEEN 22 AND 23
             OR  peak_hour_of_day BETWEEN 0  AND 5
        THEN 1.0 ELSE 0.0 END)                                       AS overnight_peak_fraction,
    -- Fraction of days where peak hour falls in evening (17-21) —
    -- Level-1/L2 plug-in-after-commute pattern.
    AVG(CASE WHEN peak_hour_of_day BETWEEN 17 AND 21
        THEN 1.0 ELSE 0.0 END)                                       AS evening_peak_fraction,
    -- Mode hour of day for peak — categorical signal of routine
    MODE() WITHIN GROUP (ORDER BY peak_hour_of_day)                  AS mode_peak_hour
  FROM daily
  GROUP BY customer_id
)

, customer_context AS (
  SELECT
    customer_id,
    income_band,
    household_size,
    customer_class,
    peer_building_subtype,
    peer_sqft_band
  FROM ${curated_schema}.dim_customer
)

, label AS (
  -- The raw DER feed keeps its STRING natural key; curated mints BIGINT
  -- customer_id. Resolve the label's string id to the durable BIGINT via
  -- dim_customer.customer_number so it aligns with the feature keys (which come
  -- from the curated, BIGINT-keyed fact). MAX(): a customer "has EV" if any of
  -- their premises does (multi-site chains map many DER rows to one customer).
  SELECT
    dc.customer_id                  AS customer_id,
    MAX(CAST(d.has_ev AS INT))      AS has_ev_label
  FROM ${der_adoption_schema}.raw_der_customer d
  JOIN ${curated_schema}.dim_customer dc ON dc.customer_number = d.customer_id
  GROUP BY dc.customer_id
)

SELECT
  t.customer_id,

  -- Demographics for stratification + as model features
  cc.customer_class,
  cc.income_band,
  cc.household_size,
  cc.peer_building_subtype,
  cc.peer_sqft_band,

  -- Energy magnitude
  ROUND(t.avg_daily_kwh, 2)            AS avg_daily_kwh,
  ROUND(t.std_daily_kwh, 2)            AS std_daily_kwh,
  ROUND(t.median_daily_kwh, 2)         AS median_daily_kwh,
  ROUND(t.max_daily_kwh, 2)            AS max_daily_kwh,

  -- Peakiness
  ROUND(t.avg_peak_hour_kwh, 3)        AS avg_peak_hour_kwh,
  ROUND(t.max_peak_hour_kwh, 3)        AS max_peak_hour_kwh,
  ROUND(t.peak_to_mean_ratio, 3)       AS peak_to_mean_ratio,
  ROUND(t.coef_of_variation, 3)        AS coef_of_variation,

  -- Seasonality
  ROUND(s.avg_summer_kwh, 2)           AS avg_summer_kwh,
  ROUND(s.avg_winter_kwh, 2)           AS avg_winter_kwh,
  ROUND(s.avg_shoulder_kwh, 2)         AS avg_shoulder_kwh,
  ROUND(s.summer_to_winter_ratio, 3)   AS summer_to_winter_ratio,

  -- Weekly pattern
  ROUND(w.avg_weekend_kwh, 2)          AS avg_weekend_kwh,
  ROUND(w.avg_weekday_kwh, 2)          AS avg_weekday_kwh,
  ROUND(w.weekday_to_weekend_ratio, 3) AS weekday_to_weekend_ratio,

  -- Charging-window signatures
  ROUND(c.overnight_peak_fraction, 3)  AS overnight_peak_fraction,
  ROUND(c.evening_peak_fraction, 3)    AS evening_peak_fraction,
  c.mode_peak_hour                     AS mode_peak_hour,

  -- Label (training/validation only)
  COALESCE(l.has_ev_label, 0)          AS has_ev_label,

  current_timestamp() AS _ingested_at
FROM totals t
LEFT JOIN seasonality       s  USING (customer_id)
LEFT JOIN weekly_pattern    w  USING (customer_id)
LEFT JOIN charging_window   c  USING (customer_id)
LEFT JOIN customer_context  cc USING (customer_id)
LEFT JOIN label             l  USING (customer_id);
