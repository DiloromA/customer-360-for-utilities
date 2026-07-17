# Explorer polish: focus/filter desync, dot crowding, box-select flicker, "Premises" nomenclature

Four user-reported issues from live use of the Explorer map, diagnosed
2026-07-13. This doc carries the root-cause analysis and the recommended fixes
into the next session. None are started yet.

---

## Issue 1 — attribute filters survive "Clear focus" and are invisible in the top bar

### Repro (as reported)

1. Build and clear a few focus groups (any method).
2. Open **⊕ Build focus group** → section **② Pick attributes** → uncheck
   **Residential** under Customer class.
3. Close the tray (click away / Done) *without* clicking "Use 1 attribute as
   focus group".
4. The map is now genuinely narrowed to Commercial only (cells + dots), but:
   - the tray says **"No focus group yet — define one with any method below."**
   - the top bar says **Service territory** and shows **no ✕ Clear focus**
     button — there is no visible way to clear the filter from the top bar.

A second, related leak: even in the *canonical* flow (uncheck Residential →
"Use as focus" → later hit top-bar **✕ Clear focus**), the cohort is cleared
but the chips stay unchecked — so the map silently remains Commercial-only.

### Root cause: two parallel state systems that only meet in one direction

There are two independent notions of "narrowed view" in `ExplorerMap.tsx`:

| State | Where | Applied how | Cleared by |
|---|---|---|---|
| `filters: FilterState` | client state, `ExplorerMap.tsx:666` | **live** — spread into every cells/points/program query body (`filterStrings(filters)` at lines ~939, ~997, ~1018), the instant a chip is toggled | only the "Clear all" button inside tray section ② (line ~2346), or re-toggling chips |
| focus cohort (`focusSummary` / `focusActive`) | server-side `app_focus_set` row keyed by `sessionId`, summary at `ExplorerMap.tsx:703–716` | via `/api/focus/set` (`writeFocus`, line ~726) | tray "Clear" + top-bar **✕ Clear focus** → `clearFocusGroup` (line ~1778) → `clearSelection` + `resetGenie` + `clearFocus` |

Everything in the top bar — the scope label, the premise count, **Frame
focus**, **✕ Clear focus** — is gated on `focusActive` only. `nActiveFilters`
(line 668) is consulted *only inside the tray* (the "Clear all" button and the
"Use N attributes" button label/disable). So live filters with no cohort are
completely invisible at the top level, and `clearFocusGroup` never touches
`setFilters`.

Historical note: `filters` predates the focus tray — it was the standalone
"filter rail" (see the header comment in `app/client/src/filters.tsx`), which
applied live by design. When the focus tray absorbed the filter UI as method
②, the live-apply behavior came along, and now reads as "preview", but nothing
labels it and nothing above the tray owns it.

One more inconsistency the desync causes: the right-rail metrics
(`useGroupAnalytics`, line ~576) post `{}` when `focusActive` is false — they
show **whole-territory** numbers while the map shows the **filtered** subset.
So map and rail disagree whenever filters are live without a cohort.

### Design discussion

Three coherent shapes, in increasing order of change:

**A. Make section ② a draft.** Chips stop feeding the map queries directly;
they only take effect through "Use as focus". Pros: one state system, the
"No focus group yet" copy becomes true. Cons: kills the live-preview feel
(toggle a chip → map responds instantly), which is genuinely good UX while
composing a cohort; also a behavior regression for anyone using chips as a
quick view slice without wanting a named cohort.

**B. Keep live filters, but surface and unify clearing.** Filters remain a
live view slice; fix the two leaks:
1. Top bar: when `nActiveFilters > 0`, always show a filter chip (e.g.
   `⧩ 1 attribute filter ✕`) regardless of `focusActive`; its ✕ does
   `setFilters(emptyFilterState())`. The scope label can stay "Service
   territory" — the chip communicates "…but sliced".
2. `clearFocusGroup` additionally resets filters, so top-bar **✕ Clear focus**
   returns the map to the true whole-territory default (matching its tooltip:
   "metrics return to the whole territory").
3. Optional: pass `filterStrings(filters)` into `/api/genie/group` when no
   cohort is active so the rail matches the map. (Server change: the group
   analytics query would need to accept the same filter params the cells
   query does.)

**C. Unify: active filters ARE a focus group.** Debounced auto-promote —
whenever `nActiveFilters > 0`, call `writeFocus({ filters }, "N attributes")`
(~600 ms after the last toggle); when it drops to 0, `clearFocus()`. One state
system, top bar always right, rail always right, "Use as focus" button
disappears. Cons: every chip-toggle burst costs an `/api/focus/set` round trip
(INSERT … REPLACE WHERE into `app_focus_set` — not free, focus writes are the
slowest interaction in the app today); the tray's method ② stops being
composable-then-commit; and a user who wanted a *drawn* cohort *plus* an
attribute slice loses the ability to layer them (today filters and cohort
compose: the queries take both).

**Recommendation: B.** It fixes both reported leaks with small, local changes,
preserves the (intentional-looking) live-preview behavior, and preserves the
filters × cohort composition that C would remove. C is the cleaner long-term
mental model but changes semantics and adds write traffic; revisit only if the
two-concept model keeps confusing users after B ships. A is a UX regression.

### Implementation sketch (option B)

All in `app/client/src/ExplorerMap.tsx` unless noted:

1. `clearFocusGroup` (line ~1778): add `setFilters(emptyFilterState())`.
2. Top context bar (`context-actions`, line ~1861): render a filter chip when
   `nActiveFilters > 0`. Suggested placement: left of "Frame territory".
   Clicking ✕ resets filters only (not the cohort — they're independent).
   Label via `nActiveFilters`, title text listing the constrained dimensions
   would be a nice touch (`filterStrings` already normalizes).
3. Tray empty-state copy (line ~2326): when `!focusActive && nActiveFilters > 0`,
   swap the copy to make the situation legible, e.g. *"No focus group yet —
   your N attribute filters are slicing the map live; use them as a focus
   group below, or clear them."*
4. (Optional, server) `/api/genie/group` accepts filter params so the rail
   matches a filtered-but-no-cohort map. Check `app/server` route for
   `genie/group`; the SQL there needs the same 4 filter predicates as
   `exec_map_cells.sql`. If skipped, at least note the rail is
   territory-grained in the FocusPanel eyebrow.

Watch out for: the boolean-string AppKit gotcha doesn't apply here (no query
result booleans involved); `togglePartition`'s min-1 rule means `customerClass`
can never go empty, so "unchecked Residential" always leaves exactly
`{Commercial}` — `isUnconstrained` handles the full-set case already.

### Acceptance checks

- Uncheck Residential in tray, close tray → top bar shows the filter chip;
  clicking its ✕ restores the full map. No cohort involved anywhere.
- Build an attribute focus group → top-bar ✕ Clear focus → map returns to
  full territory (chips re-checked), tray shows no active filters.
- Drawn-box cohort + unchecked Residential still composes (dots outside the
  box dim; Commercial-only within).
- Rail headline count agrees with the visible map in the filtered-no-cohort
  state (if item 4 is done).

---

## Issue 2 — dots too big / crowded at medium zoom

### Report

Zoomed out to a "medium distance" (dots just fully faded in, roughly zoom
12–13), the customer dots read as oversized, overlapping blobs.

### Why now

Two compounding causes:

1. **Fixed-pixel radii.** The main `customer-dots` ScatterplotLayer
   (`ExplorerMap.tsx:1472–1537`) uses `radiusUnits: "pixels"` with base
   `CUSTOMER_DOT_RADIUS = 4` (`mapConstants.ts:200`), metric-scaled up to
   ~8 px, clamped to [1.5, 7] px. Pixel units mean a dot occupies the same
   screen area at zoom 12 as at zoom 16 — but at zoom 12 one pixel ≈ 28 m of
   ground (at this latitude), so a 5-px-radius dot covers ~280 m of street.
2. **The dense-100k redeploy** (merged 2026-07-14, `57d7278`) deliberately
   saturated contiguous areas with premises. Neighboring premises are now far
   closer together than a medium-zoom dot diameter, so dots that used to have
   air between them now shingle. The dots fade in over zoom 11→12
   (`DOTS_FADE_START`/`END`, `mapConstants.ts:219–220`), which is exactly the
   crowded regime.

### Design discussion

Two cheap mechanisms (both avoid per-frame attribute recompute):

**A. Switch the dot layer to `radiusUnits: "meters"`.** Radius then tracks
ground scale automatically; the existing `radiusMinPixels`/`radiusMaxPixels`
clamps become the guard rails. With a base of ~20 m (≈ a premise footprint)
and metric scaling to ~40 m, the progression at this latitude is:

| zoom | m/px | 20 m dot renders as |
|---|---|---|
| 12 | ~28 | 0.7 px → clamped to `radiusMinPixels` 1.5 |
| 13 | ~14 | 1.4 px → ~min clamp |
| 14 | ~7  | ~2.8 px |
| 15 | ~3.5 | ~5.7 px |
| 16 | ~1.8 | 11 px → clamped to `radiusMaxPixels` 7 |

So medium zoom gets small separated points (the heatmap/hex underlay still
carries density there — it's designed to, see the cross-fade comments at
line ~1441), and street-level zoom looks exactly like today. One-line-ish
change: `radiusUnits`, `getRadius` values ×5-ish into meters, keep clamps.

**B. Zoom-driven `radiusScale` uniform.** Keep pixel units; add
`radiusScale: f(fadeZoom)` (e.g. 0.45 at z ≤ 12.5 ramping to 1.0 at z ≥ 14.5).
`radiusScale` is a layer-level uniform exactly like the `opacity` cross-fade
(`fadeZoom` state already exists at line 838 and re-renders at 0.1-zoom
granularity), so it's equally cheap and gives hand-tuned control over the
curve.

**Recommendation: A**, with B as fallback if the meters look wrong in
practice. A is self-calibrating (dot ≈ premise footprint is a defensible
physical meaning), needs no new state, and the clamp rails are already there.
Known trade-offs to accept:

- At zoom 12–13 every dot sits at the min clamp, so the **metric-driven size
  variation compresses away** there. Fine — color still encodes the metric,
  and at those zooms the choropleth/heatmap is the intended density story.
- Same compression applies to **program mode**'s 1.5× "relevant" enlargement
  (line ~1510) and the critical-care 1.6× ring in the live-outage dots layer
  (line ~1401) — verify both still read at zoom ≥ 14, which is where users
  actually inspect individual programs/outages.
- `autoHighlight` + picking: tiny dots are harder to hover/click at zoom
  12–13. Consider leaving `radiusMinPixels` at 1.5 for rendering but bumping
  pick radius via `pickingRadius` on the DeckGL overlay if clicking feels
  fiddly (check current overlay props in `DeckOverlay.tsx`).

Out of scope but note: the **Genie answer dots** layer (line ~1338: fixed
9–13 px) has the same fixed-pixel character; a Genie cohort of thousands at
medium zoom will blob identically. Same treatment applies if it bothers —
but its dots are *meant* to pop, so leave unless reported.

### Acceptance checks

Boot the app locally (see `app-local-dev-boot` memory / `app/` README) and
screenshot at zooms 12, 13, 14, 16 over the densest county:

- Zoom 12–13: dots are distinguishable points with visible gaps over the
  heatmap glow; no shingled blobs.
- Zoom 14+: appearance ≈ today's; metric size variation and program-mode
  enlargement still legible.
- Dot click → Premise inspector still lands reliably at zoom 13 (pick radius).
- Pinned "Dots" render mode at LOW zoom (renderMode toggle) doesn't become
  invisible — dots at min clamp 1.5 px should still read against the basemap;
  if not, raise `radiusMinPixels` slightly or make the min clamp
  mode-dependent.

---

## Issue 3 — box/lasso select: dots highlight, blank out for ~1 s, then relight

### Report

Draw a box (lasso presumably identical — same code path): the dots inside
highlight instantly, then **all** dots dim/disappear for about a second, then
the selected ones come back lit and the right-rail numbers update. Reads as
three separate updates instead of one.

### Root cause: dot dimming keys off `focusActive` one fetch before the per-dot truth arrives

Timeline of a box commit over dots (`ExplorerMap.tsx`):

1. **Drag release** sets `selectionPoly` → `selectedCustomers`/`selectedIds`
   are derived client-side (lines ~1114–1123) → `getFillColor`'s
   `lit = inSel && (!focusActive || !!d.in_focus)` (line ~1487). `focusActive`
   is still false, so the client-side `selectedIds` test alone drives the
   highlight. **Instant, correct.**
2. The commit effect (line ~1144) fires
   `writeFocus({ accountNumbers }, "Drawn area")`. When `/api/focus/set`
   resolves, `focusSummary` lands → **`focusActive` flips true** and
   `focusVersion` bumps.
3. **The blank second:** `pointsCache` still holds rows fetched *without*
   `sessionId` — no row has an `in_focus` field. With `focusActive` now true,
   `lit = inSel && !!d.in_focus` is false for *every* dot, including the
   selected ones. The whole layer dims to alpha 30.
4. The points fetch re-fires (its deps include `focusActive`/`focusVersion`,
   line 948), now passing `sessionId` → rows return with `in_focus` → selected
   dots relight. Separately, `useGroupAnalytics` refetches and the rail/top-bar
   count reveals. Three visually distinct beats.

The cells layer already solves exactly this race with `cohortCellsReady`
(line ~975): `BaseCache` records the `focusVersion` its rows were fetched
under, and cohort-only visuals (outline/dim) wait until
`baseCache.focusVersion === focusVersion`. **The dots layer has no analogous
guard** — `pointsCache` is a bare `PointRow[]` with no version stamp.

### Fix: version-stamp the points cache; gate dot dimming on it

Mirror the cells pattern:

1. Extend the points cache to `{ rows: PointRow[]; focusVersion: number }`
   (`-1` = territory), stamped in `onData` the same way `setBaseCache` does
   (line ~1000): `focusActive ? focusVersion : -1`. Note `useViewportFetch`
   snapshots `resolution` at dispatch for cells — stamp the points version at
   dispatch the same way, not at arrival, or a slow response can carry a
   fresher version than its rows.
2. Derive `cohortPointsReady = focusActive && !focusPending &&
   pointsCache.focusVersion === focusVersion`.
3. In the dots layer, replace `focusActive` with `cohortPointsReady` in the
   `lit` computation (line ~1487) and in `updateTriggers.getFillColor` /
   the layer memo deps (lines ~1534, ~1549).

Resulting behavior: during the round-trip, the client-side `selectedIds`
highlight simply **persists** (the `selectionPoly` stays set, so `inSel` keeps
driving the dimming), and when the `in_focus` rows land the paint swaps to the
server truth — which for a drawn box is the *same set of accounts*, so the
swap is invisible. One continuous state, no blank frame.

This also fixes the same flash for **every other cohort definition method**
(hex click, attributes-as-focus, Genie auto-promote): today each of those has
the same one-fetch window where `focusActive` is true but no dot carries
`in_focus`, dimming the entire layer. With the guard, dots hold their previous
paint until the cohort-aware rows arrive — same "hold the last good frame"
philosophy the cells cache comments describe (line ~951).

Two lesser beats to check while in there:

- **Rail vs dots timing:** the rail count intentionally reveals with
  `useGroupAnalytics` (shared with the top bar so those two land together —
  comment at line ~571). After the fix the dots no longer blank, so the rail
  updating a beat later reads as "numbers catching up", which is fine. Don't
  try to gate the dot repaint on analytics too — that would *delay* visible
  feedback for no gain.
- **Sampled viewports:** the refetch can theoretically return a different
  attention-sample of 15k dots (`sample: "attention"`, line 940), which would
  make some unselected dots swap identity at relight time. Attention ordering
  is deterministic for a fixed viewport, so in practice the set is stable;
  if churn is ever visible, consider keeping the old rows until the new ones
  arrive (already the behavior — `onData` replaces atomically) and ignore.

### Acceptance checks

- Box-select over dots: selected dots stay lit continuously from drag-release
  through rail update — zero frames where the selection (or the layer) blanks.
- Lasso: same.
- Hex click and "Use N attributes as focus group": territory dots hold their
  current paint (no full-layer dim) until the cohort recolor lands in one step.
- Clear focus: no inverse flash (dots should relight territory-wide in one
  step — `clearFocus` bumps `focusVersion` and `focusSummary` goes null
  immediately, so `focusActive` false already restores full paint using the
  stale-but-correct cached rows; verify).

---

## Issue 4 — rename "Locations" → "Premises" (nomenclature consistency)

The rail's Count-by toggle says **"Locations"** for the premise unit, but the
entire rest of the app standardized on **"premise(s)"** back in W3 ("service
location" was renamed app-wide; `units.ts` labels the unit `premise/premises`;
the top-bar and rail counts already render "N premises" via `unitLabel`). The
toggle label is a leftover. User call: **Premises everywhere.**

User-facing strings to change (all remaining "location" copy in the client):

1. `app/client/src/ExplorerMap.tsx:2799` — the Count-by toggle:
   `"Locations"` → `"Premises"`. This is the reported one.
2. `app/client/src/ExplorerMap.tsx:2790` — the toggle's tooltip: "Count this
   focus group by service location, customer, or owner" → "…by premise,
   customer, or owner".
3. `app/client/src/App.tsx:892` — Accounts & Premises tab button:
   "Show all locations (N)" → "Show all premises (N)". (The tab itself is
   already named "Accounts & Premises"; OwnerInspector's equivalent button
   says "Light up portfolio" — leave it.)

Deliberately NOT renamed (identifiers, not copy — rename only if touching
anyway, and never the wire shape casually):

- `onShowAllLocations` prop threading (App.tsx / OwnerInspector.tsx /
  PremiseInspector.tsx) — internal identifier, harmless.
- `FocusSummary.cohortLocations` / `territoryLocations` — these come from the
  server (`/api/focus/set` response); renaming means a coordinated
  server+client change for zero user-visible gain.
- `customer_locations` analytics query name — same reasoning.

Also grep dashboards/Genie copy if ambition strikes, but the report was about
the rail; the Genie space instructions already use "premise" (serialized_space
v2 rewrite).

### Acceptance check

`grep -rn "Location" app/client/src` returns only identifiers/comments — no
user-visible strings; the toggle reads Premises / Customers / Owners.

---

## Suggested sequencing for the next session

All four changes are client-only (unless Issue 1 item 4 is taken) and
independent; do them as one branch/PR ("Explorer polish: filter visibility,
dot scaling, select flicker, Premises copy"). Suggested order: Issue 4
(trivial copy, do first), Issue 3 (the flicker — most annoying in demos),
Issue 1 option B, Issue 2, then one live browser pass over all the acceptance
checks — this app has a history of bugs that only live browser testing catches
(zoom-clamp copy-paste, `=== 0` on string counts, boolean-string). Redeploy
via the bundle with **all 4 `--var` flags** per the `deploy-target-and-clobber`
memory, and consider running /review before merging (the last two PRs shipped
un-reviewed).
