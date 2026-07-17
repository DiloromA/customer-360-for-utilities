# Databricks notebook source
# MAGIC %md
# MAGIC # Table & column comments + UC tags — ml_ev_* tables

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value, label):
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")

# COMMAND ----------

TABLE_COMMENTS = {
    "ml_ev_detection_features": (
        "Customer-level features for EV detection. Derived from "
        "fact_meter_readings_daily; the label has_ev_label is joined "
        "from raw_der_customer for training and "
        "validation only — scoring does not consume it.",
        {
            "customer_id":             "PK. FK -> dim_customer.customer_id.",
            "customer_class":          "Residential | SmallCommercial | LargeCommercial. Demographic feature.",
            "income_band":             "ACS-derived income decile band.",
            "household_size":          "ACS-derived household size.",
            "peer_building_subtype":   "Building type label for peer comparison (single-family, multi-family, etc.).",
            "peer_sqft_band":          "Square-footage band used for peer comparison.",
            "avg_daily_kwh":           "Mean daily total kWh delivered, 2018 full year.",
            "std_daily_kwh":           "Day-to-day standard deviation of total kWh.",
            "median_daily_kwh":        "Median daily total kWh.",
            "max_daily_kwh":           "Max daily total kWh observed.",
            "avg_peak_hour_kwh":       "Mean of the per-day peak-hour kWh.",
            "max_peak_hour_kwh":       "Max single-hour kWh across the year (sharp spikes signal Level-2 EV charging).",
            "peak_to_mean_ratio":      "avg_peak_hour_kwh / hourly mean. >2 suggests sharp loading.",
            "coef_of_variation":       "std_daily_kwh / avg_daily_kwh. Higher = more irregular consumption.",
            "avg_summer_kwh":          "Avg daily kWh Jun–Sep.",
            "avg_winter_kwh":          "Avg daily kWh Dec–Feb.",
            "avg_shoulder_kwh":        "Avg daily kWh shoulder months.",
            "summer_to_winter_ratio":  "Drops when an EV adds year-round flat load.",
            "avg_weekend_kwh":         "Mean daily kWh on Sat/Sun.",
            "avg_weekday_kwh":         "Mean daily kWh on Mon–Fri.",
            "weekday_to_weekend_ratio":"Above 1 suggests commuter-EV charging weekdays.",
            "overnight_peak_fraction": "Fraction of days where peak hour falls 22:00-06:00.",
            "evening_peak_fraction":   "Fraction of days where peak hour falls 17:00-21:00.",
            "mode_peak_hour":          "Most-frequent peak hour of day, 0-23.",
            "has_ev_label":            "Ground truth: 1 if has_ev = true in raw_der_customer. Used for training/validation only.",
        },
    ),
    "ml_ev_training_data": (
        "Snapshot of ml_ev_detection_features taken at training time. Lets "
        "SQL + Genie query the exact rows the model saw.",
        {},
    ),
    "ml_ev_detection_predictions": (
        "Per-customer EV likelihood scores from the latest @champion run "
        "of ml_ev_detector. Consumed by the app's customer drawer to flag "
        "likely-unregistered EV (ev_likely_flag true, has_ev_label false).",
        {
            "customer_id":     "PK. FK -> dim_customer.customer_id.",
            "ev_probability":  "Predicted probability the customer owns an EV (0-1).",
            "ev_likely_flag":  "1 if ev_probability >= 0.5.",
            "has_ev_label":    "Ground truth for offline evaluation. NOT used at scoring time.",
            "scored_at":       "Timestamp when the predictions were produced.",
        },
    ),
}

# COMMAND ----------

for table_name, (table_comment, column_comments) in TABLE_COMMENTS.items():
    fqn = f"`{catalog}`.`{schema}`.`{table_name}`"
    if not spark.catalog.tableExists(fqn):
        print(f"  Skip {fqn} (does not exist yet)")
        continue
    spark.sql(
        f"COMMENT ON TABLE {fqn} IS '{table_comment.replace(chr(39), chr(39) * 2)}'"
    )
    existing = {c.name for c in spark.table(fqn).schema.fields}
    for col, col_comment in column_comments.items():
        if col not in existing:
            continue
        escaped = col_comment.replace("'", "''")
        # COMMENT ON COLUMN works for both tables and (materialized) views;
        # ALTER TABLE ... ALTER COLUMN fails on views with EXPECT_TABLE_NOT_VIEW.
        spark.sql(f"COMMENT ON COLUMN {fqn}.`{col}` IS '{escaped}'")
    try:
        spark.sql(
            f"ALTER TABLE {fqn} SET TAGS ('demo' = 'customer-360-for-utilities')"
        )
    except Exception as e:
        print(f"  Tag failed for {fqn}: {e}")
    print(f"  Commented {fqn}")

print("Done.")
