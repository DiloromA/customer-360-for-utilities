# Databricks notebook source
# Feature contract for the EV-detection model — the single source of truth for
# which columns the model consumes. train.py and score.py both `%run` this file,
# so their feature sets and name-sanitization can never drift apart.

NUMERIC_FEATURES = [
    "avg_daily_kwh",
    "std_daily_kwh",
    "median_daily_kwh",
    "max_daily_kwh",
    "avg_peak_hour_kwh",
    "max_peak_hour_kwh",
    "peak_to_mean_ratio",
    "coef_of_variation",
    "avg_summer_kwh",
    "avg_winter_kwh",
    "avg_shoulder_kwh",
    "summer_to_winter_ratio",
    "avg_weekend_kwh",
    "avg_weekday_kwh",
    "weekday_to_weekend_ratio",
    "overnight_peak_fraction",
    "evening_peak_fraction",
    "mode_peak_hour",
]

CATEGORICAL_FEATURES = [
    "customer_class",
    "income_band",
    "peer_building_subtype",
    "peer_sqft_band",
]

import re as _re


def _safe_feature_name(name: str) -> str:
    # XGBoost rejects feature names containing < > [ ] — the sqft_band values
    # ('<1000', '15000+') produce exactly those. Replace with safe ASCII.
    return _re.sub(r"[<>\[\] +/]+", "_", name)
