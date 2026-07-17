# Exec Map — Selection & Focus-Group UX Fixes (Design)

Status: **Design ready, nothing implemented.** Guide for the next
session. Verified against the working tree at `c9c65fd` (ExecMap.tsx is
3064 lines; filters.tsx 135; focusPlugin.ts 369; geniePlugin.ts points
route at ~500). §5–§7 were added after a second round of live testing —
re-verified against the same tree. Trust the file:line anchors below but
re-check them after any rebase — ExecMap is large and shifts easily.

Seven asks from the user, grouped by priority. **§6 is a P0 broken-navigation
bug — do it first.**

| # | Ask | Verdict | Risk |
|---|-----|---------|------|
| 6 | Zoom/pan desync — basemap and dots diverge, buttons zoom "diagonally" | **P0 bug** — stale MapLibre container dims + no 2D camera lock | Low (resize handling + lock to 2D) |
| 5 | Attribute focus paints the whole map flat blue; legend no longer matches; "have to click to update" | **UX/data bug** — the blue footprint blankets the choropleth; cohort doesn't recolor the cells | Medium (recolor cells by cohort; retire the footprint fill) |
| 1 | Box/lasso doesn't work over H3 hexes | **Real bug** — the zoomed-out selection is a wired-up-but-dead-end feature; finish it server-side | Medium (new focus definer + server route change) |
| 4 | Focus-group builder chips are confusing ("all selected but only 2 look selected") | **UX model fix** — switch partition dimensions to "all-on-by-default, uncheck to narrow" | Low (contained to `filters.tsx` + one panel) |
| 2 | Toggle to force dots or hexes regardless of zoom | **New feature** — a 3-way render-mode control over the existing auto cross-fade | Low-medium (all rendering already keys off two derived values) |
| 3 | Too many dots to render (falls out of #2) | **New guardrail** — count-aware, honest downsampling with a "showing X of Y" pill | Medium (server sampling + client indicator) |
| 7 | "Make it snappier" — general perf/UX review | **Review** — buffered viewport fetch, drop a network hop, GPU cells (optional) | Varies |

They interlock: **#2 forces dots at low zoom, which is exactly when #3
bites**, so build #3 as part of #2. **§5 and §7 both point at retiring the
focus-footprint round-trip** — do them together. #1 and #4 are standalone.
§6 is independent and urgent.

---

## 0. Architecture recap (what these features touch)

The map has **two representations of the same data at different
altitudes**, cross-faded continuously by zoom — there is no discrete tier
switch:

- **Far — value choropleth.** H3 hexagons (`cells-fill` MapLibre layer,
  `ExecMap.tsx:1906-1949`), server-aggregated by `/api/genie/cells`,
  shaded by the active metric. Fade governed by GPU zoom expressions
  `HEX_FILL_OPACITY` / `HEX_LINE_OPACITY` (`ExecMap.tsx:321-330`) over
  `[DOTS_FADE_START=11.0, HEX_FADE_END=11.6]`.
- **Near — customer dots.** deck.gl `ScatterplotLayer` (`customer-dots`,
  `ExecMap.tsx:1369`), from `/api/genie/points`, faded in by
  `dotOpacityForZoom(fadeZoom)` over `[DOTS_FADE_START, DOTS_FADE_END=12.0]`
  (`mapConstants.ts:219-227`).

**Two derived booleans/scalars gate essentially everything:**

- `dotsVisible = zoom >= DOTS_FADE_START` (`ExecMap.tsx:754`) — settled
  zoom, so toolbars don't flicker mid-gesture. Controls: points fetch
  gate, hex-click vs dot-click routing, selection semantics, focus
  footprint, legend mode, panel hints.
- `dotOpacity = dotOpacityForZoom(fadeZoom)` (`ExecMap.tsx:1342`) — the
  per-frame dot layer opacity.

**These two are the seam every workstream cuts along.** #2 makes them
overridable; #1 keys off `dotsVisible` to decide selection meaning.

The **focus group** (cohort) is server-side, per browser session, in
`{catalog}.{schema}.app_focus_set`. It is defined via `/api/focus/set`
(`focusPlugin.ts:62`) by one of **five definers, in precedence order**:
`sql` → `filters` → `hex` → `accountNumbers` → `customerIds`
(`focusPlugin.ts:93-159`). Customer ids never round-trip the client
(19-digit BIGINT, lossy as JS number) — cohorts are always resolved
server-side. **This is the key constraint for #1.**

---

## 1. Box/lasso over hexes

### 1.1 What actually happens today (root cause)

Drawing over hexes is *half* implemented. The gesture works, the shape
renders, hexes even highlight — but nothing becomes a cohort.

Trace it:

1. Mouse handlers `onMapMouseDown/Move/Up` (`ExecMap.tsx:1561-1596`) build
   `drawPts` → commit `selectionPoly`. These fire at any zoom;
   `dragPan={selectTool === null}` (`:1893`) frees the drag for drawing.
   **Drawing works over hexes.**
2. The shape polygon renders regardless of zoom (`shapeLayer`,
   `:1345-1358`, returned even in the no-dots branch at `:1359`). **The
   box is visible over hexes.**
3. Zoomed out, `selectedHexes` computes the hexes whose centroid is inside
   the shape (`:1058-1064`) and they get an outline via
   `cells-selected-multi` (`:1941-1948`). **Hexes highlight under the box.**
4. **Dead end:** the only effect that turns a committed selection into a
   cohort (`:1044-1053`) reads `selectedCustomers`, which is derived from
   `pointsCache` (`:1027-1032`). At hex zoom `pointsCache` is **empty**
   (points aren't fetched below `POINTS_FETCH_ZOOM=10.5`). So
   `accts.length === 0` → `writeFocus` is never called. `selectedHexes`
   has **no consumer beyond the cosmetic outline.**

Net: over hexes you draw a box, see hexes light up, and then… nothing.
The rail doesn't change, no focus group forms. That's the "doesn't work"
the user sees. The panel hint even admits it — `"Zoom in first to select
individual customers"` (`:2202`) — the region path was scaffolded and
abandoned.

### 1.2 Recommended fix — a sixth focus definer: `hexes`

**Opinion: make the zoomed-out selection WYSIWYG — the cohort is exactly
the hexes you see highlighted under the shape.** We already compute them
(`selectedHexIds`, `:1064`). Send those cell ids to the server and resolve
to customers the same way the single-`hex` definer already does. This:

- reuses the proven `dim_premise_h3` + `bridge_account_premise`
  join (`focusPlugin.ts:124-128`) — no dependency on `ST_*` geospatial
  functions,
- is exact at the resolution the user is looking at,
- keeps ids server-side (satisfies the BIGINT constraint),
- makes the outline and the cohort definitionally identical (no "why did
  it grab that hex" surprises).

Rejected alternatives:
- *`polygon`/`bbox` definer with `ST_Contains`* — more "correct" for
  lasso, but adds a geospatial-function dependency we haven't verified in
  this warehouse, and the result wouldn't match the highlighted hexes.
  Skip unless we later want sub-hex precision.
- *Client-side `h3.polygonToCells`* (available, h3-js 4.4.0) to expand the
  ring into covering cells — unnecessary; `selectedHexIds` already IS the
  set the user sees. Keep `polygonToCells` in the back pocket only if we
  ever want to select cells with no rows in `baseCache` (e.g. empty
  hexes), which we don't.

### 1.3 Implementation

**Server — `focusPlugin.ts`:** add definer #4.5 (between `hex` and
`accountNumbers`, `:114`):

```ts
} else if (Array.isArray(b.hexes) && b.hexes.length > 0 && b.hexRes) {
  const hexRes = Number(b.hexRes);
  const cells = b.hexes.map((v) => String(v).trim()).filter((v) => H3_CELL_RE.test(v));
  if (cells.length === 0 || !Number.isInteger(hexRes) || hexRes < 5 || hexRes > 9) {
    res.status(400).json({ error: "Invalid 'hexes' / 'hexRes'." }); return;
  }
  if (cells.length > HEX_SET_CAP /* e.g. 4000 */) {
    res.status(400).json({ error: `Too many hexes (>${HEX_SET_CAP}); zoom out or draw smaller.` }); return;
  }
  const inList = cells.map((c) => `h3_stringtoh3('${c}')`).join(",");
  selectClause =
    `SELECT DISTINCT '${sid}' AS session_id, b.customer_id, current_timestamp() AS created_at\n` +
    `FROM ${catalog}.${schema}.dim_premise_h3 h3\n` +
    `JOIN ${catalog}.${schema}.bridge_account_premise b ON b.premise_id = h3.premise_id AND b.is_current\n` +
    `WHERE h3.h3_res${hexRes} IN (${inList})`;
}
```

Add `hexes?: string[]; hexRes?: number` to the request body type
(`:64-71`), and note the new definer in the precedence comment
(`:82-92`). Cap the IN-list (a large drawn area at res 9 could be
thousands of cells) — reject and tell the user to zoom out or draw
smaller, mirroring the existing `EXPLICIT_ID_CAP` guard style.

**Client — `writeFocus` def type** (`ExecMap.tsx:659-668`): add
`hexes?: string[]; hexRes?: number`.

**Client — split the commit effect by tier.** Replace the dead-end effect
at `:1044-1053`. Keep the polygon-identity dedupe (fires once per fresh
selection, not on pan):

```ts
useEffect(() => {
  if (!selectionPoly) { lastFocusPolyRef.current = null; return; }
  if (selectionPoly === lastFocusPolyRef.current) return;
  lastFocusPolyRef.current = selectionPoly;
  if (dotsVisible) {
    const accts = selectedCustomers.map((c) => c.account_number);
    if (accts.length > 0) writeFocus({ accountNumbers: accts }, "Drawn area");
  } else {
    const cells = selectedHexIds;
    if (cells.length > 0) {
      writeFocus({ hexes: cells, hexRes: effectiveResolution }, "Drawn region");
      setFocusCells(cells); // optimistic footprint = exactly what was outlined
    }
  }
  // eslint-disable-next-line react-hooks/exhaustive-deps
}, [selectionPoly]);
```

Note `selectedHexIds` / `effectiveResolution` are read at commit time
(the effect keys only on `selectionPoly` by design).

**Footprint refinement.** The `/api/focus/cells` effect (`:952-985`)
re-bins the cohort's customers into on-screen-resolution cells. For a
multi-hex drawn region we want the footprint to stay the drawn hexes, not
scatter to multi-premise customers' other locations. Simplest: set
`focusCells = selectedHexIds` optimistically (above) and **skip the
server refine for drawn regions** — treat it like `focusHex`, but with a
set instead of one cell. If we want zoom-refinement later, extend
`/api/focus/cells` to accept `withinCells: string[]` (parallel to the
existing `withinCell`, `:238-246`).

**Copy fixes:** update the panel hint (`:2202`) and the map select bar
(`:1866`) — the region path now works, so drop "Zoom in first". Say e.g.
"Drag to select this region's hexes" when `!dotsVisible`.

### 1.4 Edge cases / tests
- Draw over hexes → rail shows "X of N in focus", footprint = outlined
  hexes, top bar label "Drawn region". Clearing works.
- Draw over an area with sparse/empty hexes → only cells present in
  `baseCache` are grabbed (acceptable; empty cells have no customers).
- Draw, then zoom in past the fade → dots for that cohort highlight via
  the existing `in_focus` path (`:1384`). Confirm no double-fetch.
- Program/live layers: `selectedHexes` reads `baseCache.rows` only
  (`:1060`). On those layers a drawn region will use base cells. **Decide:
  acceptable, or gate region-select to the base layer.** Recommend: allow
  it (the cohort is customers, layer-independent); note it in the commit.
- Huge selection → server 400 with the cap message; surface it (today
  `writeFocus` only `console.error`s on failure, `:685-687` — consider a
  toast).

---

## 2. Force dots / force hexes toggle

### 2.1 Design

Add a 3-state control to the map toolbar: **Auto · Dots · Hexes**. Auto is
today's zoom cross-fade. Dots/Hexes pin the representation at any zoom.

Introduce one state:

```ts
const [renderMode, setRenderMode] = useState<"auto" | "dots" | "hex">("auto");
```

**Everything already keys off `dotsVisible` and `dotOpacity`.** Make both
respect the mode — that's ~90% of the work:

```ts
const dotsVisible =
  renderMode === "dots" ? true :
  renderMode === "hex"  ? false :
  zoom >= DOTS_FADE_START;                         // was :754

const dotOpacity =
  renderMode === "dots" ? 1 :
  renderMode === "hex"  ? 0 :
  dotOpacityForZoom(fadeZoom);                     // replaces the inline calls
```

Today `dotOpacityForZoom(fadeZoom)` is called inline in `deckLayers`
(`:1288`, `:1342`). Lift it to a `useMemo`'d `dotOpacity` and add
`renderMode` to the `deckLayers` dep array (`:1441-1445`).

**Hex fill/line opacity** are GPU zoom expressions (`HEX_FILL_OPACITY`
etc.). Override them by mode so hexes don't fade out when pinned, and
vanish when dots are pinned:

```ts
const hexFillOpacity =
  renderMode === "dots" ? 0 :
  renderMode === "hex"  ? (focusActive || !!focusHex ? 0.22 : 0.7) :  // flat, no fade
  ((focusActive || !!focusHex) ? HEX_FILL_OPACITY_DIM : HEX_FILL_OPACITY);
// analogous for line; feed into the paint props at :1911-1931
```

(Pull the flat constants into `mapConstants.ts` next to the fade
expressions.)

### 2.2 Points fetch gate — the coupling to #3

`pointsActive = zoom >= POINTS_FETCH_ZOOM && ...` (`:813`). Forcing dots
below zoom 10.5 must fetch points. Change to:

```ts
const wantDots = renderMode === "dots" || zoom >= POINTS_FETCH_ZOOM;
const pointsActive = wantDots && !!bounds && !layer.isLiveOutage;
```

**This is where "too many dots" becomes real:** at zoom 8 the viewport
can hold the whole ~50k territory. Do **not** ship #2 without #3. Also add
`renderMode` to the points-fetch deps (`:832`) so toggling to Dots at low
zoom triggers a fetch.

### 2.3 UI placement

Put the toggle in the `map-toolbar` (`:1768`), as a segmented control next
to the Hex-density slider. **Show the density slider whenever hexes are
visible** — today it's gated on `!genieActive && !dotsVisible` (`:1824`).
Update that to `!genieActive && (renderMode === "hex" || (renderMode === "auto" && !dotsVisible))`
so pinned-hex-at-high-zoom keeps its density control.

Hide/disable the render-mode toggle when `genieActive` or
`layer.isLiveOutage` (those own their rendering — `buildGenieLayers` /
`buildLiveLayers`, `:1248`, `:1286`). In those modes force `"auto"`.

### 2.4 Interactions to re-verify
- Hex-click focus (`onMapClick`, `:1532`) is gated `if (genieActive ||
  dotsVisible) return`. With forced dots this correctly disables hex
  clicks (dots own picking). With forced hexes at high zoom, hex clicks
  work — good.
- `interactiveLayerIds` (`:1895`) is `["cells-fill"]` when `!dotsVisible`
  — now correctly follows the overridden `dotsVisible`.
- The `#1` region-vs-customer selection branch keys off `dotsVisible` too,
  so forcing hexes at high zoom makes box/lasso grab hexes (consistent).

---

## 3. Too many dots

### 3.1 The real constraint

deck.gl renders 15k–100k+ points on the GPU without breaking a sweat. The
limits are **(a) JSON payload over the wire** and **(b) warehouse query
time**, not rendering. Today `/api/genie/points` does `ORDER BY
attention_score DESC ... LIMIT lim` (`geniePlugin.ts:547`), `lim` clamped
to 25000, default 15000 (`:518`, `:149`).

Two problems when the viewport exceeds the cap:
1. **Silent truncation.** You see the top-15k-by-attention and never learn
   there are 40k more. Fine for "who needs attention", **misleading as a
   density map** — forced-dots at low zoom would look like attention
   clusters, not population.
2. **No feedback.** The user can't tell they're looking at a sample.

### 3.2 Recommended: count-aware, honest sampling + a pill

**Opinion: keep the attention-ranked cap as the default (it's the right
bias for an exec triage tool), but (a) return the true total so we can
tell the user, and (b) when the mode is a density view, switch to a
uniform spatial sample so density reads honestly.**

**Server (`fetchViewportPoints`, `geniePlugin.ts:502-548`):**

- Return `{ customers, total, sampled }` where `total` is the unfiltered
  in-viewport count (a cheap `COUNT(*)` with the same WHERE, or a windowed
  `COUNT(*) OVER ()` piggy-backed on the main query so it's one round
  trip). `sampled = total > returnedCount`.
- Accept a `sample: "attention" | "uniform"` param (default `attention`,
  today's behavior). For `uniform`, replace the ORDER BY with a
  **deterministic** hash sample so dots don't flicker between fetches:
  ```sql
  WHERE ... AND pmod(hash(a.account_number), ${bucket}) = 0
  ```
  where `bucket = greatest(1, ceil(total / lim))`. Deterministic on
  `account_number` → stable across pans at the same density; spatially
  uniform → honest density.

**Client:**
- Send `sample: "uniform"` when `renderMode === "dots"` and
  `zoom < POINTS_FETCH_ZOOM` (i.e. a forced wide-area dot view where
  density matters); otherwise `"attention"` (triage view, zoomed in).
- Store `pointsTotal` / `pointsSampled` alongside `pointsCache`.
- Show a pill when `pointsSampled`: **"Showing 15,000 of 41,203 — zoom in
  or narrow filters to see all."** Place near the `map-loading-pip`
  (`:1776`) or as a small overlay on the map. This is the honesty
  guardrail — cheap and high-value.

**Do not** raise the hard cap much past 25k — payload/query cost grows
linearly and the marginal dot is invisible at low zoom anyway. The pill +
uniform sample is the right answer, not "render everything."

### 3.3 Optional follow-on (only if requested)
- **Client-side supercluster / deck `GridLayer` aggregation** at very low
  zoom instead of raw dots. Heavier; the hex choropleth already IS the
  aggregation tier, so forced-dots-at-low-zoom is a niche view. Skip
  unless the user wants literal clustered bubbles.

### 3.4 Tests
- Force dots at zoom 8 over full territory → pill shows "~15k of ~50k",
  dots spatially uniform (not clumped on high-attention). Pan → stable
  sample (no flicker).
- Zoom in until viewport < cap → pill disappears, all dots shown.
- Apply filters that drop the count below the cap → pill disappears.

---

## 4. Focus-group builder chip confusion

### 4.1 Root cause

`emptyFilterState()` seeds `customerClass: new Set(["Residential",
"Commercial"])` (both on "so views don't open empty",
`filters.tsx:58-66`) but leaves `usageBand`, `engagement`, `issueFlags`
**empty**. `FilterGroup` paints a chip `.active` (blue) iff
`selected.has(value)` (`:126`).

Result in the builder (`ExecMap.tsx:2146-2169`):
- **Customer class:** both chips blue (set is pre-filled).
- **Usage / Engagement / Issue flags:** *no* chips blue (empty sets).

But **empty set = no constraint = everyone** (`filterStrings`,
`:99-108`). So the map shows the whole territory while the UI implies only
Residential+Commercial are chosen and nothing else. That's the
contradiction the user hit: "blue as if selected, others not, yet the
whole territory is selected."

### 4.2 The design decision that matters

The user wants: **all chips blue by default (= everyone), uncheck to
remove subsets.** That's the right model — *but only for dimensions that
partition the population.* There are two kinds of dimension here, and they
must behave differently:

| Dimension | Kind | Every customer has exactly one? | "All on = everyone"? |
|---|---|---|---|
| Customer class (Res/Com) | **Partition** | Yes | ✅ makes sense |
| Usage band (low/med/high) | **Partition** | Yes | ✅ |
| Engagement (high/med/low) | **Partition** | Yes | ✅ |
| Issue flags (payment stress, churn, …) | **Additive/opt-in** | No — 0..many, most have none | ❌ **"all on" would EXCLUDE healthy customers** |

**Opinion: apply the "all-on, uncheck-to-narrow" model to the three
partition dimensions. Leave Issue flags as opt-in (none-on-by-default,
select to require), and visually mark it as different.** Making issue
flags "all on by default" is a trap: it reads as "everyone" but the SQL is
"has ≥1 of these flags", which silently drops every unflagged customer —
the opposite of what the blue implies. Keep it additive and label it
clearly (it already says "Issue flags (any)", `:2165`).

### 4.3 Implementation — partition dimensions

**`filters.tsx`:**

1. Default all partition dims to their **full** set:
   ```ts
   export function emptyFilterState(): FilterState {
     return {
       customerClass: new Set(CUSTOMER_CLASS_OPTIONS.map(o => o.value)),
       usageBand:     new Set(USAGE_BAND_OPTIONS.map(o => o.value)),
       engagement:    new Set(ENGAGEMENT_OPTIONS.map(o => o.value)),
       issueFlags:    new Set(),   // opt-in, unchanged
     };
   }
   ```
2. `filterStrings` / `filterSqlParams` already normalize customer class
   "empty OR full → no constraint" (`:87-88`, `:100-101`). **Extend that
   same rule to usageBand and engagement** so full = no filter (keeps
   `activeFilterCount` at 0 when unconstrained, and the SQL clean):
   ```ts
   const norm = (set: Set<string>, opts: FilterOption[]) =>
     (set.size === 0 || set.size === opts.length) ? "" : Array.from(set).join(",");
   ```
   Apply to customer/usage/engagement; issue flags stays a plain join.
3. `activeFilterCount` (`:75-82`): count a partition dim as active only
   when it's a strict non-empty subset (same `allX` test, generalized).

**Interaction guard — the "deselect the last one" trap.** With
"empty = all", unchecking chips down to zero would flip the whole group
back to blue ("all"), which is jarring (especially the 2-option class:
uncheck Res → only Com; uncheck Com → both blue again). **Opinion:
forbid the empty partition** — the last remaining chip in a partition
can't be unchecked (min 1 selected). Implement in the toggle handler used
by the partition groups:

```ts
function togglePartition(set: Set<string>, value: string): Set<string> {
  const next = toggleSet(set, value);
  return next.size === 0 ? set : next;   // never allow empty; ignore the last uncheck
}
```

Wire the three partition `FilterGroup`s (`ExecMap.tsx:2146-2163`) to
`togglePartition`; leave issue flags on plain `toggleSet` (`:2167`).

Because the default is now the full set, the visual "chip active iff
`selected.has(value)`" (`filters.tsx:126`) already yields **all-blue by
default, uncheck to narrow** — no change to `FilterGroup`'s render for the
partition groups.

### 4.4 Visually separate issue flags

Since issue flags keep opt-in semantics, make that legible so the mixed
model doesn't reconfuse:
- Keep the "(any)" in the label, and consider a one-line helper: "Add a
  flag to require it — none = no restriction."
- Optional: a subtle style difference (e.g. issue-flag pills use a
  different accent when active) so "these are additive requirements" reads
  differently from "these are the population slices you kept."

### 4.5 Ripple checks
- `App.tsx` imports only `localityText` from `filters` (`App.tsx:6`) — the
  customer-search view does **not** use `emptyFilterState`/`FilterGroup`,
  so this change is contained to the Exec map. Confirmed at `c9c65fd`.
- `applyFiltersAsFocus` (`:715-718`) uses `activeFilterCount` for its
  label and `filterStrings` for the predicate — both go through the
  normalization above, so "all on" correctly means "territory" (button
  stays disabled at 0 active, `:2174`).
- Server `hasAnyFilter` (`focusPlugin.ts:49-52`) treats empty strings as
  "no filter" — matches the normalized full→"" output. Good.

---

## 5. Attribute focus paints the map flat blue (recolor by cohort instead)

### 5.1 What the user saw
Pick attribute chips → "Use 2 attributes as focus group" → **the whole map
turns flat blue**, but the legend still shows the complaints green→red
scale, and nothing seems to react until you *click on the map* (which
actually clears the focus). Their instinct — "I'd expect the hexes to
recolor based on the selection" — is exactly right.

### 5.2 Root cause
Two separate things collide:

1. **The blue is the focus *footprint overlay*** — `focus-cells-fill`
   painted at `FOCUS_HEX_FILL_OPACITY` (`ExecMap.tsx:1955-1973`), fed by
   `focusCells` from `/api/focus/cells`. Its job is to show *where* a
   sparse cohort is. But an attribute cohort ("high usage", "payment
   stress") is spread across the **entire territory**, so the footprint
   covers **every** cell → flat blue. Meanwhile the base choropleth is
   dimmed to `HEX_FILL_OPACITY_DIM` (`:1920`), so the real metric colors
   are all but invisible under the blue.
2. **The choropleth never re-fetches on a focus change.** The `/cells`
   effect deps are `[bounds, resolution, filters, effectiveComplaintTheme,
   layer.isLiveOutage]` (`:867`) — **no `focusVersion`, no `sessionId`.**
   So defining a focus does nothing to the cells; only a later pan/zoom
   (bounds change) re-queries. That's the "have to click to update" —
   any map interaction triggers a bounds refetch, and clicking empty
   choropleth *clears* the focus (`onMapClick`, `:1540-1546`), which is
   why it "fixed" itself.

Note the base cells *do* already filter by the attribute predicate
(`filterStrings(filters)` is in the `/cells` body, `:865`) — so the
underlying choropleth is *already correct* for an attribute filter. The
flat-blue footprint is just **hiding a choropleth that was right all
along.**

### 5.3 Recommended design — recolor cells by cohort + a thin cohort outline

**Opinion (decided): make the active focus group *recolor the choropleth*
to cohort-only aggregates, replace the flat-blue footprint fill with a
*thin accent outline* on the cohort cells.** Recolor answers "how much";
the outline gives a crisp "this is your selection" edge and keeps
pale-metric cohort cells legible on the dark basemap. This is what the
user expects, keeps the legend valid, and unifies every cohort type:

- **Pass `sessionId` to `/api/genie/cells` when `focusActive`.** Server
  adds a `JOIN app_focus_set fs ON fs.customer_id = ... AND fs.session_id
  = '<sid>'` to `fetchMapCells` (`geniePlugin.ts:161`, SQL builder
  downstream), so each cell's metric is computed over **only the cohort's
  customers**. Cells with no cohort members fall through the existing
  low-n gray guard (`MIN_CUSTOMERS_FOR_COLOR`, `ExecMap.tsx:294`) → they
  go transparent.
- **Result:** the colored cells *are* the cohort's footprint (only cohort
  cells light up) **and** they carry the real metric value on the
  legend's scale. "Where" and "how much" in one layer. This **supersedes**
  the separate blue footprint overlay.
- **Draw the thin outline from the SAME recolored source — no extra
  round-trip.** Because the `/cells` response is now cohort-only, every
  returned cell with `n_customers >= MIN_CUSTOMERS_FOR_COLOR` *is* a cohort
  cell. So add one accent line layer on the existing `cells` source
  (`:1907`), filtered to those cells — e.g. `["==", ["get","h3_index"],
  …]` replaced by a `>=` filter on `n_customers`, painted a thin bright
  accent (`#4f8ff7`, width ~1.2, opacity ~0.9). This gives the cohort edge
  **without** the `/api/focus/cells` fetch.
- **Retire `focusCells` / `focus-cells-*` fill layers, the base-dim, and
  the `/api/focus/cells` effect.** Delete the footprint fill `Source`/
  `Layer`s (`:1955-1973`), the `focusCells` state + the
  `/api/focus/cells` effect (`:948-985`), and the `HEX_FILL_OPACITY_DIM`
  dim path (`:1920`) — the base choropleth stays at full opacity because it
  now *is* the cohort view. **This removes a whole server round-trip per
  focus change (see §7-C).** (The outline replaces the fill; it does not
  bring the round-trip back — it reads the cells we already fetched.)
- **Add `focusVersion` + `sessionId` to the `/cells` deps** (`:867`) so the
  choropleth re-queries the instant the cohort changes — no click needed.

Not worth it: dissolving the per-cell borders into a single outer cohort
boundary (needs a turf/union pass). The per-cell accent outline reads fine
and is a one-line-layer change.

### 5.4 Interaction with §1 (drawn regions) and hex-click
- Drawn region / hex-click cohorts are spatially confined, so cohort-only
  coloring naturally shows just those cells lit — better than today's
  optimistic single-cell footprint, and the §5.3 accent outline traces
  exactly the drawn/clicked cells. §1's `setFocusCells(...)` optimistic
  paint becomes unnecessary once cells recolor by cohort; the outline of
  *selected* hexes (`cells-selected-multi`, `:1941`) still gives instant
  pre-commit feedback *before* the cohort round-trip resolves.
- Sequencing note: §5 removes `focusCells`, and §1's commit effect
  originally set it optimistically — when doing §1 after §5 (the
  recommended order, §8), drop that `setFocusCells(cells)` line from the
  §1.3 sketch; the recolor + accent outline cover it.
- The dots tier is unaffected — dots already recolor via `in_focus`
  dimming (`:1384`); this section is purely the hex tier.

### 5.5 Tests
- Apply "high usage" attributes as focus → choropleth **immediately**
  recolors to complaint intensity among high-usage customers; cells with
  no high-usage customers go transparent; a thin accent outline traces the
  lit cells; legend still valid. No flat blue, no click.
- Draw a region → only those cells stay colored (cohort-only) and outlined,
  rest transparent.
- Clear focus → full-territory choropleth returns; outline gone.

---

## 6. P0 — Zoom/pan desync & "diagonal" zoom

### 6.1 Symptom
Start zoomed in; zoom out → the **dots** track one camera while the
**basemap** (streets/towns) pans sideways and zooms on a *different*
camera; then the +/- buttons zoom **diagonally**, making navigation
impossible.

### 6.2 Root cause — stale MapLibre container dimensions (+ no 2D lock)
This is the classic signature of **MapLibre holding stale canvas
dimensions while deck.gl uses the real ones**:

- The Exec map is kept mounted but **hidden with `display:none`** when you
  navigate to another tab (`App.tsx:398-401` — deliberate, to preserve
  viewport/focus state). A `display:none` element is `0×0`, and
  **`ResizeObserver` does not report size changes for a hidden element**.
  So if the window is resized (or any layout shifts) while the map is on
  another tab, MapLibre never learns its new size. On return it renders
  with **stale width/height**.
- With wrong dimensions, MapLibre's transform puts "screen center" at the
  wrong pixel → the +/- buttons (which zoom about center) zoom toward the
  *actual* off-center point → **diagonal drift**.
- **deck.gl (`MapboxOverlay`, interleaved) recomputes its viewport from
  the true canvas size each frame**, so the dots render on the correct
  camera while the basemap renders on the stale one → the two **visibly
  diverge** during the gesture. (Interleaved *shares* the GL context but
  each still reads viewport dims; a size mismatch desyncs them.)
- Compounding it: the map has **no 2D lock**. `dragRotate`,
  `touchZoomRotate` (rotation), and `touchPitch`/`pitchWithRotate` are all
  **on by default**, and `NavigationControl` uses `visualizePitch`
  (`ExecMap.tsx:1898`). On a Mac trackpad a sloppy pinch easily adds
  **bearing/pitch**, which independently produces "diagonal zoom" and a
  perspective that bunches far dots together while the basemap tilts —
  matching the user's "dots get closer together but streets pan away."

### 6.3 Fix — two changes, both best practice

**A. Keep MapLibre's size honest (the actual bug).** Attach a
`ResizeObserver` to the map container that calls `map.resize()` whenever it
has a non-zero size — this fires on the `display:none → visible`
transition (0 → real), catching both the tab-return and
window-resized-while-hidden cases. Self-contained in `ExecMap`:

```ts
useEffect(() => {
  const map = mapRef.current?.getMap();
  const el = map?.getContainer();
  if (!map || !el) return;
  const ro = new ResizeObserver(() => {
    // Only resize when actually visible; a 0×0 (hidden) box is a no-op.
    if (el.clientWidth > 0 && el.clientHeight > 0) map.resize();
  });
  ro.observe(el);
  return () => ro.disconnect();
}, []);
```

Belt-and-braces: also `map.resize()` when the Exec view becomes active
again. Simplest is to pass a `visible` prop from `App.tsx` (true when
`activeView === DEFAULT_VIEW`) and `map.resize()` on the `false→true`
edge; the ResizeObserver alone likely suffices, but the explicit call
removes any doubt about a missed transition.

**B. Lock the camera to 2D north-up (predictable navigation).** A
choropleth/dot analytics map has no use for tilt or rotation, and both are
pure footguns here. On `<Map>` (`:1882`):

```tsx
dragRotate={false}
touchZoomRotate={true}      // keep pinch-zoom …
touchPitch={false}          // … but no tilt
pitchWithRotate={false}
maxPitch={0}
minZoom={6}                 // don't let the world shrink to a dot
maxZoom={16}                // don't over-zoom past dot usefulness
```

and drop `visualizePitch` from `NavigationControl` (or
`showCompass={false}`) so there's no rotate/pitch affordance. To also kill
trackpad-rotate: `mapRef.current?.getMap().touchZoomRotate.disableRotation()`
in `onLoad`.

### 6.4 Verify best-practice integration (research summary)
Cross-checked against deck.gl's official
[Using with MapLibre](https://deck.gl/docs/developer-guide/base-maps/using-with-maplibre)
guide and the [`MapboxOverlay`](https://deck.gl/docs/api-reference/mapbox/mapbox-overlay)
reference. The current setup is already on the recommended path:
- **`interleaved: true`** via `MapboxOverlay` mounted as an `IControl`
  through `useControl` (`DeckOverlay.tsx:15-18`) — this is the documented
  react-map-gl + MapLibre pattern. ✅ (requires WebGL2 + maplibre-gl@>3;
  we're on 5.24. ✅)
- **`interleaved` is a constructor-only option** — set once in the
  `useControl` factory, `layers`/handlers updated via `setProps` each
  render. Current code does exactly this. ✅ Don't try to toggle
  `interleaved` via props; it won't take.
- **Uncontrolled camera** — `initialViewState` only, no controlled
  `viewState`/`longitude`/`zoom` props (`:1884`). Good: a single camera
  owner (MapLibre) with deck following is correct and avoids a
  controlled/uncontrolled fight. The desync is *dimensions*, not two
  camera owners.

Known upstream lag reports
([deck.gl discussion #9586](https://github.com/visgl/deck.gl/discussions/9586),
[@deck.gl/mapbox v9 tracker #8541](https://github.com/visgl/deck.gl/issues/8541))
are mostly about **overlaid** (`interleaved:false`) mode drawing a frame
behind. We're interleaved, so that class doesn't apply — reinforcing that
our divergence is the stale-dimensions issue, not overlay lag.

### 6.5 Tests
- Navigate to another tab, resize the window, return → basemap fills the
  container; +/- buttons zoom straight to/from center; dots and streets
  stay locked together.
- Trackpad pinch → zoom only, never rotate/tilt. Compass affordance gone.
- Zoom to min/max clamps — no zooming into the void.

---

## 7. "Make it snappier" — perf/UX review

Grounded findings, most-impactful first. (A) is also the §6 fix; (B) and
(C) are the highest-value new wins.

**A. Lock 2D + honest resize (§6).** Beyond fixing the bug, removing
rotate/pitch makes every gesture land where the user expects — the single
biggest "feels broken vs. feels solid" lever.

**B. Buffered viewport fetch (kills blank-on-pan + cuts server calls).**
Today every `onMoveEnd` sets `bounds` to the *exact* viewport, and each
`useViewportFetch` refires (`ExecMap.tsx:859-907`) — so even a tiny pan
re-queries the warehouse and the map edges briefly blank until it returns.
Fix: fetch a **padded bbox** (viewport grown ~30–50%) and **skip the
refetch when the new viewport is still inside the last fetched bbox**.
Keep the last fetched bbox in a ref; in `onMoveEnd`, only update `bounds`
(→ trigger a fetch) when the new viewport escapes it. Result: small pans
reuse loaded data instantly, no edge pop-in, far fewer queries. This is
the classic slippy-map pattern and the biggest perceived-latency win.

**C. Drop the focus-footprint round-trip (§5).** Retiring
`/api/focus/cells` removes a **second** server hop that currently fires
after every `/api/focus/set` (`focusPlugin.ts:218`, effect
`ExecMap.tsx:948-985`). Recoloring cells by cohort (§5.3) folds "where the
cohort is" into the choropleth query the map already runs → one fewer
network dependency on every focus change → focus feels instant.

**D. Camera zoom clamps (§6.3B).** `minZoom`/`maxZoom` stop the two
gestures that produce the most "lost" moments (world shrinks to a speck /
over-zoom into empty tiles).

**E. Optional, last-resort — draw the hexes with deck.gl instead of
MapLibre.** *Read this before reaching for it — it's easy to over-read.*

*What it is, plainly:* this is purely a **client-side rendering** choice —
which browser library draws the hexagons. It is **not a Databricks
concern**, and **"GPU" here means the end user's browser GPU (WebGL), not
Databricks compute.** The Databricks side (H3 aggregation via
`h3_stringtoh3` / `h3_res5..9` in the `/cells` SQL) is already idiomatic
and **stays exactly as-is** regardless of this item.

*The observation:* the app draws hexes and dots two different ways. Dots
already go through **deck.gl** (`ScatterplotLayer`) straight from raw rows.
Hexes instead go through **MapLibre as a GeoJSON source** — the server's
`{h3_index, metric}` rows are converted to GeoJSON polygons by
`cellsToGeoJSON` (`:260-286`) and handed to MapLibre (`Source` at
`:1907`). At fine H3 res a viewport holds 20k+ polygons, so each fetch is a
real CPU build + MapLibre source diff.

*The option:* deck.gl's `H3HexagonLayer` (a deck.gl layer — nothing to do
with Databricks) renders hexagons directly from the `{h3_index, value}`
rows, skipping the GeoJSON build, and would unify hexes + dots under one
deck pipeline.

*Why it's last-resort, not recommended:* it's a **bigger refactor** — the
hex fade and the §5 cohort recolor are currently MapLibre paint
expressions and would have to be re-expressed as deck.gl accessors. Do
**A–D first**; they're where the real wins are. Only consider E if fine-res
hex updates are still visibly janky after A–D, and treat it as a
standalone spike, not part of any other workstream.

**F. Minor.** `reuseMaps` on `<Map>` avoids re-initializing the GL context
if the map ever *does* unmount; keep the current `display:none` mounting
(it already preserves state) but the flag is cheap insurance.

Non-goals for snappiness: don't add client-side clustering (the hex tier
is the aggregation), and don't switch fetch-on-moveEnd to
fetch-on-every-frame — the buffered bbox (B) is the right lever, not more
frequent queries.

---

## 8. Suggested sequencing

1. **§6 (P0 zoom/pan bug)** — broken navigation; ship first, standalone.
2. **§4 (chips)** — smallest self-contained UX win.
3. **§5 (recolor cells by cohort) + §7-C (drop footprint hop)** — same
   change; do together.
4. **§1 (box/lasso over hexes)** — builds cleanly on §5's cohort coloring.
5. **§7-B (buffered viewport fetch)** — independent perf win, any time.
6. **§3 (too-many-dots sampling + pill)** — prerequisite for §2.
7. **§2 (render-mode toggle)** — lands on top of §3.

§6, §4, §7-B are mutually independent. §5 should precede §1.

## 9. Non-goals (don't scope-creep)
- No `ST_*` geospatial polygon precision for lasso — hex-granular
  selection is the intended model (§1.2).
- No client-side clustering/supercluster (§3.3, §7) — the hex choropleth
  is already the aggregation tier.
- No change to the Genie-answer or live-outage rendering paths — those own
  their layers and force `renderMode = "auto"`.
- No persistence of `renderMode` across sessions (local component state is
  fine).
- No map tilt/rotation — locked out on purpose (§6.3B).
- No move to deck.gl for the choropleth unless §7-B/D fall short (§7-E).

## 10. Manual test pass (in the running app)
Run the app locally against real data (see the `app-local-dev-boot`
memory), then:
1. **§6:** switch tabs, resize window, return → basemap fills container,
   +/- zoom straight to center, dots+streets locked together; trackpad
   pinch never rotates/tilts.
2. **§4:** Focus builder → all class/usage/engagement chips blue, issue
   flags empty; "0 attributes" → button disabled. Uncheck one usage chip →
   narrows; try to uncheck all → last one sticks.
3. **§5:** apply "high usage" as focus → choropleth recolors immediately
   (no click) to cohort-only complaint intensity; empty cells transparent;
   legend still valid; no flat-blue blanket.
4. **§1:** zoomed-out hex view, Build focus → Box → drag → rail shows a
   cohort, only the drawn cells stay colored.
5. **§7-B:** small pans don't blank the map edges or spam the warehouse
   (watch the network tab / loading pip).
6. **§2/§3:** Dots at zoom 8 → dots appear, "showing X of Y" pill, uniform
   spread; pan → stable. Hexes at zoom 13 → hexes stay, density slider
   available. Genie/live-outage → render-mode toggle hidden.
