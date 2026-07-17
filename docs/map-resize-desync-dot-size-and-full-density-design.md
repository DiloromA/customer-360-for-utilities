# Explorer map: tab-return viewport desync, dot size at high zoom, and full-density dots

**Status: DESIGN — not implemented.** Written 2026-07-14 for the next session to execute.

Three user-reported items, all in `app/client/src/ExplorerMap.tsx` and its server
counterpart `app/server/geniePlugin.ts`:

1. **BUG — viewport desync after tab round-trip.** Repro: click an individual
   customer dot on the Explorer map → navigate to Data Model (left nav) → back to
   Explorer → scroll-wheel zoom out. The map pans sideways instead of zooming
   around the cursor, and the (drilled) dot renders disconnected from the basemap.
2. **Dots too big when zoomed way in.** At street-level zoom every dot saturates
   its max-pixel clamp and reads oversized. Wanted: a bit smaller.
3. **More dots.** The dots tier truncates to a 15,000-point sample. When the
   viewport's true population is under a "reasonably viewable" threshold, show the
   full dataset, not the sample.

---

## 1. Tab-return viewport desync (the bug)

### What the code does today

- `App.tsx:422` keeps `ExplorerMap` **mounted** across nav switches and hides it
  with `display: none` (deliberate — preserves viewport, focus cohort, Genie
  conversation). While hidden, the map container box is **0×0**.
- `ExplorerMap.tsx:1705` has a `useEffect(..., [])` whose stated purpose is exactly
  this bug: attach a `ResizeObserver` to the map container and call `map.resize()`
  on every non-zero size report, to repair MapLibre's stale transform after the
  `display:none → visible` transition.
- Dots are a deck.gl `MapboxOverlay` in **interleaved** mode (`DeckOverlay.tsx`,
  attached via `useControl`), rendering into MapLibre's own canvas.

### Root cause A (confirmed by code inspection): the ResizeObserver fix is dead code

react-map-gl v8 re-exports `@vis.gl/react-maplibre`, whose `<Map>` creates the
MapLibre instance **asynchronously**:

```js
// node_modules/@vis.gl/react-maplibre/dist/components/map.js
useEffect(() => {
  Promise.resolve(mapLib || import('maplibre-gl')).then((module) => {
    ... maplibre = new Maplibre(...); setMapInstance(maplibre); ...
  });
}, []);
useImperativeHandle(ref, () => contextValue.map, [mapInstance]);
```

The instance (and therefore `mapRef.current`) only exists after a **microtask**
following the mount commit. `ExplorerMapInner`'s ResizeObserver effect has empty
deps and runs synchronously in that same commit, so:

```ts
const map = mapRef.current?.getMap();   // ← null, always, at this point
if (!map || !el) return;                 // ← early-returns; observer NEVER attached
```

The effect never re-runs (deps `[]`). **The documented resize repair has never
executed.** Any fix must re-anchor this logic to a point where the map exists —
the `onLoad` callback (`ExplorerMap.tsx:1677`) is the natural place; it already
runs post-instantiation and already does one-time map setup
(`touchZoomRotate.disableRotation()`).

### Root cause B (to confirm live): MapLibre's built-in trackResize doesn't fully heal the 0×0 round-trip

MapLibre v5 has its own container `ResizeObserver` (`trackResize: true` default):
debounced 50 ms, calls `this.resize(entries); this.redraw()`, skipping only the
initial observation. So in theory the hide (→0×0) / show (→W×H) cycle self-heals
50 ms after return — yet the desync is observed. That means either:

- the resize-from-zero path leaves something stale (transform vs. canvas buffer vs.
  pixel ratio), and/or
- the **interleaved deck overlay** caches a viewport/framebuffer across the 0-size
  frame that a plain `map.resize()` doesn't refresh (there are long-standing
  upstream reports of exactly this with `MapboxOverlay` + `display:none`), and/or
- something (a `flyTo` from the pre-hide dot click, the `NavigationControl`, the
  scroll-zoom anchor math) consumed the 0-size transform mid-animation and holds a
  corrupted camera.

The observed symptoms — wheel zoom translating the map sideways (zoom anchored at
a point that isn't under the cursor) and dots offset from the basemap — are both
classic stale-size signatures.

### Phase 0 — instrumented repro (do this first, ~15 min)

Boot the app locally (see memory `app-local-dev-boot`: env vars, token mint, the
`{{catalog}}/{{schema}}` sed gotcha) and drive it with the Chrome DevTools MCP:

1. Load Explorer, zoom to dots tier, click a dot (drill opens).
2. Nav → Data Model → back to Explorer.
3. Before touching the map, evaluate in the page:
   `const m = <map instance via window hook or React devtools>;
   ({ tW: m.transform.width, tH: m.transform.height,
      cW: m.getCanvas().width, cH: m.getCanvas().height,
      elW: m.getContainer().clientWidth, dpr: devicePixelRatio })`
   (Expose the map on `window.__c360map` in `onLoad` behind `import.meta.env.DEV`
   to make this trivial.)
4. Dispatch real wheel events over the canvas; observe whether center drifts.
5. Record which invariant is violated (transform ≠ container, canvas ≠ transform,
   or all equal ⇒ the bug is inside deck's cached viewport). This decides how much
   of Fix 3 below is needed.

### Fix design (belt and braces — all three are cheap)

**Fix 1 — stop collapsing the container (primary; kills the failure class).**
Hide the Explorer with a box-preserving technique instead of `display:none`:

```css
/* App.css */
.main { position: relative; }
.explorer-root.is-hidden {
  visibility: hidden;
  position: absolute;
  inset: 0;
  pointer-events: none;
  z-index: -1;
}
```

```tsx
// App.tsx:422
<div className={`explorer-root${nav.activeView === DEFAULT_VIEW ? "" : " is-hidden"}`}>
```

The container never becomes 0×0, so neither MapLibre nor deck ever sees a
degenerate size — no resize round-trip to get wrong. The absolute positioning
takes the hidden explorer out of flow so Data Model & co. lay out exactly as they
do today. `visibility:hidden` still culls paint; MapLibre only re-renders on
camera/data changes, so idle cost is nil. Check: window resizes **while hidden**
now propagate naturally (the box tracks `.main`), which also fixes the
"resized-while-hidden" sub-case the old comment worried about.

**Fix 2 — make the dead ResizeObserver effect real (or delete it).**
Move the observer attach into `onLoad` (map guaranteed to exist), e.g. store
`ro` in a ref, `ro.observe(map.getContainer())` there, and disconnect in a
`useEffect` cleanup. With Fix 1 in place this observer's original reason mostly
evaporates — decide at implementation time: keep it as a guard (it now also
covers drill-rail open/close reflows if those ever resize the map box), or delete
the effect and its 18-line comment so no one trusts dead code again. **Do not
leave it as-is** — a fix that silently never runs is worse than no fix.

**Fix 3 — explicit resize on tab return (cheap safety, ~5 lines).**
Thread visibility down: `<ExplorerMap visible={nav.activeView === DEFAULT_VIEW}>`
and inside, on the `false → true` edge:

```ts
useEffect(() => {
  if (!visible) return;
  requestAnimationFrame(() => mapRef.current?.getMap()?.resize());
}, [visible]);
```

Harmless with Fix 1 (resize is a no-op when dimensions are unchanged) and repairs
whatever Phase 0 shows lives beyond MapLibre's own observer (e.g. if the deck
overlay needs the `resize` event re-fired after the transition).

### Verification (browser, real mouse — synthetic events don't cover wheel anchoring)

- The exact repro: dot click → Data Model → Explorer → wheel zoom out **and** in;
  map must zoom about the cursor with no lateral drift; drill halo stays glued.
- Same round-trip via Documentation and CSAT tabs (different DOM weight).
- Resize the window **while** on Data Model, return, wheel-zoom.
- +/− NavigationControl buttons after return (the old "diagonal zoom" symptom).
- Box-select drag after return (screen→lngLat mapping uses the same transform).
- Theme toggle + drill drawer open/close after return (layout churn while visible).

---

## 2. Dots a bit smaller at high zoom

### Where the size comes from

`customer-dots` (`ExplorerMap.tsx:1505`) uses ground-scale radii:
`CUSTOMER_DOT_RADIUS_METERS = 20` (metric-scaled up to ~40 m), with screen clamps
`radiusMinPixels: 1.5`, `radiusMaxPixels: 7`. At the demo latitude (~42.45°),
1 px ≈ 1.76 m at zoom 16 — so from roughly **zoom ≥ 13.5–14.5 every dot rides the
7 px max clamp**: a uniform 14 px-diameter blob field, which is exactly the "too
big when zoomed way in" complaint (it also flattens the metric-size signal, since
small and large values clamp alike).

Related layers for consistency: `genie-dots` (pixel units, base 4 px, clamp 2–9),
`active-out-dots` (clamp 2–8), incident markers (7–36, leave alone), and the
`drill-highlight` halo (9–13, leave alone — it must stay prominent).

### Change

In `mapConstants.ts`, add one shared constant and drop the clamp:

- `CUSTOMER_DOT_MAX_PX = 5` (from 7) for `customer-dots`; try 4.5–5.5 live and
  pick by eye at zoom 14–16 in the dense-100k data.
- `genie-dots` max 9 → 7 (it renders far fewer points, can stay a touch larger).
- `active-out-dots` max 8 → 6.
- Keep `radiusMinPixels` and `CUSTOMER_DOT_RADIUS_METERS` as they are — the
  mid-zoom (12–13) look was tuned in polish round 2 (memory
  `explorer-polish-round2-plan`) and this change must not reopen dot crowding;
  the max clamp only bites above ~z13.5.
- `pickingRadius={4}` on `DeckOverlay` (`ExplorerMap.tsx:2202`) exists because
  dots clamp SMALL at mid zoom; smaller max size doesn't affect it. Leave it.

Verify in the browser at zooms 12 / 13.5 / 15 / 16, light + dark basemap, with
the complaint-volume lens (metric-scaled radii) and program lens (fixed two-size
radii) both checked.

---

## 3. Full-density dots when zoomed in ("don't sample if we can show everyone")

### What actually limits dots today (no table-level sample — good news)

- Client (`ExplorerMap.tsx:958`) always requests `limit: 15000`.
- Server `/api/genie/points` (`geniePlugin.ts:537`) clamps to **25,000** hard cap,
  computes the true pre-truncation viewport total via a windowed `COUNT(*)`, and
  returns `sampled: total > returned`. Sampling only happens when the viewport
  holds more than the limit; a zoomed-in viewport under the limit already shows
  **everyone**. The "Showing X of Y" pill (`ExplorerMap.tsx:2086`) is already
  honest about truncation.
- So the gap is purely the **size of the cap** at mid zoom with the dense-100k
  dataset (~100k premises territory-wide): entering the dots tier (~z11–12) a
  viewport can hold 40–80k customers → user sees a 15k sample and the pill.

### Constraints on raising it

- **Rendering is not the constraint.** deck.gl ScatterplotLayer handles 100k+
  points easily.
- **The wire is.** Rows are ~21 columns ≈ 300–400 B as JSON; transport is the
  Statement Execution API with `disposition: INLINE` (`dbx.ts:90`), whose inline
  result limit is ~25 MiB (verify against current docs), then a second hop
  app-server → browser as JSON. 15k ≈ 5–6 MB (today, works); ~50k ≈ 15–20 MB —
  approaching the INLINE ceiling and multi-second parse; 100k would need
  `EXTERNAL_LINKS`/chunking. There is also `wait_timeout: 30s` + a 30 s poll
  deadline in `runStatement`.

### Design: zoom-tiered adaptive limit, full data when it fits

1. **Pick the "reasonably viewable" threshold by measurement, not vibes.**
   In Phase 0's local session, time `/api/genie/points` end-to-end at limits
   15k / 30k / 40k / 50k over a dense viewport (log payload bytes + ms). Choose
   `FULL_VIEW_LIMIT` as the largest tier that stays comfortably interactive
   (target ≲ 3–4 s and ≲ 60 % of the INLINE cap; expected landing zone
   **30–40k**).
2. **Client** (`mapConstants.ts` + the `/points` fetch body): make the requested
   limit zoom-tiered instead of flat —
   `pointsLimitForZoom(zoom)`: `15000` below z12.5, `FULL_VIEW_LIMIT` at/above
   (viewport is bounded there; that's where "show me everyone" is the intent).
   Add `zoom` (or the computed limit) to the fetch effect's deps so crossing the
   tier re-fetches — same pattern as the existing `wantUniformSample` boolean
   (`ExplorerMap.tsx:936`), which exists precisely because `pointsActive` alone
   wouldn't re-fire.
3. **Server**: raise the hard cap `25000 → FULL_VIEW_LIMIT` (keep a hard cap —
   the limit is client-supplied input). No query change needed: the windowed
   total + `sampled` flag semantics already do "full data when total ≤ limit".
4. **Pill copy**: unchanged — it disappears automatically once the viewport's
   total fits, which is the user-visible proof of "I'm seeing everyone".
5. **Optional, only if measurement says 30k JSON is too slow:** slim the payload
   (the biggest strings are `complaint_risk_category`, class/band/tier enums —
   could be dictionary-encoded server-side), or move `/points` to
   `EXTERNAL_LINKS` + streaming. Write it up as a follow-up, don't build it now.

### Interactions to keep in mind

- `wantUniformSample` (pinned-Dots below `POINTS_FETCH_ZOOM`) keeps the uniform
  spatial hash sample and the **15k** tier — a wide-area forced-dots view at 40k
  points is a smear, and uniform sampling is the honest density picture there.
- Focus-cohort dimming, program lens, and complaint-theme filter all ride the
  same query — no change, but re-verify the `in_focus` dimming at the new row
  count (client-side `colorForValue` per point is O(n), fine at 40k).
- `dotScale` min/max (`ExplorerMap.tsx:1320`) iterates all rows per fetch — fine.

### Verification

- Dense downtown viewport at z12.5+: pill disappears when total ≤ limit; dot
  count matches the pill's former "of Y".
- Time-to-dots after a pan at the new limit feels acceptable (< ~4 s).
- Box-select over 30k+ dots (client point-in-polygon loop) stays responsive.
- Mid-zoom (z11–12) unchanged: still 15k attention-ranked sample + honest pill.

---

## Suggested implementation order

1. Phase 0 instrumented repro (bug facts + `/points` latency numbers in one
   local session).
2. Bug fixes 1–3 (small, independent diffs; verify with the real-mouse checklist).
3. Dot max-pixel change (one-constant diff, visual check).
4. Adaptive point limit (client tier fn + server cap + measured constant).
5. Single PR is fine; these touch disjoint code paths. Run `/review` before
   merge — the last three Explorer PRs shipped un-reviewed (see memory).
