# Customer 360 for Utilities — Architecture

This document describes how the repo is built: one Databricks Asset Bundle that
deploys into **one catalog and one schema**, orchestrated by **one Job**, from
external-data ingest through synthetic generation, a curated star schema, ML, and
an interactive map app. The [boundary-spine redesign](#10-roadmap) at the end is a
planned enhancement, clearly marked as such; everything before it describes what
ships today.

## 1. Design goals

- **Self-contained** — reproduces the entire pipeline (external ingest → synthetic
  generation → curated star schema → ML + app) with no external dependencies
  beyond public open-data sources.
- **Single catalog + single schema** — every Unity Catalog object lands in one
  schema, tier-encoded in the table-name prefix.
- **One orchestrating Job** — all SDP pipelines and notebooks run as tasks of
  `customer_360_job`.
- **A polished demo *and* a clone-and-extend foundation** — deploys an impressive
  seeded demo out of the box (`customer_sample_size` defaults to 1,000 premises,
  but is a deploy-time var, not a fixed scale), and is modular so a customer team
  can extend or contract it based on their own data availability.

## 2. Repo layout

`src/` is organized by tier for readability, even though every table lands in the
one schema:

```
src/
  10_ingest/     External open data → UC volumes → raw_* tables:
                 fema_buildings, tiger_counties, weather, load_shapes.
  20_synthetic/  transformations/ = 13 generator modules → raw_* tables (globbed
                 by the pipeline); change_feeds.py (a Job notebook) at the root.
  30_curated/    transformations/ = the dimensional (star) model → dim_* /
                 fact_* / bridge_* (globbed); table_comments.py +
                 metric_views.py (Job notebooks) at the root.
  40_ml/         One folder per model (e.g. ev_detector/) → ml_* tables.
app/             AppKit map app (client + server) + Genie/focus-set setup jobs.
resources/       Bundle resource definitions (jobs.yml, pipelines.yml, app.yml).
shared/          Shared bundle config (compute_defaults.yml).
```

Job task DAG: `10_ingest` (downloads, parallel) → `ingest_counties`/`ingest_data`
(SDP) → `synthetic` (SDP) → `change_feeds` → `curated` (SDP) → metric views →
`ml_features` (SDP) → per-model train → score. App-setup jobs (Genie space, focus
set) live in `resources/app.yml` and run separately after the app is deployed.

## 3. Naming in a single schema

Tier is encoded in the **table-name prefix** (not the schema name), so every
table's tier is obvious from its name and the flat UC table list stays legible:
`raw_*`, the curated star (`dim_*` / `fact_*` / `bridge_*` / `metric_*` — the
role token alone identifies it as curated, so there's no separate `curated_`
prefix), `ml_*`, `app_*`. For what each tier actually holds and why, see the
in-app **Documentation → Tiers** page (demo-facing) — this doc stays at the
naming-convention mechanics.

Raw external downloads land in a **UC Volume** first, then SDP materializes them
into `raw_*` tables ("raw as files; SDP once it's in UC").

## 4. Pipelines & the two-layer substitution pattern

Five SDP pipelines all publish into the one schema, wired together by the Job:
`ingest_counties`, `ingest_data`, `synthetic`, `curated`, `ml_features`. The
`synthetic` and `curated` pipelines pick up their SQL with `libraries.glob`
over a `transformations/**` folder (following the Databricks convention: a glob
entry is a folder path ending in `/**`, so the folder must hold only pipeline
source — Job notebooks live outside it at the tier root). Adding or removing a
table is then a matter of dropping or deleting a `.sql` file in
`transformations/` — no pipeline edit. SDP resolves the intra-pipeline DAG from
the fully-qualified table references, so file order is irrelevant.
(`ml_features` lists each model's `features.sql` explicitly — one line per
model — because that file lives beside the model's Job notebooks; see §8.)

No SQL hardcodes a schema-qualified table name; every cross-source reference goes
through a variable. This uses **two substitution layers that share the `${...}`
syntax but resolve differently**:

- **`${var.X}` = DAB substitution** — resolved at deploy time, only in
  `databricks.yml` / `resources/*.yml`.
- **`${X}` inside a `.sql` file = SDP config substitution** — resolved at pipeline
  runtime from the pipeline's `configuration:` block (a Spark conf).

Worked example — the curated meter-readings fact reading the AMI source:

```yaml
# resources/pipelines.yml — the SDP config wires the key to the one schema
configuration:
  ami_schema: ${var.catalog}.${var.schema}
```
```sql
-- src/30_curated/fact_meter_readings_daily.sql references the config key
FROM ${ami_schema}.raw_meter_readings
```

At runtime `${var.catalog}.${var.schema}` resolves (DAB) to e.g.
`main.customer_360`, and `${ami_schema}` in the SQL resolves (SDP) so the `FROM`
becomes `main.customer_360.raw_meter_readings`. This indirection is what makes the
demo portable across environments and is the BYO-data seam (§6).

## 5. The curated star schema

A normalized dimensional model with durable `xxhash64` BIGINT surrogate keys
(`*_id`) alongside the natural keys (`*_number`). For the conceptual walkthrough
(dims/facts/bridges, SCD2 history, metric views) and the live interactive
diagram, see the in-app **Documentation → The Curated Star Schema** page and the
**Data Model** view — this doc stays at what's mechanically distinctive:
governed metric views are defined in `30_curated/metric_views.py`; adding one is
a single entry in the `METRIC_VIEWS` dict. They're real consumers, not just
governance scaffolding: Genie prefers them for aggregate/KPI questions (`app/setup/01_create_genie_space.py`),
and the CSAT, marketing-program, and DSM-enrollment app queries
(`app/config/queries/csat_*.sql`, `mkt_program_kpis.sql`,
`mkt_enrollment_monthly.sql`) read `metric_csat`/`metric_nps`/`metric_fcr`/
`metric_customer_base`/`metric_dsm_uptake` directly (the map/drawer/search/cohort
surfaces deliberately stay on the star schema). The demo's "now" is a deploy-time var,
`as_of_date` (defaults to `2018-12-31`); all as-of / effective-dating anchors to
that date.

## 6. The raw→curated contract (BYO-data seam)

The seam where a real utility swaps synthetic generation for their own data. Each
curated source is reached through a `*_schema` SDP config key (all defaulting to
the one schema). A BYO-data team replaces the synthetic `raw_*` tables for a source
with their own tables of the same shape; the curated star schema, ML, and app run
unchanged. The published contract is the set of columns/types/keys the curated
layer reads via each `${x_schema}.raw_*` reference. A team that already has a
governed dimensional layer can instead target the deeper seam — populate the
curated star directly and drop the synthetic + curated transformations — see
`docs/curated-layer-contract.md` for that table-by-table contract.

## 7. Source capability matrix (extend/contract with data availability)

Each source is a module; a deployment can drop the ones it lacks (curated facts are
one-file-per-source, so removing a source is deleting its generator and the facts
that read it).

| Source | Feeds | If absent |
|---|---|---|
| `fema_buildings` → `curated_buildings` | premise anchor + geometry | **Core** — the premise spine; hard to remove without stubbing synthetic geometry. |
| `tiger_counties` | county boundaries / geography | **Core** — required for geography + county scoping. |
| `weather` (EULP AMY2018) | AMI heat-pump adder + PV generation shape | **Required** — keyless OEDI S3 download; skip → HP/PV DER features degrade. |
| `load_shapes` (ResStock/ComStock) | AMI load profiles | **Optional** — without it AMI falls back to simpler synthetic load; realism drops. |
| 13 synthetic generators | all curated facts/dims | **Replaceable** — the BYO-data seam (§6). |

One structural caveat: `dim_customer` bakes disclosed behavioural signals
from several optional upstreams (billing, outages, complaints, digital, DSM, legacy
CX) as CTE joins. Dropping one of those sources means removing its CTE + column +
join from that one file, rather than deleting a standalone file — it is the least
modular object in the layer.

## 8. Machine learning

`40_ml/` holds one folder per model. `ev_detector/` (EV detection from AMI patterns)
is the reference model:

```
40_ml/ev_detector/
  features.sql       SDP materialized view of per-customer features
  feature_spec.py    the model's feature list + name-sanitizer (single source of truth)
  train.py           trains XGBoost, registers to UC, promotes @champion
  score.py           scores all customers → ml_*_predictions
  table_comments.py  table/column comments + UC tags
```

`train.py` and `score.py` both `%run ./feature_spec`, so their feature sets can
never drift. A model's `features.sql` lives beside its Job notebooks, so it
can't share a `transformations/**` glob; instead the `ml_features` pipeline
lists each model's `features.sql` explicitly (one line). **To add a model:** drop
a new `40_ml/<model>/` folder, add its `features.sql` line to `pipelines.yml`,
and copy the four ML task definitions in `jobs.yml`, renaming the task keys and
notebook paths (the pattern is documented inline in both files).

## 9. Deployment

- **DABs only, serverless only, one Job** orchestrates the data + ML pipeline.
- **App deployment is standard `databricks bundle deploy`** with
  `source_code_path: app/deploy/`. `app/deploy/` is a build artifact (produced by
  `npm run build`), gitignored, and force-included into the sync via
  `sync.include`.
- **Staging pattern** (`app/scripts/stage-deploy.sh`): build locally, then stage
  `app/deploy/` with a slim `node_modules` (tsdown inlines the rest) so the Apps
  runtime never runs `npm install`.
- **Service-principal grants:** the app runs as an SP that does not inherit user
  grants — run `app/scripts/grant-permissions.sh` after the first deploy, or SQL
  queries fail with `[INSUFFICIENT_PERMISSIONS] USE SCHEMA`.
- **Catalog / schema are injected at runtime** — the app's `config/queries/*.sql`
  carry `{{catalog}}`/`{{schema}}` tokens that the app.yml launch command
  substitutes at container start, so one build deploys to any environment.

## 10. Roadmap

### Boundary spine (planned)

Geographic scope is currently set by several independent knobs kept mutually
consistent by hand: `states_filter` (FEMA, state names), `state_fips` (TIGER),
`target_geoids` (premise county prefilter; also scopes the weather/buildings
downloads), and `target_state`
(load_shapes / weather). The planned redesign collapses these into **one boundary spec**
resolved by a first Job task against national TIGER counties, producing every
downstream selector plus an authoritative `boundary_polygon`. Coarse
state/point-granular filtering at download time keeps a public demo from pulling
continental-US volumes; an exact `ST_INTERSECTS` clip in the curated layer then
scopes silver/gold for free. Boundary (**where**) and sample size (**how many**)
stay orthogonal, so a user can run "a small sample in a bounding box" or "everyone
in a service territory".

### Geospatial types

The curated layer uses native `GEOMETRY`/`GEOGRAPHY` internally, with WKT/WKB/GeoJSON
only at I/O edges. Note the **SDP GEOMETRY-DDL gotcha**: never declare a
`GEOMETRY`/`GEOGRAPHY` column in a typed-column MV DDL — infer it from the `SELECT`
instead (`dim_premise` does this, which is why it declares no typed PK).

## 11. Modularity: where the extension points are

Every layer of this repo is built to be added to or subtracted from without
touching the layers around it. Most of these are described in depth where
they're introduced above — this section is the index. Two (business functions
in the left nav, executive-map layers) aren't documented anywhere else, so
they're covered here in full.

| Want to... | Extension point |
|---|---|
| Add/remove a raw data source | swap the `*_schema` config key; add/remove the matching synthetic generator (§6, §7) |
| Add/remove a curated table | drop or delete a `.sql` file in `transformations/` (§4) |
| Add a governed metric | one entry in the `METRIC_VIEWS` dict, `30_curated/metric_views.py` (§5) |
| Add an ML model | new `40_ml/<model>/` folder, one line in `pipelines.yml`, copy the four tasks in `jobs.yml` (§8) |
| Add/remove a left-nav view | one entry in `NAV_ITEMS`, `app/client/src/nav/navConfig.ts` (below) |
| Add/remove an executive-map layer | one entry in `LAYERS`, `app/client/src/mapConstants.ts` (below) |

### Business Functions (left nav)

The left nav (`app/client/src/nav/navConfig.ts`) is a single declarative
`NAV_ITEMS` array — `NavRail` and `App.tsx` just iterate it; nothing is
hardcoded per-item. Each entry has a `group`: `top` (rail label **Insights** —
the live analytical surfaces: Explorer, CSAT) or `reference`
(docs/data-model/metrics pages). Standing up a new view is one object in this
array plus its view; retiring one is deleting the entry.

The four **Business Functions** a utility actually organizes around — Customer
Service, Outages & Reliability, Revenue & Collections, EE & DER Programs — were
carried for a while as placeholder nav cards, then retired to keep the rail to
what's genuinely live. Their "what this could grow into" story now lives in the
in-app **Documentation** (application-architecture topic) rather than as dead
nav items.

### Executive map layers

The map's layer picker (`app/client/src/mapConstants.ts`) is driven by a
`LAYERS: LayerSpec[]` array — each entry declares its id/label, whether it's a
numeric gradient or a categorical palette, which GeoJSON property it colors
by, and how individual customer dots render for it. Adding a layer (e.g. a new
risk score a utility wants surfaced) is one entry in this array plus the query
field it reads; removing one is deleting the entry. The zoom-tiered rendering
(hexagon choropleth fading into customer dots) and color-scale machinery are
shared infrastructure underneath every layer, so a new layer gets that behavior
for free.

## Data sources & attributions

Canonical list (licensing) is in `README.md`; the demo-facing "where the data
comes from" narrative is the in-app **Documentation → Data Sources** page.
