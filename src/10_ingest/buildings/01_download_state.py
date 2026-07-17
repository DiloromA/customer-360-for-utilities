# Databricks notebook source
# MAGIC %md
# MAGIC # FEMA USA Structures (one state) → parquet → UC volume
# MAGIC
# MAGIC One iteration of the upstream `for_each_task`. Downloads the state's
# MAGIC GDB-format zip from the public FEMA/ORNL S3 bucket, converts the
# MAGIC feature class to a single parquet file via pyogrio (no GDAL CLI
# MAGIC needed), and copies it to the landing volume for SDP to pick up.
# MAGIC
# MAGIC The geometry column is preserved as WKB binary; ST_GEOMFROMWKB
# MAGIC reconstructs it in the curated layer.

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
dbutils.widgets.text("volume", "landing")
dbutils.widgets.text("state", "Delaware")
dbutils.widgets.text("s3_key", "")
# Comma-separated 5-digit county FIPS; empty = keep the whole state (today's
# behavior). Applied as an Arrow-side filter on the FIPS column before the
# parquet write, so downstream volumes/tables only ever see the target counties.
dbutils.widgets.text("geoids", "")
dbutils.widgets.text("force_download", "false")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value: str, label: str) -> str:
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")
volume = _check_id(dbutils.widgets.get("volume").strip(), "volume")
state = dbutils.widgets.get("state").strip()
s3_key = dbutils.widgets.get("s3_key").strip()
_geoids = [g.strip() for g in dbutils.widgets.get("geoids").split(",") if g.strip()]
_force_download = dbutils.widgets.get("force_download").strip().lower() == "true"

if not state:
    raise ValueError("state is required")
if not s3_key or not s3_key.endswith(".zip"):
    raise ValueError(f"Invalid s3_key: {s3_key!r}")

# Schema + volume creation is idempotent; safe under concurrent for_each iterations.
spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS `{schema}`")
spark.sql(f"USE SCHEMA `{schema}`")
spark.sql(f"CREATE VOLUME IF NOT EXISTS `{volume}`")

volume_path = f"/Volumes/{catalog}/{schema}/{volume}"
safe_state = state.replace(" ", "_")

print(f"State:       {state}")
print(f"S3 key:      {s3_key}")
print(f"Volume:      {volume_path}")
print(f"Geoids:      {_geoids or 'all'}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 0: Skip-if-exists scope check

# COMMAND ----------

import json
import os

_scope = {"s3_key": s3_key, "geoids": sorted(_geoids)}
_scope_path = os.path.join(volume_path, f"_scope_{safe_state}.json")
_final_volume_dest = os.path.join(volume_path, f"{safe_state}.parquet")


def _existing_scope() -> dict | None:
    try:
        with open(_scope_path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


if not _force_download and _existing_scope() == _scope and os.path.exists(_final_volume_dest):
    print(
        f"Scope unchanged ({_scope}) and {_final_volume_dest} already present "
        f"— skipping download."
    )
    dbutils.notebook.exit(json.dumps({"status": "skipped", "state": state}))

# COMMAND ----------

import gc
import shutil
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq
import pyogrio

S3_BASE = "https://fema-femadata.s3.amazonaws.com"

# Columns we keep from the source GDB. pyogrio.read_info reports which of
# these are actually present per state (FEMA schema is consistent but we
# defensively intersect at read time).
GDB_COLUMNS = [
    "UUID",
    "OCC_CLS",
    "PRIM_OCC",
    "PROP_ADDR",
    "PROP_CITY",
    "PROP_ST",
    "PROP_ZIP",
    "PROP_CNTY",
    "FIPS",
    "LATITUDE",
    "LONGITUDE",
    "SQFEET",
    "SQMETERS",
    "HEIGHT",
    "POP_MEDIAN",
    "CENSUSCODE",
]

# COMMAND ----------

# Stage the entire state worker on local scratch — multi-GB GDBs are
# unreliable when written through FUSE. Final parquet is shutil.copy2'd
# to the volume at the end.
work_dir = tempfile.mkdtemp(prefix=f"fema_{safe_state}_")
zip_path = os.path.join(work_dir, f"{safe_state}.zip")
extract_dir = os.path.join(work_dir, "extracted")
parquet_path = os.path.join(work_dir, f"{safe_state}.parquet")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 1: Download the state deliverable zip from S3

# COMMAND ----------

encoded_key = urllib.parse.quote(s3_key, safe="/")
url = f"{S3_BASE}/{encoded_key}"
print(f"Downloading {url}")

t0 = time.time()
last_err: Exception | None = None
for attempt in range(1, 4):
    try:
        urllib.request.urlretrieve(url, zip_path)
        last_err = None
        break
    except (OSError, urllib.error.URLError) as e:  # noqa: PERF203 - bounded retry loop
        last_err = e
        if attempt < 3:
            time.sleep(10 * attempt)

if last_err is not None:
    raise RuntimeError(f"Download failed after 3 attempts: {last_err}")

zip_mb = os.path.getsize(zip_path) / (1024 * 1024)
print(f"Downloaded {zip_mb:.1f} MB in {time.time() - t0:.0f}s")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 2: Extract GDB

# COMMAND ----------

os.makedirs(extract_dir, exist_ok=True)
with zipfile.ZipFile(zip_path, "r") as z:
    z.extractall(extract_dir)
os.remove(zip_path)

gdb_path: str | None = None
for root_dir, dirs, _files in os.walk(extract_dir):
    for d in dirs:
        if d.endswith(".gdb"):
            gdb_path = os.path.join(root_dir, d)
            break
    if gdb_path:
        break

if not gdb_path:
    raise RuntimeError(f"No .gdb directory found inside {zip_path}")

print(f"GDB: {gdb_path}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 3: GDB → Parquet (pyogrio Arrow stream)
# MAGIC
# MAGIC pyogrio reads OpenFileGDB directly without a system GDAL install, and
# MAGIC returns geometry as a WKB binary column that survives a parquet
# MAGIC round-trip cleanly. We keep one parquet file per state — Auto Loader
# MAGIC discovers them in the volume regardless of count.

# COMMAND ----------

layers = pyogrio.list_layers(gdb_path)
if len(layers) == 0:
    raise RuntimeError(f"No layers found in {gdb_path}")
layer_name = str(layers[0][0])
info = pyogrio.read_info(gdb_path, layer=layer_name)
available_fields = set(info["fields"])
read_cols = [c for c in GDB_COLUMNS if c in available_fields]
missing = set(GDB_COLUMNS) - available_fields
if missing:
    print(f"Note: missing source columns for {state}: {sorted(missing)}")

t0 = time.time()
_meta, table = pyogrio.read_arrow(gdb_path, layer=layer_name, columns=read_cols)
total_rows = table.num_rows
if _geoids and "FIPS" in table.column_names:
    table = table.filter(pc.is_in(table.column("FIPS"), value_set=pa.array(_geoids)))
    print(f"{state}: {total_rows:,} rows -> {table.num_rows:,} rows after geoid filter {_geoids}")
pq.write_table(table, parquet_path, row_group_size=500_000)
rows = table.num_rows
parquet_mb = os.path.getsize(parquet_path) / (1024 * 1024)
print(f"{state}: {rows:,} rows -> {parquet_mb:.1f} MB parquet in {time.time() - t0:.0f}s")

# Free Arrow buffers and the on-disk extract before the volume copy.
del table
gc.collect()
shutil.rmtree(extract_dir, ignore_errors=True)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 4: Copy parquet to UC volume
# MAGIC
# MAGIC The sequential `shutil.copy2` avoids the FUSE write quirks of writing
# MAGIC pyarrow output directly to /Volumes/.

# COMMAND ----------

volume_dest = os.path.join(volume_path, f"{safe_state}.parquet")
shutil.copy2(parquet_path, volume_dest)
shutil.rmtree(work_dir, ignore_errors=True)

with open(_scope_path, "w") as f:
    json.dump(_scope, f)

print(f"Wrote {volume_dest} ({parquet_mb:.1f} MB, {rows:,} rows)")
