# Databricks notebook source
# MAGIC %md
# MAGIC # Score complaint risk for every customer
# MAGIC
# MAGIC Loads `@champion` from UC, scores the **latest** billing cycle per
# MAGIC customer from `ml_complaint_risk_features`, and writes one row per
# MAGIC customer to `ml_complaint_risk_scores`: the five head probabilities,
# MAGIC top category, risk tier, top-3 reason codes, and the outreach playbook.
# MAGIC Consumed by the app's CSAT view (risk distribution, top-risk cohorts)
# MAGIC and the CSR profile (per-customer risk + drivers).
# MAGIC
# MAGIC Reason codes are a deterministic mapping from the customer's own
# MAGIC feature values crossing the generator's known thresholds — honest
# MAGIC here because the generator is threshold-based; add SHAP later only if
# MAGIC we want the generic story.

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
# MAGIC ## Load model + latest cycle per customer

# COMMAND ----------

# MAGIC %run ./feature_spec

# COMMAND ----------

import mlflow
import pandas as pd

mlflow.set_registry_uri("databricks-uc")

model_name = f"{catalog}.{schema}.ml_complaint_predictor"
model_uri = f"models:/{model_name}@champion"
model = mlflow.pyfunc.load_model(model_uri)
print(f"Loaded {model_uri}")

# Latest bill_period_end per customer — one score row per customer.
features_df = (
    spark.sql(
        f"""
        SELECT * FROM {catalog}.{schema}.ml_complaint_risk_features
        QUALIFY ROW_NUMBER() OVER (
          PARTITION BY customer_id ORDER BY bill_period_end DESC
        ) = 1
        """
    )
    .drop(*LABEL_COLUMNS)  # scoring never reads the labels
    .toPandas()
)
print(f"Scoring {len(features_df)} customers (latest cycle each)")

encoded = pd.get_dummies(
    features_df[NUMERIC_FEATURES + CATEGORICAL_FEATURES],
    columns=CATEGORICAL_FEATURES,
    drop_first=False,
    dummy_na=False,
)
# Same sanitizer map as training time. Align to the model signature's
# column set and cast to float64 BEFORE predict: MLflow enforces the
# signature (all doubles, all required) ahead of the wrapper's own
# alignment, and get_dummies emits int64/bool columns it refuses to
# "unsafely" convert.
encoded.columns = [_safe_feature_name(c) for c in encoded.columns]
expected = model.metadata.get_input_schema().input_names()
encoded = encoded.reindex(columns=expected, fill_value=0.0).astype("float64")

proba = model.predict(encoded)
print(f"Predicted mean p_any: {proba['p_any'].mean():.2%}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Tiers, reason codes, playbooks

# COMMAND ----------

import numpy as np

CATEGORY_HEADS = [h for h in HEADS if h != "any"]

# argmax of the four category heads
cat_probs = proba[[f"p_{h}" for h in CATEGORY_HEADS]].values
top_category = pd.Series(
    [CATEGORY_HEADS[i] for i in np.argmax(cat_probs, axis=1)],
    index=proba.index,
)

# Percentile tiers on the headline score: the top 5% are the "high" cohort
# (matches the capture@5% lift metric the CSAT view leads with), the next
# 15% "elevated", the rest baseline.
rank_pct = proba["p_any"].rank(pct=True, ascending=False)
risk_tier = pd.Series(
    np.where(rank_pct <= 0.05, "high",
             np.where(rank_pct <= 0.20, "elevated", "baseline")),
    index=proba.index,
)

PLAYBOOKS = {
    "billing": "Proactive high-bill alert; offer rate review / EE audit",
    "outage":  "Restoration follow-up; reliability credit; critical-care check",
    "payment": "Offer payment plan; screen for LIHEAP / assistance enrollment",
    "service": "Priority CSR callback; confirm channel preference",
}


def _reason_codes(row: pd.Series, top_cat: str) -> list[str]:
    # (category tag, reason) — thresholds are the generator's own recipe
    # (bill_shock > 30%, 240 outage minutes / 3 outages per 30d, $300
    # arrears), which are also the thresholds a real CX team would pick.
    candidates: list[tuple[str, str]] = []
    if row["bill_shock_pct"] is not None and row["bill_shock_pct"] >= 0.30:
        candidates.append(
            ("billing", f"Bill +{row['bill_shock_pct'] * 100:.0f}% vs trailing 12-mo avg")
        )
    elif row["bill_shock_pct"] is not None and row["bill_shock_pct"] >= 0.15:
        candidates.append(
            ("billing", f"Bill +{row['bill_shock_pct'] * 100:.0f}% vs trailing 12-mo avg")
        )
    if row["max_outage_minutes_30d"] > 240:
        candidates.append(
            ("outage", f"{row['max_outage_minutes_30d']:.0f}-min outage in last 30d")
        )
    if row["outages_count_30d"] >= 3:
        candidates.append(
            ("outage", f"{row['outages_count_30d']:.0f} outages in last 30d")
        )
    if row["previous_balance"] > 300:
        candidates.append(
            ("payment", f"${row['previous_balance']:.0f} balance carried forward")
        )
    if row["late_payments_90d"] >= 2:
        candidates.append(
            ("payment", f"{row['late_payments_90d']:.0f} late payments in 90d")
        )
    if row["prior_complaints_365d"] >= 2:
        candidates.append(
            ("service", f"{row['prior_complaints_365d']:.0f} complaints in last 12 mo")
        )
    if 0 <= row["latest_nps_365d"] <= 6:
        candidates.append(
            ("service", f"Recent NPS {row['latest_nps_365d']:.0f}/10")
        )
    if row["csr_contacts_90d"] >= 3:
        candidates.append(
            ("service", f"{row['csr_contacts_90d']:.0f} CSR contacts in 90d")
        )
    # Drivers matching the top category lead; stable order otherwise.
    candidates.sort(key=lambda cr: cr[0] != top_cat)
    return [reason for _, reason in candidates[:3]]


scores = pd.DataFrame(
    {
        "customer_id": features_df["customer_id"].values,
        "as_of_date": features_df["bill_period_end"].values,
        "p_complaint_30d": proba["p_any"].values,
        "p_billing": proba["p_billing"].values,
        "p_outage": proba["p_outage"].values,
        "p_payment": proba["p_payment"].values,
        "p_service": proba["p_service"].values,
        "top_category": top_category.values,
        "risk_tier": risk_tier.values,
        "top_drivers": [
            _reason_codes(features_df.iloc[i], top_category.iloc[i])
            for i in range(len(features_df))
        ],
        "recommended_action": top_category.map(PLAYBOOKS).values,
        "outreach_channel": features_df["preferred_channel"].fillna("phone").values,
    }
)
scores["scored_at"] = pd.Timestamp.utcnow()

(
    spark.createDataFrame(scores)
    .write.mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(f"{catalog}.{schema}.ml_complaint_risk_scores")
)
print(f"Wrote {len(scores)} rows to ml_complaint_risk_scores")
print(scores["risk_tier"].value_counts().to_string())
print("Top-category mix in the high tier:")
print(scores.loc[scores["risk_tier"] == "high", "top_category"].value_counts().to_string())
