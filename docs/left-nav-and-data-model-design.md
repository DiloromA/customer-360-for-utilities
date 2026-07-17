# Design: Left Navigation Rail + Dynamic Data-Model (ERD) view

**Status:** Phase 1 + Phase 2 shipped (2026-07-06) · Phase 0 + Phase 3 open — see §12.
**Author:** design pass (Claude) with Tim Stanton
**Scope:** `app/client` (React) + one new `app/server` AppKit plugin. No pipeline
or curated-schema changes required to ship v1 (one *optional, recommended* schema
change is called out in §7.4).

This doc is deliberately opinionated and implementation-ready. Where a decision is
genuinely the implementer's, it's flagged in §11 (Open questions). The ERD unknown
from the first draft has now been **investigated and resolved** — see §7.1.

---

## 1. Goal

Add a Databricks-style **left navigation rail** to the app and reorganize it from
a single-canvas map into a small IA with three groups:

1. **Explorer** (top) — the existing map view (`ExecMap`), unchanged in behavior.
2. **Business Functions** (middle) — persona/department entry points (Customer
   Service, Marketing, …). Placeholders in v1.
3. **Reference** (bottom, pinned to the bottom like Databricks' settings cluster) —
   **Data Model** (a dynamic ERD over Unity Catalog metadata) and **Documentation**,
   plus the additional items proposed in §8.

The rail must **collapse** via a static toggle button to an **icon-only** state
(icons stay visible), styled after the reference screenshot (Databricks workspace
nav) but with our own sections and palette.

---

## 2. Current state (grounded facts the implementation must respect)

- **Layout** (`app/client/src/App.tsx`): the root is a CSS grid
  `.app.no-picker` with `grid-template-rows: 56px 1fr` and areas `topbar` / `main`.
  There is **no left nav today**. `<main>` contains `.exec-root` → `<ExecMap …>`.
  The customer profile opens as an over-map drawer (`.cust-drawer`), not a route.
- **The "Explorer" view is `ExecMap`** (`app/client/src/ExecMap.tsx`, ~1000+ lines).
  It holds significant live state: the map viewport, a per-session **focus-set
  cohort** (`/api/focus/*`), and a **Genie "Ask the map" conversation**
  (`/api/genie/*`). Unmounting it resets the cohort and conversation. → **The nav
  must keep `ExecMap` mounted across view switches** (toggle visibility, don't
  unmount). See §6.3.
- **No router.** Views are not URL-routed. A lightweight `activeView` state is
  sufficient for v1 (§6.2); adopting hash routing is optional (§11).
- **Styling** (`app/client/src/App.css`): dark-first with a light theme via
  `:root[data-theme="light"]`. Design tokens already exist and **must be reused**:
  `--bg --panel --panel-2 --border --text --text-muted --accent --accent-dim
  --accent-edge --shadow`. `--accent` (#4f8ff7 dark / #2f6fd9 light) is the
  interactive/active-chrome color — use it for the active nav item. Theme is
  persisted in `localStorage["c360-theme"]`; follow that pattern for nav state.
- **Icons today** are hand-authored inline SVG (`BrandLogo` in `App.tsx`). There is
  **no icon library dependency**. Because the collapsed rail is icon-only, icon
  quality/accuracy now matters a lot — see §5.1.
- **Server pattern** for anything needing Databricks metadata: an **AppKit plugin**
  class (see `app/server/focusPlugin.ts`, `geniePlugin.ts`) that uses the shared
  helpers in `app/server/dbx.ts` — `resolveHost`, `resolveToken` (mints the app
  **service-principal** OAuth token, falls back to forwarded user token, then
  `DATABRICKS_TOKEN` in dev), `resolveCatalog`/`resolveSchema` (from
  `DATABRICKS_CATALOG`/`DATABRICKS_SCHEMA` env), and `runStatement` (Statement
  Execution API, typed rows). The ERD backend follows this exact pattern (§7.2).
- **Naming convention:** tables are prefixed **`curated_`** (not `_curated`). Full
  convention (`ARCHITECTURE.md` §3): `raw_*` (inputs), `curated_*` (star schema:
  `dim_*`, `fact_*`, `bridge_*`, `metric_*` metric
  views), `ml_*` (features/preds), `app_*` (session state). The ERD's convention
  filter keys off the **`curated_` prefix** and is parameterized (§7.5).
- **The query namespaces already imply the business-function decomposition**
  (`app/config/queries/`): `exec_*` (executive/map), `customer_*` (customer
  service), `mkt_*` (marketing: `mkt_recommended_targets`, `mkt_program_kpis`,
  `mkt_enrollment_monthly`, `mkt_complaint_themes`, `mkt_demographics`). Marketing
  already has real backing data (§9).

---

## 3. Target information architecture

```
┌──────────────────────────────────────────── topbar (56px, unchanged) ─────────┐
│  Lakeshore Power & Light        CUSTOMER 360        [search] [☀/☾]             │
├──────┬─────────────────────────────────────────────────────────────────────────┤
│ [«]  │   ← static collapse toggle, top-left of the rail                         │
│      │                                                                          │
│ OVERVIEW               ← section label (muted; hidden when collapsed)          │
│ ▸ CSAT                ← satisfaction overview (added 2026-07; placeholder)      │
│ ▸ Explorer            ← primary, active by default (the map)                    │
│                                                                                 │
│ BUSINESS FUNCTIONS    ← section label (muted; hidden when collapsed)            │
│ ▸ Customer Service                                                              │
│ ▸ Outages & Reliability         (proposed, §9)                                  │
│ ▸ Revenue & Collections         (proposed, §9)                                  │
│ ▸ EE & DER Programs             (proposed, §9)                                  │
│                                                                                 │
│      ⋮  (flex spacer pushes Reference to the bottom)                            │
│                                                                                 │
│ REFERENCE             ← bottom-pinned cluster                                   │
│ ▸ Data Model          ← the dynamic ERD (§7)                                    │
│ ▸ Documentation                                                                 │
│ ▸ Metrics Catalog               (proposed, §8)                                  │
│ ▸ Data Quality & Freshness      (proposed, §8)                                  │
└──────┴──────────────────────────── main (view host) ───────────────────────────┘
```

- **The collapse toggle lives at the top-left of the nav area**, matching the
  screenshot's top-left panel icon.
- **"Explorer" sits under its own "Overview" header** (added post-v1 — the v1 build
  shipped it headerless as the app's home, but a header reads more consistently
  next to "Business Functions"/"Reference" and leaves room to grow past one item).
- **Reference is bottom-pinned** via a flex spacer, reading as utility/meta
  navigation distinct from the working functions above it.

---

## 4. Rail collapse interaction (simplified — static toggle, icon-only collapse)

**Decision (per feedback): drop the hover-peek entirely.** A single static toggle
button that flips between two in-grid states is enough and far less code. Icons stay
visible when collapsed.

| State | Width | Shows | Trigger |
|---|---|---|---|
| **Expanded** | `~248px` | icons **+** text labels **+** section headers | default |
| **Collapsed** | `~64px` | **icons only**; each label appears as a hover tooltip | click the toggle |

- The toggle is a plain `<button>` at the top-left of the rail (icon
  `PanelLeftClose` expanded / `PanelLeftOpen` collapsed). Click flips the state.
- Collapsed keeps the rail **in the grid**, just narrower — **no overlay, no
  hover hot-zone, no intent timers, no absolute positioning.** This removes all the
  fiddly machinery from the first draft.
- Because collapsing changes the grid track width, `main` reflows and MapLibre
  resizes **once** per toggle — deliberate and infrequent, so acceptable. (Verify
  the map calls `resize()` after the transition; MapLibre usually auto-observes.)
- Section headers ("OVERVIEW", "BUSINESS FUNCTIONS", "REFERENCE") **hide** when
  collapsed; use a thin divider or a larger gap to keep the three groups visually
  separated.
- **Collapsed is icon-only, so every item needs a reliable label affordance:**
  `aria-label` on each item for the accessible name, plus a custom `position:
  fixed` hover/focus tooltip (post-v1 addition — the v1 build used the native
  `title` tooltip, but its browser-default delay/styling was a weak affordance for
  an icon-only rail; see §5.1 — this is why icon accuracy still matters even with
  a tooltip).
- Persist the collapsed flag in `localStorage["c360-nav-collapsed"]` (default:
  expanded), following the `c360-theme` precedent.
- **Keyboard:** `Ctrl/Cmd+B` toggles collapse. The button carries `aria-expanded`
  and an `aria-label` ("Collapse navigation" / "Expand navigation").
- Respect `@media (prefers-reduced-motion: reduce)` — instant width change, no
  slide.

### 4.1 Accessibility
The rail is a `<nav aria-label="Primary">`; items are `<button>`s (or `<a>` if
hash-routed) with `aria-current="page"` on the active view and visible
`:focus-visible` rings (reuse `--accent-edge`). In collapsed mode the accessible
name comes from `aria-label`, not the (hidden) text.

---

## 5. Visual design

Match the reference's calm, line-icon aesthetic using **our existing tokens** (§2).

- **Rail:** `background: var(--panel)`, right border `1px solid var(--border)`,
  width `248px` expanded / `64px` collapsed. Section labels reuse the existing
  muted-uppercase style from `.archetype-group-label` (10px, `letter-spacing:.08em`,
  `text-transform: uppercase`, `color: var(--text-muted)`).
- **Item (resting):** transparent bg, `--text-muted` icon + `--text` label,
  `~8px 12px` padding, `6px` radius, icon `20px`. Collapsed: icon centered, label
  hidden.
- **Item (hover):** `background: var(--panel-2)`, icon → `--text`.
- **Item (active):** `background: var(--accent-dim)`, a left accent bar and
  icon/label in `--accent`, `aria-current="page"`. (Our blue, not the reference's
  red.)

### 5.1 Icons — recommendation + why accuracy now matters
Collapsed mode is icon-only, so an ambiguous icon = a lost destination. **Adopt
`lucide-react`** — a large, consistent, tree-shakeable line-icon set that visually
matches Databricks' iconography and gives us precise, unambiguous glyphs per item.
Every item must also carry a `title`/`aria-label` so the tooltip backstops the icon.

Suggested mapping (each chosen to be self-evident at 20px, no label):

| Item | lucide icon | Why it reads clearly |
|---|---|---|
| Collapse toggle | `PanelLeftClose` / `PanelLeftOpen` | literal panel-collapse affordance |
| CSAT | `Smile` | satisfaction glyph, reads instantly |
| Explorer | `Map` | the view *is* a map |
| Customer Service | `Headset` | universal CSR/support glyph |
| Outages & Reliability | `ZapOff` | power-off = outage (very literal) |
| Revenue & Collections | `CircleDollarSign` | money/revenue, unambiguous |
| EE & DER Programs | `Leaf` | energy-efficiency / clean-energy programs |
| Data Model | `Waypoints` (or `Network`) | connected nodes = an ERD |
| Documentation | `BookOpen` | docs/reading |
| Metrics Catalog | `Gauge` | measures/KPIs |
| Data Quality & Freshness | `ShieldCheck` | data-quality/validation |

These are recommendations — **validate them visually** in the running app at the
collapsed size before locking in; swap any that read ambiguously. If the team wants
zero new deps, hand-author inline SVGs as `BrandLogo` does, but that's materially
more effort and easy to drift, and the accuracy bar is higher now — prefer lucide.

---

## 6. Component architecture (client)

### 6.1 Grid change (`App.tsx` + `App.css`)
Keep the topbar full-width; introduce a `nav` column beneath it:

```css
.app.no-picker {
  grid-template-columns: var(--nav-w, 248px) 1fr;   /* var flips to 64px collapsed */
  grid-template-rows: 56px 1fr;
  grid-template-areas:
    "topbar topbar"
    "nav    main";
}
.app.no-picker.nav-collapsed { --nav-w: 64px; }
```

Transition `--nav-w` (gated by `prefers-reduced-motion`).

### 6.2 New components
```
app/client/src/nav/
  NavRail.tsx        # the rail: sections, items, collapse toggle
  navConfig.ts       # declarative section/item model (id, label, icon, group)
  useNavState.ts     # collapsed + activeView state, localStorage, Cmd+B
app/client/src/views/
  DataModelView.tsx  # the ERD (§7.3)
  DocumentationView.tsx
  PlaceholderView.tsx  # reusable "Coming soon" for business-function stubs
```

`navConfig.ts` is the single source of truth so adding an item is one entry:
```ts
export type NavItem = {
  id: string; label: string; icon: LucideIcon;
  group: "top" | "business" | "reference";
  status?: "ready" | "placeholder";
};
```

### 6.3 View switching — keep `ExecMap` mounted
In `App.tsx`, hold `const [activeView, setActiveView] = useState("explorer")`.
Render **all** views but toggle visibility so `ExecMap` never unmounts:

```tsx
<main className="main">
  <div className="exec-root" style={{ display: activeView === "explorer" ? "" : "none" }}>
    <ExecMap onJumpToCustomer={setFullProfile} focus={focus} />
  </div>
  {activeView === "data-model" && <DataModelView />}
  {activeView === "documentation" && <DocumentationView />}
  {/* business-function placeholders … */}
</main>
```

`display:none` on `.exec-root` preserves the map instance, viewport, focus-set
cohort, and Genie conversation. Other views are cheap and can mount lazily on first
visit. **Do not** conditionally render `ExecMap` in/out — it resets the cohort and
re-runs every `useAnalyticsQuery`. Mount Explorer visible on load (the default) so
the map sizes correctly, and only ever hide it afterward.

**Search → view coupling:** the top-bar search drives `focus` + opens the customer
drawer over the map; on pick, also set `activeView → "explorer"` (searching a
customer is an Explorer/CS action — snap back to the map). *(Confirm in §11.)*

### 6.4 Future direction (NOT in scope now — architect so as not to preclude it)
Tim's envisioned future: **saveable focus groups** with **quick-links that hand a
focus group from Explorer into a Business Function** (e.g. "send this cohort to
Marketing"). Two cheap, forward-compatible choices to make *now* so this stays easy
later — no feature work required:
1. Keep `ExecMap` mounted (already decided) so a live cohort survives navigation.
2. When lifting/refactoring focus-group state, put the "active focus group" concept
   where it can be **shared app-wide** (an `App`-level state or a small React
   context), rather than burying it inside `ExecMap`. A future "open in Marketing"
   button then just switches `activeView` and reads the shared cohort.

Do not build saveable/named focus groups or cross-view handoff in this pass.

---

## 7. The Data Model view (dynamic ERD over Unity Catalog)

A live ERD generated from UC metadata, filtered by naming convention (default
`curated_`), with PK badges + inferred FK edges, table/column descriptions on hover,
and deep links to each object in Unity Catalog.

### 7.1 ✅ Investigated & resolved — metadata reality (`timstanton_stable.customer_360`)

| Finding | Result | Implication for the ERD |
|---|---|---|
| **Primary keys** | **15 declared PKs** on curated tables (all `dim_*` + `bridge_account_premise`), single-column surrogate keys named `<entity>_id`. UC materializes them as named table constraints (e.g. `dim_customer_pk`) but declared **without `RELY`** — informational only, not usable by the optimizer (see §7.4) | PK badges are **authoritative** — read them directly. |
| **Foreign keys** | **0** — `referential_constraints` is empty. The `CONSTRAINT … EXPECT(…)` lines on facts are **SDP data-quality expectations, not relational FKs** | **FK edges must be inferred by convention (§7.6).** There are no declared edges to read. |
| **Tables w/o PK** | `dim_premise` has no PK (native `GEOMETRY` is incompatible with typed-column constraint DDL); facts declare no PK | Inference must tolerate PK-less tables; premise edges resolve to `dim_premise_h3` (which *does* PK `premise_id`) — see the edge-case note in §7.6. |
| **Table comments** | **46 / 46 (100%)** populated | Table-header tooltips are fully backed. |
| **Column comments** | **549 / 703 (78%)** populated | Column tooltips mostly backed; render "—" / omit gracefully when null. |
| **Curated inventory** | **46 tables**: 16 dim · 19 fact · 1 bridge · **7 metric views** · 3 other | 46 nodes is a large graph → **scope the default view (§7.7).** |

Bottom line: the ERD is **PK-anchored (authoritative) and FK-inferred (dashed)**.
Because surrogate keys are consistently named `<entity>_id` and the PK set is known,
inference is clean and high-precision.

### 7.2 Backend: new `dataModelPlugin` (`app/server/dataModelPlugin.ts`)
Model it on `focusPlugin.ts`. Register in `server.ts`:
`plugins: [server(), analytics(), geniePlugin(), focusPlugin(), dataModelPlugin()]`.

- **Endpoint:** `GET /api/data-model/erd?prefix=curated_`
- Uses a `resolveCtx`-style helper (host/token/warehouse/catalog/schema) exactly
  like focusPlugin. Validate `prefix` against `/^[A-Za-z0-9_]+$/` before inlining
  (same discipline as focusPlugin's regex guards). Runs against
  `<catalog>.information_schema`:
  - `tables` → name, `table_type`, `comment` (filter
    `table_schema=:schema AND table_name LIKE :prefix||'%'`).
  - `columns` → name, `ordinal_position`, `full_data_type`, `is_nullable`, `comment`.
  - `table_constraints` ⋈ `key_column_usage` → the 15 PKs (`constraint_type='PRIMARY KEY'`).
  - *(FKs: skip — confirmed none. Inference happens server-side, §7.6.)*
- **Response contract:**
```jsonc
{
  "catalog": "…", "schema": "…", "prefix": "curated_",
  "generatedAt": "ISO-8601",
  "edgesAreInferred": true,             // always true today (no declared FKs)
  "tables": [
    { "name": "dim_customer", "kind": "dim",
      "comment": "…",
      "ucUrl": "https://<host>/explore/data/<catalog>/<schema>/dim_customer",
      "columns": [
        { "name": "customer_id", "type": "BIGINT", "nullable": false,
          "comment": "…", "isPk": true, "isFk": false,
          "refTable": null, "refColumn": null } ] }
  ],
  "edges": [
    { "fromTable": "fact_customer_billing", "fromColumn": "customer_id",
      "toTable": "dim_customer", "toColumn": "customer_id",
      "inferred": true } ]
}
```
- **UC deep link:** `${host}/explore/data/${catalog}/${schema}/${table}` (Catalog
  Explorer table page). No stable per-column deep link — link at table grain.
- **Caching:** metadata is slow-changing and warehouse spin-up has latency. Cache
  the assembled response **in-process with a TTL** (5–10 min) keyed by
  `catalog.schema.prefix`, with `?refresh=1` bypass. Reuse focusPlugin's
  try/catch → `res.status(500)` error shape.

### 7.3 Frontend: `DataModelView.tsx` — recommendation
Render an **interactive node-graph ERD** with **`@xyflow/react` (React Flow)** +
**`dagre`** (or `elkjs`) auto-layout. React Flow is the right call given ~40 nodes:
pan/zoom, fit-to-view, and minimap make a large graph legible in a way Mermaid
can't.

- **Node = table.** Custom node: header (table name + `kind` badge + external-link
  icon → `ucUrl`, opens UC in a new tab), then a compact column list. PK columns get
  a key glyph; inferred-FK columns get a link glyph.
- **Table tooltip:** the table `comment` (100% populated) on the header.
- **Column tooltip:** hover a column row → `type`, nullability, and `comment`
  (78% populated; show type/nullability even when comment is blank).
- **Edge = inferred FK.** Directed `fk_table → pk_table`, labeled with the join
  column, rendered **dashed** with a small "inferred" affordance; a one-line banner
  notes "relationships inferred from naming convention" (driven by
  `edgesAreInferred`).
- **Layout:** dagre left-to-right; fit-to-view on load; pan/zoom + minimap;
  "re-layout" button.
- **Convention control:** a prefix selector (default `curated_`; also `raw_`,
  `ml_`, `app_`) so the same view redraws for any tier (§7.5).
- **Scope control:** see §7.7 (default to the star; toggles for history/other).
- **States:** loading skeleton, empty, error — reuse `.loading`/`.empty-state`/
  `.error` from `App.css`.
- **Theming:** feed React Flow node/edge colors from CSS vars; canvas bg
  `var(--bg)`.

*Alternative (lighter, weaker UX):* render a Mermaid `erDiagram` from the same JSON
— fast, but poor per-column tooltips and no reliable per-object click-through, and
it struggles at 40 nodes. The JSON contract supports either renderer, so it's
swappable. Given the graph size, React Flow is recommended.

### 7.4 Constraint review & recommended hardening (reviewed against live UC)

**Verdict of the UC review:** the curated layer sets **PKs correctly but not
completely, and declares no FKs at all** — so we are *not* yet using the full,
current UC constraint toolkit.

What's implemented today (from `SHOW CREATE TABLE`):
- ✅ **PKs** on every keyed dim + the bridge, as named table constraints
  (`curated_<t>_pk`). Good practice.
- ⚠️ **PKs carry no `RELY`.** In Databricks/UC, PK/FK constraints are always
  informational (never enforced); **`RELY` is the switch that lets the optimizer
  trust them** for rewrites (join/aggregate elimination). Without it the PKs are
  pure documentation.
- ❌ **Zero FOREIGN KEYs.** Facts/bridges carry `account_id`, `customer_id`,
  `service_agreement_id`, `service_point_id`, `date_key`, `rate_schedule`, etc. as
  plain columns with "joins dim_X" *comments only* — UC has **no relational
  graph** for the star.
- ➖ Fact **grain keys** (e.g. `bill_id`) use SDP `EXPECT` data-quality rules, not a
  declared PK/UNIQUE. `EXPECT` is a pipeline runtime check; it does **not** appear
  in `SHOW CREATE TABLE` or `information_schema.table_constraints` (why the probe
  saw only 15 PKs).
- ➖ `dim_premise` has **no PK** (native `GEOMETRY` conflicts with the
  inline typed-column constraint DDL). This can't be fixed by adding an inline PK,
  and SDP MVs aren't easily `ALTER`-ed post-create — so premise stays PK-less.

**Recommended hardening** (a fast-follow to make the star authoritative — and it
also improves Genie join inference and query optimization):

1. **Add `FOREIGN KEY … REFERENCES … NOT ENFORCED` to facts/bridges** in
   `src/30_curated/`. FKs are declarable in the MV column-spec and reference another
   MV's PK in the same schema. The concrete map (from the reviewed DDL):
   - `fact_customer_billing`: `account_id`→`dim_account`, `customer_id`→`dim_customer`,
     `service_agreement_id`→`dim_service_agreement`, `service_point_id`→
     `dim_service_point`, `date_key`→`dim_date`, **`rate_schedule`→
     `dim_rate_schedule(rate_schedule_id)`** (note the column/PK name mismatch — §7.6).
   - `fact_meter_readings_daily`: `account_id`, `customer_id`, `service_point_id`,
     `date_key` → their dims.
   - `bridge_account_premise`: `account_id`→`dim_account`, `customer_id`→`dim_customer`.
   - `premise_id` FKs **cannot** be declared (target `dim_premise` has no PK) → stay
     inferred, dashed. (Optionally FK to `dim_premise_h3`, which *does* PK
     `premise_id`, but that's the H3 helper, not the premise dimension — a modeling
     judgment call.)
2. **Add `RELY`** to the new FKs (and, if desired, the existing PKs) **only after
   validating** the data satisfies uniqueness + referential integrity. `RELY` on
   violated RI can yield wrong query results, so gate it behind a one-time validation
   query (every fact FK value exists in its dim; every PK is unique). Surrogate keys
   are `abs(xxhash64(...))` of unique natural keys, so uniqueness effectively holds;
   RI should hold but must be checked before asserting `RELY`.
3. **Verify FK-on-MV support in the pipeline's DBR channel** before rolling out — it
   is supported on recent serverless/DBR, but confirm in a dev pipeline run.

Impact if adopted: the ERD's edges become **declared/authoritative (solid)** instead
of inferred (dashed), and the `edgesAreInferred` flag flips to `false`. **Out of
scope for this app pass** (it's a pipeline change requiring a curated re-run), but
it's the single highest-leverage schema improvement and is recommended. *(Decision
in §11.)*

### 7.5 "Dynamic by convention" — prefix is a parameter
Don't hardcode `curated_`. The endpoint takes `?prefix=` and the view exposes it;
parse `curated_<kind>_<name>` to tag each table `dim|fact|bridge|metric` for
grouping/coloring. Point it at any tier and it redraws — that's the "dynamic by
convention" requirement.

### 7.6 Convention-inferred FK edges (the actual edge source today)
For each non-PK column named `<x>_id` on any curated table, draw a dashed edge to
the table whose **declared PK** is `<x>_id`. Since the 15 PKs are known, this is a
precise lookup, not a guess. Edge cases to handle:
- **PK-less dimensions:** `premise_id` references resolve to `dim_premise_h3`
  (which PKs `premise_id`), not `dim_premise` (no PK). Acceptable, but note
  it; optionally special-case a display alias to the conceptual dimension.
- **Naming mismatches break pure inference:** the review found
  `fact_customer_billing.rate_schedule` joins `dim_rate_schedule
  (rate_schedule_id)` — the column is `rate_schedule`, not `rate_schedule_id`, so a
  `<x>_id`→PK`<x>_id` rule **misses this edge**. Either maintain a small alias map
  for known mismatches, or (better) declare the FK (§7.4) so the edge is explicit.
  This gap is itself an argument for the §7.4 hardening.
- **Bridges** (`bridge_account_premise`) carry multiple `_id` FKs — emit one
  edge per matched key.
- **History tables** (`dim_*_history`) use `*_sk` PKs; keep them out of the
  default scope (§7.7) to avoid clutter.
- Mark every inferred edge `inferred:true`; set top-level `edgesAreInferred:true`.

### 7.7 Scale: default scope for a 46-table schema (DECIDED)
46 nodes / 703 columns is too much to dump at once. **Default the ERD to the core
star** — `dim_*` + `fact_*` + `bridge_*` (~36 nodes) — with
**three independent toggles** to layer in the rest:
- **SCD2 history** — `dim_*_history` tables (`*_sk` PKs).
- **Other** — the 3 non-standard-prefix curated tables.
- **Metric views** — the 7 `metric_*` views.

**Metric views appear as ERD nodes when their toggle is on** (per decision), but they
are semantic layers with **no relational PK/FK**, so they render as standalone nodes
(no FK edges). *Optional enhancement:* parse each metric view's `source`/definition to
draw a dashed "based-on" association to its underlying fact — nice-to-have, not
required for v1. Metric views also still get their own richer **Metrics Catalog**
(§8) surface (name, description, dims/measures); the ERD toggle shows *where they sit*
in the model, the catalog explains *what they compute*.

---

## 8. Reference section — full item set (proposed)

| Item | What it is | Why / backing |
|---|---|---|
| **Data Model** ✱ | The dynamic ERD (§7) | requested |
| **Documentation** ✱ | Rendered in-app docs | requested |
| **Metrics Catalog** | The 7 governed `metric_*` views — name, description, dims/measures | Real data (`metric_views.py`); natural pairing with the ERD. |
| **Data Quality & Freshness** | Last pipeline run, per-tier row counts, the frozen "now" (2018-12-31), source-availability matrix, comment-coverage (e.g. the 78% column-comment stat) | Reinforces demo credibility; sources in `ARCHITECTURE.md` §7. |
| **Sources & Attributions** | FEMA/ORNL, NREL NSRDB, ResStock/ComStock, TIGER credits | Already written in `ARCHITECTURE.md`; licensing-appropriate. |
| **About / Release notes** | App version, environment (catalog.schema), build | Cheap, useful in demos. |

✱ = explicitly requested. Recommend shipping **Data Model + Documentation** in v1,
then **Metrics Catalog + Data Quality & Freshness** as fast follows (both have real
backing data).

**Documentation content — three surfaces, one canonical home per topic (DECIDED).**
Render in-app Markdown (the app already depends on `react-markdown` + `remark-gfm`,
used by "Ask the map"), sourced from a curated set of `.md` under
`app/client/src/docs/` in a demo-facing product voice. This is *not* a fourth doc
pile — it's part of a deliberate split of today's docs across three readers:

| Surface | Reader | Content |
|---|---|---|
| `README.md` | repo cloner | stays **lean**: quickstart, at-a-glance, the five seams, attributions (canonical — licensing), status |
| In-app focus pages (`app/client/src/docs/`) | demo viewer (product voice) | the **conceptual** narrative: the tier model (raw/curated/ml/app), the **curated star schema** (pairs with the Data Model/ERD view), "what the data is / where it comes from" |
| `ARCHITECTURE.md` (slimmed) | repo extender (engineer) | **build mechanics only**: two-layer `${...}` substitution, SDP globs, raw→curated BYO contract + capability matrix, ML add-a-model recipe, deployment/SP-grants, the GEOMETRY-DDL gotcha, roadmap |

**Reorg (do it in Phase 3, alongside building the Documentation view — not now):**
migrate ARCHITECTURE.md's *conceptual* sections (tier model, star schema, data
sources) into the new focus pages rewritten for product voice; leave the *mechanics*
in a slimmed ARCHITECTURE.md; keep README simple with its "full design" link
pointing at the slimmed ARCHITECTURE.md. **Rule:** each concept has exactly one
canonical home — the other surfaces link or one-line-summarize, never re-explain
(prevents drift). Doing this in the same pass as the focus pages means the content
*moves* in one motion, with no interim duplication.

---

## 9. Business Functions — full item set (proposed)

Personas/departments for a utility Customer 360. The existing query namespaces
(`customer_*`, `mkt_*`, `exec_*`) confirm the first two are real, not hypothetical.

| Function | v1 | What it becomes | Backing today |
|---|---|---|---|
| **Customer Service** | placeholder | CSR console: search → full customer profile (the `CustomerDetail` drawer promoted to a first-class view), active-outage + next-best-action | `customer_*` queries already power the drawer |
| **Outages & Reliability** | placeholder | Ops view: active-outage incidents/points, reliability metrics, major-event days | `exec_active_outage_*` queries exist |
| **Revenue & Collections** | placeholder | Credit & collections: payment-stress cohorts, arrears, LIHEAP-eligible outreach | flags on `dim_customer` |
| **EE & DER Programs** | placeholder | Energy-efficiency & DER: EV/heat-pump/solar detection, program fit, "detected · not enrolled" | `ml_*` EV detector + DER opportunity logic exist |

**Update (2026-07-07):** Marketing was **cut from the rail** and a **CSAT** item was
added at the top of the Overview group (placeholder, `Smile` icon) — customer
satisfaction is an overview-level concern, not a department. The `mkt_*` queries
remain valid backing; the complaint-themes / targeting content they powered largely
moves to CSAT, which will also surface the complaint-risk scores from the planned
complaints predictor (see `docs/complaints-predictor-scoping.md`). "Outage &
Reliability" was renamed to "Outages & Reliability". Build order shifts accordingly:
Customer Service, then CSAT, then the remaining placeholders.

**Explorer vs Executive:** the current map is executive/territory-level (`exec_*`).
Leave Explorer as the shared map home; don't add a separate Executive function in v1
(avoid redundancy).

---

## 10. Placeholder view spec

`PlaceholderView({ title, icon, blurb })`: centered card reusing `.card` styling, the
function's icon, a one-line description of what the view *will* do, and a subtle
"Coming soon" badge (reuse `.badge.neutral`). Keeps the nav fully clickable and the
demo story coherent without half-built views.

---

## 11. Open questions / decisions to review

Resolved by investigation/feedback and no longer open: FK-constraint reality (§7.1 —
none, edges inferred), collapse behavior (§4 — static toggle, icon-only), keep
Explorer mounted (§6.3), icons visible on collapse (§4/§5.1).

**DECIDED (this design cycle):**
- **Constraint hardening:** implement FKs + RELY in `src/30_curated/` (§7.4) — the
  near-term path, not deferred. ERD then shows authoritative solid edges.
- **ERD renderer:** React Flow (`@xyflow/react`) + dagre (§7.3).
- **ERD default scope:** core star + three toggles — SCD2 history, other, **and
  metric views** (§7.7).
- **Icons:** `lucide-react` (§5.1) — reads clearly at the 64px collapsed size.
- **Documentation:** in-app curated focus pages (`app/client/src/docs/`), part of the
  three-surface doc split (§8) — with ARCHITECTURE.md's conceptual content migrating
  into the focus pages during Phase 3.
- **Routing:** `activeView` React state for v1 (hash routing deferred as an optional
  later add — deep-links + Back button, no structural change to the views).
- **Search → view coupling:** on customer pick, also set `activeView → "explorer"`
  so the map comes forward and flies to the customer (one-line change to the existing
  `onPick` handler in `App.tsx`). Revisit only when Customer Service becomes a real
  view.

Nothing outstanding — all threads resolved for the downstream build session.

---

## 12. Suggested phasing

**Implementation status (2026-07-07):**

| Phase | Status | Notes |
|---|---|---|
| 0 — Constraint hardening | ✅ Shipped | `RELY` added to the 6 core-star PKs; 12 `FOREIGN KEY … NOT ENFORCED RELY` constraints declared across `fact_customer_billing` (6), `fact_meter_readings_daily` (4), `bridge_account_premise` (2) in `src/30_curated/transformations/`. RI/uniqueness validated with 0 violations before asserting RELY. `dataModelPlugin.ts` now reads declared FKs from `information_schema.referential_constraints` and renders them solid; confirmed live post-run (12 declared edges present, 63 still convention-inferred — `edgesAreInferred: true` until Phase 0's scope widens). **Gotcha hit during rollout:** on the first pipeline run, `fk_fmrd_customer` silently failed to attach with zero error events — SDP's flow scheduler orders by data lineage, not declared FK references, so a fact whose query never actually reads the referenced dim (as `fact_meter_readings_daily` doesn't read `dim_customer`) has no ordering guarantee against that dim's concurrent refresh; a second `curated` pipeline run attached it cleanly. Worth a re-run + a live constraint check after any future FK addition of this shape, rather than trusting a clean `update_progress` alone. |
| 1 — Nav shell | ✅ Shipped — commit `ef13070`, polish in `ffc1801` | Matches the design as written. Fast-follow polish (`ffc1801`): added an "Overview" header above Explorer (all three groups now have one) and replaced the collapsed rail's native `title` tooltip with a custom `position: fixed` hover/focus tooltip styled to the app theme. |
| 2 — Data Model | ✅ Shipped — commit `d3d48b8` | One deviation from §7.3/§6.2: no separate `DocumentationView.tsx` yet (Documentation stayed a Phase-1 placeholder — it's Phase 3 scope, §8). ERD nodes render PK/FK columns by default with a "+N more columns" expand toggle per table, rather than always listing every column — kept the default graph legible at the 36-node star; full column list (with tooltips) is one click away. |
| 3 — Reference fast-follows | 🔶 In progress — items 1-2/4 shipped | Documentation ✅ + Metrics Catalog ✅ shipped; Data Quality & Freshness, then the remaining function views remain — Marketing was cut from the rail on 2026-07-07 in favor of a CSAT item under Overview (see §9 update), so the first real Business-Function/Overview builds are Customer Service and CSAT. Detailed sequenced plan + rough edges in §12.1. |

- **Phase 0 — Constraint hardening (important first step; §7.4).** Add
  `FOREIGN KEY … NOT ENFORCED RELY` across the curated facts/bridge in
  `src/30_curated/`, gated behind a one-time RI/uniqueness validation, then re-run
  the `curated` pipeline and re-probe `information_schema` to confirm the edges are
  live. **Do this first** so the ERD (Phase 2) reads authoritative declared edges
  rather than inferred ones. *Caveat / why it's carved out as its own phase:*
  iterating on the pipeline (FK-on-MV support in the DBR channel, RI validation,
  re-materialization) can get into the weeds — keep it **decoupled** from the app
  work so the nav/ERD isn't blocked on it. Validate in a **dev pipeline** before
  touching the shared schema. **Graceful degradation:** if Phase 0 slips, Phase 2
  still ships — the ERD just renders convention-inferred *dashed* edges
  (`edgesAreInferred:true`) until the constraints land, then flips to solid with no
  app change.
- **Phase 1 — Nav shell:** grid change, `NavRail`, `navConfig`, `useNavState`
  (static collapse toggle + persistence + Cmd+B), `lucide-react` icons, Explorer
  wired as the mounted default, all other items as placeholders. Ships the entire
  requested chrome. *(Independent of Phase 0 — can run in parallel.)*
- **Phase 2 — Data Model:** `dataModelPlugin` + `/erd` endpoint (PKs from
  information_schema; declared FK edges if Phase 0 landed, else inferred; TTL cache);
  `DataModelView` with React Flow, tooltips, UC links, prefix + scope controls.
- **Phase 3 — Reference fast-follows:** Documentation, Metrics Catalog, Data Quality
  & Freshness; then progressively replace the remaining placeholders starting with
  Customer Service and CSAT (Marketing was cut 2026-07-07; its `mkt_*` queries
  back CSAT instead — §9 update). Later: saveable focus groups + cross-view
  handoff (§6.4). Detailed, sequenced plan in §12.1.

### 12.1 Phase 3 — detailed plan (next session)

**Sanity-check verdict (2026-07-07):** Phases 0–2 reviewed and confirmed correct.
The new Phase 1/2 code (`nav/*`, `views/*`, `dataModelPlugin.ts`, `server.ts` wiring)
is type-clean — the only `tsc --noEmit` errors (10) are all in the pre-existing
`CustomerDetail` region of `App.tsx` (lines 420–450, last touched at `b413ad3`, before
any nav work): the known `appKitTypes.d.ts`-baseline fluctuation, not a regression.
App.tsx keeps `ExecMap` mounted via `display:none` and snaps search picks back to
Explorer exactly as §6.3/§11 specify. Two minor rough edges to fold into Phase 3
(neither blocks anything):
- **ERD prefix selector breaks for non-`curated_` tiers (§7.5 gap).** ✅ **Fixed.**
  `tableKind()` only classifies `curated_*` names, so selecting `raw_`/`ml_`/`app_`
  tagged every table `other`, which the default scope hid → blank canvas (not the
  empty-state, since tables *do* load). Fix took the "show all tables regardless of
  kind" branch (not the alternative "`derive kind generically`" branch — the
  dim/fact/bridge/history/metric taxonomy is curated_-specific and doesn't
  generalize meaningfully to raw_/ml_/app_): `DataModelView.visibleTables` now
  returns `erd.tables` unfiltered when `erd.prefix !== "curated_"`, and the three
  scope checkboxes (SCD2 history / Other / Metric views) are hidden from the
  toolbar for non-curated prefixes since they'd be dead controls. No server-side
  `tableKind()` change needed. Browser-verified: raw_/ml_/app_ all render real
  table nodes (not blank, not the empty-state), curated_ unaffected.
- **Metric-view / Data-Quality nav items don't exist yet.** Metrics Catalog ✅
  shipped as item 2 above; Data Quality remains — that's item 3 below, not yet
  started.

Recommended order (each item is independently shippable; earliest have real backing
data and unblock the demo story):

1. **Documentation view** ✅ **Shipped** (flip the existing `documentation`
   placeholder → `ready`).
   - `views/DocumentationView.tsx` renders in-app Markdown with `react-markdown` +
     `remark-gfm` (already deps — used by "Ask the map"), sourced from a new
     `app/client/src/docs/*.md` set (`tiers.md`, `star-schema.md`,
     `data-sources.md`) in demo product voice, imported via Vite's `?raw` suffix
     (added `"vite/client"` to `app/tsconfig.json`'s `types` for the import to
     typecheck). Two-pane layout: left sub-nav (3 pages), right content pane; the
     Star Schema page has a cross-link button that calls `setActiveView("data-model")`.
   - Content = the **conceptual** narrative (§8 middle row): tier model
     (raw/curated/ml/app), the curated **star schema** (pairs with the ERD), "what the
     data is / where it comes from."
   - **Doc reorg done in the same motion:** trimmed ARCHITECTURE.md §3 (tier
     descriptions) and §5 (star schema walkthrough) to mechanics-only, each with a
     pointer to the new in-app page; deduped the trailing "Data sources &
     attributions" section against README's copy (now the canonical one, per §8's
     table) down to a one-line pointer.
   - Wire into `App.tsx`'s view host next to `DataModelView` (`activeView === "documentation"`).
   - Verified: `tsc --noEmit` shows the same pre-existing 10-error baseline (no new
     errors); browser-tested locally on :8000 against real data — all 3 pages
     render, tab switching + active-highlight work, the Data-Model cross-link
     navigates correctly, both themes render cleanly, no console errors.

2. **Metrics Catalog** ✅ **Shipped** (new Reference nav item → `navConfig.ts`,
   icon `Gauge` per §5.1).
   - Surfaces the 7 governed `metric_*` views: name, description, dimensions,
     measures. Backing: `metric_views.py` (real data).
   - Backend: `app/server/metricsPlugin.ts`, `GET /api/metrics/catalog`, reusing
     `dbx.ts` + the same TTL-cache pattern as `dataModelPlugin`. **A metric view's
     dimensions/measures aren't structured anywhere in `information_schema`** —
     `information_schema.columns` lists them as plain columns (dimensions then
     measures, in YAML declaration order) with no dimension/measure tag, and
     `information_schema.views` doesn't list metric views at all (`table_type =
     'METRIC_VIEW'`, not a regular view). Confirmed live against
     `timstanton_stable.customer_360` before building. The actual source of
     truth is `SHOW CREATE TABLE`'s embedded YAML body (`WITH METRICS LANGUAGE
     YAML AS $$…$$`), parsed with the `yaml` package (added as a direct dep —
     it was already resolvable transitively, but pinned explicitly since a regex
     parse of Spark's YAML serialization would mangle folded/escaped multi-line
     comments). Client: `views/MetricsCatalogView.tsx`, a card grid (one card per
     view) with dimension/measure lists and a UC-explorer link per card.
   - Pairs with the ERD: added a one-line cross-reference from the Documentation
     "Star Schema" page's metric-views bullet ("See the Metrics Catalog for
     exactly what each one computes") rather than the ERD's metric-view toggle
     itself, which doesn't have room for a deep link — the ERD shows *where* they
     sit, the catalog explains *what* they compute.
   - Verified: `tsc --noEmit` back at the pre-existing 10-error baseline (1 new
     error surfaced transiently after `npm install --package-lock-only` alone —
     `yaml` wasn't actually in `node_modules` yet — resolved with a real `npm
     install`); browser-tested locally on :8000 against real data — exactly 7
     cards render, Refresh re-fetches cleanly, both themes readable, no console
     errors.

3. **Data Quality & Freshness** (new Reference nav item, icon `ShieldCheck`).
   - Last pipeline run, per-tier row counts, the frozen "now" (2018-12-31),
     source-availability matrix, comment-coverage (e.g. the 78% column-comment stat).
     Sources in `ARCHITECTURE.md` §7.

4. **CSAT view** (Overview placeholder → `ready`; replaces the cut Marketing view,
   2026-07-07).
   - Inherits the shovel-ready `mkt_*` queries where they fit (`mkt_complaint_themes`,
     `mkt_program_kpis`, `mkt_enrollment_monthly`, `mkt_demographics`); adds CSAT/NPS
     trend from `fact_survey_responses` and, once built, the complaint-risk
     scores from `ml_complaint_risk_scores`
     (see `docs/complaints-predictor-scoping.md`). `views/CsatView.tsx`.
   - Then **Customer Service** next (promote the `CustomerDetail` drawer to a
     first-class view), per §9's data-readiness ordering.

**Deliberately still deferred (NOT Phase 3 core; §6.4):** saveable/named focus groups
+ cross-view handoff ("send this cohort to Customer Service"). Forward-compat is already
preserved (ExecMap stays mounted). When it comes up, first lift the "active focus
group" concept out of `ExecMap` into App-level state / a small context so any view
can read it — do that refactor *before* building the handoff UI.

---

## 13. File-change checklist (for the implementer)

**Client**
- `app/client/src/App.tsx` — grid area for `nav`; render `<NavRail>`; `activeView`
  state; keep `ExecMap` mounted via visibility toggle; view host switch.
- `app/client/src/App.css` — `.app.no-picker` grid cols + `.nav-collapsed`; rail,
  section-label, item (resting/hover/active), collapsed icon-only, reduced-motion.
- `app/client/src/nav/{NavRail,navConfig,useNavState}.tsx|ts` — new.
- `app/client/src/views/{DataModelView,DocumentationView,PlaceholderView}.tsx` — new.
- `app/package.json` — add `lucide-react`; (Phase 2) `@xyflow/react` + `dagre`
  (or `mermaid`).

**Server**
- `app/server/dataModelPlugin.ts` — new; `GET /api/data-model/erd`, reuses `dbx.ts`,
  in-process TTL cache, prefix validation, server-side PK-anchored edge inference.
- `app/server/server.ts` — register `dataModelPlugin()`.
- No new env vars — reuses `DATABRICKS_HOST/CATALOG/SCHEMA/WAREHOUSE_ID` + SP creds
  already wired in `dbx.ts`.

**Verify (per repo `verify`/`run` conventions)**
- Local boot on `:8000` against real data (see the app local-dev memory), then:
  collapse toggle flips expanded↔icon-only and persists; icons read clearly at 64px
  with tooltips; Explorer keeps its map/cohort/Genie state across switches;
  `/api/data-model/erd` returns 15 PKs + inferred edges over the ~36-node star;
  table tooltips (100%) and column tooltips (78%, graceful when blank) work; UC
  links open the right Catalog Explorer pages; theme toggle still themes the rail
  and ERD.
```
