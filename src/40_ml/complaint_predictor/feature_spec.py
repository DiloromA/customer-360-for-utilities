# Databricks notebook source
# Feature contract for the complaint-risk model — the single source of truth
# for which columns the model consumes and how the five one-vs-rest heads map
# to label columns. train.py and score.py both `%run` this file, so their
# feature sets, head definitions, and name-sanitization can never drift apart.

# Time-based split boundary: train on cycles ending at or before this date,
# evaluate on everything after. Billing/outage conditions are strongly
# autocorrelated within a customer, so random splits would leak. This is a
# fallback default only — train.py overrides it (trailing 6 months of the
# display window held out) after `%run`-ing this file, so it tracks
# as_of_date instead of going stale when the window shifts.
SPLIT_DATE = "2018-06-30"

NUMERIC_FEATURES = [
    # Billing
    "n_accounts_billed",
    "current_charges",
    "total_kwh",
    "bill_shock_pct",
    "yoy_bill_change_pct",
    "yoy_kwh_change_pct",
    "previous_balance",
    "unpaid_carry",
    "on_tou_rate_flag",
    "medical_baseline_flag",
    # Outage exposure
    "outages_count_30d",
    "outage_minutes_30d",
    "max_outage_minutes_30d",
    "outages_count_90d",
    "outage_minutes_90d",
    "days_since_last_outage",
    # Arrears & payments
    "late_payments_90d",
    "avg_days_late_90d",
    "assistance_enrolled_flag",
    # Contact & sentiment history
    "prior_complaints_90d",
    "prior_complaints_365d",
    "days_since_last_complaint",
    "prior_billing_complaints_365d",
    "prior_outage_complaints_365d",
    "prior_payment_complaints_365d",
    "prior_service_complaints_365d",
    "csr_contacts_90d",
    "avg_csat_90d",
    "latest_nps_365d",
    "digital_events_90d",
    # Profile
    "household_size",
    "critical_care_flag",
    "autopay_enrolled_flag",
    "paperless_enrolled_flag",
    "account_tenure_years",
]

CATEGORICAL_FEATURES = [
    "customer_class",
    "income_band",
    "tenure",
    "language_preference",
    "preferred_channel",
]

# One-vs-rest heads: head name -> label column in ml_complaint_risk_features.
# 'any' is the headline P(complaint in 30d); the four category heads carry
# the per-team outreach playbooks.
HEADS = {
    "any":     "label_any",
    "billing": "label_billing",
    "outage":  "label_outage",
    "payment": "label_payment",
    "service": "label_service",
}

LABEL_COLUMNS = list(HEADS.values())

import re as _re


def _safe_feature_name(name: str) -> str:
    # XGBoost rejects feature names containing < > [ ] — income/tenure band
    # values ('<25k', '10+ years') produce exactly those. Replace with safe
    # ASCII.
    return _re.sub(r"[<>\[\] +/]+", "_", name)
