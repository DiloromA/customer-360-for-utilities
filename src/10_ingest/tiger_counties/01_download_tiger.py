# Databricks notebook source
# MAGIC %md
# MAGIC # Census TIGER county shapefile → parquet → UC volume
# MAGIC
# MAGIC Downloads the Census Bureau's TIGER/Line **all-US county** shapefile
# MAGIC for the given vintage year, filters to the target state FIPS
# MAGIC (default `26` = Michigan), and writes one parquet file to the landing
# MAGIC volume for SDP to pick up. Geometry is preserved as WKB binary;
# MAGIC `ST_GEOMFROMWKB` reconstructs it in the SQL materialized view.
# MAGIC
# MAGIC **Source:** `https://www2.census.gov/geo/tiger/TIGER<year>/COUNTY/`
# MAGIC (public domain, no auth required).
# MAGIC
# MAGIC TIGER/Line uses NAD83 (EPSG:4269). The horizontal difference between
# MAGIC NAD83 and WGS84 (EPSG:4326) is <1 m for the conterminous US — fine
# MAGIC for clipping FEMA building centroids to county polygons downstream.

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
dbutils.widgets.text("volume", "landing")
dbutils.widgets.text("tiger_year", "2024")
dbutils.widgets.text("state_fips", "26")
dbutils.widgets.text("force_download", "false")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")
_SAFE_YEAR = re.compile(r"^\d{4}$")
_SAFE_FIPS = re.compile(r"^\d{2}$")


def _check(pattern: re.Pattern[str], value: str, label: str) -> str:
    if not pattern.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check(_SAFE_ID, dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check(_SAFE_ID, dbutils.widgets.get("schema").strip(), "schema")
volume = _check(_SAFE_ID, dbutils.widgets.get("volume").strip(), "volume")
tiger_year = _check(_SAFE_YEAR, dbutils.widgets.get("tiger_year").strip(), "tiger_year")
state_fips = _check(_SAFE_FIPS, dbutils.widgets.get("state_fips").strip(), "state_fips")
_force_download = dbutils.widgets.get("force_download").strip().lower() == "true"

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS `{schema}`")
spark.sql(f"USE SCHEMA `{schema}`")
spark.sql(f"CREATE VOLUME IF NOT EXISTS `{volume}`")

volume_path = f"/Volumes/{catalog}/{schema}/{volume}"

print(f"Catalog:    {catalog}")
print(f"Schema:     {schema}")
print(f"Volume:     {volume_path}")
print(f"TIGER year: {tiger_year}")
print(f"State FIPS: {state_fips}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 0: Skip-if-exists scope check

# COMMAND ----------

import json
import os

_scope = {"tiger_year": tiger_year, "state_fips": state_fips}
_scope_path = os.path.join(volume_path, f"_scope_state{state_fips}.json")
_final_volume_dest = os.path.join(volume_path, f"counties_state{state_fips}.parquet")


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
    dbutils.notebook.exit(json.dumps({"status": "skipped", "state_fips": state_fips}))

# COMMAND ----------

import gc
import shutil
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

import pyarrow.compute as pc
import pyarrow.parquet as pq
import pyogrio
from pyarrow.types import is_binary as pyarrow_is_binary

# All-US county shapefile zip. ~80 MB; <30s to download on serverless.
TIGER_URL = (
    f"https://www2.census.gov/geo/tiger/TIGER{tiger_year}/COUNTY/tl_{tiger_year}_us_county.zip"
)

# Columns we keep from the source shapefile. Reference:
# https://www2.census.gov/geo/pdfs/maps-data/data/tiger/tgrshp2024/TGRSHP2024_TechDoc.pdf
SHP_COLUMNS = [
    "STATEFP",  # 2-digit state FIPS
    "COUNTYFP",  # 3-digit county FIPS within state
    "GEOID",  # state + county FIPS (5 digits)
    "NAME",  # county name without "County" (e.g., "Multnomah")
    "NAMELSAD",  # county name with legal/statistical area description (e.g., "Multnomah County")
    "LSAD",  # legal/statistical area description code
    "ALAND",  # land area in sq meters
    "AWATER",  # water area in sq meters
    "INTPTLAT",  # latitude of internal point as string
    "INTPTLON",  # longitude of internal point as string
]

# COMMAND ----------

# Stage everything on local scratch; FUSE writes for multi-MB parquet are
# unreliable. Final parquet is shutil.copy2'd to the volume at the end.
work_dir = tempfile.mkdtemp(prefix=f"tiger_{tiger_year}_")
zip_path = os.path.join(work_dir, f"tl_{tiger_year}_us_county.zip")
extract_dir = os.path.join(work_dir, "extracted")
parquet_path = os.path.join(work_dir, f"counties_state{state_fips}.parquet")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 1: Download the all-US county shapefile

# COMMAND ----------

print(f"Downloading {TIGER_URL}")

t0 = time.time()
last_err: Exception | None = None
for attempt in range(1, 4):
    try:
        urllib.request.urlretrieve(TIGER_URL, zip_path)
        last_err = None
        break
    except (OSError, urllib.error.URLError) as e:
        last_err = e
        if attempt < 3:
            time.sleep(10 * attempt)

if last_err is not None:
    raise RuntimeError(f"Download failed after 3 attempts: {last_err}")

zip_mb = os.path.getsize(zip_path) / (1024 * 1024)
print(f"Downloaded {zip_mb:.1f} MB in {time.time() - t0:.0f}s")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 2: Extract shapefile

# COMMAND ----------

os.makedirs(extract_dir, exist_ok=True)
with zipfile.ZipFile(zip_path, "r") as z:
    z.extractall(extract_dir)
os.remove(zip_path)

shp_path: str | None = None
for fname in os.listdir(extract_dir):
    if fname.endswith(".shp"):
        shp_path = os.path.join(extract_dir, fname)
        break

if not shp_path:
    raise RuntimeError(f"No .shp file found inside {extract_dir}")

print(f"Shapefile: {shp_path}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 3: Read → filter by state FIPS → write parquet
# MAGIC
# MAGIC pyogrio.read_arrow returns an Arrow table with geometry as a WKB
# MAGIC binary column. We filter rows server-side via pyarrow.compute
# MAGIC (state FIPS is a small varchar comparison — fast).

# COMMAND ----------

info = pyogrio.read_info(shp_path)
available_fields = set(info["fields"])
read_cols = [c for c in SHP_COLUMNS if c in available_fields]
missing = set(SHP_COLUMNS) - available_fields
if missing:
    print(f"Note: missing source columns: {sorted(missing)}")

t0 = time.time()
meta, table = pyogrio.read_arrow(shp_path, columns=read_cols)
total_rows = table.num_rows

# Filter to target state. STATEFP is a string column ('01'..'72' across US+territories).
mask = pc.equal(table.column("STATEFP"), state_fips)
table = table.filter(mask)
state_rows = table.num_rows
print(f"All-US counties: {total_rows:,} -> state {state_fips}: {state_rows:,}")
if state_rows == 0:
    raise RuntimeError(
        f"No counties found for state_fips={state_fips!r} in TIGER {tiger_year}. "
        "Check that the FIPS code is valid."
    )

# pyogrio's geometry-column name varies by source (often "geometry" or
# "wkb_geometry"). Find it by dtype (binary) and rename to a canonical
# name so the SDP MV doesn't depend on pyogrio internals.
binary_cols = [f.name for f in table.schema if pyarrow_is_binary(f.type)]
if not binary_cols:
    raise RuntimeError(
        f"No binary (geometry) column found in pyogrio Arrow output. Schema: {table.schema}"
    )
if len(binary_cols) > 1:
    raise RuntimeError(f"Multiple binary columns found, ambiguous geometry: {binary_cols}")
geom_col = binary_cols[0]
if geom_col != "wkb_geometry":
    print(f"Renaming geometry column {geom_col!r} -> 'wkb_geometry'")
    new_names = ["wkb_geometry" if n == geom_col else n for n in table.column_names]
    table = table.rename_columns(new_names)

print(f"CRS reported by pyogrio: {meta.get('crs')!r}")
print(f"Final schema: {table.schema}")

pq.write_table(table, parquet_path, row_group_size=500_000)
parquet_mb = os.path.getsize(parquet_path) / (1024 * 1024)
print(f"Wrote {parquet_mb:.2f} MB parquet in {time.time() - t0:.1f}s")

del table
gc.collect()
shutil.rmtree(extract_dir, ignore_errors=True)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Phase 4: Copy parquet to UC volume
# MAGIC
# MAGIC Clear any prior file for the same state so re-runs don't accumulate.

# COMMAND ----------

volume_dest = os.path.join(volume_path, f"counties_state{state_fips}.parquet")
if os.path.exists(volume_dest):
    os.remove(volume_dest)

shutil.copy2(parquet_path, volume_dest)
shutil.rmtree(work_dir, ignore_errors=True)

with open(_scope_path, "w") as f:
    json.dump(_scope, f)

print(f"Wrote {volume_dest} ({parquet_mb:.2f} MB, {state_rows:,} rows)")
