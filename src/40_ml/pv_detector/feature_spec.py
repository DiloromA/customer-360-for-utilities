# Databricks notebook source
# Feature contract for the unregistered-PV-detection model — the single source
# of truth for which columns the model consumes. train.py and score.py both
# `%run` this file, so their feature sets and name-sanitization can never
# drift apart.

NUMERIC_FEATURES = [
    "avg_daily_kwh",
    "std_daily_kwh",
    "median_daily_kwh",
    "max_daily_kwh",
    "coef_of_variation",
    "avg_midday_kwh",
    "midday_to_daily_ratio",
    "avg_min_hour_kwh",
    "near_zero_midday_fraction",
    "summer_to_winter_ratio",
    "summer_midday_to_daily_ratio",
    "winter_midday_to_daily_ratio",
    "midday_seasonal_gap",
]

CATEGORICAL_FEATURES = [
    "customer_class",
    "income_band",
    "peer_building_subtype",
    "peer_sqft_band",
    "tenure",
]

import re as _re


def _safe_feature_name(name: str) -> str:
    # XGBoost rejects feature names containing < > [ ] — the sqft_band values
    # ('<1000', '15000+') produce exactly those. Replace with safe ASCII.
    return _re.sub(r"[<>\[\] +/]+", "_", name)
