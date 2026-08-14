# Databricks notebook source
# MAGIC %md
# MAGIC # NREL End-Use Load Profiles → UC Volume
# MAGIC
# MAGIC Downloads residential (ResStock) and commercial (ComStock) building
# MAGIC load profile CSVs from the [OEDI public S3 bucket](https://data.openei.org/)
# MAGIC into a Unity Catalog volume for downstream SDP ingestion.
# MAGIC
# MAGIC CSVs are stored under `{volume}/load_profiles/{sector}/state={XX}/` so the
# MAGIC SDP pipeline can extract metadata from file paths.
# MAGIC
# MAGIC **Source:** `s3://oedi-data-lake/nrel-pds-building-stock/end-use-load-profiles-for-us-building-stock`

# COMMAND ----------

# MAGIC %pip install boto3
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
dbutils.widgets.text("volume", "landing")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value: str, label: str) -> str:
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")
volume = _check_id(dbutils.widgets.get("volume").strip(), "volume")

# Only download the state(s) the demo actually uses. AMI joins load shapes with
# WHERE state = '<target_state>', so pulling all ~50 states is pure waste.
# Comma-separated 2-letter codes; empty = all states (original behavior).
dbutils.widgets.text("states", "MI")
_states = [s.strip().upper() for s in dbutils.widgets.get("states").split(",") if s.strip()]
STATE_FILTER = {f"state={s}" for s in _states}

dbutils.widgets.text("force_download", "false")
_force_download = dbutils.widgets.get("force_download").strip().lower() == "true"

spark.sql(f"USE CATALOG `{catalog}`")

print(f"Catalog: {catalog}")
print(f"Schema:  {schema}")
print(f"Volume:  {volume}")

# COMMAND ----------

spark.sql(f"CREATE SCHEMA IF NOT EXISTS `{schema}`")
spark.sql(f"USE SCHEMA `{schema}`")
spark.sql(f"CREATE VOLUME IF NOT EXISTS `{volume}`")

volume_path = f"/Volumes/{catalog}/{schema}/{volume}"
print(f"Volume path: {volume_path}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 0: Skip-if-exists scope check

# COMMAND ----------

import json
import os

output_dir = os.path.join(volume_path, "load_profiles")
_scope = {"states": sorted(_states)}
_scope_path = os.path.join(output_dir, "_scope.json")


def _existing_scope() -> dict | None:
    try:
        with open(_scope_path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


if not _force_download and _existing_scope() == _scope:
    _existing_csvs = [
        f for root, _dirs, files in os.walk(output_dir) for f in files if f.endswith(".csv")
    ]
    if _existing_csvs:
        print(
            f"Scope unchanged ({_scope}) and {len(_existing_csvs)} CSVs already "
            f"present in {output_dir} — skipping download."
        )
        dbutils.notebook.exit(json.dumps({"status": "skipped", "files": len(_existing_csvs)}))

# COMMAND ----------

import shutil
import tempfile

S3_BUCKET = "oedi-data-lake"
S3_PREFIX_BASE = "nrel-pds-building-stock/end-use-load-profiles-for-us-building-stock"

DATASETS = [
    {
        "name": "resstock_amy2018_release_2",
        "year": "2024",
        "sector": "residential",
    },
    {
        "name": "comstock_amy2018_release_2",
        "year": "2024",
        "sector": "commercial",
    },
]

# Download to local temp dir first, then copy to volume.
# Concurrent FUSE writes to UC volumes are unreliable, but local disk is fast.
_tmp_dir = tempfile.mkdtemp(prefix="nrel_csv_")
print(f"Temp dir: {_tmp_dir}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 1: List & download CSVs from OEDI S3 (parallel)

# COMMAND ----------

import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from botocore import UNSIGNED
from botocore.config import Config

MAX_WORKERS = 16

# List all CSV files across both datasets
files_to_download: list[tuple[str, str, dict]] = []

for ds in DATASETS:
    prefix = f"{S3_PREFIX_BASE}/{ds['year']}/{ds['name']}/timeseries_aggregates/by_state/upgrade=0/"
    s3 = boto3.client("s3", config=Config(signature_version=UNSIGNED))
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith(".csv"):
                continue
            # Layout: {sector}/state=XX/filename.csv
            rel = key[len(prefix) :]
            # Skip states we don't need (AMI only reads target_state).
            if STATE_FILTER and not any(f"/{sf}/" in f"/{rel}" for sf in STATE_FILTER):
                continue
            dest = os.path.join(_tmp_dir, ds["sector"], rel)
            files_to_download.append((key, dest, ds))

print(f"CSV files to download: {len(files_to_download)}")
for ds in DATASETS:
    n = sum(1 for _, _, d in files_to_download if d is ds)
    print(f"  {ds['sector']} ({ds['name']}): {n}")

# COMMAND ----------


def _download_one(s3_key: str, dest: str) -> tuple[str, str | None]:
    """Download one file from S3. Returns (dest, error_or_None)."""
    try:
        client = boto3.client("s3", config=Config(signature_version=UNSIGNED))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        client.download_file(S3_BUCKET, s3_key, dest)
        return dest, None
    except Exception as e:
        return s3_key, str(e)


print(f"Downloading with {MAX_WORKERS} threads...")
t0 = time.time()
downloaded = []
failed = []

with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
    futures = {pool.submit(_download_one, k, d): k for k, d, _ in files_to_download}
    for i, future in enumerate(as_completed(futures), start=1):
        dest, err = future.result()
        if err is None:
            downloaded.append(dest)
        else:
            failed.append((dest, err))
        if i % 50 == 0 or i == len(futures):
            print(f"  [{i}/{len(futures)}] ok={len(downloaded)} failed={len(failed)}")

elapsed = time.time() - t0
print(f"\nDownloaded: {len(downloaded)}, Failed: {len(failed)} ({elapsed:.0f}s)")

if failed:
    for path, err in failed[:10]:
        print(f"  FAILED: {path}: {err}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 2: Copy local CSVs → UC volume

# COMMAND ----------

# Clear previous run
if os.path.exists(output_dir):
    shutil.rmtree(output_dir)

print(f"Copying CSVs to {output_dir} ...")
t0 = time.time()
shutil.copytree(_tmp_dir, output_dir)
elapsed = time.time() - t0
print(f"Copy complete ({elapsed:.0f}s)")

# Clean up temp dir
shutil.rmtree(_tmp_dir, ignore_errors=True)

with open(_scope_path, "w") as f:
    json.dump(_scope, f)

# COMMAND ----------

# Verify volume contents
csv_files = []
for root, dirs, files in os.walk(output_dir):
    for f in files:
        if f.endswith(".csv"):
            csv_files.append(os.path.join(root, f))

total_mb = sum(os.path.getsize(p) for p in csv_files) / (1024 * 1024)
print(f"CSV files: {len(csv_files)}")
print(f"Total size: {total_mb:.1f} MB")

if failed:
    print(f"\n{len(failed)} download failure(s) — check logs above.")
else:
    print("\nAll files downloaded successfully.")
