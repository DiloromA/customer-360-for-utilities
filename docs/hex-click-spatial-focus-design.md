# Exec Map — Hex-Click Spatial Focus + No-Flash Selection (Design)

Status: **Design ready, nothing implemented.** Guide for the next
session. Verified against the working tree at `2c5297d`
(`ExecMap.tsx` 3146 lines; `focusPlugin.ts` 347; `geniePlugin.ts` 1035;
`exec_map_cells.sql` 201; `02_focus_set_setup.py` 67). Trust the
file:line anchors below but re-check them after any rebase — `ExecMap.tsx`
is large and shifts easily.

Follow-on to `docs/map-selection-and-focus-ux-design.md` (the focus-group /
cohort-recolor work, shipped in `b3a501b`). This doc fixes two problems the
user hit while clicking individual hexes on the choropleth.

---

## 0. The two problems (user's words)

1. **"When I click a hex, the UI highlights ALL of the hexes with a blue
   outline first, then once the info loads, the rest go away."** — an
   ugly intermediate frame where the whole territory is outlined blue.
2. **"Clicking one hex highlights other hexes too — I think because the
   same customer can be at multiple premises."** — correct diagnosis.
   The user wants: **clicking a hex shows info about ONLY that hex**
   (plus whatever else is genuinely part of the focus group, e.g. a
   multi-hex box/lasso).

**Product decisions already made with the user (drive this whole doc):**

- **Q1 — a hex click scopes to _the place_ (spatial, WYSIWYG).** The
  focus is the premises physically inside the clicked hex. A multi-site
  customer is counted **only for the premise that sits in this hex**, not
  followed to their other premises. The map outlines exactly the hex(es)
  clicked and nothing else.
- **Q2 — a hex click still builds a _focus group_.** It is a real cohort
  like box/lasso: the right rail shows full group analytics and
  "Ask the map" scopes to it. So it keeps the `/api/focus/set`
  round-trip — which means Problem 1's timing must be fixed, not
  side-stepped by making the click cohort-free.

These two combine into one target: **hex/box-over-hex focus must be
premise-grained, and the cohort visuals must not appear until the
cohort-scoped cells are actually on screen.**

---

## 1. Root causes (verified)

### Problem 1 — the "all hexes flash blue"

Pure render-timing; no data issue. Sequence on a hex click
(`onMapClick`, `ExecMap.tsx:1595-1617`):

1. `setSelectedCell(h3)` fires synchronously → the **`cells-selected`**
   line layer (`ExecMap.tsx:2025-2030`) outlines *just* the clicked hex.
   This part is correct and gives instant feedback.
2. `writeFocus({ hex: {...} }, "Hex area")` (`ExecMap.tsx:1615`) is an
   async POST to `/api/focus/set`. `focusPending` goes true; `focusActive`
   is still false.
3. When the round-trip resolves, `setFocusSummary(data)` flips
   `focusActive = true` and bumps `focusVersion` (`ExecMap.tsx:696-697`).
4. **The instant `focusActive` becomes true**, the **`cells-cohort-outline`**
   layer (`ExecMap.tsx:2046-2053`) switches its filter from "match
   nothing" to `n_customers >= 1` (`ExecMap.tsx:2049-2051`). But the
   GeoJSON on screen is **still the full-territory cell set** — the
   re-scoped `/cells` fetch hasn't returned yet — so *every* cell
   satisfies `n_customers >= 1` and **every hex gets outlined blue.**
5. A beat later the cohort-scoped `/cells` response arrives (the fetch
   deps include `focusActive`/`focusVersion`, `ExecMap.tsx:934`), the
   GeoJSON shrinks to cohort cells, and the outline collapses. → "the
   rest go away."

**The flash = the window between `focusActive` flipping true and the
cohort-scoped cells landing.** The cohort-outline layer keys off a stale
full-territory GeoJSON.

### Problem 2 — clicking one hex lights up others

The hex-click cohort definer (`focusPlugin.ts:125-139`) resolves the
click to a set of **`customer_id`s**:

```sql
-- POST /api/focus/set, body { hex: { cellId, resolution } }
SELECT DISTINCT '<sid>' AS session_id, b.customer_id, current_timestamp()
FROM dim_premise_h3 h3
JOIN bridge_account_premise b ON b.premise_id = h3.premise_id AND b.is_current
WHERE h3.h3_res<res> = h3_stringtoh3('<cellId>')
```

Then the choropleth recolors to that cohort via
`exec_map_cells.sql:110-116`:

```sql
AND (:session_id = '' OR EXISTS (
  SELECT 1 FROM app_focus_set fs
  WHERE fs.session_id = :session_id AND fs.customer_id = c.customer_id))
```

The cells are aggregated **per current premise** (`customers_in_view` is
one row per premise, `exec_map_cells.sql:53-117`). Because a customer can
hold **multiple current premises** (multi-site commercial is real — see
the `map-counting-grain` memory), a customer captured in the clicked hex
lights up **every other hex where they also have a premise**. The cohort
is customer-grained; its map footprint is not the hex you clicked.

The same customer-grained spread is baked into the **rail count** and
**Ask-the-map**:
- Group analytics cohort source (`geniePlugin.ts:735-744`) joins
  `focus_set.customer_id → bridge_account_premise (is_current)`, one row
  per (customer, premise), so the headline "current service locations"
  count *also* follows multi-site customers to their other premises.
- Genie context (`01_create_genie_space.py:180-184`,
  `geniePlugin.ts:376-385`) describes the cohort purely as
  `focus_set.customer_id`.

So Problem 2 is not a bug in one query — it's that **`app_focus_set`
throws away the spatial grain.** Every definer (hex, box, filters, Genie
SQL) is flattened to `customer_id`, and a hex is intrinsically a *place*,
not a *set of customers*.

---

## 2. Design overview

Two workstreams. **§3 (flash) is independent and low-risk — it can ship
first and alone.** §4 (spatial WYSIWYG) is the larger change and is what
actually satisfies "only the hex I clicked."

They compose cleanly: once §4 makes a single-hex cohort's footprint == the
clicked hex, the `cells-cohort-outline` and `cells-selected` layers trace
the *same* hex, and §3 ensures they appear together in one frame.

---

## 3. Workstream A — kill the flash (gate cohort visuals on ready cells)

**Principle:** the cohort outline / cohort recolor must not appear until
the GeoJSON on screen actually reflects the active cohort version.

### A1. Track which focus version the cached cells belong to

`BaseCache` currently is `{ rows, resolution }` (`ExecMap.tsx:901,904`).
Add the focus version the rows were fetched under:

```ts
type BaseCache = { rows: CellRow[]; resolution: number; focusVersion: number };
```

In the `/cells` `onData` (`ExecMap.tsx:933`), stamp it. `onData` is
captured fresh per fire (see the `useViewportFetch` contract,
`ExecMap.tsx:455-459`), so it can close over the live `focusActive` /
`focusVersion`:

```ts
onData: (rows) => setBaseCache({
  rows,
  resolution,
  focusVersion: focusActive ? focusVersion : -1,  // -1 = territory (no cohort)
}),
```

Initialize the cache's `focusVersion: -1` (`ExecMap.tsx:904`).

### A2. Derive a "cohort cells are ready" flag

```ts
// The cells currently rendered were fetched for the active cohort — safe to
// draw cohort-only visuals (outline/dim). False during the round-trip after a
// cohort change, when the GeoJSON is still the previous (territory) cell set.
const cohortCellsReady =
  focusActive && !focusPending && baseCache.focusVersion === focusVersion;
```

### A3. Gate the cohort outline on it

`cells-cohort-outline` filter (`ExecMap.tsx:2049-2051`) — swap
`focusActive` for `cohortCellsReady`:

```tsx
filter={cohortCellsReady
  ? [">=", ["to-number", ["coalesce", ["get", "n_customers"], 0]], MIN_CUSTOMERS_FOR_COLOR]
  : ["==", ["get", "h3_index"], "__none__"]}
```

Now on a hex click:
- **Frame 1:** `cells-selected` outlines just the clicked hex (unchanged,
  instant). Cohort outline is OFF (`cohortCellsReady` false during the
  round-trip). No all-blue flash.
- **When cohort cells land:** GeoJSON becomes cohort-only *and*
  `cohortCellsReady` flips true in the same commit → the recolored cells
  and their outline appear together, in one step.

### A4. (Recommended) also gate the fill's cohort treatment

The `cells-fill` recolor (`ExecMap.tsx:2000-2014`) shows the *previous*
territory cells (already colored) until the new cells arrive — so it does
not flash blue, but it does briefly show "all colored" before collapsing
to the cohort. That collapse is the user's *desired* "rest go away" step,
so leave the fill as-is; do **not** blank it during the fetch (that would
reintroduce the mid-pan clear that `baseCache` exists to prevent,
`ExecMap.tsx:894-905`). If live testing shows the collapse still reads as
two steps, the cheapest polish is a short `fill-opacity-transition`
(already 160ms, `ExecMap.tsx:2012`) — tune, don't restructure.

### A5. Verify

Local dev (`app-local-dev-boot` memory), zoomed out to the hex
choropleth. Click a single hex. Watch for: (a) no frame where >1 hex is
blue-outlined; (b) the clicked hex stays outlined the whole time; (c) the
recolor + cohort outline arrive together. Use Chrome DevTools MCP; a
`take_screenshot` right after click is the tell. Note the
`map-selection-focus-ux-design` memory caveat: synthetic browser events
can't drive real drags, but a plain hex **click** is scriptable.

---

## 4. Workstream B — make hex focus spatial (WYSIWYG)

**Goal:** a hex/box-over-hex cohort's footprint on the map AND its rail
count are exactly the selected cells — multi-site customers counted only
for the premise inside the selection.

The clean root fix is to **stop discarding the spatial grain**: make
`app_focus_set` premise-aware. Spatial definers pin the specific
`premise_id`s; customer definers (Genie SQL, attribute filters,
account-number lasso over dots) stay whole-customer. §4.6 documents a
lighter, no-schema-change alternative if the team wants to de-risk.

### 4.1 Schema — add a nullable `premise_id` to `app_focus_set`

`02_focus_set_setup.py:44-55`. New column:

```sql
CREATE TABLE IF NOT EXISTS <fq> (
  session_id  STRING    NOT NULL COMMENT '...',
  customer_id BIGINT    NOT NULL COMMENT '...',
  premise_id  BIGINT             COMMENT 'When set, this cohort row is scoped to ONE premise (spatial selection). NULL = the whole customer, all premises (query/attribute/account cohorts).',
  created_at  TIMESTAMP          COMMENT '...'
)
```

Because the table is `CREATE TABLE IF NOT EXISTS` and already deployed,
add an idempotent `ALTER TABLE ... ADD COLUMN IF NOT EXISTS premise_id
BIGINT` after the create (existing rows are ephemeral / TTL-swept per
`03_focus_set_ttl.py`, so back-fill is unnecessary). Re-run the
`app_focus_set_setup` job after deploy (`resources/app.yml:42-56`).

**Grain rule:**
- **Spatial cohort** (hex, hexes): one row per **(customer_id,
  premise_id)** for every current premise in the selected cell(s).
  `premise_id` NOT NULL.
- **Customer cohort** (sql, filters, accountNumbers, customerIds): one
  row per **customer_id** with `premise_id = NULL`, preserving today's
  behavior for those definers exactly.

`h3_stringtoh3`, `dim_premise_h3.h3_res5..9`, and `bridge_account_premise
(is_current)` already give containment at any display resolution, so a
res-7 pin still resolves correctly when the user zooms to res-8.

### 4.2 Server — populate `premise_id` for spatial definers

`focusPlugin.ts` `POST /set`. The `hex` (`:125-139`) and `hexes`
(`:140-160`) branches must project `premise_id` alongside `customer_id`:

```sql
-- hex branch (single clicked cell)
SELECT DISTINCT '<sid>' AS session_id, b.customer_id, b.premise_id, current_timestamp()
FROM dim_premise_h3 h3
JOIN bridge_account_premise b ON b.premise_id = h3.premise_id AND b.is_current
WHERE h3.h3_res<res> = h3_stringtoh3('<cellId>')
```

The other four branches (`sql` `:105-119`, `filters` `:120-124`,
`accountNumbers` `:161-176`, `customerIds` `:177-190`) project
`NULL AS premise_id`. The `INSERT ... REPLACE WHERE session_id`
(`:195`) is unchanged (still atomic per session); just ensure the column
list matches. The `VALUES` path (`:189-190`) becomes
`('<sid>', <id>, NULL, current_timestamp())`.

### 4.3 Server — premise-aware cohort predicate everywhere it's read

The single conceptual change: **"customer in cohort" → "this premise is
in the cohort."** Wherever the cohort is joined, add
`AND (fs.premise_id IS NULL OR fs.premise_id = <the premise on this row>)`.

Four read sites:

1. **Choropleth** — `exec_map_cells.sql:110-116`. The `customers_in_view`
   CTE has `premise_id` in scope (via `premises_in_view p`,
   `:27-43,75-77`; add `p.premise_id` to its select at `:57-74` if not
   already projected). Change the EXISTS to:
   ```sql
   AND (:session_id = '' OR EXISTS (
     SELECT 1 FROM app_focus_set fs
     WHERE fs.session_id = :session_id
       AND fs.customer_id = c.customer_id
       AND (fs.premise_id IS NULL OR fs.premise_id = p.premise_id)))
   ```
   → a spatial cohort lights only its own premises' hexes. Customer
   cohorts (`premise_id NULL`) are unaffected. This alone fixes the
   visible spread.

2. **Rail group analytics** — `geniePlugin.ts:735-744`. The cohort
   `source` joins `fs → bridge_account_premise b (is_current)`. Add the
   premise guard to the join/where so multi-site customers contribute
   only their in-hex premise:
   ```sql
   JOIN bridge_account_premise b
     ON b.customer_id = fs.customer_id AND b.is_current
     AND (fs.premise_id IS NULL OR fs.premise_id = b.premise_id)
   ```
   This makes the headline "current service locations" WYSIWYG. Also
   review `computeSummary` (`focusPlugin.ts:291-345`): its `cohort_count`
   (`:313-317`) and `extent` (`:323-330`) joins need the same guard, or
   the "X of N" and frame-to-fit will still reflect the customers'
   other premises.

3. **Points `in_focus`** — `geniePlugin.ts:539-541`. The dot-layer
   `LEFT JOIN app_focus_set fs ON fs.customer_id = c.customer_id AND
   fs.session_id`. The points source is per-premise
   (`:558-569`), so add
   `AND (fs.premise_id IS NULL OR fs.premise_id = <premise on the point row>)`
   to the join. Then a multi-site customer's dot is lit only at their
   in-hex premise — matching the choropleth. (Confirm the point CTE
   exposes the premise key to join on; it selects one dot per current
   premise, `:558`.)

4. **Genie / Ask-the-map** — `01_create_genie_space.py:180-184` and the
   runtime context `geniePlugin.ts:376-385`. Update the cohort
   description so Genie counts WYSIWYG: "the cohort is the premises in
   `app_focus_set` for `session_id = '...'`; join
   `focus_set.customer_id = dim_customer.customer_id` and, when
   `focus_set.premise_id IS NOT NULL`, also
   `focus_set.premise_id = bridge_account_premise.premise_id`". This is
   the least-critical site (Genie is best-effort prose + SQL) — get 1–3
   solid first; treat Genie as a follow-up if time-boxed.

### 4.4 Client — the click already carries what's needed

`onMapClick` → `writeFocus({ hex: { cellId, resolution } }, "Hex area")`
(`ExecMap.tsx:1615`) is unchanged; the resolution is snapshotted from
the on-screen grid (`effectiveResolution`, `ExecMap.tsx:1001`). Box/lasso
over hexes already sends `{ hexes, hexRes }` (`ExecMap.tsx:1082`). No
client payload change — all the grain work is server-side.

One client nicety: label the cohort **"This hex"** (or "3 hexes") instead
of the current "Hex area"/"Drawn region" (`ExecMap.tsx:1615,1082`) so the
rail eyebrow reinforces the WYSIWYG meaning. Cosmetic; optional.

### 4.5 Interaction with Workstream A

After §4, a single-hex cohort's footprint == the clicked hex. So
`cells-cohort-outline` (cohort footprint, `n_customers>=1` over the
cohort-scoped GeoJSON) and `cells-selected` (the literal clicked
`h3_index`, `ExecMap.tsx:2028`) trace the **same** cell. That's fine —
they overlay. With §3's `cohortCellsReady` gate, both the recolor and the
cohort outline show up in the same frame the cohort cells arrive, and the
`cells-selected` outline held the clicked hex in the interim. Clean
single-step reveal, no flash, no spread.

### 4.6 Lighter alternative (no schema change) — footprint intersect

If the team prefers to avoid touching `app_focus_set`'s schema and the
setup job: keep the cohort customer-grained, but pass the **hex footprint**
(cell ids + resolution) to the read routes and *intersect*. For a spatial
cohort, `/cells` additionally requires the premise's
`h3_res<res> IN (<footprint cells>)`; the rail count applies the same
intersect. This kills the visible spread with a smaller blast radius (no
DDL, no TTL/back-fill concern).

**Trade-off:** it introduces a *second* notion of "the cohort" (the
customer set in `focus_set` vs. the footprint carried alongside), which
must be kept in sync, and Genie still sees only the customer set (its
counts would still spread unless separately taught the footprint). The
premise-aware column (§4.1–4.3) is the single-source-of-truth version and
generalizes to box/lasso and Genie for free. **Recommendation:
premise-aware column** unless schema change is blocked; document this
alternative so the next session can pick with eyes open.

---

## 5. Suggested order & risk

| Step | Work | Risk | Independent? |
|------|------|------|--------------|
| A | Flash fix — `cohortCellsReady` gate (§3) | **Low** | Yes — ship alone |
| B1 | `premise_id` column + setup/ALTER (§4.1) | Low | Prereq for B2–B3 |
| B2 | Server populate + read predicates: cells, group, summary, points (§4.2–4.3.1–3) | **Medium** | After B1 |
| B3 | Genie context wording (§4.3.4) | Low | After B1; can trail |

Do **A first** (immediate visible win, no server/SQL risk). Then B1→B2.
B3 and the label cosmetic (§4.4) are trailers.

Deploy notes: B1 requires re-running the `app_focus_set_setup` job
(`resources/app.yml:42-56`) after `bundle deploy`. No new grants
(`app_focus_set` already has SELECT/MODIFY for the app SP —
`grant-permissions.sh:59-61`; the new column is covered by the
table-level grant). Confirm the app SP grants per the `app-sp-grants`
memory if data doesn't render post-deploy.

## 6. Verification (both workstreams)

Local dev against real data (`app-local-dev-boot` memory; revert the
`{{catalog}}/{{schema}}` sed before commit). Zoom out to the choropleth.

1. **No flash (A):** click a single hex → no frame with the whole
   territory outlined; clicked hex outlined throughout; recolor + outline
   land together.
2. **No spread (B):** click a hex that you know holds a multi-site
   commercial customer → only that one hex recolors/outlines; no distant
   hexes light up. Confirm by finding a customer with >1 current premise
   (`bridge_account_premise` where `is_current`, grouped by `customer_id`
   having `count(distinct premise_id) > 1`) and clicking one of their
   hexes.
3. **WYSIWYG count (B):** the rail headline for a single-hex focus equals
   the hex's own `n_customers` from the choropleth (not inflated by
   multi-site customers' other premises). Cross-check the cell's
   `n_customers` (from `/api/genie/cells`) against the rail's "current
   service locations".
4. **Customer cohorts unregressed (B):** run an attribute-filter focus
   and a Genie "show me …" answer → they still recolor across the
   territory as before (premise_id NULL path). This is the critical
   regression check — the whole point of the nullable column is that
   these are untouched.

Then run `/review` (Isaac Review) before pushing.

---

## 7. Files this touches

- `app/client/src/ExecMap.tsx` — §3 (`BaseCache` type ~901, cache init
  ~904, `/cells` onData ~933, `cohortCellsReady` new, cohort-outline
  filter ~2049); §4.4 label (~1615, ~1082).
- `app/setup/02_focus_set_setup.py` — §4.1 add `premise_id` column +
  idempotent ALTER.
- `app/server/focusPlugin.ts` — §4.2 populate `premise_id` (hex ~135,
  hexes ~156, others NULL); §4.3.2 `computeSummary` guards (~313, ~323).
- `app/server/geniePlugin.ts` — §4.3.2 group source (~735); §4.3.3
  points `in_focus` join (~539); §4.3.4 Genie context (~376).
- `app/config/queries/exec_map_cells.sql` — §4.3.1 cohort EXISTS
  (~110); ensure `p.premise_id` in `customers_in_view` (~57).
- `app/setup/01_create_genie_space.py` — §4.3.4 cohort description
  (~180).
- `resources/app.yml` — re-run `app_focus_set_setup` after deploy
  (no edit; operational note).

Remember the twin-tree gotcha: query files exist under both
`app/config/queries/` and `app/deploy/config/queries/` (see the repo
listing). Confirm which one the running app reads and keep them in sync,
per the deploy conventions.
