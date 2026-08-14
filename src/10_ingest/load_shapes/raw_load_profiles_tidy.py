# Databricks notebook source
# MAGIC %md
# MAGIC # Load Profiles — Tidy (Long) Format
# MAGIC
# MAGIC Unpivots the wide-format `out_*` columns (energy consumption, loads,
# MAGIC emissions) into a tidy long-format table with `load_shape` (name) and
# MAGIC `value` (numeric) columns. Dynamic column discovery avoids hard-coding
# MAGIC hundreds of column names.

# COMMAND ----------

from pyspark import pipelines as dp
from pyspark.sql import functions as F


@dp.materialized_view(
    name="raw_load_profiles_tidy",
    comment=(
        "Tidy (long) format NREL End-Use Load Profiles. "
        "Each row is one load-shape measurement: the out_* columns from the "
        "wide-format table are unpivoted into load_shape (name) and value "
        "(numeric) columns. NULL values are excluded. "
        "Source: OEDI S3 bucket (oedi-data-lake)."
    ),
)
def load_profiles_tidy():
    raw = spark.read.table("raw_load_profiles")
    # Only electricity end-use load shapes are consumed downstream (AMI filters
    # `load_shape LIKE 'out_electricity_%'`). Unpivoting the gas/propane/fuel-oil/
    # emissions/loads columns too would multiply this table several-fold for no use.
    out_cols = sorted(c for c in raw.columns if c.startswith("out_electricity_"))
    id_cols = [c for c in raw.columns if not c.startswith("out_")]
    return raw.unpivot(id_cols, out_cols, "load_shape", "value").filter(F.col("value").isNotNull())
