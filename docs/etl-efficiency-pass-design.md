# ETL efficiency pass — trim over-ingestion + job-run inefficiencies

**Status:** SHIPPED 2026-07-12. All 8 changes implemented, deployed, and
verified against two full end-to-end runs of the renamed `customer_360_job`
in `timstanton_stable.customer_360`. See §6 for verification results.
**Author handoff:** written for a fresh session to execute end-to-end.
**Date:** 2026-07-12

---

## 1. Context

Before starting W10 (temporal realism Phase 4), this session audited the
ingest layer for data we download/materialize but never use, and reviewed the
latest job run for inefficiencies. The audit is done and verified against
live tables in `timstanton_stable.customer_360` and job run `541955076990846`
(~31 min wall).

The demo consumes exactly **3 counties** (Detroit tri-county:
26163/26125/26099, `target_geoids_quoted` in `databricks.yml:50`), but two
sources ingest the whole state, and a third stores far more columns than
anything downstream reads. All four ingest downloads also re-fetch from
scratch on every run, and one curated-tier notebook burns significant
serverless time on strictly-sequential per-table work.

## 2. Findings

| Source | Ingested today | Actually used | Waste |
|---|---|---|---|
| EULP weather (`src/10_ingest/weather/01_download.py`) | all 83 MI county CSVs → `raw_weather_hourly` 727,080 rows | 3 counties (26,280 rows) — sole join is `raw_meter_readings.sql:384` on premise `county_fips` | ~96% of rows + ~2 min download |
| FEMA buildings (`src/10_ingest/buildings/01_download_state.py`) | whole-state parquet → `curated_buildings` 4,925,408 rows | 1,551,780 rows in target counties (then sampled to `customer_sample_size`) — sole consumer is `raw_premises.sql:54` | ~68% of rows |
| Load shapes | already state-scoped (MI, `upgrade=0` only) ✅ | electricity columns only — `raw_meter_readings.sql` filters `load_shape LIKE 'out_electricity_%'` against the tidy table, whose `id_cols` pass every non-`out_*` wide column straight through unpivot | non-`out_electricity_*` wide `out_*` columns (gas/propane/fuel-oil/emissions/loads) stored in `raw_load_profiles`, never read downstream |
| TIGER counties | national zip (unavoidable — no per-state file at source), filtered to 83 MI rows in `01_download_tiger.py` | 3 rows join | negligible; leave as-is |

All 4 downloads re-fetch every run (clear-and-recopy, e.g.
`weather/01_download.py:167-169`, or remove-then-copy for the single-file
downloads like `tiger_counties/01_download_tiger.py:222-224`) — no
skip-if-exists. Sources are fixed vintages (AMY2018, TIGER 2024), so
re-downloads are pure waste (~4-5 task-minutes/run).

Run-level: `curated_table_comments` burns 440s issuing hundreds of sequential
`COMMENT ON COLUMN` statements across all curated tables
(`src/30_curated/table_comments.py`: `apply_uc_tags` lines 41-55,
`apply_column_comments` lines 58-75, dispatched per-table in two sequential
loops at lines 109-116 and 786-801); the `complaint_predictor_score` failure
seen in the baseline run was a Databricks `INTERNAL_ERROR` auto-retried
(platform, not ours); the true critical path is `complaint_predictor_train`
(537s, ML — out of scope here).

Safety checks already done: `weather_calendar_map.sql` is pure calendar math
(no weather-table read); app queries touch none of these wide tables;
`curated_buildings` and `raw_weather_hourly` each have exactly one downstream
consumer, both already county-filterable at the source; `raw_load_profiles_tidy`'s
`id_cols = [c for c in raw.columns if not c.startswith("out_")]` already
excludes every `out_*` column regardless of fuel type, so pruning non-electricity
`out_*` columns from the wide table doesn't change tidy's `id_cols` logic —
only the `out_cols` unpivot set shrinks (it already only unpivots
`out_electricity_*`).

Also found: `src/10_ingest/buildings_curate/04_test_quality.py` is orphaned —
no `resources/*.yml` references it (only `buildings.sql` is wired into the
`ingest_data` pipeline glob) — and is doubly stale: it hardcodes the retired
all-states assumption (`min_rows=50000000`, `min_state_count=51`) *and*
references a table named `"buildings"` that doesn't exist (the real MV is
`curated_buildings`).

And: the orchestrating Job resource is named `customer_360_pipeline`
(`resources/jobs.yml:12-13`) even though it *contains* SDP pipelines as
tasks — confusing; should be `customer_360_job`.

## 3. Changes

### 1. Unify the county-scope knob: `target_geoids` (unquoted)
- `databricks.yml:50-52`: replace `target_geoids_quoted`
  (`"'26163','26125','26099'"`) with `target_geoids` = `"26163,26125,26099"`.
- `src/20_synthetic/transformations/customer_master/raw_premises.sql:54`:
  `WHERE county_fips IN (${target_geoids_quoted})` →
  `WHERE ARRAY_CONTAINS(SPLIT('${target_geoids}', ','), county_fips)`;
  update the header comment at line 8 ("~50K premises") and the `COMMENT`
  clause at line 31 ("~50K rows... footprint via target_geoids_quoted") to
  reference the new knob name and, ideally, the actual default
  (`customer_sample_size` defaults to 1,000, not ~50K).
- `resources/pipelines.yml:84`: rename the `synthetic` pipeline's
  `target_geoids_quoted:` conf key to `target_geoids:`.
- This is a small step toward the documented boundary-spine unification
  (`ARCHITECTURE.md` §10) without building the spine.

### 2. County-scope the weather download
- `src/10_ingest/weather/01_download.py`: add a `geoids` widget
  (comma-separated county FIPS, empty = all counties in the state — today's
  behavior). Filter the S3 listing (currently lines 97-106) by GISJOIN
  filename prefix — geoid `26163` → `G2601630` (`G` + 2-digit state FIPS +
  `0` + 3-digit county FIPS + `0`, per `raw_weather_hourly.sql:24-29`, which
  already decodes this on read). Fail hard if a requested geoid matches no
  file, consistent with this script's existing fail-hard philosophy.
- `resources/jobs.yml` `weather_download` task (currently lines 66-74): pass
  `geoids: ${var.target_geoids}`.
- Result: 83 CSVs → 3; `raw_weather_hourly` 727K → ~26K rows; download task
  ~128s → seconds.

### 3. County-filter FEMA buildings at parquet-write
- `src/10_ingest/buildings/01_download_state.py`: add a `geoids` widget
  (empty = keep whole state). After `pyogrio.read_arrow` (currently line
  183), filter the Arrow table on the `FIPS` column
  (`pyarrow.compute.is_in`) before `pq.write_table` (currently line 184) —
  mirror the pattern `tiger_counties/01_download_tiger.py` already uses for
  its `STATEFP` filter. The whole-state GDB fetch itself is unavoidable
  (FEMA publishes per-state only, not per-county).
- `resources/jobs.yml` `fema_download` for-each task (currently lines
  36-51): pass `geoids: ${var.target_geoids}`.
- Update the stale "~125M US" row-count claims in `raw_buildings.sql:17` and
  `buildings_curate/buildings.sql:14` — both comments are already stale
  today (the actual landed volume is MI-only, ~4.9M rows, not 125M US) and
  become doubly stale after this change (~1.55M county rows).
- Result: `curated_buildings` 4.9M → ~1.55M rows; smaller parquet + faster
  `pipe_ingest_data`.

### 4. Prune non-electricity columns from the wide load-profiles table
- `src/10_ingest/load_shapes/raw_load_profiles.py`: in `load_profiles()`,
  after the existing column-name sanitization loop (currently lines 60-62),
  select down to: the path-derived metadata columns (`state`,
  `building_type`, `sector`, `dataset`), the timestamp column, the
  `units_represented`/`floor_area_represented` columns (both read by
  `raw_meter_readings.sql`'s `hourly_total_per_unit` CTE), the
  `in_geometry_building_type_recs`/`in_comstock_building_type` columns
  (used via `COALESCE` in the same CTE), and `out_electricity_*` columns
  only. Confirmed via `raw_load_profiles_tidy.py:31` and
  `raw_meter_readings.sql:62-81` that this is the complete set actually
  read.
- Update the DLT table comment (currently lines 18-24 of
  `raw_load_profiles.py`) — "all original out_* end-use columns preserved"
  is no longer true after this change.

### 5. Skip-if-exists on all 4 downloads (scope-manifest guard)
- Pattern (apply to `weather/01_download.py`, `load_shapes/01_download.py`,
  `tiger_counties/01_download_tiger.py`, `buildings/01_download_state.py`):
  after widget parsing, build a scope dict (states/geoids/year/source
  prefix, whichever inputs that script's scope is defined by); if
  `<landing-dir>/_scope.json` exists, matches, and the expected output
  file(s) are present → print a summary and exit early
  (`dbutils.notebook.exit(...)`). Write `_scope.json` after a successful
  download. Add a `force_download` widget (default `"false"`) to override.
- Scope mismatch (e.g. widening `target_geoids`) automatically triggers a
  full re-download — no manual cleanup.
- Ensure the SDP `read_files` globs don't pick up `_scope.json`
  (underscore-prefixed files are ignored by Spark's default `read_files`
  behavior, but verify the exact patterns in `raw_weather_hourly.sql`,
  `raw_buildings.sql`, and `raw_all.sql` before relying on that).
- Saves ~4-5 serverless task-minutes on every re-run; wave-1 ingest becomes
  near-instant on unchanged scope.

### 6. Parallelize `curated_table_comments` (440s → ~1 min)
- `src/30_curated/table_comments.py`: the outer per-table dispatch loops
  (tag application at lines 109-116, column-comment application at lines
  786-801) should run inside a `ThreadPoolExecutor` (~8 workers) — one table
  per submitted unit of work. The helper functions themselves
  (`apply_uc_tags` lines 41-55, `apply_column_comments`'s per-column loop
  lines 58-75) stay as-is. Same pattern optionally for the three tiny
  `src/40_ml/*/table_comments.py` — low value, skip unless trivial.
- Off the wall-clock critical path but burns serverless compute; cheap fix.

### 7. Cleanup
- Delete `src/10_ingest/buildings_curate/04_test_quality.py` — orphaned
  (referenced by no job/pipeline), encodes the retired all-states assumption
  (`min_rows=50M`, `min_state_count=51`), and separately references a
  nonexistent table name (`"buildings"` vs. the real `curated_buildings`).
  No functional risk in deleting it.

### 8. Rename the job: `customer_360_pipeline` → `customer_360_job`
Confusing today because the Job contains SDP pipelines as tasks.
- `resources/jobs.yml:12-13`: resource key `customer_360_pipeline` →
  `customer_360_job`; `name: ${bundle.name}_pipeline` → `${bundle.name}_job`.
- Doc references: `README.md:93` (`databricks bundle run
  customer_360_pipeline`), `README.md:109`, `ARCHITECTURE.md:18`.
- Deploy note: renaming the bundle resource key makes DABs **delete the old
  job and create a new one** (new `job_id`; run history on the old job is
  orphaned, not migrated). Acceptable; just expect the recreate on first
  deploy.

## 4. Explicitly NOT changing (and why)
- **TIGER national zip** — Census publishes no per-state county file; 80 MB,
  covered by #5's skip logic.
- **`pipe_curated` full_refresh`** — required: `cm_change_feeds` re-creates
  `raw_*_changes` each run, breaking AUTO CDC checkpoints
  (`jobs.yml:118-121`).
- **`fema_list_states` + for_each for one state** — keeps multi-state
  genericity; ~90s of parallel wave-1 time, not the bottleneck.
- **`complaint_predictor_train` 537s** — the real critical path, but that's
  ML tuning, not ETL; out of scope for this pass.
- **`complaint_predictor_score` `INTERNAL_ERROR`** — Databricks platform
  error, auto-retry already worked.

## 5. Verification
1. `databricks bundle deploy` (DEFAULT profile → `timstanton_stable.customer_360`).
   **Correction found while executing this step:** the bundle's variable
   *defaults* (`catalog=main`, `schema=customer_360_test`) do **not** point at
   `timstanton_stable.customer_360` — every real deploy of this repo has
   always passed `--var catalog=timstanton_stable --var schema=customer_360
   --var warehouse_id=8c35ef80cbacd670 --var genie_space_id=<id>` explicitly.
   Deploying with truly zero `--var` flags makes Terraform plan to **destroy**
   the live `timstanton_stable.customer_360` schema and create
   `main.customer_360_test` instead (caught by the CLI's own destructive-action
   prompt before anything was touched). Always pass the explicit `--var` set
   above; "no `--var` flags" was a misreading of the W4 near-miss memory,
   which was actually about *missing* (not zero) `--var` flags.
2. Run `customer_360_job` (renamed) end-to-end; then run it a **second
   time** to exercise the skip-if-exists path (downloads should no-op,
   second run's download tasks noticeably faster).
3. Row-count assertions via SQL: `raw_weather_hourly` = 26,280 rows / 3
   distinct geoids; `curated_buildings` ≈ 1.55M rows, all in the 3 counties;
   `raw_load_profiles` has no non-`out_electricity_*` `out_*` columns;
   `dim_premise`/`fact_meter_reading` counts unchanged vs. today (sampling
   is seeded — spot-check a few `premise_id`s for stability).
4. Re-verify FKs via `information_schema.table_constraints` (full-refresh
   runs can silently drop them — see fk-constraint-dag-race precedent).
5. App smoke test locally (`app` on `:8000`): map loads, premise drawer
   usage chart renders (exercises meter readings + weather-derived data),
   CSAT view intact.
6. Compare task durations vs. baseline run `541955076990846`
   (`weather_download` 128s, `loadshapes_download` 120s,
   `pipe_ingest_data` 102s, `curated_table_comments` 440s); expect
   `weather_download` in seconds and `curated_table_comments` ≤ ~90s.

## 6. Verification results (executed 2026-07-12, run 1: `335966161667687`, run 2: `1125705892818068`)

All checks passed. Row counts matched predictions exactly:

| Assertion | Result |
|---|---|
| `raw_weather_hourly` rows / distinct geoids | 26,280 / 3 (both runs) |
| `curated_buildings` rows / distinct counties | 1,551,780 / 3 (both runs) |
| `raw_load_profiles` columns | 106 → 47 (all non-`out_electricity_*` `out_*` columns gone; also incidentally dropped `upgrade`/`in_state`/`models_used`, confirmed unused downstream) |
| `dim_premise` / `fact_meter_readings_daily` row counts | 2,739 / 1,999,470 — identical before and after both runs |
| FK count (`information_schema.table_constraints`) | 83 — unchanged across both full-refresh runs |
| App smoke test | map loads (2,731 premises), premise-inspector usage chart renders with real data (spot-checked 4657 Oak Way, Wayne County — 3,579 avg monthly kWh, 112% of peer P75), CSAT view intact, zero console errors |

**Skip-if-exists confirmed working**: all 4 download notebooks explicitly
returned `{"status": "skipped", ...}` on run 2. However, the wall-clock
savings are smaller than the design assumed — `weather_download` (128s →
97s → 76s) and `loadshapes_download` (120s → 111s → 80s) are dominated by
serverless notebook cold-start (`%pip install boto3` + `restartPython()`,
~60-70s) that runs *before* the skip-check can execute, not by the
listing/download work the skip logic actually eliminates. `fema_download`
showed the clearest win (93s → 21.5s, `geo` environment, no runtime pip
install) since its environment likely stayed warm from the preceding
`fema_list_states` task. **Correction:** "near-instant on unchanged scope"
(§3 item 5) does not hold uniformly — treat it as "download/listing work
eliminated, environment-startup floor remains," not "sub-10s."

`curated_table_comments` held its win consistently: 440s baseline → 125.1s
(run 1) → 116.7s (run 2), a stable ~3.7x speedup (a bit above the ~90s
estimate in §3 item 6, but still the single biggest win in this pass).

ML training durations were noisy run-to-run (`complaint_predictor_train`
563.8s → 608.6s) — expected, unrelated to this pass, not a regression.
Total wall clock: run 1 = 1477s (~24.6 min, vs. ~31 min baseline), run 2 =
1474s (near-identical, since ML training — untouched by this pass — is the
true critical path and dominates total wall clock regardless of ingest
savings).
