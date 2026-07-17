# Design & Implementation: Drop the redundant `curated_` prefix from UC object names

**Status:** Ready to implement. Nothing built yet.
**Author handoff:** written for a fresh session to execute end-to-end.
**Date:** 2026-07-08

---

## 1. Goal & decision

The curated star schema currently carries a **double prefix** — `curated_dim_customer`,
`curated_fact_customer_billing`, `curated_metric_usage`. The word `curated_` is redundant
with the role token (`dim_`/`fact_`/`bridge_`/`metric_`) that follows it: no `raw_`, `ml_`,
or `app_` table ever uses those role tokens, so the role token alone already identifies a
table as curated.

**Decision (Option 1 from the naming discussion):** drop `curated_` and keep the role
prefix. `raw_` stays (raw tables have no role token, so the prefix earns its keep). This is
a pure rename — one catalog, one schema, no medallion schema split.

| Before | After |
|---|---|
| `curated_dim_customer` | `dim_customer` |
| `curated_fact_customer_billing` | `fact_customer_billing` |
| `curated_bridge_account_premise` | `bridge_account_premise` |
| `curated_metric_usage` | `metric_usage` |
| `raw_customer_billing` | `raw_customer_billing` *(unchanged)* |

We are **not** splitting into bronze/silver/gold schemas — that would violate the
deliberate "one schema this demo owns" constraint in `databricks.yml` and multiply the
grant surface. Tier stays a naming convention; medallion story (if wanted later) can live
in UC tags.

---

## 2. The rename rule (safe, scoped — NOT a blind `s/curated_//`)

A naive global replace of `curated_` → `` is **dangerous** and must not be used. Apply
exactly these six literal find/replace patterns (they only ever match real star-object
names):

```
curated_dim_                        →  dim_
curated_fact_                       →  fact_
curated_bridge_                     →  bridge_
curated_metric_                     →  metric_
curated_meter_installation          →  meter_installation
curated_peer_monthly_usage_benchmark →  peer_monthly_usage_benchmark
```

The last two are the only curated star tables without a role token; they get the bare
drop. Everything else is covered by the four role-prefix patterns.

### DO NOT TOUCH — these contain the substring `curated_` / `curated` but are not star-object names

| Token | What it is | Why it stays |
|---|---|---|
| `curated_schema` | SDP config **variable** (`${curated_schema}`, set in `resources/pipelines.yml:140` to `${var.catalog}.${var.schema}`) | Renaming it breaks every `${curated_schema}.<table>` reference. It's plumbing, invisible in UC. |
| `curated_buildings` | **Ingest-tier** MV (`src/10_ingest/buildings_curate/buildings.sql`), referenced in `resources/pipelines.yml:78` and `raw_premises.sql` comment | Not part of the star-schema double-prefix ugliness; it's a cleaned FEMA source in the ingest stage. Out of scope for this pass (see §7). |
| `src/30_curated/` directory | Pipeline tier folder | Filesystem/tier name, not a UC asset. |
| `pipe_curated`, `curated_table_comments`, `curated_metric_views` task keys; `_curated` pipeline name; `area: curated` tags | Job/pipeline/tag identifiers | Not UC object names. |
| the word "curated" in prose/comments describing the tier | Documentation | Keep — the tier concept is still called "curated". |

Because the six patterns never match `curated_schema`, `curated_buildings`, or
`30_curated`, they are safe to run mechanically. Still: review each diff hunk, don't
autopilot.

> Note: the SDP transformation **filenames** already have no `curated_` prefix
> (`src/30_curated/transformations/dim_customer.sql`, `fact_customer_billing.sql`, …).
> **No file renames are needed** — only the object names *inside* the files change
> (the `CREATE`, `REFERENCES`, `FROM`, and `JOIN` occurrences).

---

## 3. Complete object rename map

**Dimensions**
```
curated_dim_account            → dim_account
curated_dim_account_history    → dim_account_history      (kind: history)
curated_dim_account_scd2       → dim_account_scd2
curated_dim_agent              → dim_agent
curated_dim_customer           → dim_customer
curated_dim_customer_history   → dim_customer_history     (kind: history)
curated_dim_customer_scd2      → dim_customer_scd2
curated_dim_date               → dim_date
curated_dim_geography          → dim_geography
curated_dim_meter              → dim_meter
curated_dim_premise            → dim_premise
curated_dim_premise_h3         → dim_premise_h3
curated_dim_program            → dim_program
curated_dim_rate_schedule      → dim_rate_schedule
curated_dim_service_agreement  → dim_service_agreement
curated_dim_service_point      → dim_service_point
```

**Facts**
```
curated_fact_active_outage_customer_impact → fact_active_outage_customer_impact
curated_fact_active_outage_event           → fact_active_outage_event
curated_fact_assistance_enrollment         → fact_assistance_enrollment
curated_fact_csr_interactions              → fact_csr_interactions
curated_fact_customer_billing              → fact_customer_billing
curated_fact_customer_complaints           → fact_customer_complaints
curated_fact_customer_hourly_load_profile  → fact_customer_hourly_load_profile
curated_fact_der_adoption                  → fact_der_adoption
curated_fact_digital_engagement            → fact_digital_engagement
curated_fact_legacy_cx_snapshot            → fact_legacy_cx_snapshot
curated_fact_meter_readings_daily          → fact_meter_readings_daily
curated_fact_meter_readings_monthly        → fact_meter_readings_monthly
curated_fact_outage_customer_impact        → fact_outage_customer_impact
curated_fact_outage_events                 → fact_outage_events
curated_fact_payment_history               → fact_payment_history
curated_fact_program_enrollment            → fact_program_enrollment
curated_fact_service_event                 → fact_service_event
curated_fact_social_mentions               → fact_social_mentions
curated_fact_survey_responses              → fact_survey_responses
```

**Bridge / other star tables**
```
curated_bridge_account_premise         → bridge_account_premise
curated_meter_installation             → meter_installation
curated_peer_monthly_usage_benchmark   → peer_monthly_usage_benchmark
```

**Metric views** (semantic layer — renamed, but see §5: removed from the ERD)
```
curated_metric_usage           → metric_usage
curated_metric_complaints      → metric_complaints
curated_metric_reliability     → metric_reliability
curated_metric_nps             → metric_nps
curated_metric_fcr             → metric_fcr
curated_metric_dsm_uptake      → metric_dsm_uptake
curated_metric_tenure_at_premise → metric_tenure_at_premise
```

---

## 4. Affected artifacts (by category)

All counts are `curated_` occurrences per file at time of writing. Apply the §2 patterns to
every file below. Grouped by what kind of change it is.

### 4a. Pipeline SQL — defines & cross-references the objects (`src/30_curated/transformations/*.sql`)
Each `fact_*.sql` / `dim_*.sql` / `bridge_*.sql` / `meter_installation.sql` /
`peer_monthly_usage_benchmark.sql` file contains its own `CREATE OR REFRESH …`, its FK
`CONSTRAINT … REFERENCES curated_…`, and `FROM`/`JOIN ${curated_schema}.curated_…`
references. Rename all object occurrences; **leave `${curated_schema}` intact**.
High-touch files: `fact_customer_billing.sql` (8), `fact_meter_readings_daily.sql` (7),
`dim_customer_history.sql` (7), `dim_account_history.sql` (7), plus ~30 more.

### 4b. Pipeline metadata notebooks (`src/30_curated/`)
- `table_comments.py` (**114**) — `COMMENT ON TABLE curated_…` statements + comment bodies
  that name other curated tables. Largest single file; mechanical.
- `metric_views.py` (**74**) — the `METRIC_VIEWS` dict keys (`curated_metric_*` → `metric_*`)
  **and** each YAML `source:` that points at `curated_fact_*`/`curated_dim_*`.

### 4c. ML feature SQL (`src/40_ml/`)
- `complaint_predictor/features.sql` (13), `complaint_predictor/table_comments.py` (2)
- `ev_detector/features.sql` (4), `ev_detector/table_comments.py` (3)
These read curated facts/dims. `ml_*` output names are unaffected.

### 4d. Ingest-tier stragglers (a few `curated_` mentions in comments/sources)
- `src/20_synthetic/transformations/customer_master/raw_premises.sql` (1 — comment naming
  `curated_buildings`; **leave** per §2), `.../outages/raw_active_outage_customer_impact.sql`
  (1), `.../digital/raw_digital_event.sql` (1), `raw_portal_session.sql` (2).
  Inspect these — most are prose comments; only rename if they name a **star** object.

### 4e. App server plugins (`app/server/*.ts`)
- `geniePlugin.ts` (32), `focusPlugin.ts` (11), `dataModelPlugin.ts` (7 — **§5, design change**),
  `metricsPlugin.ts` (2), `dbx.ts` (1). These embed SQL / table-name constants.

### 4f. App query catalog (`app/config/queries/*.sql`) — ~30 files
Every `exec_*`, `customer_*`, `mkt_*`, `programs_list` query that reads the star. These use
`{{catalog}}.{{schema}}` template tokens; just rename the `curated_…` table tokens. (Recall
the local-dev sed gotcha for `{{catalog}}/{{schema}}` — unrelated, but don't commit those
substitutions.)

### 4g. App client (`app/client/src/`)
- `views/DataModelView.tsx` (5 — **§5, design change**)
- `views/MetricsCatalogView.tsx` (1 — metric-view name reference)
- `docs/star-schema.md` (8), `docs/tiers.md` (1) — client-facing prose; update names.

### 4h. Setup / ops
- `app/setup/01_create_genie_space.py` (**42**) — Genie space table list + sample-SQL /
  instructions that name curated tables. Mechanical but high-touch; the Genie space must be
  re-created/updated after (see §6).
- `app/setup/02_focus_set_setup.py` (1)
- `app/scripts/grant-permissions.sh` (2) — verify these are comments or schema-level grants;
  schema-level `SELECT`/`USE SCHEMA` grants are name-agnostic so **no new grants needed**
  for renamed tables (per the app-SP-grants note). `MODIFY` on `app_focus_set` is unaffected.

### 4i. Bundle config
- `resources/pipelines.yml` (5) — comments + `buildings_table: …curated_buildings`
  (**leave**) + `curated_schema: …` var (**leave**). Likely **no change** here beyond
  optional comment tidy.
- `resources/jobs.yml` (3) — task keys `pipe_curated` etc. (**leave**).
- `databricks.yml` (1) — the schema-var description string "All raw_/curated_/ml_/app_
  tables land here"; update prose to reflect new convention (optional).

### 4j. Docs (prose only — update names for accuracy)
`ARCHITECTURE.md` (6), `README.md` (1), `docs/left-nav-and-data-model-design.md` (37),
`docs/complaints-predictor-scoping.md` (15), `docs/temporal-realism-scoping.md` (2),
`docs/map-selection-and-focus-ux-design.md` (3). These are historical/design docs — update
opportunistically; not load-bearing for the deploy.

---

## 5. ERD page — the one place that needs *design*, not find/replace

The dynamic ERD (`app/server/dataModelPlugin.ts` + `app/client/src/views/DataModelView.tsx`)
selects and classifies tables **by the `curated_` prefix**. Dropping the prefix breaks it.
Three coordinated changes, plus the two UX cleanups you asked for.

### 5.1 Server: table selection (`dataModelPlugin.ts:132-179`)
Today: `const like = \`${prefix}%\`` and every `information_schema` query filters
`table_name LIKE '${like}'`. With `prefix = "curated_"` this now matches nothing.

**Change:** treat the curated star as a *layer* selected by its role prefixes, not one
string prefix. When the requested layer is curated, build the filter as:

```sql
(table_name LIKE 'dim_%' OR table_name LIKE 'fact_%' OR table_name LIKE 'bridge_%')
```

For `raw_` / `ml_` / `app_`, keep the existing single-prefix `LIKE`. Suggested contract:
accept a `layer` query param with values `curated | raw | ml | app` (map `curated` →
the three-way OR; the others → `'<layer>_%'`). Keep `PREFIX_RE`-style validation (allowlist
the four literal values rather than interpolating arbitrary input — these strings go into
SQL).

This selection **naturally excludes** `metric_*` views (satisfying "remove metric views
from the ERD") and internal SDP tables (`__materialization*`, `event_log*`), and the two
orphan tables `meter_installation` / `peer_monthly_usage_benchmark` (which were already
hidden-by-default "other").

### 5.2 Server: `tableKind()` (`dataModelPlugin.ts:71-78`)
Drop `curated_` from every branch:
```ts
function tableKind(name: string): TableKind {
  if (/^dim_.+_history$/.test(name)) return "history";
  if (name.startsWith("dim_")) return "dim";
  if (name.startsWith("fact_")) return "fact";
  if (name.startsWith("bridge_")) return "bridge";
  return "other";
}
```
The `metric` branch can be removed (metric views are no longer selected). `history` must be
tested **before** `dim` (order preserved).

### 5.3 Frontend: layer selector (`DataModelView.tsx`)
- `PREFIX_OPTIONS` (line 53) / the `<select>` (lines 246-251): replace the raw prefix strings
  with labeled layers, e.g. `Curated star` / `Raw` / `ML` / `App`, sending
  `layer=curated|raw|ml|app`. Default to `curated`.
- `useState("curated_")` (line 152) → default `"curated"`.
- `visibleTables` gate (line 196): `erd.prefix !== "curated_"` → compare against the new
  `curated` value (rename the response field `prefix` → `layer` for clarity, or keep
  `prefix` carrying the layer token — pick one and keep server/client consistent).

### 5.4 UX cleanup #1 — remove the redundant kind badge (your ask)
After the rename, a node named `dim_customer` **and** a badge reading `dim` is pure
duplication. Remove the visible badge:
- Delete `<span className="erd-node-kind">{table.kind}</span>` (`DataModelView.tsx:113`).
- **Keep** `table.kind` in the data model — it still drives the node color class
  `erd-node-${table.kind}` (line 108). Only the text label goes.
- Optional: drop the now-unused `.erd-node-kind` rule in `App.css`.

### 5.5 UX cleanup #2 — remove metric views from the ERD (your ask)
- Remove the **"Metric views"** toggle (`DataModelView.tsx:260-262`), the `showMetrics`
  state (155), and the `t.kind === "metric"` branch in `visibleTables` (200). Metric views
  are already excluded by the §5.1 selection, so this is just removing dead UI.
- The **"Other"** toggle (`showOther`, lines 257-259, 199) also becomes dead under
  role-prefix selection (nothing classifies as "other" within dim/fact/bridge). Recommend
  removing it too for a cleaner toolbar. Keep the **"SCD2 history"** toggle — `dim_*_history`
  tables still exist and are still classified `history`.

### 5.6 Header comment
Update the file-top comment in both files that says the ERD is "scoped to a
naming-convention prefix (default `curated_`)" to describe the new layer selection.

---

## 6. Deploy / migration & verification

This renames SDP-managed materialized views & streaming tables. SDP will **create** the new
`dim_*`/`fact_*`/… objects but will **not drop** the old `curated_*` ones — they orphan.
Order:

1. **Land all code changes** (§2–§5) on a branch.
2. **Redeploy the bundle** and **run the pipeline job** (rebuilds the curated pipeline →
   creates the new-named objects; runs `table_comments.py` + `metric_views.py`).
   Deploy target per project setup: `timstanton_stable.customer_360` via the DEFAULT profile
   / warehouse `8c35ef80cbacd670`.
3. **Drop the orphaned `curated_*` objects.** Generate the drop list from the §3 map, e.g.:
   ```sql
   -- for each old name:
   DROP MATERIALIZED VIEW IF EXISTS timstanton_stable.customer_360.curated_dim_customer;
   -- (STREAMING TABLE for the two _scd2 objects; VIEW for the metric views)
   ```
   Confirm nothing else references the old names first (`information_schema` / lineage).
4. **Re-verify FK constraints** via `information_schema.referential_constraints` /
   `table_constraints`. Per the known SDP FK-DAG race, a fact that refreshes before its dim
   can silently drop its declared constraint — if any are missing, re-run the pipeline and
   re-check. The ERD's solid-vs-dashed edges are a good visual smoke test here.
5. **Re-create / update the Genie space** from `01_create_genie_space.py` so it points at
   the new names (old table refs will 404 in Genie otherwise).
6. **Rebuild + redeploy the app** (client bundle picks up `DataModelView.tsx`;
   server picks up `dataModelPlugin.ts` and the renamed query catalog). App SP grants are
   schema-level, so **no new grants** are required for the renamed tables.
7. **Manual smoke test in the browser** (tsc won't catch a stale table name in a `.sql`
   string): load the ERD (curated layer renders dim/fact/bridge, no metric views, no kind
   badge), the exec map, a customer drawer, the metrics catalog, and run a Genie question.

### Verification checklist
- [ ] `grep -rn 'curated_\(dim\|fact\|bridge\|metric\)\|curated_meter_installation\|curated_peer' src app` returns **zero** hits (outside this doc).
- [ ] `${curated_schema}` still present and intact in `src/30_curated/transformations/*.sql`.
- [ ] `curated_buildings` still present in ingest tier and `pipelines.yml:78`.
- [ ] No orphaned `curated_*` objects remain in the schema.
- [ ] FK constraints all present in `information_schema`.
- [ ] ERD renders; kind badge gone; metric views absent; SCD2-history toggle works.

---

## 7. Out of scope / optional follow-ups

- **`curated_buildings`** (ingest tier). Naming-inconsistent (a "curated" table living in
  `10_ingest`), but not part of the star-schema double-prefix problem. Leave it this pass.
  Follow-up options if you want consistency: rename to `buildings` or `ingest_buildings`
  (touches `pipelines.yml:78`, `buildings.sql`, `04_test_quality.py`, `raw_premises.sql`
  comment).
- **`curated_schema` SDP variable.** Could be renamed to something like `star_ns` for
  clarity, but it's internal plumbing and invisible in UC — not worth the churn/risk now.
- **UC tags for medallion story.** If you later want the bronze/silver/gold narrative
  without a schema split, add a `layer` UC tag per object (you already run a tag pass in
  `metric_views.py` / `table_comments.py`). Separate effort.
- **Metric views in the ERD.** Removed "for now" per this doc. If re-added later, restore
  §5.5 as a dedicated, opt-in "semantic layer" overlay rather than mixing into the star.

---

## 8. Kill the dashed lines — declare every relationship as a UC FK

**Goal:** every edge in the ERD is a **declared** `FOREIGN KEY` constraint (solid), so
`edgesAreInferred` is `false`, the inference banner disappears, and the `COLUMN_ALIAS` /
convention-guessing code in `dataModelPlugin.ts` can eventually be retired.

Independent of the rename (§2–§7) but touches the same SQL files, so do it in the same pass.
Object names below use the **post-rename** convention (`dim_*`, `fact_*`).

### 8.1 Why the dashed lines exist (three root causes)

An edge is drawn **solid** only when the server reads it from
`information_schema.referential_constraints` (a declared FK). Everything else is a
convention guess (dashed), and some relationships don't render at all. Current reality:

1. **Almost nothing declares FKs.** Only **3** of ~36 curated tables declare any:
   `fact_customer_billing`, `fact_meter_readings_daily`, `bridge_account_premise`. Every
   other relationship is convention-inferred → dashed.
2. **13 facts are `SELECT`-inferred** (no typed-column DDL), so there is *no syntactic place*
   to attach a `CONSTRAINT`. These must be **converted to typed-column DDL** before any FK can
   be declared — the bulk of the effort.
3. **`dim_premise` has no PK** — this was believed to be an unfixable `GEOMETRY`/typed-DDL
   incompatibility. **It is fixable (verified empirically — see §8.6).** The real cause was
   using the bare `GEOMETRY` type name (= `GEOMETRY(ANY)`, which cannot be persisted);
   declaring the columns with an explicit SRID (`GEOMETRY(0)`, matching the current stored
   `geometry(0)`) in a full typed column list lets `dim_premise` declare
   `premise_id BIGINT NOT NULL PRIMARY KEY`. Until that lands, a FK can only point at a table
   with a declared PK, so no `premise_id` relationship can be declared — and the server's
   dashed-edge inference also needs a single-column PK on the parent, so `premise_id` edges
   currently don't render **at all**, not even dashed. `dim_geography` is the same
   (select-inferred, no real PK) but nothing references it, so it's a non-issue.

### 8.2 Valid FK targets today (parents with a declared PK)

```
dim_account(account_id)                 dim_service_agreement(service_agreement_id)
dim_customer(customer_id)               dim_service_point(service_point_id)
dim_date(date_key)                      dim_meter(meter_id)
dim_agent(agent_id)                     dim_premise_h3(premise_id)   ← the ONLY keyed premise table
dim_program(program_id)                 meter_installation(meter_installation_id)
dim_rate_schedule(rate_schedule_id)     bridge_account_premise(account_premise_link_id)
dim_account_history(account_sk)         dim_customer_history(customer_sk)
fact_service_event(service_event_id)
```
**No PK today:** `dim_premise` (fixable — §8.6, gets `premise_id` PK), `dim_geography`
(unreferenced, leave).

### 8.3 Three tiers of work

**Tier A — cheap: child is already typed-DDL + parent has a PK → just add `CONSTRAINT` lines.**
Follow the exact pattern already in `fact_customer_billing.sql:10-15`
(`CONSTRAINT fk_… FOREIGN KEY (col) REFERENCES dim_… (pk) NOT ENFORCED RELY`). Verified
FK-shaped columns whose parent is keyed:

| File (typed-DDL) | Add FK on → target |
|---|---|
| `dim_account` | `customer_id` → `dim_customer`; `parent_account_id` → `dim_account` (self) — **do NOT add this one, see 8.4** |
| `dim_customer_history` | `customer_id` → `dim_customer` |
| `dim_account_history` | `customer_id` → `dim_customer` (also `account_id` → `dim_account`) |
| `dim_meter` | `service_point_id` → `dim_service_point` |
| `dim_service_agreement` | `account_id` → `dim_account`; `customer_id` → `dim_customer`; `service_point_id` → `dim_service_point` |
| `fact_service_event` | `account_id`, `customer_id`, `service_point_id`, `service_agreement_id`, `meter_id` → matching dims |
| `meter_installation` | `meter_id` → `dim_meter`; `service_point_id` → `dim_service_point`; `to_meter_id` → `dim_meter` |
| `fact_customer_complaints` | typed-DDL; **audit its key columns** and add FKs to keyed dims |
| `fact_customer_hourly_load_profile` | same — audit columns, add FKs |
| `fact_meter_readings_monthly` | same — audit columns, add FKs |
| `peer_monthly_usage_benchmark` | typed-DDL (no PK of its own); add FKs to whatever keyed dims its columns reference |

> In every row above, any `premise_id` column is **deferred to Tier C** — it can't be
> declared until premise gets a PK (or you point it at `dim_premise_h3`; see 8.3-C).

**Tier B — larger: child is `SELECT`-inferred → convert to typed-column DDL, then add FKs.**
Thirteen files. Each needs its `SELECT` output columns written out as an explicit typed
column list in the `CREATE OR REFRESH MATERIALIZED VIEW <name> ( … )` header (matching the
types the `SELECT` actually produces — mismatches will fail the refresh), then FK constraints
added. Files: `fact_active_outage_customer_impact`, `fact_active_outage_event`,
`fact_assistance_enrollment`, `fact_csr_interactions`, `fact_der_adoption`,
`fact_digital_engagement`, `fact_legacy_cx_snapshot`, `fact_outage_customer_impact`,
`fact_outage_events`, `fact_payment_history`, `fact_program_enrollment`,
`fact_social_mentions`, `fact_survey_responses`. This is most of the effort — budget it as
the real cost of "all relationships in UC."

**Tier C — the premise blocker (SOLVED; see §8.6 for the empirical proof).** Give
`dim_premise` a typed column list with the two geometry columns declared as `GEOMETRY(0)`
(explicit SRID — **not** bare `GEOMETRY`) and `premise_id BIGINT NOT NULL PRIMARY KEY`. The
MV refreshes and the PK registers in `information_schema` — verified on the target serverless
warehouse, current channel, no PREVIEW needed. Once this lands, every `premise_id` FK across
Tiers A and B becomes declarable, pointing at `dim_premise` (no split, no re-pointing at
`dim_premise_h3`).

Concrete change to `dim_premise.sql`: convert the `CREATE OR REFRESH MATERIALIZED VIEW
dim_premise AS SELECT …` to a typed column list. The exact 22-column schema is in the live
`DESCRIBE` (all `STRING`/`INT`/`DOUBLE`/`TIMESTAMP` as today, with
`centroid_point GEOMETRY(0)` and `footprint_polygon GEOMETRY(0)`), with
`premise_id BIGINT NOT NULL PRIMARY KEY`. Keep the `AS SELECT` body unchanged.

Watch-outs:
- **SRID must match the data.** The columns are stored as `geometry(0)` today, so declare
  `GEOMETRY(0)`. A typed `GEOMETRY(0)` column rejects rows with a different SRID — if the
  `SELECT` is ever changed to emit `GEOMETRY(4326)` (e.g. via `ST_SetSRID(…,4326)`), change
  the DDL type to match.
- **All columns must be typed** (pipelines grammar allows no partial spec), so this is a
  full-schema declaration, not a one-line PK add. Types must match what the `SELECT`
  produces or the refresh fails.
- The other documented geometry limitation still holds but doesn't apply here: `GEOMETRY`
  can't be a GROUP BY key / metric-view dimension. `dim_premise` is a passthrough dim (no
  aggregation), so it's fine.

### 8.4 Cross-cutting risks (read before mass-declaring FKs)

- **`RELY` + orphan rows = wrong results.** `NOT ENFORCED RELY` tells the optimizer to *trust*
  the FK for join elimination etc. If the synthetic data has any orphan (a fact
  `customer_id` with no matching `dim_customer` row), RELY can silently produce **wrong query
  results**. Before declaring RELY, validate zero orphans per relationship (anti-join count),
  or declare `NOT ENFORCED` **without** `RELY`. The ERD reads the constraint either way, so
  for the dashed-line goal, `NOT ENFORCED` (no RELY) is the safe default; add RELY only where
  you've proven referential integrity.
- **The SDP FK-DAG race** (see the `fk-constraint-dag-race` note). SDP orders refreshes by
  *data lineage*, not declared FKs. If you declare a FK on a fact that does **not** read its
  parent dim in its `SELECT`, the fact can refresh before the dim and SDP **silently drops the
  constraint**. After the rollout, **re-verify every constraint** via
  `information_schema.referential_constraints`; re-run the pipeline if any are missing. The ERD
  itself is a good smoke test — a relationship you declared that's still dashed = a dropped
  constraint.
- **Post-rename ordering.** Do the §2 rename first (or together), so FK `REFERENCES` targets
  use the new `dim_*` names, not `curated_dim_*`.
- **No self-referencing FKs on materialized views (verified 2026-07-08).** Declaring
  `dim_account.parent_account_id REFERENCES dim_account (account_id)` — a self-loop, not a
  cross-table edge — makes SDP throw `TABLE_MATERIALIZATION_CYCLIC_FOREIGN_KEY_DEPENDENCY`
  and fail the whole `pipe_curated` flow, even with `NOT ENFORCED RELY`. Confirmed
  reproducible across 6 consecutive full-refresh attempts. Unlike the FK-DAG race (which only
  drops the one constraint), this is a hard pipeline failure. Fix: don't declare a FK on any
  column that references its own table's PK; keep the plain column (still queryable/joinable,
  just not a formal constraint — that edge stays dashed in the ERD, which is correct given the
  engine can't materialize it as a constraint anyway).

### 8.5 Suggested sequencing
1. Land Tier A (biggest visual win for least effort — most core-star edges go solid).
2. Land Tier C (give `dim_premise` a typed schema + PK per §8.3/§8.6), then add `premise_id`
   FKs everywhere they were deferred in Tiers A/B.
3. Grind through Tier B (convert + declare), a few files at a time, re-verifying constraints
   after each pipeline run (FK-DAG race).
4. When `edgesAreInferred` is reliably `false`, simplify `dataModelPlugin.ts`: drop the
   convention-inference branch and `COLUMN_ALIAS`, and remove the inference banner from
   `DataModelView.tsx`. (Optional final cleanup — leave the inference code until then as a
   safety net for any straggler.)

### 8.6 Empirical proof for the premise/GEOMETRY fix (run 2026-07-08)

Tested on the target serverless warehouse (`8c35ef80cbacd670`, `timstanton_stable`, current
channel), throwaway objects dropped after:

- **Bare `GEOMETRY` in a typed column list → fails**, both for an MV and a plain table:
  `[UNSUPPORTED_DATATYPE] Unsupported data type "GEOMETRY". SQLSTATE: 0A000`. Bare `GEOMETRY`
  resolves to `GEOMETRY(ANY)`, which per the docs "cannot be persisted." This is the "gotcha"
  the old `dim_premise.sql` comment ran into.
- **`DESCRIBE curated_dim_premise`** shows the geometry columns are already stored as
  `geometry(0)` — created via `SELECT` inference (`ST_GeomFromWKT`/`ST_Point` results). So
  GEOMETRY values persist fine in an MV; only the *bare type name in DDL* was the problem.
- **Explicit SRID (`GEOMETRY(0)`) in a typed column list, with a PK → succeeds:**
  ```sql
  CREATE OR REPLACE MATERIALIZED VIEW …_zz_geo_pk_test (
    id BIGINT NOT NULL PRIMARY KEY,
    centroid_point GEOMETRY(0),
    footprint_polygon GEOMETRY(0)
  ) AS SELECT CAST(1 AS BIGINT) AS id,
             ST_GeomFromWKT('POINT(0 0)') AS centroid_point,
             ST_GeomFromWKT('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))') AS footprint_polygon;
  ```
  The MV created, and `information_schema.table_constraints` reported
  `PRIMARY KEY  _zz_geo_pk_test_pk`. **No PREVIEW channel required.**

Conclusion: the third root cause is a fixable DDL detail (explicit SRID), not a platform
limitation. It does **not** need a preview channel, a runtime bump, a table split, or
re-pointing FKs at `dim_premise_h3`.

Docs consulted: [GEOMETRY type](https://docs.databricks.com/aws/en/sql/language-manual/data-types/geometry-type),
[CREATE MATERIALIZED VIEW (pipelines)](https://docs.databricks.com/aws/en/ldp/developer/ldp-sql-ref-create-materialized-view),
[spatial pipelines tutorial](https://docs.databricks.com/aws/en/ldp/tutorial-spatial-pipelines).

### 8.7 Can we avoid writing the full typed column list? (verified 2026-07-08)

Short answer: **not via SQL on a materialized view.** For MVs, PK/FK constraints can only be
declared inline in `CREATE`, and the column list must be complete. Empirically confirmed on
the target warehouse:

- **Partial column list → rejected.** Declaring only the key column and letting the rest
  infer fails: *"user-specified schema … is incompatible with the schema inferred from its
  query"* (declared `{id}` vs inferred `{id, name}`). The typed list must enumerate **every**
  output column.
- **No `ALTER` path for MV constraints.** `ALTER MATERIALIZED VIEW … ADD CONSTRAINT …` is a
  parse error (unsupported). `ALTER MATERIALIZED VIEW … ALTER COLUMN … SET NOT NULL` is
  explicitly unsupported. `ALTER TABLE …` refuses ("expects a table but … is a view"). So you
  cannot add PK/FK to an MV after creation, the way `table_comments.py` adds comments.

So on the current MV-based architecture, a PK or FK **requires** the full typed schema on that
table. What teams do to make that bearable, in rough order of fit here:

1. **Code-generate the typed DDL from the inferred schema (recommended).** The `AS SELECT`
   already fixes the schema — don't hand-maintain it. One-time scaffold: create each table
   SELECT-inferred (as today), then read `information_schema.columns` and emit the
   `CREATE … (typed cols)` block; paste it back into the `.sql` and add the handful of
   constraint lines. The only thing authored by hand is the small **constraint spec** (which
   column is the PK, which columns are FKs and to where) — the wide type list is generated.
   This repo already has the muscle for it (`metric_views.py` templates view DDL from a dict;
   `table_comments.py` walks `information_schema`). Consider a tiny `scaffold_typed_ddl.py`
   helper. Note the `GEOMETRY(0)` caveat from §8.6 when generating (introspection reports
   `geometry(0)` — emit that, not bare `GEOMETRY`).
2. **Constrain only the tables that matter.** PK/FK give the optimizer (RELY) and the ERD
   value on the **conformed dims + high-traffic facts** — not on every peripheral fact. Typing
   ~10 core tables is a bounded task; leave the long tail SELECT-inferred and accept a few
   dashed/absent edges. This is the pragmatic 80/20 and pairs well with (1).
3. **Plain Delta tables + `ALTER … ADD CONSTRAINT` (the classic route).** Regular managed
   Delta tables **do** support post-load `ALTER TABLE ADD CONSTRAINT` and `SET NOT NULL` — you
   name only the key columns, no full list. Many "classic" dimensional teams on Databricks
   build dims/facts as plain tables (MERGE/INSERT in a task) plus a governance step that adds
   PK/FK. Cost: you give up MV incremental/declarative refresh and own the load logic. Only
   worth it if you're already fighting MV refresh semantics — a bigger architectural change
   than this whole doc otherwise implies.

Recommendation: **(1) + (2)** — generate the typed schema for the ~10 core tables you want
solid, keep the constraint spec small and hand-authored, and don't chase 100% coverage.
