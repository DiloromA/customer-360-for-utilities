# Solar Shape Injection + PV Detector — Implementation Design

Status: **Design approved 2026-07-09, nothing implemented.** This doc is
self-contained — a fresh session can execute it without redoing the
research. It implements Phase 1 of `docs/temporal-realism-scoping.md`
(retire the NREL API) plus a new deliverable that doc didn't scope: a
PV detection model mirroring `src/40_ml/ev_detector/`.

Verified against the working tree at `a8c6ba5` (2026-07-09). All S3
paths were verified by live anonymous fetch on 2026-07-07/08.

---

## 1. Context & decisions (do not relitigate)

`src/10_ingest/nsrdb_solar/01_download_psm3.py` is the only
credentialed external dependency in the pipeline (NREL API key via
secret scope `c360/nrel_api_key` + `nrel_email` widget). NREL has been
unreachable repeatedly (most recently mid-run 2026-07-08), which is why
solar is currently an "optional module" that degrades to an empty stub
table. Decisions, all user-approved:

1. **Remove every NREL API / NSRDB reference.** Replace with data that
   ships inside the ResStock/ComStock release already being downloaded
   from the anonymous OEDI S3 bucket (keyless, unsigned boto3 — same
   pattern `src/10_ingest/load_shapes/01_download.py` uses today).
2. **PV generation needs NO new download.** The by_state aggregates
   already ingested carry `out.electricity.pv.energy_consumption.kwh`
   — real EnergyPlus-simulated rooftop-PV generation (MI SFD: 35,040
   15-min rows, −32.4 GWh/yr, negative = generation). It flows through
   `raw_load_profiles` → `raw_load_profiles_tidy` today (dots
   normalized to underscores: `out_electricity_pv_energy_consumption_kwh`)
   and is discarded only by the exclusion list in
   `src/20_synthetic/transformations/ami/raw_meter_readings.sql:57-61`.
   We build a normalized sum-to-one annual shape from it and "inject"
   PV per adopter — exactly how EV charging is injected from hourly
   templates in the same file.
3. **Temperature (for the heat-pump adder) needs a small new download.**
   The EULP release ships per-county AMY2018 weather CSVs in the same
   bucket. Verified path:
   ```
   s3://oedi-data-lake/nrel-pds-building-stock/end-use-load-profiles-for-us-building-stock/
     2024/resstock_amy2018_release_2/weather/state=MI/G2600010_2018.csv
   ```
   ~200 KB/file, ~85 files for MI, hourly. Columns:
   `date_time, Dry Bulb Temperature [°C], Relative Humidity [%],
   Wind Speed [m/s], Wind Direction [Deg],
   Global Horizontal Radiation [W/m2], Direct Normal Radiation [W/m2],
   Diffuse Horizontal Radiation [W/m2]`.
   GISJOIN filename encoding: `G` + state fips + `0` + county fips +
   `0` (geoid `26163` → `G2601630`).
4. **The weather download is REQUIRED / fail-hard** (user confirmed) —
   like FEMA/TIGER/load-shapes. No empty-stub fallback, no
   `solar_available` gating, no "solar optional" carve-outs anywhere.
5. **Option A shape model only** (from the scoping doc): one
   state-level fleet-average PV shape; commercial adopters ride the
   residential shape. Option B (pvlib per-county transposition from
   DNI/DHI) is deferred — keep DNI/DHI columns landed so it's possible
   later.
6. **PV detector framing — differs from EV.** Utilities KNOW their
   registered solar (interconnection agreements / net metering;
   `raw_der_customer` sets `pv_net_metered = true` for all adopters).
   Frame the model everywhere (comments, table COMMENTs, docs) as
   detecting **unregistered/unpermitted PV** — validating
   interconnection records, surfacing self-installs (islanding safety,
   revenue protection, forecasting). This also justifies the
   delivered-channel-only feature restriction: registered systems show
   in the export channel; unregistered ones must be inferred from
   consumption patterns.
7. **No app-layer changes.** The EV detector is table-only today (no
   UI consumes `ml_ev_detection_predictions` — verified by grep).
   Parity for the PV detector means table-only too.
8. **Real-utility drop-in posture preserved:** all injection stays in
   `20_synthetic` (the layer a utility replaces with real AMI); the
   weather ingest feeds only the synthetic generator; the curated star
   schema remains the clean integration contract.
9. **Known consequence, deliberately deferred to Phase 2 (do NOT fix
   here):** after this change, displayed 2017 and 2018 are hour-for-hour
   identical copies — real 2017-vs-2018 NSRDB weather was the last
   source of YoY variation, so YoY benchmarks compute ~0% until Phase 2
   lands. Phase 2 was AMENDED 2026-07-09 (user-approved) to address
   this properly: single source year, all display history manufactured
   via `weather_calendar_map` with a deterministic `kwh_scale` YoY
   column, `target_years` deleted entirely. See
   `docs/temporal-realism-scoping.md` §3. Phase 1's source-clock joins
   (§A2 below) are the prerequisite and are unchanged by the amendment.

---

## 2. Part A — Retire NREL, inject solar

### A1. New ingest module `src/10_ingest/weather/`

**`01_download.py`** — copy the structure of
`load_shapes/01_download.py`: widgets (`catalog`, `schema`, `volume`,
`states` default `MI`), `_SAFE_ID` validation, unsigned boto3
(`Config(signature_version=UNSIGNED)`), ThreadPoolExecutor download to
local temp then copy to the volume. Source prefix:
`nrel-pds-building-stock/end-use-load-profiles-for-us-building-stock/2024/resstock_amy2018_release_2/weather/state={XX}/`.
Land under `{volume_path}/weather/state=XX/` so the SDP source can
parse path metadata. **Fail-hard:** raise on any failed download (like
the FEMA/TIGER downloads) — no stub writing, no try/except degrade.

**`raw_weather_hourly.sql`** — new SDP MV reading the CSVs via
`read_files('${weather_volume_path}', format => 'csv', header => true)`.
- Parse `geoid` from the GISJOIN filename via
  `_metadata.file_path`: regex `G(\d{2})0(\d{3})0_` → geoid =
  fips2 || fips3 (e.g. `G2601630` → `26163`).
- Land the columns the AMI generator's contract needs —
  `geoid, timestamp_utc, temperature_c, ghi_w_m2` — plus the free
  extras (`relative_humidity_pct, wind_speed_m_s, dni_w_m2, dhi_w_m2`)
  for future storm-outage realism / Option B.
- Backtick-quote the source column names (they contain spaces and
  brackets): e.g. `` `Dry Bulb Temperature [°C]` ``. Verify the exact
  header spelling against a downloaded file before writing the CAST
  list — read_files header parsing of `[°C]` should be checked once at
  implementation time.
- **Timestamp convention (fixes the latent clock bug by doing
  nothing):** EULP weather `date_time` is local standard time. The AMY
  load-shape hours in `raw_meter_readings.sql` are ALSO local standard
  time, merely labeled `'UTC'` by `MAKE_TIMESTAMP(..., 'UTC')`. Parse
  `date_time` directly with NO timezone conversion and name the column
  `timestamp_utc` to keep the existing join contract. Both series then
  share one (fake-UTC, actually-LST) clock and solar noon aligns with
  load noon. Put a comment in the MV explaining this deliberately.
- Constraints mirroring the old MV: non-null geoid/timestamp,
  `ghi_w_m2 >= 0`. COMMENT should credit the source: "NREL End-Use
  Load Profiles AMY2018 weather (OEDI public S3, keyless)".

**Delete `src/10_ingest/nsrdb_solar/` entirely** (both files).

### A2. `src/20_synthetic/transformations/ami/raw_meter_readings.sql`

- **`nsrdb` CTE → `weather` CTE**, reading `${weather_table}` (renamed
  config key). Drop the `DATE_TRUNC('HOUR', …)` mid-hour fix-up — that
  existed for PSM3's `:30` stamps; EULP is top-of-hour.
- **CRITICAL join-key change — weather joins on the SOURCE clock, not
  the display timestamp.** NSRDB had real data for both display years
  (2017 AND 2018), so the old join on `(geoid, b.timestamp_utc)`
  worked. EULP weather exists for ONE source year (AMY2018). If the
  join stayed on display timestamps, every displayed-2017 row would
  find no weather → the HP adder silently vanishes for half the
  window. Instead: carry `htp.amy_timestamp_hour` through the `base`
  CTE (it's available at the `hourly_total_per_unit` join) and join
  BOTH `weather` and `pv_shape` on `(geoid,) amy_timestamp_hour` —
  the same source-clock key the load shapes use. Only the final
  display stamp (`MAKE_TIMESTAMP(y.year, …)`) is calendar-projected.
  This is also the Phase-2 pre-wiring: when `weather_calendar_map`
  arrives (temporal-realism-scoping §3), only the display projection
  changes to a map join — every physics join already sits on the
  canonical AMY2018 source clock and is untouched. (Timing coherence
  note, worth a comment in the SQL: base load, PV generation, and
  weather are now consistent BY CONSTRUCTION at each source hour —
  same EnergyPlus simulation vintage — which is better than the old
  setup where displayed-2017 base reflected 2018 weather while PV/HP
  reflected real 2017 NSRDB. Known accepted residue until Phase 2:
  re-stamping drifts day-of-week for displayed 2017 — a base-load
  occupancy artifact that exists today; weather/PV don't care about
  weekdays.)
- **New `pv_shape` CTE** from `${load_shapes_table}`
  (`raw_load_profiles_tidy`):
  ```sql
  pv_shape AS (
    SELECT
      DATE_TRUNC('HOUR', timestamp) AS amy_timestamp_hour,
      SUM(-value) / SUM(SUM(-value)) OVER ()   AS pv_fraction  -- sign-flip; sum-to-one over the year
    FROM ${load_shapes_table}
    WHERE state = '${target_state}'
      AND sector = 'residential'
      AND load_shape = 'out_electricity_pv_energy_consumption_kwh'
    GROUP BY DATE_TRUNC('HOUR', timestamp)
  )
  ```
  (Aggregating across residential building types = fleet-average
  shape. Negative values are generation, hence `-value`. Guard: keep
  `GREATEST(pv_fraction, 0)` or filter, in case of tiny positive
  parasitic-load values in the channel.)
- **Thread the shape to the adder.** The `base` CTE already carries
  the AMY hour before re-stamping — join `pv_shape` on the same
  `amy_timestamp_hour` used to join `hourly_total_per_unit` (easiest:
  select `htp.amy_timestamp_hour` through `base`, join `pv_shape` in
  `with_der`, then drop the column in the final SELECT).
- **Replace the GHI PV formula** (lines ~221-230):
  ```sql
  -- PV generation: EULP-simulated fleet-average shape (sum-to-one over the
  -- year) scaled to the system size. 1150 kWh per kW-DC per year is the
  -- Michigan fleet-average yield (typical range 1100-1200).
  CASE
    WHEN b.has_pv AND ps.pv_fraction IS NOT NULL
      THEN b.pv_system_kw_dc * 1150.0 * ps.pv_fraction
    ELSE 0.0
  END AS kwh_pv,
  ```
- HP adder unchanged except its source CTE name (`weather.temperature_c`).
- Update the header comment block (CTE list + PV model description).
- The now-pointless PV exclusion in `hourly_total_per_unit`
  (`raw_meter_readings.sql:57-61`) **stays** — base load must still
  exclude the PV channel (it would otherwise net generation out of the
  base). Update the comment there to say the PV channel is consumed by
  `pv_shape` instead of "thrown away".

### A3. Bundle wiring

**`resources/pipelines.yml`:**
- `ingest_data` libraries: replace
  `../src/10_ingest/nsrdb_solar/raw_irradiance_hourly.sql` with
  `../src/10_ingest/weather/raw_weather_hourly.sql`.
- `ingest_data` configuration: `nsrdb_volume_path` →
  `weather_volume_path: /Volumes/${var.catalog}/${var.schema}/landing_weather`.
- `synthetic` configuration: `nsrdb_table:
  ${var.catalog}.${var.schema}.raw_irradiance_hourly` →
  `weather_table: ${var.catalog}.${var.schema}.raw_weather_hourly`.
- Fix the stale header comment on `ingest_counties` ("Counties is its
  own pipeline because nsrdb_download … needs raw_counties") — the
  weather download no longer needs county lat/lons (GISJOIN encodes
  the FIPS). Counties stays a separate pipeline (dim_geography /
  raw_premises still read it) but the stated reason changes.

**`resources/jobs.yml`:**
- Delete the `nsrdb_download` task (lines ~67-80).
- Add `weather_download`, shaped like `loadshapes_download` (no
  dependency on `pipe_ingest_counties`):
  ```yaml
  - task_key: weather_download
    environment_key: default
    notebook_task:
      notebook_path: ../src/10_ingest/weather/01_download.py
      base_parameters:
        catalog: ${var.catalog}
        schema: ${var.schema}
        volume: landing_weather
        states: ${var.target_state}
  ```
- `pipe_ingest_data.depends_on`: replace `nsrdb_download` with
  `weather_download`.
- Update the header comment ("Optional modules: the NSRDB solar and
  load-shapes branches…") — there are no optional modules anymore.

**`databricks.yml`:** delete vars `nrel_email`, `nrel_secret_scope`,
and `target_geoids` (verified: `target_geoids` was only consumed by
`nsrdb_download`; `target_geoids_quoted` is a SEPARATE var used by
customer_master premise sampling — it stays).

### A4. Docs sweep

- `ARCHITECTURE.md`: ingest-module table row `nsrdb_solar` →
  `weather`, drop the "Optional — needs NREL key" column text; delete
  the Secrets paragraph about the NREL key (lines ~178-179); update
  the `target_geoids` mention (~190).
- `README.md`: mermaid node "NREL NSRDB" → EULP weather; source list
  entries (~168-169) → one keyless OEDI bullet; fix the "You likely
  won't have every source" paragraph (~135).
- `app/client/src/docs/data-sources.md`: same treatment (rows ~14-15,
  attribution line ~34). Keep NREL/ResStock/ComStock **attribution**
  everywhere — that's factual publisher credit, not a dependency.
- `docs/temporal-realism-scoping.md`: mark Phase 1 **SHIPPED** in the
  status header + phase table (same convention used for Phase 3).

---

## 3. Part B — PV detector `src/40_ml/pv_detector/`

Structural clone of `src/40_ml/ev_detector/` (5 files). Same XGBoost
binary classifier, same `sqrt(imbalance)` scale_pos_weight, same UC
registration + `@champion` alias, same top-K-by-base-rate threshold in
scoring, same `%run ./feature_spec` sharing. Anti-leakage: label is
`raw_der_customer.has_pv`; features read ONLY `kwh_delivered`-derived
columns — never `kwh_pv`, `kwh_received`, or `kwh_base` (near-perfect
label leaks).

### B1. Curated feature inputs — `src/30_curated/transformations/fact_meter_readings_daily.sql`

Add two additive columns to the daily aggregate (precedent:
`peak_hour_kwh` / `peak_hour_of_day` were added for the EV model):
```sql
ROUND(SUM(CASE WHEN HOUR(m.timestamp_utc) BETWEEN 10 AND 14
              THEN m.kwh_delivered ELSE 0 END), 2) AS midday_kwh,
ROUND(MIN(m.kwh_delivered), 2)                     AS min_hour_kwh,
```
Note in the table COMMENT that both are derivable from any hourly AMI
feed (keeps the real-utility drop-in contract explicit). Beware: the
curated pipeline runs `full_refresh: true` so no migration concerns.

### B2. `features.sql` → MV `ml_pv_detection_features`

One row per customer from `fact_meter_readings_daily` + `dim_customer`,
window `DATE'2017-12-31'..'2018-12-31'` (same as EV). Feature groups:
- Magnitude (context): `avg_daily_kwh, std_daily_kwh,
  median_daily_kwh, max_daily_kwh, coef_of_variation`.
- **Midday-dip signature** (the solar tell — net demand sags toward /
  below zero around solar noon):
  - `avg_midday_kwh` (mean of daily `midday_kwh`)
  - `midday_to_daily_ratio` = `AVG(midday_kwh) / NULLIF(AVG(kwh_delivered),0)`
    (5 of 24 hours ⇒ ~0.21 baseline; PV pushes it toward 0)
  - `avg_min_hour_kwh` (mean daily floor; PV floors near zero midday)
  - `near_zero_midday_fraction` = fraction of days with
    `midday_kwh < 0.5` kWh (deep-suppression days)
- **Seasonal asymmetry** (opposite direction from EV): overall
  `summer_to_winter_ratio`, plus `summer_midday_to_daily_ratio` vs
  `winter_midday_to_daily_ratio` and their difference — insolation
  suppresses summer midday far more than winter; nothing else produces
  that split.
- Demographics (from `dim_customer`, all non-DER): `customer_class,
  income_band, household_size, peer_building_subtype, peer_sqft_band`
  **plus `tenure`** (own/rent — a real CIS attribute strongly
  correlated with rooftop-PV eligibility; column exists at
  `dim_customer.sql:32`).
- Label CTE: identical to EV's (`features.sql:112-124`) with
  `has_pv`: join `raw_der_customer` → `dim_customer` on
  `customer_number = d.customer_id`, `MAX(CAST(d.has_pv AS INT)) AS
  has_pv_label` (multi-site chains).

COMMENT framing: "…label from raw_der_customer.has_pv (proxy for the
interconnection register). Use case: flag consumption patterns
consistent with unregistered rooftop solar…"

### B3. `feature_spec.py`, `train.py`, `score.py`, `table_comments.py`

Line-for-line mirrors of the EV files with the rename map:

| ev_detector | pv_detector |
|---|---|
| `ml_ev_detection_features` | `ml_pv_detection_features` |
| `ml_ev_training_data` | `ml_pv_training_data` |
| `ml_ev_detector` (UC model) | `ml_pv_detector` |
| `ml_ev_detection_predictions` | `ml_pv_detection_predictions` |
| `has_ev_label` | `has_pv_label` |
| `ev_probability` / `ev_likely_flag` | `pv_probability` / `pv_likely_flag` |
| run_name `xgboost_ev_detector` | `xgboost_pv_detector` |

`feature_spec.py`: NUMERIC_FEATURES / CATEGORICAL_FEATURES lists match
B2 (add `tenure` to categoricals); keep `_safe_feature_name` verbatim.
Same xgboost/mlflow pin versions as the EV files. Same base-rate
threshold logic in score.py (PV base rate will be lower than EV's
~3.2% — the logic self-adjusts).

### B4. Wiring

- `resources/pipelines.yml` `ml_features` libraries: add
  `- file: { path: ../src/40_ml/pv_detector/features.sql }`.
- `resources/jobs.yml`: add `pv_detector_train` / `pv_detector_score`
  / `pv_detector_table_comments`, copied from the three
  `ev_detector_*` tasks (this copy-pattern is exactly what the jobs.yml
  40_ml header comment prescribes). `pv_detector_train` depends on
  `ml_build_features`.

---

## 4. Verification

1. `databricks bundle validate` then `deploy` (DEFAULT profile,
   target catalog/schema `timstanton_stable.customer_360`, warehouse
   `8c35ef80cbacd670` — see repo memory). Confirm no `nrel_*` vars and
   no `nsrdb_download` task in the deployed job.
2. Run the full job green. Weather download must FAIL the job if S3 is
   unreachable (no silent stub).
3. Re-verify FK constraints via `information_schema.table_constraints`
   after the run (SDP FK-attach race — repo memory: a fact not reading
   its FK's dim can silently drop the constraint; re-run fixes).
4. Physics spot-check on a `has_pv=true` premise:
   - July day: hourly `kwh_pv` peaks 12:00–14:00 displayed time
     (proves the LST convention), `kwh_received > 0` midday.
   - January day: `kwh_pv` well under half the July peak.
   - Annual: `SUM(kwh_pv) ≈ pv_system_kw_dc * 1150` per adopter.
   - **Displayed-2017 rows have non-zero `kwh_hp` and `kwh_pv`**
     (proves the source-clock join — a display-timestamp join would
     zero both for 2017 since weather only exists for source-2018).
5. `grep -rin "nrel\|nsrdb"` → remaining hits are attribution-only
   (docs credit lines) plus the OEDI S3 prefix constant
   (`nrel-pds-building-stock` — a bucket path, fine). Zero hits for
   `nrel_api_key`, `nrel_email`, `nrel_secret_scope`, `psm3`,
   `solar_available`, "optional" solar language.
6. PV detector: training run logs AUC in MLflow (expect high — the
   synthetic signature is strong); `ml_pv_detection_predictions`
   populated; `ml_pv_detection_features` contains no `kwh_pv` /
   `kwh_received` / `kwh_base` derived columns.
7. Post-run housekeeping (live workspace): drop the retired
   `raw_irradiance_hourly` table and the `landing_nsrdb` volume from
   the schema — the pipeline won't manage them anymore, and the FK/ERD
   surfaces shouldn't show orphans. Grant check: new `ml_pv_*` tables
   need app-SP SELECT only if the app ever reads them (it doesn't yet).

## 5. Known gotchas for the implementing session

- Pipeline globs only accept folders ending `/**` — the weather SQL
  goes in `src/10_ingest/weather/` and is added as an explicit
  `file:` entry in `ingest_data` (matching how the other 10_ingest SQL
  is wired; only 20_synthetic/30_curated use globs).
- `raw_load_profiles_tidy` only unpivots `out_electricity_*` columns
  (`raw_load_profiles_tidy.py:31`) — the PV channel IS in that set; no
  tidy-layer change needed.
- The `units_represented` weighting: `hourly_total_per_unit` divides
  by units to get per-unit load. The PV shape does NOT need that —
  it's normalized to sum-to-one, so absolute scaling drops out.
- Local app dev is unaffected (no app queries touch these tables), but
  if any app SQL is edited, remember the `{{catalog}}/{{schema}}`
  sed gotcha (repo memory).
- Curated pipeline runs with `full_refresh: true` — schema changes to
  `fact_meter_readings_daily` rebuild cleanly.
