# Databricks notebook source
# MAGIC %md
# MAGIC # NREL End-Use Load Profiles — AMY2018 Weather → UC Volume
# MAGIC
# MAGIC Downloads per-county AMY2018 weather CSVs (dry-bulb temperature, solar
# MAGIC irradiance components, humidity, wind) from the same public OEDI S3
# MAGIC bucket the load-shape download already reads, into a Unity Catalog
# MAGIC volume for downstream SDP ingestion. Keyless — no NREL API key.
# MAGIC
# MAGIC CSVs are stored under `{volume}/weather/state=XX/` so the SDP source can
# MAGIC extract the county GISJOIN from the file path.
# MAGIC
# MAGIC **Source:** `s3://oedi-data-lake/nrel-pds-building-stock/end-use-load-profiles-for-us-building-stock/2024/resstock_amy2018_release_2/weather/`
# MAGIC
# MAGIC **Required, fail-hard:** this download raises on any failure — it's the
# MAGIC same anonymous, unauthenticated bucket the load shapes already depend on,
# MAGIC so there's no more-available fallback tier below it.

# COMMAND ----------

# MAGIC %pip install boto3
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
dbutils.widgets.text("volume", "landing_weather")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value: str, label: str) -> str:
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")
volume = _check_id(dbutils.widgets.get("volume").strip(), "volume")

# Comma-separated 2-letter state codes; same knob as load_shapes/01_download.py.
dbutils.widgets.text("states", "MI")
_states = [s.strip().upper() for s in dbutils.widgets.get("states").split(",") if s.strip()]
if not _states:
    raise ValueError("states widget must not be empty")
STATE_PREFIXES = [f"state={s}" for s in _states]

# Comma-separated 5-digit county FIPS (state+county); empty = every county in
# the state(s) above. GISJOIN filename encoding: G + 2-digit state FIPS + 0 +
# 3-digit county FIPS + 0 (raw_weather_hourly.sql:24-29 decodes this on read).
dbutils.widgets.text("geoids", "")
_geoids = [g.strip() for g in dbutils.widgets.get("geoids").split(",") if g.strip()]
GISJOIN_PREFIXES = [f"G{g[:2]}0{g[2:]}0" for g in _geoids]

dbutils.widgets.text("force_download", "false")
_force_download = dbutils.widgets.get("force_download").strip().lower() == "true"

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS `{schema}`")
spark.sql(f"USE SCHEMA `{schema}`")
spark.sql(f"CREATE VOLUME IF NOT EXISTS `{volume}`")

volume_path = f"/Volumes/{catalog}/{schema}/{volume}"

print(f"Catalog: {catalog}")
print(f"Schema:  {schema}")
print(f"Volume:  {volume_path}")
print(f"States:  {_states}")
print(f"Geoids:  {_geoids or 'all'}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 0: Skip-if-exists scope check

# COMMAND ----------

import json
import os

output_dir = os.path.join(volume_path, "weather")
_scope = {"states": sorted(_states), "geoids": sorted(_geoids)}
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

# MAGIC %md
# MAGIC ## Phase 1: List & download weather CSVs from OEDI S3 (parallel, keyless)

# COMMAND ----------

import shutil
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from botocore import UNSIGNED
from botocore.config import Config

MAX_WORKERS = 16

S3_BUCKET = "oedi-data-lake"
S3_PREFIX = (
    "nrel-pds-building-stock/end-use-load-profiles-for-us-building-stock/"
    "2024/resstock_amy2018_release_2/weather/"
)

_tmp_dir = tempfile.mkdtemp(prefix="eulp_weather_")
print(f"Temp dir: {_tmp_dir}")

files_to_download: list[tuple[str, str]] = []
s3 = boto3.client("s3", config=Config(signature_version=UNSIGNED))
paginator = s3.get_paginator("list_objects_v2")

matched_gisjoins: set[str] = set()
for state_prefix in STATE_PREFIXES:
    prefix = f"{S3_PREFIX}{state_prefix}/"
    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith(".csv"):
                continue
            fname = key.rsplit("/", 1)[-1]
            if GISJOIN_PREFIXES:
                gisjoin = next((g for g in GISJOIN_PREFIXES if fname.startswith(g)), None)
                if gisjoin is None:
                    continue
                matched_gisjoins.add(gisjoin)
            dest = os.path.join(_tmp_dir, state_prefix, fname)
            files_to_download.append((key, dest))

if not files_to_download:
    raise RuntimeError(
        f"No weather CSVs found under s3://{S3_BUCKET}/{S3_PREFIX} for states "
        f"{_states}"
        + (f" / geoids {_geoids}" if _geoids else "")
        + ". The OEDI bucket layout or state/county coverage may have changed."
    )

if GISJOIN_PREFIXES:
    unmatched = [
        g for g, prefix in zip(_geoids, GISJOIN_PREFIXES) if prefix not in matched_gisjoins
    ]
    if unmatched:
        raise RuntimeError(
            f"Requested geoid(s) matched zero weather CSVs: {unmatched}. Check the "
            f"FIPS codes or the OEDI bucket layout."
        )

print(f"CSV files to download: {len(files_to_download)}")


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
    futures = {pool.submit(_download_one, k, d): k for k, d in files_to_download}
    for i, future in enumerate(as_completed(futures), start=1):
        dest, err = future.result()
        if err is None:
            downloaded.append(dest)
        else:
            failed.append((dest, err))
        if i % 25 == 0 or i == len(futures):
            print(f"  [{i}/{len(futures)}] ok={len(downloaded)} failed={len(failed)}")

elapsed = time.time() - t0
print(f"\nDownloaded: {len(downloaded)}, Failed: {len(failed)} ({elapsed:.0f}s)")

if failed:
    # Fail-hard: the weather download is a required source (like FEMA/TIGER/
    # load-shapes) — no empty-stub degrade, no "solar optional" carve-out.
    for path, err in failed[:10]:
        print(f"  FAILED: {path}: {err}")
    shutil.rmtree(_tmp_dir, ignore_errors=True)
    raise RuntimeError(
        f"{len(failed)} of {len(files_to_download)} weather CSV downloads failed. "
        f"See logs above for details."
    )

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 2: Copy local CSVs → UC volume

# COMMAND ----------

# Clear previous run so re-runs are idempotent and don't accumulate stale files.
if os.path.exists(output_dir):
    shutil.rmtree(output_dir)

print(f"Copying CSVs to {output_dir} ...")
t0 = time.time()
shutil.copytree(_tmp_dir, output_dir)
elapsed = time.time() - t0
print(f"Copy complete ({elapsed:.0f}s)")

shutil.rmtree(_tmp_dir, ignore_errors=True)

with open(_scope_path, "w") as f:
    json.dump(_scope, f)

# COMMAND ----------

csv_files = []
for root, dirs, files in os.walk(output_dir):
    for f in files:
        if f.endswith(".csv"):
            csv_files.append(os.path.join(root, f))

total_mb = sum(os.path.getsize(p) for p in csv_files) / (1024 * 1024)
print(f"CSV files: {len(csv_files)}")
print(f"Total size: {total_mb:.1f} MB")
print("\nAll files downloaded successfully.")
