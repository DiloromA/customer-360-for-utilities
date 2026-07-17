# Databricks notebook source
# MAGIC %md
# MAGIC # Table & column comments + UC tags — ml_pv_* tables

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
    "ml_pv_detection_features": (
        "Customer-level features for unregistered-PV detection. Derived from "
        "fact_meter_readings_daily's delivered-energy channel only. Labels "
        "joined from raw_der_customer.has_pv (proxy for the interconnection "
        "register) for training and validation only — scoring does not "
        "consume it. Use case: flag consumption patterns consistent with "
        "unregistered rooftop solar for interconnection-record validation.",
        {
            "customer_id":                    "PK. FK -> dim_customer.customer_id.",
            "customer_class":                 "Residential | SmallCommercial | LargeCommercial. Demographic feature.",
            "income_band":                    "ACS-derived income decile band.",
            "household_size":                 "ACS-derived household size.",
            "peer_building_subtype":          "Building type label for peer comparison (single-family, multi-family, etc.).",
            "peer_sqft_band":                 "Square-footage band used for peer comparison.",
            "tenure":                         "Own | Rent. Strongly correlated with rooftop-PV eligibility.",
            "avg_daily_kwh":                  "Mean daily total kWh delivered, 2018 full year.",
            "std_daily_kwh":                  "Day-to-day standard deviation of total kWh.",
            "median_daily_kwh":               "Median daily total kWh.",
            "max_daily_kwh":                  "Max daily total kWh observed.",
            "coef_of_variation":              "std_daily_kwh / avg_daily_kwh. Higher = more irregular consumption.",
            "avg_midday_kwh":                 "Mean of daily 10:00-14:00 delivered kWh — sags toward zero on a PV premise.",
            "midday_to_daily_ratio":          "avg_midday_kwh / avg_daily_kwh. ~0.21 baseline (5 of 24 hrs); PV pushes it toward 0.",
            "avg_min_hour_kwh":               "Mean of the per-day minimum-hour kWh — floors near zero midday for PV premises.",
            "near_zero_midday_fraction":      "Fraction of days with midday_kwh < 0.5 kWh (deep-suppression days).",
            "summer_to_winter_ratio":         "Avg summer daily kWh / avg winter daily kWh.",
            "summer_midday_to_daily_ratio":   "Midday-to-daily ratio restricted to summer months.",
            "winter_midday_to_daily_ratio":   "Midday-to-daily ratio restricted to winter months.",
            "midday_seasonal_gap":            "winter_midday_to_daily_ratio - summer_midday_to_daily_ratio. Insolation suppresses summer midday far more than winter; nothing else produces this split.",
            "has_pv_label":                   "Ground truth: 1 if has_pv = true in raw_der_customer. Used for training/validation only.",
        },
    ),
    "ml_pv_training_data": (
        "Snapshot of ml_pv_detection_features taken at training time. Lets "
        "SQL + Genie query the exact rows the model saw.",
        {},
    ),
    "ml_pv_detection_predictions": (
        "Per-customer unregistered-PV likelihood scores from the latest "
        "@champion run of ml_pv_detector. Consumed by the app's customer "
        "drawer to flag likely-unregistered PV (pv_likely_flag true, "
        "has_pv_label false).",
        {
            "customer_id":     "PK. FK -> dim_customer.customer_id.",
            "pv_probability":  "Predicted probability the customer's consumption pattern matches unregistered rooftop PV (0-1).",
            "pv_likely_flag":  "1 if pv_probability >= the base-rate threshold picked at scoring time.",
            "has_pv_label":    "Ground truth for offline evaluation. NOT used at scoring time.",
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
