# Databricks notebook source
# MAGIC %md
# MAGIC # Score all customers for unregistered-PV likelihood
# MAGIC
# MAGIC Loads `@champion` from UC, applies it to every row of
# MAGIC `ml_pv_detection_features`, and writes per-customer PV probabilities
# MAGIC to `ml_pv_detection_predictions`. Consumed by the app's customer
# MAGIC drawer to surface a "likely unregistered PV" flag when the prediction
# MAGIC disagrees with the interconnection record.

# COMMAND ----------

# MAGIC %pip install xgboost==2.1.3 mlflow==3.5.0 "scikit-learn>=1.6"
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value: str, label: str) -> str:
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")

print(f"Catalog: {catalog}")
print(f"Schema:  {schema}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Load model + features

# COMMAND ----------

# MAGIC %run ./feature_spec

# COMMAND ----------

import mlflow
import pandas as pd
import xgboost as xgb

mlflow.set_registry_uri("databricks-uc")

model_name = f"{catalog}.{schema}.ml_pv_detector"
model_uri = f"models:/{model_name}@champion"
booster = mlflow.xgboost.load_model(model_uri)
print(f"Loaded {model_uri}")

features_df = (
    spark.table(f"{catalog}.{schema}.ml_pv_detection_features")
    .toPandas()
)
print(f"Scoring {len(features_df)} customers")

encoded = pd.get_dummies(
    features_df[NUMERIC_FEATURES + CATEGORICAL_FEATURES + ["household_size"]],
    columns=CATEGORICAL_FEATURES,
    drop_first=False,
    dummy_na=False,
)
# _safe_feature_name comes from feature_spec — same map as training time,
# so the encoded columns align with what's stored on the booster.
encoded.columns = [_safe_feature_name(c) for c in encoded.columns]

# Align encoded columns to the model's expected feature names. The
# booster carries feature_names when trained on a DataFrame (see
# train.py); if names match the training set, missing
# columns are filled with 0 and extras dropped.
expected_features = booster.feature_names
if not expected_features:
    raise RuntimeError(
        "booster.feature_names is empty — was the model trained on a "
        "numpy array? Refit using a DataFrame so feature names persist."
    )
for col in expected_features:
    if col not in encoded.columns:
        encoded[col] = 0.0
X = encoded[expected_features].astype(float).fillna(0.0)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Predict + write

# COMMAND ----------

dmat = xgb.DMatrix(X, feature_names=expected_features)
pv_proba = booster.predict(dmat)

# Pick the threshold by base rate: the top K customers by predicted
# probability where K = expected positive count. This lines up the
# "flag" with the actual PV prevalence instead of using a hard 0.5
# cutoff that's miscalibrated for imbalanced data.
base_rate = features_df["has_pv_label"].mean()
top_k = int(round(base_rate * len(pv_proba)))
threshold = float(pd.Series(pv_proba).nlargest(top_k).min()) if top_k > 0 else 0.5
print(f"Base rate {base_rate:.1%} → flagging top {top_k} (threshold={threshold:.3f})")

predictions = pd.DataFrame({
    "customer_id":     features_df["customer_id"].values,
    "pv_probability":  pv_proba,
    "pv_likely_flag":  (pv_proba >= threshold).astype(int),
    "has_pv_label":    features_df["has_pv_label"].values,  # for offline eval
})
predictions["scored_at"] = pd.Timestamp.utcnow()

(
    spark.createDataFrame(predictions)
    .write.mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(f"{catalog}.{schema}.ml_pv_detection_predictions")
)
print(f"Wrote {len(predictions)} predictions to ml_pv_detection_predictions")
print(f"Predicted PV rate: {predictions['pv_likely_flag'].mean():.1%}")
print(f"Actual PV rate (validation): {predictions['has_pv_label'].mean():.1%}")
