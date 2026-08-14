-- Unregistered-PV detection feature table — one row per customer.
--
-- Utilities already KNOW their registered solar via interconnection
-- agreements / net metering (raw_der_customer.pv_net_metered = true for
-- every adopter). This model is NOT "does this customer have PV" — it's
-- "does this customer's consumption pattern look like rooftop PV that
-- ISN'T on the interconnection register": self-installs, expired
-- permits, islanding-safety and revenue-protection risk, forecasting
-- error. That framing is why features are restricted to columns
-- derivable from the delivered-energy channel only: registered systems
-- already show up in the export channel; unregistered ones must be
-- inferred from net consumption behavior alone.
--
-- Anti-leakage: features are derived ONLY from kwh_delivered-derived
-- columns (midday_kwh, min_hour_kwh, kwh_delivered itself). We never read
-- kwh_pv, kwh_received, or kwh_base — those are near-perfect label leaks
-- (a utility trying to detect UNregistered PV doesn't have ground-truth
-- generation telemetry for it).
--
-- The label has_pv is joined from raw_der_customer (a stand-in for "is
-- on the interconnection register" in this synthetic world — every
-- synthetic PV adopter is registered, so what the model learns here is
-- the consumption signature to later apply where the register and the
-- meter disagree). This is the ONLY place we look at the label;
-- production scoring (score.py) consumes the feature side only.

CREATE OR REFRESH MATERIALIZED VIEW ml_pv_detection_features (
  CONSTRAINT non_null_customer_id EXPECT (customer_id IS NOT NULL)
)
COMMENT 'Customer-level features for unregistered-PV detection. Derived from fact_meter_readings_daily (delivered-energy channel only — no kwh_pv/kwh_received/kwh_base). Labels joined from raw_der_customer.has_pv (proxy for the interconnection register) for training/validation only — inference does not use the label. Use case: flag consumption patterns consistent with unregistered rooftop solar for interconnection-record validation. PK: customer_id.'
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
    d.midday_kwh,
    d.min_hour_kwh
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
  -- service_points, so without this collapse, the midday-dip signature below
  -- would be computed over per-METER daily values instead of the customer's
  -- true daily total (each meter's own midday dip is a weaker, noisier
  -- version of the whole building's).
  SELECT
    customer_id,
    reading_date,
    SUM(kwh_delivered) AS kwh_delivered,
    SUM(midday_kwh)    AS midday_kwh,
    SUM(min_hour_kwh)  AS min_hour_kwh,
    EXTRACT(MONTH FROM reading_date)     AS month_num,
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
    -- Energy magnitude (context, not a PV tell by itself)
    AVG(kwh_delivered)                                              AS avg_daily_kwh,
    STDDEV_SAMP(kwh_delivered)                                       AS std_daily_kwh,
    PERCENTILE(kwh_delivered, 0.5)                                   AS median_daily_kwh,
    MAX(kwh_delivered)                                               AS max_daily_kwh,
    STDDEV_SAMP(kwh_delivered) / NULLIF(AVG(kwh_delivered), 0)        AS coef_of_variation,

    -- Midday-dip signature — the solar tell. Net demand sags toward /
    -- below zero around solar noon on a PV premise.
    AVG(midday_kwh)                                                  AS avg_midday_kwh,
    -- 5 of 24 hours (10:00-14:00) is ~0.21 of a flat day; PV pushes this
    -- toward 0 as midday generation offsets delivered consumption.
    AVG(midday_kwh) / NULLIF(AVG(kwh_delivered), 0)                  AS midday_to_daily_ratio,
    AVG(min_hour_kwh)                                                AS avg_min_hour_kwh,
    AVG(CASE WHEN midday_kwh < 0.5 THEN 1.0 ELSE 0.0 END)            AS near_zero_midday_fraction
  FROM daily
  GROUP BY customer_id
)

, seasonality AS (
  SELECT
    customer_id,
    -- Opposite direction from the EV model: insolation suppresses
    -- summer midday delivered-kwh far more than winter, so summer/winter
    -- and the midday ratio split by season are the asymmetry tells.
    AVG(CASE WHEN season = 'summer' THEN kwh_delivered END)
      / NULLIF(AVG(CASE WHEN season = 'winter' THEN kwh_delivered END), 0)
                                                                     AS summer_to_winter_ratio,
    AVG(CASE WHEN season = 'summer' THEN midday_kwh END)
      / NULLIF(AVG(CASE WHEN season = 'summer' THEN kwh_delivered END), 0)
                                                                     AS summer_midday_to_daily_ratio,
    AVG(CASE WHEN season = 'winter' THEN midday_kwh END)
      / NULLIF(AVG(CASE WHEN season = 'winter' THEN kwh_delivered END), 0)
                                                                     AS winter_midday_to_daily_ratio
  FROM daily
  GROUP BY customer_id
)

, seasonality_gap AS (
  SELECT
    customer_id,
    summer_to_winter_ratio,
    summer_midday_to_daily_ratio,
    winter_midday_to_daily_ratio,
    winter_midday_to_daily_ratio - summer_midday_to_daily_ratio AS midday_seasonal_gap
  FROM seasonality
)

, customer_context AS (
  SELECT
    customer_id,
    income_band,
    household_size,
    customer_class,
    peer_building_subtype,
    peer_sqft_band,
    tenure
  FROM ${curated_schema}.dim_customer
)

, label AS (
  -- The raw DER feed keeps its STRING natural key; curated mints BIGINT
  -- customer_id. Resolve via dim_customer.customer_number. MAX(): a
  -- customer "has PV" if any of their premises does (multi-site chains).
  SELECT
    dc.customer_id                  AS customer_id,
    MAX(CAST(d.has_pv AS INT))      AS has_pv_label
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
  cc.tenure,

  -- Energy magnitude
  ROUND(t.avg_daily_kwh, 2)               AS avg_daily_kwh,
  ROUND(t.std_daily_kwh, 2)               AS std_daily_kwh,
  ROUND(t.median_daily_kwh, 2)            AS median_daily_kwh,
  ROUND(t.max_daily_kwh, 2)               AS max_daily_kwh,
  ROUND(t.coef_of_variation, 3)           AS coef_of_variation,

  -- Midday-dip signature
  ROUND(t.avg_midday_kwh, 2)              AS avg_midday_kwh,
  ROUND(t.midday_to_daily_ratio, 3)       AS midday_to_daily_ratio,
  ROUND(t.avg_min_hour_kwh, 3)            AS avg_min_hour_kwh,
  ROUND(t.near_zero_midday_fraction, 3)   AS near_zero_midday_fraction,

  -- Seasonal asymmetry
  ROUND(sg.summer_to_winter_ratio, 3)          AS summer_to_winter_ratio,
  ROUND(sg.summer_midday_to_daily_ratio, 3)    AS summer_midday_to_daily_ratio,
  ROUND(sg.winter_midday_to_daily_ratio, 3)    AS winter_midday_to_daily_ratio,
  ROUND(sg.midday_seasonal_gap, 3)             AS midday_seasonal_gap,

  -- Label (training/validation only)
  COALESCE(l.has_pv_label, 0)              AS has_pv_label,

  current_timestamp() AS _ingested_at
FROM totals t
LEFT JOIN seasonality_gap  sg USING (customer_id)
LEFT JOIN customer_context cc USING (customer_id)
LEFT JOIN label             l USING (customer_id);
