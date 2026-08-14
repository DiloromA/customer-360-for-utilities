# Databricks notebook source
# MAGIC %md
# MAGIC # Load Profiles — Wide Format
# MAGIC
# MAGIC Reads from the `_all_raw` temporary view (CSV source), sanitises column
# MAGIC names (dots → underscores), and extracts metadata (state, building_type,
# MAGIC sector, dataset) from file paths. Dynamic column renaming avoids
# MAGIC hard-coding hundreds of column names in SQL.

# COMMAND ----------

from pyspark import pipelines as dp
from pyspark.sql import functions as F


@dp.materialized_view(
    name="raw_load_profiles",
    comment=(
        "Wide-format NREL End-Use Load Profiles for US Building Stock. "
        "Contains ResStock (residential) and ComStock (commercial) 2024 "
        "baseline data, pruned to electricity end-use columns only "
        "(out_electricity_*) — the demo only ever consumes electricity load "
        "shapes (see raw_meter_readings.sql); the gas/propane/fuel-oil/"
        "emissions/loads out_* columns are dropped here rather than carried "
        "through unpivoting in raw_load_profiles_tidy. "
        "Column names sanitised (dots replaced with underscores). "
        "Source: OEDI S3 bucket (oedi-data-lake)."
    ),
)
def load_profiles():
    df = spark.read.table("_all_raw")

    # Extract metadata from file paths
    df = (
        df.withColumn(
            "state",
            F.regexp_extract("_source_file", r"state=([A-Z]{2})", 1),
        )
        .withColumn(
            "building_type",
            F.regexp_extract("_source_file", r"up\d+-[A-Za-z]{2}-(.+)\.csv", 1),
        )
        .withColumn(
            "sector",
            F.when(
                F.col("_source_file").contains("/residential/"),
                F.lit("residential"),
            ).otherwise(F.lit("commercial")),
        )
        .withColumn(
            "dataset",
            F.when(
                F.col("_source_file").contains("/residential/"),
                F.lit("resstock_amy2018_release_2"),
            ).otherwise(F.lit("comstock_amy2018_release_2")),
        )
    )

    # Drop read_files rescue column
    if "_rescued_data" in df.columns:
        df = df.drop("_rescued_data")

    # Sanitise column names: dots → underscores
    for col_name in df.columns:
        if "." in col_name:
            df = df.withColumnRenamed(col_name, col_name.replace(".", "_"))

    # Prune to the columns actually consumed downstream (raw_load_profiles_tidy.py,
    # raw_meter_readings.sql): path-derived metadata, the join/weighting columns
    # hourly_total_per_unit needs, and electricity end-use columns only. Storing
    # the non-electricity out_* columns (gas/propane/fuel-oil/emissions/loads)
    # wide here was pure waste — nothing ever reads them.
    keep_exact = {
        "state",
        "building_type",
        "sector",
        "dataset",
        "timestamp",
        "units_represented",
        "floor_area_represented",
        "in_geometry_building_type_recs",
        "in_comstock_building_type",
        "_source_file",
        "_ingested_at",
    }
    keep_cols = [
        c for c in df.columns if c in keep_exact or c.startswith("out_electricity_")
    ]
    df = df.select(*keep_cols)

    return df
