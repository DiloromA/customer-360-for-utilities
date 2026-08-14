# Databricks notebook source
# MAGIC %md
# MAGIC # Train EV detection classifier
# MAGIC
# MAGIC Binary classifier (`has_ev` 1/0) trained on AMI-derived patterns
# MAGIC only. The label comes from `raw_der_customer.has_ev` and is held out
# MAGIC from the features so the model has to find the EV signal in total-kwh
# MAGIC patterns alone.
# MAGIC
# MAGIC Artifacts:
# MAGIC - MLflow run under the experiment passed via parameter.
# MAGIC - Model registered in Unity Catalog at
# MAGIC   `<catalog>.<schema>.ml_ev_detector` with alias `@champion`.
# MAGIC - Training snapshot table at
# MAGIC   `<catalog>.<schema>.ml_ev_training_data` so the model's view of
# MAGIC   the world is queryable from SQL.

# COMMAND ----------

# MAGIC %pip install xgboost==2.1.3 mlflow==3.5.0 "scikit-learn>=1.6"
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
dbutils.widgets.text("experiment_name", "/Shared/experiments/customer_360")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value: str, label: str) -> str:
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")
experiment_name = dbutils.widgets.get("experiment_name").strip()
if not experiment_name.startswith("/"):
    raise ValueError(
        f"experiment_name must be an absolute workspace path, got {experiment_name!r}"
    )

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")

print(f"Catalog:    {catalog}")
print(f"Schema:     {schema}")
print(f"Experiment: {experiment_name}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Load features
# MAGIC
# MAGIC `ml_ev_detection_features` is produced by the upstream SDP pipeline
# MAGIC (`features.sql`). The categorical demographic columns are one-hot encoded
# MAGIC inline because XGBoost's `enable_categorical` mode can produce
# MAGIC non-portable models for UC registration. The feature lists and the
# MAGIC name-sanitizer come from `feature_spec` so train and score can't drift.

# COMMAND ----------

# MAGIC %run ./feature_spec

# COMMAND ----------

import pandas as pd

features_df = (
    spark.table(f"{catalog}.{schema}.ml_ev_detection_features")
    .toPandas()
)
print(f"Total customers: {len(features_df)}")
print(f"Positive (has_ev) rate: {features_df['has_ev_label'].mean():.1%}")

# One-hot the small-cardinality categoricals.
encoded = pd.get_dummies(
    features_df[NUMERIC_FEATURES + CATEGORICAL_FEATURES + ["has_ev_label", "household_size"]],
    columns=CATEGORICAL_FEATURES,
    drop_first=False,
    dummy_na=False,
)
encoded.columns = [_safe_feature_name(c) for c in encoded.columns]
FEATURE_COLUMNS = [c for c in encoded.columns if c != "has_ev_label"]
print(f"Feature columns after encoding: {len(FEATURE_COLUMNS)}")

# Persist the exact training snapshot for SQL exploration. Written
# Spark-natively straight from the source feature table: a
# createDataFrame(pandas) round-trip serializes the whole frame into one
# broadcast RPC and blows spark.rpc.message.maxSize (256MB) at full scale.
snapshot_table = f"{catalog}.{schema}.ml_ev_training_data"
(
    spark.table(f"{catalog}.{schema}.ml_ev_detection_features")
    .write.mode("overwrite")
    # overwriteSchema: the curated re-key changed customer_id STRING -> BIGINT,
    # so a plain overwrite hits DELTA_FAILED_TO_MERGE_FIELDS against the stale
    # table schema. Replace the schema on overwrite.
    .option("overwriteSchema", "true")
    .saveAsTable(snapshot_table)
)
print(f"Wrote {snapshot_table} ({spark.table(snapshot_table).count()} rows)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Train XGBoost

# COMMAND ----------

import mlflow
import mlflow.xgboost
import xgboost as xgb
from sklearn.metrics import (
    accuracy_score,
    average_precision_score,
    classification_report,
    roc_auc_score,
)
from sklearn.model_selection import train_test_split

# Pass a DataFrame (not numpy array) so the booster keeps feature names.
# Scoring later reloads via name → column alignment; without this step
# booster.feature_names ends up None and scoring silently feeds zeros.
X = encoded[FEATURE_COLUMNS].astype(float).fillna(0.0)
y = encoded["has_ev_label"].astype(int).values

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42, stratify=y
)
print(f"Train: {X_train.shape}, Test: {X_test.shape}")
X_train = X_train.reset_index(drop=True)
X_test = X_test.reset_index(drop=True)
print(f"Train EV rate: {y_train.mean():.1%}, Test EV rate: {y_test.mean():.1%}")

mlflow.set_registry_uri("databricks-uc")
mlflow.set_experiment(experiment_name)

import math

# Imbalance handling — typical utility EV adoption is well under 10%.
# Full inverse ratio (~30:1 here) over-corrects and makes the model
# predict positive for everyone. sqrt is the standard middle ground.
imbalance_ratio = (len(y_train) - y_train.sum()) / max(y_train.sum(), 1)
scale_pos_weight = math.sqrt(imbalance_ratio)

params = {
    "objective": "binary:logistic",
    "learning_rate": 0.05,
    "max_depth": 5,
    "min_child_weight": 3,
    "subsample": 0.85,
    "colsample_bytree": 0.85,
    "n_estimators": 400,
    "eval_metric": "auc",
    "random_state": 42,
    "scale_pos_weight": scale_pos_weight,
}

model_name = f"{catalog}.{schema}.ml_ev_detector"

with mlflow.start_run(run_name="xgboost_ev_detector") as run:
    mlflow.log_params(params)
    mlflow.log_param("n_train_rows", int(len(X_train)))
    mlflow.log_param("n_test_rows", int(len(X_test)))
    mlflow.log_param("n_features", len(FEATURE_COLUMNS))
    mlflow.log_param("base_rate", float(y.mean()))

    model = xgb.XGBClassifier(**params)
    model.fit(X_train, y_train, eval_set=[(X_test, y_test)], verbose=False)

    test_pred = model.predict(X_test)
    test_proba = model.predict_proba(X_test)[:, 1]

    metrics = {
        "test_accuracy": float(accuracy_score(y_test, test_pred)),
        "test_auc": float(roc_auc_score(y_test, test_proba)),
        "test_avg_precision": float(average_precision_score(y_test, test_proba)),
        "test_positive_rate": float(test_pred.mean()),
    }
    mlflow.log_metrics(metrics)

    print("Test set classification report:")
    print(classification_report(y_test, test_pred, target_names=["No EV", "Has EV"]))
    print(f"Metrics: {metrics}")

    feature_importance = dict(zip(FEATURE_COLUMNS, model.feature_importances_.tolist()))
    mlflow.log_dict(feature_importance, "feature_importance.json")

    input_example = X_train.head(5)
    signature = mlflow.models.infer_signature(
        input_example, model.predict_proba(input_example)
    )

    booster = model.get_booster()
    mlflow.xgboost.log_model(
        xgb_model=booster,
        name="model",
        signature=signature,
        input_example=input_example,
        registered_model_name=model_name,
        model_format="json",
    )
    run_id = run.info.run_id

print(f"Run ID: {run_id}")
print(f"Registered model: {model_name}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Promote latest version to @champion

# COMMAND ----------

from mlflow.tracking import MlflowClient

client = MlflowClient()
versions = client.search_model_versions(f"name='{model_name}'")
latest_version = max(int(v.version) for v in versions)
client.set_registered_model_alias(model_name, "champion", latest_version)
print(f"Alias @champion → version {latest_version}")

dbutils.jobs.taskValues.set(key="run_id", value=run_id)
dbutils.jobs.taskValues.set(key="model_name", value=model_name)
dbutils.jobs.taskValues.set(key="model_version", value=str(latest_version))
dbutils.jobs.taskValues.set(key="features", value=",".join(FEATURE_COLUMNS))
