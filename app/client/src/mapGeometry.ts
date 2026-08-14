import { INITIAL_VIEW } from "./mapConstants";
import type { Bounds } from "./mapTypes";

// Pure map geometry helpers shared by ExplorerMap — bounds math, initial-camera
// bbox seeding, and point-in-polygon. These are pure functions with no React
// state, so they live in a plain module alongside mapConstants/mapTypes rather
// than under hooks/. The stateful onMove/onMoveEnd/onLoad and box/lasso+drill
// handlers that consume them remain in ExplorerMap; owning that state in a hook
// would first require hoisting the component's mid-body values (writeFocus,
// focusSummary, territoryBounds, dotsVisible, effectiveResolution), which is a
// scoped follow-up, not part of this module.

// ── Camera / bounds ──────────────────────────────────────────────────

// Buffered viewport fetch: grow the fetched bbox this much beyond the visible
// viewport on each side so small pans are covered by data already on hand.
export const VIEWPORT_PAD = 0.4;

export function padBounds(b: Bounds, factor: number): Bounds {
  const dLat = (b.north - b.south) * factor;
  const dLon = (b.east - b.west) * factor;
  return { south: b.south - dLat, north: b.north + dLat, west: b.west - dLon, east: b.east + dLon };
}

export function boundsContain(outer: Bounds, inner: Bounds): boolean {
  return (
    outer.south <= inner.south &&
    outer.north >= inner.north &&
    outer.west <= inner.west &&
    outer.east >= inner.east
  );
}

// Compute an approximate initial bounding box from the INITIAL_VIEW camera so
// the first warehouse request can be dispatched before the basemap style
// finishes loading. At zoom 8, one screen is roughly 3°×2° depending on
// container size.
export function initialBoundsFromView(): Bounds {
  const { latitude, longitude, zoom } = INITIAL_VIEW;
  const halfLon = (360 / Math.pow(2, zoom)) * 1.75;
  const halfLat = halfLon * 0.6;
  return padBounds(
    { south: latitude - halfLat, north: latitude + halfLat, west: longitude - halfLon, east: longitude + halfLon },
    VIEWPORT_PAD,
  );
}

// ── Selection ────────────────────────────────────────────────────────

// Ray-casting point-in-polygon. Used by onDeckClick and the box/lasso commit.
export function pointInPolygon(lng: number, lat: number, ring: [number, number][]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i][0], yi = ring[i][1];
    const xj = ring[j][0], yj = ring[j][1];
    const intersect = (yi > lat) !== (yj > lat)
      && lng < ((xj - xi) * (lat - yi)) / ((yj - yi) || 1e-12) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

// Standard orientation-based segment intersection test (no degenerate/collinear
// handling — sufficient for the convex-ish hex vs box/lasso use case).
function segmentsIntersect(
  p1: [number, number], p2: [number, number],
  p3: [number, number], p4: [number, number],
): boolean {
  function orient(a: [number, number], b: [number, number], c: [number, number]): number {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
  }
  const d1 = orient(p3, p4, p1);
  const d2 = orient(p3, p4, p2);
  const d3 = orient(p1, p2, p3);
  const d4 = orient(p1, p2, p4);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
         ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

// Overlap-inclusive intersection test for two closed rings (both [lng,lat][]).
// Returns true if the rings share any area, edge, or vertex — used to select
// hexes that a box/lasso *touches*, not just hexes whose centroid is inside.
// Three conditions (any one sufficient):
//   1. any vertex of a is inside b
//   2. any vertex of b is inside a
//   3. any edge of a crosses any edge of b
export function polygonsIntersect(a: [number, number][], b: [number, number][]): boolean {
  for (const [x, y] of a) if (pointInPolygon(x, y, b)) return true;
  for (const [x, y] of b) if (pointInPolygon(x, y, a)) return true;
  for (let i = 0; i < a.length; i++) {
    const a1 = a[i], a2 = a[(i + 1) % a.length];
    for (let j = 0; j < b.length; j++) {
      const b1 = b[j], b2 = b[(j + 1) % b.length];
      if (segmentsIntersect(a1, a2, b1, b2)) return true;
    }
  }
  return false;
}
