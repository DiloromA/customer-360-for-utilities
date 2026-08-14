// Map constants for the Explorer view: gradient color stops for numeric
// metrics, a discrete palette for the categorical complaint-theme layer, a
// zoom → H3 resolution mapping, and a basemap URL.

// Numeric gradient (low → high) for "higher = worse" metrics (complaints,
// outage minutes): a monotonic green → red ramp through warm hues only — no
// blue/cyan detour and no hue repeating, so the scale reads cleanly bad↔good.
// Each metric provides its own [min, max]; the stops are normalized internally.
export const NUMERIC_COLOR_STOPS: [number, string][] = [
  [0.0, "#22c55e"], // green  — low (good)
  [0.25, "#84cc16"], // lime
  [0.5, "#eab308"], // yellow — middle
  [0.75, "#f97316"], // orange
  [1.0, "#dc2626"], // red    — high (bad)
];

// Reverse for "higher = better" metrics (e.g. program adoption): red → green.
export const NUMERIC_COLOR_STOPS_REVERSED: [number, string][] = [
  [0.0, "#dc2626"], // red    — low (bad)
  [0.25, "#f97316"], // orange
  [0.5, "#eab308"], // yellow
  [0.75, "#84cc16"], // lime
  [1.0, "#22c55e"], // green  — high (good)
];

export const NULL_COLOR = "rgba(255, 255, 255, 0.05)";

// ────────────────────────────────────────────────────────────────────
// Program-adoption lens (binary / comparison)
// ────────────────────────────────────────────────────────────────────
//
// When a program layer is active, customer dots are NOT colored by a metric
// gradient — adoption is a binary fact. We color each dot by its adoption
// STATUS for the selected program, optionally cross-referenced against the
// DER signal the program targets (e.g. EV detected from AMI/DER data), so the
// map surfaces discrepancies: who has the device but never enrolled (the
// campaign opportunity), and who enrolled with no detected device (review).
export const PROGRAM_ADOPTION_PALETTE = {
  enrolledDetected: "#22c55e", // green  — enrolled (and detected, when comparing)
  detectedOnly:     "#f59e0b", // amber  — detected but NOT enrolled (opportunity)
  enrolledOnly:     "#a855f7", // purple — enrolled but no detected signal (review)
  neither:          "#64748b", // gray   — neither (dimmed)
};

// The human label for the DER signal a program targets, mirroring the
// program → device_type mapping the /points SQL uses. null = no DER signal
// for this program (e.g. LED discount) → plain enrolled/not-enrolled binary.
export function derLabelForProgram(programName?: string, programId?: string): string | null {
  const n = (programName || "").toLowerCase();
  const id = (programId || "").toUpperCase();
  if (id.includes("EV") || n.includes("ev ") || n.includes("electric vehicle")) return "EV";
  if (id.includes("HP") || id.includes("HPWH") || n.includes("heat pump")) return "heat pump";
  if (id.includes("TSTAT") || id.includes("BYOT") || n.includes("thermostat")) return "smart thermostat";
  if (n.includes("solar") || n.includes(" pv")) return "solar PV";
  return null;
}

// Discrete palette for complaint themes. Picked to be readable on the
// dark basemap and visually distinct from each other. Falls back to
// gray when a theme is not in the palette.
export const THEME_PALETTE: Record<string, string> = {
  // Billing
  high_bill:           "#f97316",
  late_fee:            "#ea580c",
  payment_arrangement: "#dc2626",
  // Outage / reliability
  prolonged_outage:    "#7c3aed",
  frequent_brief:      "#a855f7",
  no_estimate:         "#c084fc",
  // Service quality
  rude_agent:          "#06b6d4",
  long_hold:           "#0ea5e9",
  wrong_resolution:    "#2563eb",
  // Programs / connections
  enrollment_issue:    "#22c55e",
  rebate_delay:        "#16a34a",
  // Other / catchall
  other:               "#94a3b8",
  none:                "rgba(255,255,255,0.05)",
};
export const DEFAULT_THEME_COLOR = "#64748b";

// CSS gradient string for the legend bar.
export const NUMERIC_LEGEND_GRADIENT = NUMERIC_COLOR_STOPS
  .map(([v, c]) => `${c} ${v * 100}%`)
  .join(", ");
export const NUMERIC_LEGEND_GRADIENT_REVERSED = NUMERIC_COLOR_STOPS_REVERSED
  .map(([v, c]) => `${c} ${v * 100}%`)
  .join(", ");

// H3 resolution bounds for the choropleth (res 5 ≈ county-scale, res 9 ≈
// block-scale). Also the min/max of the user-facing density slider, which now
// pins an absolute resolution in this range.
export const HEX_RES_MIN = 5;
export const HEX_RES_MAX = 9;

// Zoom → H3 resolution. The demo territory is a Michigan county cluster. This is
// the AUTO default per zoom — deliberately on the granular side (one step finer
// than the old mapping) so the zoomed-out view isn't a handful of giant hexes.
// Used until the user pins an absolute level via the density slider.
export function h3ResolutionForZoom(zoom: number): number {
  if (zoom <= 7)  return 6;
  if (zoom <= 9)  return 7;
  if (zoom <= 11) return 8;
  return 9;
}

// Human-facing name + approximate hexagon area for each H3 resolution, so the
// density slider can show a live readout of which hex size is active (rather
// than an opaque coarse/fine offset). Areas are H3's average hexagon area at
// each resolution.
export const HEX_RES_LABELS: Record<number, { label: string; area: string }> = {
  5: { label: "Region",           area: "~250 km²" },
  6: { label: "District",         area: "~36 km²" },
  7: { label: "Neighborhood",     area: "~5 km²" },
  8: { label: "Sub-neighborhood", area: "~0.7 km²" },
  9: { label: "Block",            area: "~0.1 km²" },
};

// Describe the active resolution for the slider readout, flagging when it has
// bottomed/topped out so the user understands why dragging further is inert.
export function hexResReadout(resolution: number): string {
  const meta = HEX_RES_LABELS[resolution];
  const name = meta ? meta.label : `res ${resolution}`;
  const area = meta ? ` · ${meta.area}` : "";
  let edge = "";
  if (resolution >= HEX_RES_MAX) edge = " · finest";
  else if (resolution <= HEX_RES_MIN) edge = " · coarsest";
  return `${name} · res ${resolution}${area}${edge}`;
}

// Initial view: the demo territory (Southeast Michigan, centered on Detroit).
export const INITIAL_VIEW = {
  longitude: -83.2,
  latitude: 42.45,
  zoom: 8,
};

export const BASEMAP =
  "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json";

export const BASEMAP_LIGHT =
  "https://basemaps.cartocdn.com/gl/positron-gl-style/style.json";

// Layer metadata. Each entry describes a layer the user can pick from
// the layer selector, what property it reads, what its scale should be,
// and a one-line description for the UI.
export type LayerKind = "numeric" | "numeric_reversed" | "categorical";

export interface LayerSpec {
  id: string;
  label: string;
  kind: LayerKind;
  property: string;           // GeoJSON property to color by
  unit: string;               // "%", "min", "/1K", etc. — appended in tooltips
  unitNote?: string;          // when set, the legend shows this in the title and
                              // renders bare axis numbers (no per-tick unit)
  description: string;
  needsProgram?: boolean;     // layer requires a program_id
  goodWhenHigh?: boolean;     // for legend coloring
  subLayer?: boolean;         // reachable only as a sub-view; hidden from the dropdown
  isLiveOutage?: boolean;     // real-time "currently out of power" layer (own data path)
  // The metric is attributed to CUSTOMERS at the source and does not re-grain
  // when the master grain toggle flips (complaint events carry customer_id
  // always but premise_id only ~65% of the time — see fact_customer_complaints
  // premise attribution). The legend keeps its "per customer" framing at every
  // grain and, off customer grain, prints a note so the fixed grain reads as
  // intentional rather than a mislabel. See docs/feature-backlog.md "grain-aware
  // complaint metrics" for the deeper Option B (re-grain the numerator).
  customerAttributed?: boolean;
  // Grains this layer honestly supports. When a grain is not in this list, the
  // grain selector greys it and snap-and-remember kicks in on layer switch.
  // Absent = supports all grains (premise + customer).
  // Bucket 1 (premise-physical): ['premise', 'customer']
  // Bucket 2 (customer-native — no premise truth to recover): ['customer']
  // Bucket 3 (dual/partial): ['premise', 'customer'] (unmapped footnote covers the gap)
  supportedGrains?: ReadonlyArray<'premise' | 'customer'>;
  // How individual customer dots are colored/labelled at the "dots" tier for
  // this layer. `field` is a key of the per-customer PointRow. Absent = the
  // layer has no per-customer dot metric (dots fall back to plain attention).
  dotMetric?: { field: string; label: string; unit: string; reversed: boolean };
}

// Layers that mirror a single filter-rail dimension (payment stress,
// dissatisfaction, critical-care, LIHEAP, engagement tier, usage band) were
// removed from the picker: the filter rail is the better way to slice on those
// flags, and a choropleth of "% with flag X" duplicated it. What remains is
// the set of lenses the filters can't express — complaint volume/theme, the
// continuous outage-minutes field, and the program-adoption comparison.
//
// "Complaint volume" can be focused on a single complaint theme via the Theme
// sub-dropdown in the toolbar (see COMPLAINT_THEME_GROUPS in ExplorerMap); the
// layer's `property` is then swapped to the per-theme rate at render time.
export const LAYERS: LayerSpec[] = [
  { id: "complaints_per_1k", label: "Complaint volume",        kind: "numeric",          property: "complaints_per_1k_90d",    unit: "/1K", unitNote: "per 1,000 customers · 90d", supportedGrains: ['premise', 'customer'] as const, description: "Complaints per 1,000 customers in the last 90 days.", dotMetric: { field: "recent_complaint_count_90d", label: "Complaints", unit: "", reversed: false } },
  { id: "complaint_risk",    label: "Complaint risk (predicted)", kind: "numeric",       property: "avg_complaint_risk_pct",   unit: "%", unitNote: "predicted P(complaint · 30d) · avg %", supportedGrains: ['customer'] as const, customerAttributed: true, description: "Model-predicted probability of a complaint in the next 30 days (ml_complaint_predictor), averaged per cell. Where complaints are likely to come from next, vs. the volume layer's where they already happened.", dotMetric: { field: "complaint_risk_pct", label: "Complaint risk", unit: "%", reversed: false } },
  { id: "outage_exposure",   label: "Outage exposure",         kind: "numeric",          property: "avg_outage_min_per_customer_90d", unit: "min", supportedGrains: ['premise', 'customer'] as const, description: "Average outage minutes per customer in the last 90 days.", dotMetric: { field: "recent_outage_minutes_90d", label: "Outage minutes", unit: " min", reversed: false } },
  { id: "digital_adoption",  label: "Digital adoption",        kind: "numeric_reversed", property: "avg_digital_adoption",     unit: "/100", unitNote: "avg score · 0-100", supportedGrains: ['customer'] as const, description: "Average digital-adoption score (autopay, paperless, mobile app, portal use, EE-program participation). Higher = more digitally engaged.", goodWhenHigh: true, dotMetric: { field: "digital_adoption_score", label: "Digital adoption", unit: "/100", reversed: true } },
  { id: "program_enrolled",  label: "Program adoption",        kind: "numeric_reversed", property: "pct_enrolled",             unit: "%",         supportedGrains: ['premise', 'customer'] as const, description: "Per-customer dots colored by enrollment in the selected program, cross-referenced against the DER signal it targets (see legend). Zoomed out, a hex grid shaded by enrollment rate.", needsProgram: true, goodWhenHigh: true },
  { id: "active_outages",    label: "Active outages (live)",   kind: "numeric",          property: "pct_currently_out",        unit: "%", unitNote: "% currently out · live", supportedGrains: ['premise', 'customer'] as const, description: "Real-time OMS snapshot: which customers are without power right now. Zoomed out, a hex grid shaded by the share of customers currently out; zoomed in, each out customer is a dot and each open incident a marker with its restoration ETA.", isLiveOutage: true },
];

// ────────────────────────────────────────────────────────────────────
// Zoom-tiered rendering (deck.gl "points" mode)
// ────────────────────────────────────────────────────────────────────
//
// Two representations that read as the same thing at different altitudes:
//   • far:  a VALUE CHOROPLETH — each H3 hexagon (server-side aggregation,
//     exec_map_cells) shaded by its actual metric value on the fixed legend
//     scale, refining res5→res9 as you zoom. A hex's color is its value and
//     never shifts with zoom, so the field stays coherent.
//   • near: individual clickable customer DOTS (exec_map_points), which fade
//     in on top as the hexagons fade out.

export const CUSTOMER_DOT_RADIUS = 4; // base radius (px), scaled by attention

// Ground-scale radius (meters) for the main "customer-dots" layer only — the
// Genie-answer and live-outage dot layers stay on fixed pixels (CUSTOMER_DOT_
// RADIUS above) and are unaffected. Fixed pixels made dots occupy the same
// screen area at every zoom, so at medium zoom (~11-13, one pixel spans tens
// of meters of ground) dense neighboring premises shingled into blobs.
// Meters ~= a premise footprint (base 20 m, metric-scaled to ~40 m) and rely
// on the layer's radiusMinPixels/radiusMaxPixels clamps as guard rails: at
// zoom 12-13 dots clamp to the min (small, separated points, with the
// heatmap/hex underlay carrying the density story); at street-level zoom the
// clamp lifts and dots read about the same as before.
export const CUSTOMER_DOT_RADIUS_METERS = 20;

// Screen-space ceiling for "customer-dots" (radiusMaxPixels). Ground-scale
// radius means every dot rides this clamp from roughly zoom >= 13.5 up
// (1 px is only ~1-2 m of ground by then), so above that zoom the layer
// reads as a uniform field of CUSTOMER_DOT_MAX_PX-diameter dots. Lowered
// from 7 (too big/blobby at street-level zoom); radiusMinPixels and
// CUSTOMER_DOT_RADIUS_METERS are unchanged — the mid-zoom (12-13) look was
// tuned in polish round 2 and only bites above ~z13.5.
export const CUSTOMER_DOT_MAX_PX = 5;

// ────────────────────────────────────────────────────────────────────
// Continuous hexagon → dots cross-fade (no discrete tier switch)
// ────────────────────────────────────────────────────────────────────
//
// The value choropleth's fill/line opacity are zoom-interpolated MapLibre
// expressions (see HEX_*_OPACITY in ExplorerMap), evaluated per-frame on the GPU.
// As you zoom in the hexagons fade OUT while individual clickable DOTS fade IN
// over [DOTS_FADE_START, DOTS_FADE_END], so the hand-off reads continuously.

// Start fetching viewport points a touch before the fade window so they're
// loaded and ready to resolve in (viewport is bounded by this zoom).
export const POINTS_FETCH_ZOOM = 10.5;

// Dots are invisible at/below DOTS_FADE_START, fully opaque at/above
// DOTS_FADE_END, linear in between. DOTS_FADE_END is kept close behind the
// hexagon fade (HEX_FADE_END in ExplorerMap) so solid dots arrive right as the
// cells leave — no faint gap where neither layer is fully present.
export const DOTS_FADE_START = 11.0;
export const DOTS_FADE_END = 12.0;

// Opacity (0..1) of the customer-dot layer for a given zoom.
export function dotOpacityForZoom(zoom: number): number {
  if (zoom <= DOTS_FADE_START) return 0;
  if (zoom >= DOTS_FADE_END) return 1;
  return (zoom - DOTS_FADE_START) / (DOTS_FADE_END - DOTS_FADE_START);
}

// ────────────────────────────────────────────────────────────────────
// /points limit — flat at every zoom
// ────────────────────────────────────────────────────────────────────
//
// /api/genie/points already shows the full viewport population whenever it's
// under the requested limit (the server computes the true pre-truncation
// total and only samples above it), so the limit itself doesn't need to vary
// with zoom — it's sized by the wire, not by how bounded the viewport is.
// 35,000 keeps the JSON payload comfortably under the Statement Execution
// API's ~25 MiB INLINE disposition ceiling and the fetch interactive.
export const POINTS_LIMIT = 35000;

// ────────────────────────────────────────────────────────────────────
// Color helpers for deck.gl (which wants [r,g,b], not CSS strings)
// ────────────────────────────────────────────────────────────────────

export type RGB = [number, number, number];

export function hexToRgb(hex: string): RGB {
  const h = hex.replace("#", "");
  const full = h.length === 3 ? h.split("").map((c) => c + c).join("") : h;
  const n = parseInt(full, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

// Interpolate a numeric value to an [r,g,b] along the same gradient the
// choropleth uses, clamped to the dynamic [min, max]. Mirrors
// numericColorExpression() in ExplorerMap so grid and points modes match.
export function colorForValue(value: number, min: number, max: number, reversed: boolean): RGB {
  const stops = reversed ? NUMERIC_COLOR_STOPS_REVERSED : NUMERIC_COLOR_STOPS;
  const range = max - min || 1;
  const t = Math.max(0, Math.min(1, (value - min) / range));
  for (let i = 1; i < stops.length; i++) {
    const [t0, c0] = stops[i - 1];
    const [t1, c1] = stops[i];
    if (t <= t1) {
      const lt = (t - t0) / (t1 - t0 || 1);
      const a = hexToRgb(c0);
      const b = hexToRgb(c1);
      return [
        Math.round(lerp(a[0], b[0], lt)),
        Math.round(lerp(a[1], b[1], lt)),
        Math.round(lerp(a[2], b[2], lt)),
      ];
    }
  }
  return hexToRgb(stops[stops.length - 1][1]);
}

// Discrete RGB for a complaint theme key (categorical lens).
export function themeColorForKey(key: string): RGB {
  return hexToRgb(THEME_PALETTE[key] && THEME_PALETTE[key].startsWith("#")
    ? THEME_PALETTE[key]
    : DEFAULT_THEME_COLOR);
}

