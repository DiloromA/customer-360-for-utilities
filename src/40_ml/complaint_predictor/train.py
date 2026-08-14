# Databricks notebook source
# MAGIC %md
# MAGIC # Train complaint-risk classifiers
# MAGIC
# MAGIC Five one-vs-rest XGBoost binaries (`any` + billing / outage / payment /
# MAGIC service) on the customer × billing-cycle grain of
# MAGIC `ml_complaint_risk_features`. Multiclass would force the ~0.3%-rate
# MAGIC heads to compete under softmax, and a customer genuinely can be
# MAGIC high-risk for `billing` and `outage` at once — independent heads
# MAGIC express that.
# MAGIC
# MAGIC Split is time-based (train ≤ SPLIT_DATE, evaluate after): billing and
# MAGIC outage conditions are strongly autocorrelated within a customer, so a
# MAGIC random split would leak.
# MAGIC
# MAGIC Artifacts:
# MAGIC - One MLflow run, metrics prefixed per head (`any_test_auc`, ...),
# MAGIC   plus per-head feature-importance / calibration JSON artifacts.
# MAGIC - Single pyfunc model wrapping all five boosters, registered in UC at
# MAGIC   `<catalog>.<schema>.ml_complaint_predictor` with alias `@champion` —
# MAGIC   one predict() call returns all five probability columns.
# MAGIC - Training snapshot at `<catalog>.<schema>.ml_complaint_training_data`
# MAGIC   (with the train/test split column) so the model's view of the world
# MAGIC   is queryable from SQL.

# COMMAND ----------

# MAGIC %pip install xgboost==2.1.3 mlflow==3.5.0 "scikit-learn>=1.6"
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
dbutils.widgets.text("experiment_name", "/Shared/experiments/customer_360")
dbutils.widgets.text("as_of_date", "2018-12-31")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")
_SAFE_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _check_id(value: str, label: str) -> str:
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


def _check_date(value: str, label: str) -> str:
    if not _SAFE_DATE.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")
as_of_date = _check_date(dbutils.widgets.get("as_of_date").strip(), "as_of_date")
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
# MAGIC ## Load features + time split
# MAGIC
# MAGIC `ml_complaint_risk_features` is produced by the upstream SDP pipeline
# MAGIC (`features.sql`). Categoricals are one-hot encoded inline because
# MAGIC XGBoost's `enable_categorical` mode can produce non-portable models
# MAGIC for UC registration. Feature lists, head definitions, split date, and
# MAGIC the name-sanitizer come from `feature_spec` so train and score can't
# MAGIC drift.

# COMMAND ----------

# MAGIC %run ./feature_spec

# COMMAND ----------

import pandas as pd

# feature_spec's SPLIT_DATE is a fallback default only — override it here so
# the train/test boundary tracks as_of_date (trailing 6 months held out)
# instead of going stale once the display window shifts (see databricks.yml
# as_of_date / history_months).
SPLIT_DATE = (pd.Timestamp(as_of_date) - pd.DateOffset(months=6)).strftime("%Y-%m-%d")

# Pull only the columns the model consumes (features + labels + the split key
# + customer_id for the grouped early-stopping split) — not SELECT *. The
# snapshot below still reads the full source table Spark-natively, so trimming
# here only shrinks the driver-side pandas frame.
_needed_cols = (
    NUMERIC_FEATURES
    + CATEGORICAL_FEATURES
    + LABEL_COLUMNS
    + ["bill_period_end", "customer_id"]
)
features_df = (
    spark.table(f"{catalog}.{schema}.ml_complaint_risk_features")
    .select(*_needed_cols)
    .toPandas()
)
features_df["bill_period_end"] = pd.to_datetime(features_df["bill_period_end"])
print(f"Total customer-cycles: {len(features_df)}")
for head, label_col in HEADS.items():
    print(f"  {head:8s} positive rate: {features_df[label_col].mean():.2%}")

train_mask = features_df["bill_period_end"] <= pd.Timestamp(SPLIT_DATE)
print(f"Train cycles (≤ {SPLIT_DATE}): {int(train_mask.sum())}")
print(f"Test  cycles (>  {SPLIT_DATE}): {int((~train_mask).sum())}")

encoded = pd.get_dummies(
    features_df[NUMERIC_FEATURES + CATEGORICAL_FEATURES],
    columns=CATEGORICAL_FEATURES,
    drop_first=False,
    dummy_na=False,
)
encoded.columns = [_safe_feature_name(c) for c in encoded.columns]
FEATURE_COLUMNS = list(encoded.columns)
print(f"Feature columns after encoding: {len(FEATURE_COLUMNS)}")

# Persist the exact training snapshot (features + labels + split) for SQL.
# Written Spark-natively straight from the source feature table: a
# createDataFrame(pandas) round-trip serializes the whole frame into one
# broadcast RPC and blows spark.rpc.message.maxSize (256MB) at full scale.
# The split column reuses the SAME SPLIT_DATE as train_mask above (not
# feature_spec's stale default). Compare as timestamps to mirror the pandas
# train_mask (features_df["bill_period_end"] <= pd.Timestamp(SPLIT_DATE)) exactly:
# today bill_period_end is DATE (midnight), but a timestamp compare stays
# faithful even if it ever gains a time-of-day, so the persisted split can't
# drift from what the model actually trained on. NULL -> "test" in both engines.
from pyspark.sql import functions as F

snapshot_table = f"{catalog}.{schema}.ml_complaint_training_data"
(
    spark.table(f"{catalog}.{schema}.ml_complaint_risk_features")
    .withColumn(
        "split",
        F.when(
            F.col("bill_period_end").cast("timestamp") <= F.to_timestamp(F.lit(SPLIT_DATE)),
            "train",
        ).otherwise("test"),
    )
    .write.mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(snapshot_table)
)
print(f"Wrote {snapshot_table} ({spark.table(snapshot_table).count()} rows)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Train the five heads

# COMMAND ----------

import math

import mlflow
import numpy as np
import xgboost as xgb
from sklearn.calibration import calibration_curve
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score

# DataFrame (not numpy) so the DMatrices keep feature names; scoring reloads
# via name → column alignment.
X = encoded[FEATURE_COLUMNS].astype(float).fillna(0.0)

# ── Early-stopping validation split ───────────────────────────────────────────
# Carve a validation slice OUT OF TRAIN (never the test set) so early stopping
# has an honest stopping signal without peeking at the reported-metrics set.
# Split by customer_id, not by row: the grain is customer × billing-cycle and a
# customer's cycles are strongly autocorrelated, so a per-row split would put
# the same customer on both sides and let the stopping signal leak. The test set
# (post-SPLIT_DATE) stays completely untouched — every *_test_* metric below is
# still measured on data the model never saw.
_rng = np.random.RandomState(42)
_train_customers = features_df.loc[train_mask.values, "customer_id"].unique()
_n_val = max(int(round(0.10 * len(_train_customers))), 1)
_val_customers = set(_rng.choice(_train_customers, size=_n_val, replace=False))
_is_val_row = features_df["customer_id"].isin(_val_customers).values

fit_mask = train_mask.values & ~_is_val_row  # trees are fit on this
val_mask = train_mask.values & _is_val_row  # early stopping watches this
test_mask = ~train_mask.values  # reported metrics only

X_fit = X[fit_mask].reset_index(drop=True)
X_val = X[val_mask].reset_index(drop=True)
X_test = X[test_mask].reset_index(drop=True)
print(
    f"Fit rows: {len(X_fit)}  Val rows (early-stop): {len(X_val)}  "
    f"Test rows: {len(X_test)}"
)

# ── Shared quantile sketch ────────────────────────────────────────────────────
# The histogram cut points depend only on the feature matrix, which is identical
# across all five heads — only the label changes. Building the QuantileDMatrix
# once and reusing it (swapping the label per head via set_label) computes the
# ~4M-row sketch a single time instead of 5×. X_val is quantized against the
# SAME cuts (ref=dtrain); X_test is a plain DMatrix used for inference only.
dtrain = xgb.QuantileDMatrix(X_fit, feature_names=FEATURE_COLUMNS)
dval = xgb.QuantileDMatrix(X_val, feature_names=FEATURE_COLUMNS, ref=dtrain)
dtest = xgb.DMatrix(X_test, feature_names=FEATURE_COLUMNS)

mlflow.set_registry_uri("databricks-uc")
mlflow.set_experiment(experiment_name)

model_name = f"{catalog}.{schema}.ml_complaint_predictor"


def _lift_metrics(y_true: np.ndarray, y_proba: np.ndarray, frac: float = 0.05):
    """Share of actual positives captured by the top `frac` of scores.

    'The top 5% of customers by predicted risk capture N% of next month's
    complaints' — the sentence a capacity-constrained outreach team buys.
    """
    n_top = max(int(round(frac * len(y_proba))), 1)
    top_idx = np.argsort(-y_proba)[:n_top]
    captured = y_true[top_idx].sum()
    capture_rate = float(captured / max(y_true.sum(), 1))
    return capture_rate, capture_rate / frac


boosters: dict[str, xgb.Booster] = {}
best_iterations: dict[str, int] = {}
head_metrics: dict[str, float] = {}

# Cap on boosting rounds; early stopping usually lands well short of this.
NUM_BOOST_ROUND = 400
EARLY_STOPPING_ROUNDS = 40
# Minimum positives the val slice needs before its aucpr is a trustworthy
# early-stopping signal. Below this (a rare head at small iteration sample
# sizes), fall back to a fixed full-length fit so the head is never crippled.
MIN_VAL_POSITIVES = 5

with mlflow.start_run(run_name="xgboost_complaint_predictor") as run:
    mlflow.log_param("split_date", SPLIT_DATE)
    mlflow.log_param("n_train_rows", int(train_mask.sum()))
    mlflow.log_param("n_fit_rows", int(len(X_fit)))
    mlflow.log_param("n_val_rows", int(len(X_val)))
    mlflow.log_param("n_test_rows", int(len(X_test)))
    mlflow.log_param("n_features", len(FEATURE_COLUMNS))
    mlflow.log_param("num_boost_round", NUM_BOOST_ROUND)
    mlflow.log_param("early_stopping_rounds", EARLY_STOPPING_ROUNDS)
    mlflow.log_param("heads", ",".join(HEADS))

    for head, label_col in HEADS.items():
        y = features_df[label_col].astype(int).values
        y_fit = y[fit_mask]
        y_val = y[val_mask]
        y_test = y[test_mask]

        # Reuse the shared sketch; only the label differs per head.
        dtrain.set_label(y_fit)
        dval.set_label(y_val)

        # Monthly complaint rates run ~0.3%-4% per head. Full inverse ratio
        # over-corrects; sqrt is the standard middle ground (same recipe as
        # ev_detector). Computed on the fit set the trees actually see.
        imbalance_ratio = (len(y_fit) - y_fit.sum()) / max(y_fit.sum(), 1)
        params = {
            "objective": "binary:logistic",
            "learning_rate": 0.05,
            "max_depth": 5,
            "min_child_weight": 3,
            "subsample": 0.85,
            "colsample_bytree": 0.85,
            "eval_metric": "aucpr",
            "tree_method": "hist",
            "nthread": -1,
            "seed": 42,
            "scale_pos_weight": math.sqrt(imbalance_ratio),
        }

        # Use early stopping only when the val slice carries enough positives
        # for a stable aucpr; otherwise train the full cap (the pre-early-stopping
        # behavior) so a rare head at small sample sizes isn't halted at ~0 trees
        # and promoted near-empty. At demo scale every head clears the threshold.
        n_val_pos = int(y_val.sum())
        n_fit_pos = int(y_fit.sum())
        if n_val_pos >= MIN_VAL_POSITIVES and n_fit_pos > 0:
            booster = xgb.train(
                params,
                dtrain,
                num_boost_round=NUM_BOOST_ROUND,
                evals=[(dval, "val")],
                early_stopping_rounds=EARLY_STOPPING_ROUNDS,
                verbose_eval=False,
            )
            best_iteration = int(booster.best_iteration)
        else:
            print(
                f"[{head:8s}] early stopping OFF (val positives={n_val_pos} "
                f"< {MIN_VAL_POSITIVES}); training full {NUM_BOOST_ROUND} rounds"
            )
            booster = xgb.train(
                params, dtrain, num_boost_round=NUM_BOOST_ROUND, verbose_eval=False
            )
            best_iteration = NUM_BOOST_ROUND - 1  # serve/score with all trees
        # Score test with only the trees up to the best round; serving uses the
        # identical iteration_range (see the pyfunc wrapper below).
        test_proba = booster.predict(dtest, iteration_range=(0, best_iteration + 1))

        # roc_auc / average_precision / calibration need both classes present; a
        # rare head's trailing-window test slice can be single-class at small
        # sample sizes, so guard rather than crash the whole run.
        two_class_test = len(np.unique(y_test)) > 1
        capture_5pct, lift_5pct = _lift_metrics(y_test, test_proba)
        metrics = {
            f"{head}_base_rate": float(y.mean()),
            f"{head}_scale_pos_weight": float(params["scale_pos_weight"]),
            f"{head}_best_iteration": float(best_iteration),
            f"{head}_test_brier": float(brier_score_loss(y_test, test_proba)),
            f"{head}_test_capture_at_5pct": capture_5pct,
            f"{head}_test_lift_at_5pct": lift_5pct,
        }
        if two_class_test:
            metrics[f"{head}_test_auc"] = float(roc_auc_score(y_test, test_proba))
            metrics[f"{head}_test_avg_precision"] = float(
                average_precision_score(y_test, test_proba)
            )
        else:
            print(f"[{head:8s}] test slice single-class — skipping AUC/AP/calibration")
        mlflow.log_metrics(metrics)

        # Reliability curve — the app surfaces probabilities and tiers, so
        # calibration matters more than rank.
        if two_class_test:
            frac_pos, mean_pred = calibration_curve(
                y_test, test_proba, n_bins=10, strategy="quantile"
            )
            mlflow.log_dict(
                {
                    "mean_predicted": mean_pred.tolist(),
                    "fraction_positive": frac_pos.tolist(),
                },
                f"calibration_{head}.json",
            )

        # Sanity vs. the generator: each head should be dominated by its own
        # driver family (bill-shock / outage-minutes / previous-balance).
        # gain-weighted importance, normalized, with unused columns at 0.
        raw_importance = booster.get_score(importance_type="gain")
        _imp_total = sum(raw_importance.values()) or 1.0
        importance = {
            c: float(raw_importance.get(c, 0.0)) / _imp_total for c in FEATURE_COLUMNS
        }
        mlflow.log_dict(importance, f"feature_importance_{head}.json")
        top5 = sorted(importance.items(), key=lambda kv: -kv[1])[:5]

        boosters[head] = booster
        best_iterations[head] = best_iteration
        head_metrics.update(metrics)
        print(
            f"[{head:8s}] base={y.mean():.2%} "
            f"best_iter={best_iteration} "
            f"auc={metrics.get(f'{head}_test_auc', float('nan')):.3f} "
            f"ap={metrics.get(f'{head}_test_avg_precision', float('nan')):.3f} "
            f"capture@5%={capture_5pct:.1%}"
        )
        print(f"           top features: {[k for k, _ in top5]}")

    # ── Package the five boosters as one pyfunc ──────────────────────────
    # predict(DataFrame of features) → DataFrame(p_any, p_billing, p_outage,
    # p_payment, p_service). Input is aligned to the training columns inside
    # the wrapper (missing → 0, extras dropped), so score.py stays trivial.
    import json
    import os
    import tempfile

    artifact_dir = tempfile.mkdtemp()
    artifacts = {}
    for head, booster in boosters.items():
        path = os.path.join(artifact_dir, f"booster_{head}.json")
        booster.save_model(path)
        artifacts[f"booster_{head}"] = path
    columns_path = os.path.join(artifact_dir, "feature_columns.json")
    with open(columns_path, "w") as f:
        json.dump(FEATURE_COLUMNS, f)
    artifacts["feature_columns"] = columns_path
    # Persist each head's best round so serving predicts with the SAME trees
    # early stopping selected — a reloaded native Booster otherwise scores with
    # every round it happened to run past the optimum.
    best_iter_path = os.path.join(artifact_dir, "best_iterations.json")
    with open(best_iter_path, "w") as f:
        json.dump(best_iterations, f)
    artifacts["best_iterations"] = best_iter_path

    class ComplaintRiskModel(mlflow.pyfunc.PythonModel):
        def load_context(self, context):
            import json as _json

            import xgboost as _xgb

            with open(context.artifacts["feature_columns"]) as fh:
                self.feature_columns = _json.load(fh)
            with open(context.artifacts["best_iterations"]) as fh:
                self.best_iterations = _json.load(fh)
            self.boosters = {}
            for key, path in context.artifacts.items():
                if key.startswith("booster_"):
                    booster = _xgb.Booster()
                    booster.load_model(path)
                    self.boosters[key.removeprefix("booster_")] = booster

        def predict(self, context, model_input, params=None):
            import pandas as _pd
            import xgboost as _xgb

            aligned = (
                model_input.reindex(columns=self.feature_columns, fill_value=0.0)
                .astype(float)
                .fillna(0.0)
            )
            dmat = _xgb.DMatrix(aligned, feature_names=self.feature_columns)
            out = {}
            for head, booster in self.boosters.items():
                best_it = self.best_iterations.get(head)
                # (0, 0) is XGBoost's "use every tree" sentinel — the fallback
                # if a best round somehow wasn't recorded.
                rng = (0, int(best_it) + 1) if best_it is not None else (0, 0)
                out[f"p_{head}"] = booster.predict(dmat, iteration_range=rng)
            return _pd.DataFrame(out)

    wrapper = ComplaintRiskModel()
    input_example = X_fit.head(5)
    output_example = pd.DataFrame(
        {
            f"p_{head}": booster.predict(
                xgb.DMatrix(input_example, feature_names=FEATURE_COLUMNS),
                iteration_range=(0, best_iterations[head] + 1),
            )
            for head, booster in boosters.items()
        }
    )
    signature = mlflow.models.infer_signature(input_example, output_example)

    mlflow.pyfunc.log_model(
        python_model=wrapper,
        name="model",
        artifacts=artifacts,
        signature=signature,
        input_example=input_example,
        registered_model_name=model_name,
        pip_requirements=[
            f"xgboost=={xgb.__version__}",
            f"pandas=={pd.__version__}",
        ],
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
