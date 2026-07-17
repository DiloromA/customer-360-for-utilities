# Flat /points limit — kill the 15k wide-view tier

## Symptom (user report, 2026-07-14)

Zoomed in, the sampling pill reads "Showing 35,000 of 99,533". Zoom out past a
certain level and it drops to "Showing 15,000 of 99,533". A wider view showing
*fewer* customers than a narrower one reads as a bug: the user expects the 35k
cap to hold at every zoom.

## Root cause (confirmed in code — no repro needed)

This is the deliberate two-tier limit from the full-density design
(`docs/map-resize-desync-dot-size-and-full-density-design.md` §3):

- `pointsLimitForZoom(zoom)` (`app/client/src/mapConstants.ts:267`) returns
  `FULL_VIEW_LIMIT` (35,000) at `zoom >= FULL_VIEW_ZOOM` (12.5), else **15,000**.
- `wantFullView` (`app/client/src/ExplorerMap.tsx:951`) exists solely to force a
  re-fetch when zoom crosses 12.5, and sits in the `/points` fetch deps
  (`ExplorerMap.tsx:984`).
- Server `POINTS_HARD_CAP = 35000` (`app/server/geniePlugin.ts:30`) clamps the
  client-supplied limit; `fetchMapPoints` (`geniePlugin.ts:524`) computes the
  true windowed total and returns `sampled`, which drives the pill
  (`ExplorerMap.tsx:2120`).

So crossing z12.5 downward legitimately re-fetches with `limit: 15000` and the
pill honestly reports the smaller sample. The mechanism works exactly as
designed — the design was wrong.

## Why the 15k tier's original rationale no longer holds

The tier was specified before the Phase-0 measurements, on the theory that a
wide-area view "can still hold far more than 35k" and should stay cheap. Every
constraint that motivated it has since been resolved or disproven:

1. **The wire cost of a 35k response is identical at every zoom.** `LIMIT`
   caps the payload; a wide viewport doesn't make the response bigger, only the
   candidate set. 35k end-to-end was measured acceptable and has been live
   since the full-density change shipped.
2. **The INLINE truncation bug is fixed.** `runStatement()` used to silently
   drop rows past the first ~28.7k-row INLINE chunk; that was found and fixed
   2026-07-14 (see memory `statement-execution-inline-chunk-truncation`). 35k
   round-trips complete and correct.
3. **Warehouse-side cost of a wide viewport barely changes with the limit.**
   The `candidates` CTE + windowed `COUNT(*)` (`geniePlugin.ts:579-590`) scans
   every in-viewport row *regardless of the limit* — a territory-wide viewport
   already scans ~100k rows today to return 15k. Raising the `LIMIT` to 35k
   only changes the top-k sort output size. No new query cost of note.
4. **Rendering was never the constraint** (deck.gl handles 100k+), and the
   "wide-area 40k dots is a smear" concern from the old doc predates the
   ground-scaled dot radii (`CUSTOMER_DOT_RADIUS_METERS`, polish round 2):
   at wide zoom dots now clamp to `radiusMinPixels`, so 35k points reads as a
   density field — which is exactly what a pinned-Dots wide view is for.

## Design: one flat limit, delete the tier

Make 35k the limit everywhere `/points` is fetched. Considered keeping 15k
only for the `wantUniformSample` (pinned-Dots, z < 10.5) path — rejected: that
path is the *most* zoomed-out view of all, so it would preserve precisely the
"zoom out → fewer dots" inconsistency being fixed, just at a different
boundary.

### Client — `app/client/src/mapConstants.ts`

- Delete `FULL_VIEW_ZOOM` and `pointsLimitForZoom()`; keep `FULL_VIEW_LIMIT`
  (rename to `POINTS_LIMIT` or similar — it's no longer "full view" specific)
  and rewrite the block comment: the limit is sized by the wire (Statement
  Execution INLINE ~25 MiB ceiling + interactive fetch), not by zoom.

### Client — `app/client/src/ExplorerMap.tsx`

- `/points` body (`:973`): `limit: POINTS_LIMIT` (constant).
- Delete `wantFullView` (`:951`) and drop it from the fetch deps (`:984`).
  **Free UX win:** today a zoom-in/out across 12.5 with unchanged bounds forces
  a full re-fetch (and a dot repaint) purely to swap limits; with a flat limit
  that re-fetch disappears.
- `wantUniformSample` stays — it switches the *sampling strategy*
  (uniform spatial hash vs attention-ranked), which is still correct and is
  orthogonal to the limit.

### Server — `app/server/geniePlugin.ts`

- `POINTS_HARD_CAP` stays 35000 (it's a clamp on client-supplied input — keep
  it). Update its comment and the default at `:156` (`Number(b.limit) || 15000`
  → `|| 35000`, or just leave the fallback; client always sends a limit).
- No query changes. The windowed-total + `sampled` semantics already do the
  right thing at any limit.

### Expected pill behavior after the change

- Wide/territory view (total ≈ 99.5k): pill shows ~35,000 of 99,533 at every
  zoom. One nuance on the **uniform** path (`geniePlugin.ts:570`): the hash
  bucket keeps ~`total / CEIL(total/limit)` rows — at 99,533 total that's
  `CEIL = 3` → ~33.2k, so the pill will read "Showing ~33,177 of 99,533"
  rather than exactly 35,000. That's inherent to deterministic hash sampling
  and fine; do not "fix" it by topping up (it would break spatial uniformity).
- Bounded views: unchanged — pill disappears once total ≤ 35k.

## Non-goals / future

- True 100k full-territory dots needs `EXTERNAL_LINKS` + chunked transport
  (payload ~30-40 MB). Out of scope; the old doc's §3.5 follow-up note stands.
- No pill copy changes.

## Verification (browser, dense-100k workspace)

1. Pinned Dots at territory zoom (~z9-10): pill ≈ 33k of 99.5k (uniform path).
2. Free zoom from z14 out to z11: pill count never *decreases* through the old
   12.5 boundary; no re-fetch fires on crossing 12.5 when bounds are unchanged
   (network tab).
3. Wide-view pan latency with the 35k limit feels ≈ today's 15k (wire payload
   is the only delta vs. the already-measured bounded 35k fetch).
4. Box/lasso select over a wide 35k view stays responsive (client
   point-in-polygon loop — was fine at 35k bounded, re-check wide).
5. Focus-cohort dimming + program lens at 35k wide (both ride the same query).

## Implementation notes

- Small, single-PR change: 2 client files + 1 server comment/fallback. Run
  `/review` before merge — the last several Explorer PRs shipped un-reviewed.
- Supersedes §3.2 of
  `docs/map-resize-desync-dot-size-and-full-density-design.md` (the zoom-tier
  design); leave that doc as-is, it records why 35k is the ceiling.
