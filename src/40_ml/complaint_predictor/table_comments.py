# Databricks notebook source
# MAGIC %md
# MAGIC # Table & column comments + UC tags — ml_complaint_* tables

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
# "false" on a governed workspace whose UC tag policy rejects our tag values
#. When false, all COMMENT ON TABLE/COLUMN still applies; only
# the `demo` UC tag below is skipped. Mirrors databricks.yml data_asset_tags.
dbutils.widgets.text("apply_data_asset_tags", "true")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value, label):
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")
APPLY_TAGS = dbutils.widgets.get("apply_data_asset_tags").strip().lower() == "true"

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")

# COMMAND ----------

TABLE_COMMENTS = {
    "ml_complaint_risk_features": (
        "Customer x billing-cycle features for 30-day complaint-risk "
        "prediction. Recomputed from curated billing / outage / payment / "
        "contact facts as-of each bill_period_end. The label_* columns are "
        "joined from complaints filed in the following 30 days, for "
        "training and validation only — scoring does not consume them.",
        {
            "customer_id":              "PK (with bill_period_end). FK -> dim_customer.customer_id.",
            "bill_period_end":          "PK (with customer_id). The as-of date every feature is computed against.",
            "n_accounts_billed":        "Accounts billed this cycle — >1 flags multi-site commercial chains.",
            "current_charges":          "Total current charges across the customer's accounts this cycle.",
            "total_kwh":                "Total kWh billed this cycle.",
            "bill_shock_pct":           "Worst per-account (current - trailing-12-avg)/avg, as a FRACTION (0.30 = +30%). The generator's dominant billing driver.",
            "yoy_bill_change_pct":      "Worst per-account bill change vs same month last year (fraction).",
            "yoy_kwh_change_pct":       "Worst per-account kWh change vs same month last year (fraction).",
            "previous_balance":         "Balance carried into this cycle, summed across accounts. >$300 is the generator's arrears multiplier threshold.",
            "unpaid_carry":             "Unpaid amount carried out of this cycle.",
            "on_tou_rate_flag":         "1 if any account is on a time-of-use rate.",
            "medical_baseline_flag":    "1 if any account is on a medical-baseline rate.",
            "outages_count_30d":        "Outage events in the 30 days ending at bill_period_end (>=3 is a generator outage-category trigger).",
            "outage_minutes_30d":       "Total minutes out in the trailing 30 days.",
            "max_outage_minutes_30d":   "Longest single outage in the trailing 30 days (>240 min is a generator outage-category trigger).",
            "outages_count_90d":        "Outage events in the trailing 90 days.",
            "outage_minutes_90d":       "Total minutes out in the trailing 90 days.",
            "days_since_last_outage":   "Days since the last outage within 90d; 999 = none in window.",
            "late_payments_90d":        "Payments with days_late > 0 in the trailing 90 days.",
            "avg_days_late_90d":        "Mean days late across payments in the trailing 90 days.",
            "assistance_enrolled_flag": "1 if enrolled in any assistance program as of the cycle end.",
            "prior_complaints_90d":     "Complaints filed in the trailing 90 days (any category).",
            "prior_complaints_365d":    "Complaints filed in the trailing 365 days (any category).",
            "days_since_last_complaint":"Days since the last complaint within 365d; 999 = none in window.",
            "prior_billing_complaints_365d": "Trailing-365d complaints in category billing.",
            "prior_outage_complaints_365d":  "Trailing-365d complaints in category outage.",
            "prior_payment_complaints_365d": "Trailing-365d complaints in category billing_process.",
            "prior_service_complaints_365d": "Trailing-365d complaints in customer_service / service_quality / program.",
            "csr_contacts_90d":         "CSR interactions in the trailing 90 days.",
            "avg_csat_90d":             "Mean post-interaction CSAT (1-5) in the trailing 90 days; -1 = no surveyed contact.",
            "latest_nps_365d":          "Most recent NPS/CSAT survey score (0-10) within 365d; -1 = none.",
            "digital_events_90d":       "Portal/app events in the trailing 90 days — low engagement + mail preference correlates with phone complaints.",
            "customer_class":           "Residential | SmallCommercial | LargeCommercial.",
            "income_band":              "ACS-derived income band.",
            "household_size":           "ACS-derived household size.",
            "tenure":                   "Customer tenure band.",
            "language_preference":      "Preferred language, drives outreach content.",
            "critical_care_flag":       "1 if a critical-care/medical customer — prioritize outage follow-up.",
            "preferred_channel":        "Preferred contact channel; also the outreach_channel output in the scores table.",
            "autopay_enrolled_flag":    "1 if enrolled in autopay.",
            "paperless_enrolled_flag":  "1 if enrolled in paperless billing.",
            "account_tenure_years":     "Years since the primary account opened.",
            "label_any":                "1 if any complaint was filed in the 30 days after bill_period_end. Training/validation only.",
            "label_billing":            "1 if a billing-category complaint followed within 30 days. Training/validation only.",
            "label_outage":             "1 if an outage-category complaint followed within 30 days. Training/validation only.",
            "label_payment":            "1 if a billing_process complaint followed within 30 days. Training/validation only.",
            "label_service":            "1 if a customer_service / service_quality / program complaint followed within 30 days. Training/validation only.",
        },
    ),
    "ml_complaint_training_data": (
        "Snapshot of ml_complaint_risk_features taken at training time, "
        "plus the time-based split assignment. Lets SQL + Genie query the "
        "exact rows the model saw.",
        {
            "split": "train (cycles ending on/before the split date) or test (after). The split is time-based because billing/outage conditions are autocorrelated within a customer.",
        },
    ),
    "ml_complaint_risk_scores": (
        "Per-customer 30-day complaint-risk scores from the latest "
        "@champion run of ml_complaint_predictor, scored on each "
        "customer's most recent billing cycle. One row per customer. "
        "Consumed by the app's CSAT view (risk distribution, top-risk "
        "cohorts) and the CSR profile (risk badge + drivers); the payment "
        "slice doubles as a payment-plan / LIHEAP outreach list.",
        {
            "customer_id":        "PK. FK -> dim_customer.customer_id.",
            "as_of_date":         "The bill_period_end the customer was scored at (their latest cycle).",
            "p_complaint_30d":    "Predicted probability of any complaint in the next 30 days ('any' head).",
            "p_billing":          "Probability of a billing complaint (bill-shock driven; high-bill alert playbook).",
            "p_outage":           "Probability of an outage complaint (restoration follow-up playbook).",
            "p_payment":          "Probability of a billing_process complaint (arrears driven; payment-plan / LIHEAP playbook).",
            "p_service":          "Probability of a service-ish complaint (customer_service / service_quality / program).",
            "top_category":       "argmax of the four category heads: billing | outage | payment | service.",
            "risk_tier":          "high (top 5% by p_complaint_30d) | elevated (next 15%) | baseline.",
            "top_drivers":        "Top-3 reason codes from the customer's own feature values crossing the known thresholds (e.g. 'Bill +62% vs trailing 12-mo avg').",
            "recommended_action": "Outreach playbook keyed by top_category.",
            "outreach_channel":   "Customer's preferred contact channel for the outreach.",
            "scored_at":          "Timestamp when the scores were produced.",
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
    if APPLY_TAGS:
        try:
            spark.sql(
                f"ALTER TABLE {fqn} SET TAGS ('demo' = 'customer-360-for-utilities')"
            )
        except Exception as e:
            print(f"  Tag failed for {fqn}: {e}")
    print(f"  Commented {fqn}")

print("Done.")
