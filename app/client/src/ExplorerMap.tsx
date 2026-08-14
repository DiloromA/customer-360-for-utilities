import { useState, useMemo, useCallback, useRef, useEffect, Component, type ReactNode } from "react";
import Map, {
  Source,
  Layer,
  NavigationControl,
  ScaleControl,
  type MapRef,
  type ViewStateChangeEvent,
  type MapLayerMouseEvent,
} from "react-map-gl/maplibre";
import "maplibre-gl/dist/maplibre-gl.css";
import { cellToBoundary } from "h3-js";
import { ScatterplotLayer, PolygonLayer } from "@deck.gl/layers";
import { useC360Query } from "./queryUtils";
import { sql } from "@databricks/appkit-ui/js";
import { rows } from "./queryUtils";
import { LineChart, Line, ResponsiveContainer } from "recharts";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { DeckOverlay } from "./DeckOverlay";
import { formatUnitCount, unitLabel, type CountUnit } from "./units";
import { PremiseDrillCard, shortId, type InspectorSubject } from "./PremiseInspector";
import type { Grain } from "./subject";
import {
  CUSTOMER_CLASS_OPTIONS,
  USAGE_BAND_OPTIONS,
  ENGAGEMENT_OPTIONS,
  ISSUE_FLAG_OPTIONS,
  type FilterState,
  emptyFilterState,
  toggleSet,
  togglePartition,
  activeFilterCount,
  filterStrings,
  localityText,
  FilterGroup,
} from "./filters";
import {
  BASEMAP,
  INITIAL_VIEW,
  LAYERS,
  NUMERIC_COLOR_STOPS,
  NUMERIC_COLOR_STOPS_REVERSED,
  NUMERIC_LEGEND_GRADIENT,
  NUMERIC_LEGEND_GRADIENT_REVERSED,
  NULL_COLOR,
  THEME_PALETTE,
  DEFAULT_THEME_COLOR,
  h3ResolutionForZoom,
  hexResReadout,
  HEX_RES_MIN,
  HEX_RES_MAX,
  colorForValue,
  CUSTOMER_DOT_RADIUS,
  CUSTOMER_DOT_RADIUS_METERS,
  CUSTOMER_DOT_MAX_PX,
  POINTS_FETCH_ZOOM,
  POINTS_LIMIT,
  DOTS_FADE_START,
  DOTS_FADE_END,
  dotOpacityForZoom,
  PROGRAM_ADOPTION_PALETTE,
  derLabelForProgram,
  hexToRgb,
  type LayerSpec,
  type RGB,
} from "./mapConstants";
import type { CellRow, ProgramCellRow, ActiveOutageCellRow, ActiveOutagePointRow, PointRow, Bounds, FocusSummary } from "./mapTypes";
import { useViewportFetch, perfMark, perfMeasure } from "./hooks/useViewportFetch";
import { padBounds, boundsContain, initialBoundsFromView, VIEWPORT_PAD, pointInPolygon, polygonsIntersect } from "./mapGeometry";
import { CustomerDrillPanel } from "./rail/CustomerDrillPanel";

// ────────────────────────────────────────────────────────────────────
// Types (shared types imported from mapTypes.ts; local-only types below)
// ────────────────────────────────────────────────────────────────────

interface ProgramRow {
  program_id: string;
  program_name: string;
  program_type: string;
  customer_segment: string;
  rebate_amount_usd: number;
  avg_annual_kwh_saved: number;
  n_enrolled: number;
}

interface ActiveOutageIncidentRow {
  active_outage_id: string;
  circuit_id: number;
  centroid_lat: number;
  centroid_lon: number;
  cause_code: string;
  weather_category: string;
  crew_status: string;
  n_customers_out: number;
  n_critical_care_out: number;
  started_at: string;
  minutes_out_so_far: number;
  estimated_restoration_at: string;
  eta_minutes: number;
  is_major_event_day: boolean;
}

interface TerritoryRow { min_lat: number; max_lat: number; min_lon: number; max_lon: number; }


// Stable empty array so `genieCustomers` keeps a constant reference when no
// Genie filter is active (avoids needless deck layer rebuilds).
const EMPTY_ROWS: PointRow[] = [];

// Starter prompts for the empty chat state — mirrors the Genie space's own
// SAMPLE_QUESTIONS (app/setup/01_create_genie_space.py) so the two surfaces
// stay consistent.
const ASK_MAP_EXAMPLES = [
  "Show me the customers who complain about high bills",
  "Which customers are payment-stressed and have filed 2 or more complaints in the last 90 days?",
  "How many critical-care customers had more than 4 hours of outages in the last 90 days?",
];

// One turn of the "Ask the map" conversation: the question, and — once it
// resolves — Genie's answer, which can be a text narrative, a result table,
// and/or a matched customer set (rendered as dots + listed in the right rail).
interface GenieTurn {
  id: number;
  question: string;
  status: "thinking" | "done" | "error";
  text?: string;
  columns?: string[];
  rows?: (string | null)[][];
  customers?: PointRow[];
  count?: number;
  // Genie hit its row cap (GENIE_ROW_CAP) before returning all matches — the
  // answer is a partial sample, not the full match set.
  truncated?: boolean;
  error?: string;
}

// ────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────

// padBounds, boundsContain imported from ./mapGeometry

function h3ToPolygon(h3Index: string) {
  const boundary = cellToBoundary(h3Index);
  const ring = boundary.map(([lat, lng]) => [lng, lat]);
  ring.push(ring[0]);
  return { type: "Polygon" as const, coordinates: [ring] };
}


function num(n: number | string | null | undefined): number {
  if (n == null) return 0;
  const v = typeof n === "string" ? Number(n) : n;
  return Number.isFinite(v) ? v : 0;
}
// useC360Query (config/queries/*.sql results) returns BOOLEAN columns as
// the literal strings "true"/"false", not real JS booleans — "false" is a
// truthy non-empty string, so a bare truthy check is always true. Every
// BOOLEAN column sourced from useC360Query MUST go through bool() before
// a truthy check. (Booleans fed by the /api/genie/* fetch endpoints are
// already coerced server-side in dbx.ts and don't need this.)
function bool(b: boolean | string | null | undefined): boolean {
  return b === true || b === "true";
}

// Cell aggregate rows → GeoJSON polygons. Copies EVERY field on the row into
// feature.properties, so any `layer.property` renders without maintaining an
// allow-list here: add a metric to the SQL + a LAYERS entry and it just works.
// h3_index and dominant_theme stay strings; every other field is coerced
// numeric (the warehouse-direct routes return numbers as JSON strings). One
// mapper serves the base, program, and active-outage cell shapes alike.
const CELL_STRING_FIELDS = new Set(["h3_index", "dominant_theme"]);
function cellsToGeoJSON(rows: ReadonlyArray<Record<string, unknown>> | null | undefined) {
  const list = rows || [];
  if (list.length === 0) return { type: "FeatureCollection" as const, features: [] };
  // Every row in a batch shares one column set (a single SQL result shape), so
  // classify the metric columns ONCE here rather than per row — the map body
  // below then does no Object.keys()/Set lookups on the hot path (a viewport
  // can hold 20k+ cells at fine H3 resolution).
  const keys = Object.keys(list[0]);
  const hasTheme = keys.includes("dominant_theme");
  const numericKeys = keys.filter((k) => !CELL_STRING_FIELDS.has(k));
  return {
    type: "FeatureCollection" as const,
    features: list.map((r) => {
      const h3 = String(r.h3_index);
      const properties: Record<string, number | string> = { h3_index: h3 };
      // Empty / absent theme normalizes to "none" so the categorical palette's
      // "none" entry matches (mirrors the old `dominant_theme || "none"`).
      if (hasTheme) properties.dominant_theme = (r.dominant_theme as string) || "none";
      for (const key of numericKeys) properties[key] = num(r[key] as number | string | null | undefined);
      return {
        type: "Feature" as const,
        properties,
        geometry: h3ToPolygon(h3),
      };
    }),
  };
}

// Cohort definer passed to writeFocus — mirrors the server's accepted body shapes.
// grain is sent for hex/hexes commits to drive the grain-following spread.
type FocusDef = {
  sql?: string;
  filters?: { customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string };
  hex?: { cellId: string; resolution: number };
  hexes?: string[];
  hexRes?: number;
  premiseNumbers?: string[];
  accountNumbers?: string[];
  grain?: string;
};

// One-level undo snapshot captured at each writeFocus call so clearFocus can
// offer a "Focus cleared · Undo" toast that replays the last cohort.
type FocusSnapshot = {
  def: FocusDef;
  label: string;
  provisional?: number;
  selectionPoly: [number, number][] | null;
  selectedCell: string | null;
};

// Minimum customer count for a cell to get its metric color. Set to 1 so
// every cell the data produces is painted — `exec_map_cells` only emits cells
// with at least one customer, so this colors them all. The population is a
// sparse sample (at res 9 the median cell has ~2 customers), so a higher guard
// would blank the bulk of fine-resolution cells; keeping it at 1 lets the
// choropleth densify continuously across the whole slider range.
const MIN_CUSTOMERS_FOR_COLOR = 1;


// "Complaint volume" can be focused on one complaint sub-category via a Theme
// sub-dropdown. Values are fact_customer_complaints.sub_category; grouped by
// category for a readable <optgroup> menu. "" = all complaints (the default).
const COMPLAINT_THEME_GROUPS: { category: string; options: { value: string; label: string }[] }[] = [
  { category: "Billing",          options: [{ value: "high_bill_dispute", label: "High bill dispute" }, { value: "unexpected_charges", label: "Unexpected charges" }] },
  { category: "Billing process",  options: [{ value: "payment_plan_request", label: "Payment plan request" }] },
  { category: "Customer service", options: [{ value: "long_hold_time", label: "Long hold time" }, { value: "rude_agent", label: "Rude agent" }] },
  { category: "Outage",           options: [{ value: "extended_outage", label: "Extended outage" }, { value: "restoration_delay", label: "Restoration delay" }, { value: "frequent_outages", label: "Frequent outages" }] },
  { category: "Program",          options: [{ value: "dsm_rebate_delay", label: "Rebate delay" }, { value: "ev_program_enrollment", label: "EV program enrollment" }] },
  { category: "Service quality",  options: [{ value: "voltage_fluctuation", label: "Voltage fluctuation" }, { value: "brownout", label: "Brownout" }] },
];
const COMPLAINT_THEME_LABEL: Record<string, string> = Object.fromEntries(
  COMPLAINT_THEME_GROUPS.flatMap((g) => g.options.map((o) => [o.value, o.label])),
);

// Zoom-driven hand-off for the value choropleth → customer dots. The hexagons
// carry the zoomed-out view at full strength below DOTS_FADE_START, then fade
// out FAST and EARLY — fully gone by HEX_FADE_END, well before the dots finish
// fading in (DOTS_FADE_END). The quick fade is deliberate: by this zoom the
// cells are at fine H3 resolution where the sampled population leaves many
// low-n cells painted gray/transparent, so a slow fade would leave a dark
// "puzzle" of sparse cells and seams hanging under the dots. Evaluated on the
// GPU per frame (MapLibre zoom expression), so it needs no React state.
const HEX_FADE_END = 11.6;       // fill fully gone here (DOTS_FADE_START + 0.6)
const HEX_LINE_FADE_END = 11.4;  // seams drop even sooner — they read as the "puzzle"
const HEX_FILL_OPACITY: any = [
  "interpolate", ["linear"], ["zoom"],
  DOTS_FADE_START, 0.6,
  HEX_FADE_END, 0,
];
const HEX_LINE_OPACITY: any = [
  "interpolate", ["linear"], ["zoom"],
  DOTS_FADE_START, 0.3,
  HEX_LINE_FADE_END, 0,
];
// Pinned-Hexes render mode: hold at the fade curves' own starting values
// (what hexes already look like below DOTS_FADE_START) at every zoom,
// instead of fading out — "this tier, always" rather than "this tier, for
// now".
const HEX_FILL_OPACITY_PINNED = 0.6;
const HEX_LINE_OPACITY_PINNED = 0.3;
// When a focus group is active, the choropleth cells ARE the cohort (the
// /cells query itself is scoped to the cohort's customers — see the cells
// fetch below), so the base fill needs no dimming. A thin accent outline on
// those same cells traces the cohort's edge; it fades out on the same window
// as the rest of the hex tier so it hands off cleanly to the dots' own
// `in_focus` highlight.
const COHORT_OUTLINE_OPACITY: any = [
  "interpolate", ["linear"], ["zoom"],
  DOTS_FADE_START, 0.9,
  HEX_FADE_END, 0,
];

// MapLibre expression: interpolate a numeric property to a color stop.
// Normalizes by clamping to the dynamic [min, max] computed from the
// data so the gradient always uses the full range. Cells with too few
// customers fall through to NULL_COLOR (gray).
function numericColorExpression(property: string, min: number, max: number, reversed: boolean): any {
  const range = max - min || 1;
  const stops = (reversed ? NUMERIC_COLOR_STOPS_REVERSED : NUMERIC_COLOR_STOPS).flatMap(
    ([t, c]) => [min + t * range, c],
  );
  return [
    "case",
    // Low-n guard: short-circuit to gray when the cell lacks customers.
    ["<", ["to-number", ["coalesce", ["get", "n_customers"], 0]], MIN_CUSTOMERS_FOR_COLOR],
    NULL_COLOR,
    ["all", ["has", property], ["!=", ["get", property], null]],
    ["interpolate", ["linear"], ["to-number", ["get", property]], ...stops],
    NULL_COLOR,
  ];
}

// MapLibre expression: discrete color per dominant theme.
// Same low-n guard so a single-complaint cell doesn't dominate visually.
function categoricalColorExpression(property: string): any {
  const matchPairs = Object.entries(THEME_PALETTE).flatMap(([k, v]) => [k, v]);
  return [
    "case",
    ["<", ["to-number", ["coalesce", ["get", "n_customers"], 0]], MIN_CUSTOMERS_FOR_COLOR],
    NULL_COLOR,
    [
      "match",
      ["get", property],
      ...matchPairs,
      DEFAULT_THEME_COLOR,
    ],
  ];
}

function fmtNum(n: number | string | null | undefined, frac = 0): string {
  if (n == null) return "—";
  const v = typeof n === "string" ? Number(n) : n;
  if (!Number.isFinite(v)) return "—";
  return v.toLocaleString(undefined, { maximumFractionDigits: frac });
}

function fmtKwh(n: number | string | null | undefined): string {
  if (n == null) return "—";
  const v = typeof n === "string" ? Number(n) : n;
  if (!Number.isFinite(v)) return "—";
  return `${Math.round(v).toLocaleString()} kWh`;
}



// Compact duration for outage ETAs / time-out, e.g. "2h 15m" or "45m".
function fmtDuration(mins: number | string | null | undefined): string {
  const m = Math.round(num(mins));
  if (m <= 0) return "—";
  const h = Math.floor(m / 60), r = m % 60;
  return h > 0 ? `${h}h ${r}m` : `${r}m`;
}

// Generic debounce hook. Returns a value that only updates after `delay` ms of
// stability. Used to batch rapid filter-chip toggles into a single warehouse
// request while keeping map navigation (bounds/zoom) changes immediate.
function useDebounce<T>(value: T, delay: number): T {
  const [debounced, setDebounced] = useState<T>(value);
  useEffect(() => {
    const id = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(id);
  }, [value, delay]); // eslint-disable-line react-hooks/exhaustive-deps
  return debounced;
}

// useViewportFetch is imported from ./hooks/useViewportFetch

// ────────────────────────────────────────────────────────────────────
// ExplorerMap — the Explorer geographic command center
// ────────────────────────────────────────────────────────────────────

// Error boundary so a render-time bug (bad query response shape, etc.)
// shows a recoverable message instead of blanking the whole tab.
class MapErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  componentDidCatch(err: Error) { console.error("ExplorerMap render error:", err); }
  render() {
    if (this.state.error) {
      return (
        <div className="card error" style={{ margin: 16 }}>
          Explorer map crashed: {this.state.error.message}.
          <button
            className="theme-toggle"
            style={{ marginLeft: 12 }}
            onClick={() => this.setState({ error: null })}
          >
            Retry
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

// A fly-to + select request handed in from the top-bar customer search (or
// the profile drawer's "Show all locations" action). `points`, when present
// with >1 entry, fits the camera to every premise instead of flying to the
// single primary lat/lon — used by multi-site customers.
export interface MapFocusRequest {
  // Optional: omitted by the Owner inspector's "light up portfolio" action,
  // which has many sites and no single account to open a drill for.
  account?: string;
  // Set by the profile drawer's location switcher: sync the map to a specific
  // premise — fly to it and ring it — WITHOUT dropping the current cohort/genie
  // context (a lighter path than the search/show-all-locations reframe).
  premiseNumber?: string;
  lat: number;
  lon: number;
  ts: number;
  points?: { lat: number; lon: number }[];
}

// Group analytics for the focus cohort (or the whole territory by default).
// Lifted OUT of the rail so the SAME loaded result and the SAME loading flag
// drive both the right-rail FocusPanel AND the top context bar — so the headline
// count reveals on one frame in both places, instead of the bar (fed by the
// faster /api/focus/set) jumping a beat before the rail (fed by this query).
function useGroupAnalytics(
  sessionId: string,
  focusActive: boolean,
  focusVersion: number,
  focusPending: boolean,
  filters: FilterState,
) {
  const [data, setData] = useState<GroupAnalytics | null>(null);
  // Which cohort version the displayed metrics belong to. The fetch only kicks
  // off once `focusVersion` bumps (after focus/set returns), so any version
  // newer than what we've loaded means a refresh is in flight.
  const [loadedVersion, setLoadedVersion] = useState(-1);
  useEffect(() => {
    // Don't refetch while a cohort commit is mid-flight (focusPending). The
    // optimistic focusActive flip fires this effect BEFORE /api/focus/set has
    // written the cohort into app_focus_set, so a cohort-body query would read
    // an EMPTY cohort and land total:0 — flashing the rail 995 → 0 → real.
    // focusPending clears right after the /set ack bumps focusVersion, so the
    // fetch that actually runs reads the committed cohort; meanwhile the rail
    // holds the prior numbers through the spinner (useGroupAnalytics keeps the
    // last `data`), then reveals the real count on one frame.
    if (focusPending) return;
    let cancelled = false;
    // With no cohort active, still carry any live attribute filters so the
    // rail agrees with the filtered-but-no-cohort map (Issue 1 desync) —
    // a cohort's analytics already reflect its own membership regardless of
    // filters, so filters only need forwarding on the territory-default path.
    fetch("/api/genie/group", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(focusActive ? { sessionId } : filterStrings(filters)),
    })
      .then((r) => r.json())
      .then((d) => { if (!cancelled && !d.error) setData(d as GroupAnalytics); })
      .catch((e) => { if (!cancelled) console.error("[focus/analytics]", e); })
      .finally(() => { if (!cancelled) setLoadedVersion(focusVersion); });
    return () => { cancelled = true; };
  }, [sessionId, focusActive, focusVersion, focusPending, filters]);
  // Loading spans BOTH phases of a cohort change: focus/set in flight
  // (focusPending), then this re-query (focusVersion ahead of what we've loaded).
  // Deriving it closes the one-frame gap at the hand-off where the spinner
  // would otherwise flicker out.
  const loading = focusPending || focusVersion !== loadedVersion;
  return { data, loading };
}

export function ExplorerMap(props: {
  onJumpToSubject: (subject: InspectorSubject) => void;
  focus?: MapFocusRequest | null;
  // False while a different left-nav view is showing (Explorer stays mounted
  // — see App.tsx's is-hidden class). Drives a resize-on-return safety net;
  // see the ResizeObserver-in-onLoad effect below for why this is needed.
  visible?: boolean;
}) {
  return <MapErrorBoundary><ExplorerMapInner {...props} /></MapErrorBoundary>;
}

// Compute an approximate initial bounding box from the INITIAL_VIEW camera so
// the first warehouse request can be dispatched before the basemap style finishes
// loading. At zoom 8, one screen is roughly 3°×2° depending on container size.
// Using the padded viewport convention (VIEWPORT_PAD = 0.4) gives a generous
// query area that covers the territory without being too large.
// initialBoundsFromView imported from ./mapGeometry

function ExplorerMapInner({ onJumpToSubject, focus, visible = true }: {
  onJumpToSubject: (subject: InspectorSubject) => void;
  focus?: MapFocusRequest | null;
  visible?: boolean;
}) {
  const mapRef = useRef<MapRef | null>(null);
  // `zoom` settles on move-end and gates data fetches; `liveZoom` tracks the
  // gesture in real time and drives only the dot cross-fade opacity (cheap —
  // a layer-level uniform, no attribute recompute). The density cloud's fade
  // is a native MapLibre zoom expression, so it needs no React state at all.
  const [zoom, setZoom] = useState(INITIAL_VIEW.zoom);
  const [liveZoom, setLiveZoom] = useState(INITIAL_VIEW.zoom);
  // Seeded from the known INITIAL_VIEW camera so the first warehouse request
  // dispatches immediately — basemap style load no longer gates the query.
  // onLoad (and onMoveEnd) update bounds with the real MapLibre bbox once ready.
  const [bounds, setBounds] = useState<Bounds>(() => initialBoundsFromView());
  const [layerId, setLayerId] = useState<string>("complaints_per_1k");
  // "" = all complaints; else a fact_customer_complaints.sub_category that
  // focuses the Complaint-volume layer on one theme.
  const [complaintTheme, setComplaintTheme] = useState<string>("");
  const [programId, setProgramId] = useState<string | null>(null);
  // Hex-density slider: an ABSOLUTE H3 resolution (5–9) the user pins, or null
  // to follow the per-zoom auto resolution. Absolute (vs. the old ±offset) so
  // every slider position maps to a distinct level — no clamping dead zone at
  // the extremes where auto was already near 5/9.
  const [hexResOverride, setHexResOverride] = useState<number | null>(null);
  const [selectedCell, setSelectedCell] = useState<string | null>(null);
  // An individual subject drilled into from the map (dot click) or any
  // customer list. Opens the inline drill-down panel — the executive stays in
  // the map context instead of bouncing to a separate customer workspace.
  // A literal map-dot click resolves to the Premise inspector by default
  // (the map's atom is the premise, not the customer);
  // list-row clicks (a customer picked by name, not by location) still
  // resolve straight to the Customer inspector via selectCustomer below.
  const [drillSubject, setDrillSubject] = useState<InspectorSubject | null>(null);
  // The full identity triple of whatever was drilled into — the source of truth
  // for (a) re-scoping when the grain toggle flips with a drill already open,
  // and (b) lighting EVERY premise of a multi-site customer (match on
  // customer_id, the only key that spans a customer's separate per-site
  // accounts). A map-dot click knows all three; a list-row select fills only
  // its own key (the rest resolve from loaded points as needed).
  type DrillAnchor = { accountNumber: string | null; premiseNumber: string | null; customerId: string | null };
  const [drillAnchor, setDrillAnchor] = useState<DrillAnchor | null>(null);
  const selectPremise = useCallback((premiseNumber: string) => {
    setDrillSubject({ kind: "premise", premiseNumber });
    setDrillAnchor({ accountNumber: null, premiseNumber, customerId: null });
  }, []);
  const selectCustomer = useCallback((accountNumber: string) => {
    setDrillSubject({ kind: "customer", accountNumber });
    setDrillAnchor({ accountNumber, premiseNumber: null, customerId: null });
  }, []);
  // Map-dot click: the point carries the full identity, so record it — this is
  // what makes a subsequent grain flip re-scope correctly and lets a customer
  // drill light all of that customer's loaded premises.
  const selectFromPoint = useCallback(
    (o: { account_number: string; premise_number: string; customer_id?: string }, g: Grain) => {
      setDrillAnchor({ accountNumber: o.account_number, premiseNumber: o.premise_number, customerId: o.customer_id ?? null });
      setDrillSubject(g === "premise"
        ? { kind: "premise", premiseNumber: o.premise_number }
        : { kind: "customer", accountNumber: o.account_number });
    }, []);
  const closeDrill = useCallback(() => { setDrillSubject(null); setDrillAnchor(null); }, []);
  // The map is always the zoom-tiered deck.gl view: a value choropleth (H3
  // hexagons) when zoomed out, refining into clickable customer dots as you
  // zoom in.
  // Customer slice — shared vocabulary with the customer filter rail. Applied
  // server-side (re-aggregates the cells / re-queries the points).
  const [filters, setFilters] = useState<FilterState>(emptyFilterState);
  // Debounced filters for warehouse queries: rapid filter toggles (e.g. checking
  // several classes in a row) are batched into one request rather than one per
  // click. Map navigation (bounds/resolution) changes remain immediate.
  const debouncedFilters = useDebounce(filters, 200);
  const [focusPanelOpen, setFocusPanelOpen] = useState(false);
  const nActiveFilters = activeFilterCount(filters);
  // Human-readable listing of which dimensions are constrained, for the
  // top-bar filter chip's title (filterStrings already normalizes
  // unconstrained partition dims to "").
  const filterSummary = useMemo(() => {
    const s = filterStrings(filters);
    const parts: string[] = [];
    if (s.customerClasses) parts.push(s.customerClasses.split(",").join("/"));
    if (s.usageBands) parts.push(`${s.usageBands.split(",").join("/")} usage`);
    if (s.engagementTiers) parts.push(`${s.engagementTiers.split(",").join("/")} engagement`);
    if (s.issueFlags) parts.push(s.issueFlags.split(",").join(", "));
    return parts.join(" · ");
  }, [filters]);

  // Box / lasso selection over the visible customer dots (dots tier only).
  const [selectTool, setSelectTool] = useState<null | "box" | "lasso">(null);
  const [drawPts, setDrawPts] = useState<[number, number][]>([]);
  const [selectionPoly, setSelectionPoly] = useState<[number, number][] | null>(null);
  const drawingRef = useRef(false);
  // Whether the user dismissed the grain-spread note for the current session.
  const [spreadNoteDismissed, setSpreadNoteDismissed] = useState(false);

  // "Ask the map" — a conversational Genie chat scoped to the visible area
  // (+ filters). Each turn is a question and its answer: a text narrative, a
  // result table, and/or a matched customer set rendered as dots.
  const [askInput, setAskInput] = useState("");
  const [asking, setAsking] = useState(false);
  const [askElapsed, setAskElapsed] = useState(0);
  const [genieConversationId, setGenieConversationId] = useState<string | null>(null);
  const [genieTurns, setGenieTurns] = useState<GenieTurn[]>([]);
  // Open by default so "Ask the map" is visible (and obviously a chat) on first
  // load, not hidden behind a collapsed header.
  const [chatOpen, setChatOpen] = useState(true);
  const chatBodyRef = useRef<HTMLDivElement | null>(null);

  // ── Focus set (cohort) ────────────────────────────────────────────────────
  // A persistent, server-side customer cohort for this browser session. It
  // highlights/dims dots, scopes "Ask the map", and survives pan/zoom. The
  // session key is a stable per-load id (NOT the Genie conversationId — the
  // cohort must exist before the first Genie turn). customer_id is a 19-digit
  // BIGINT (lossy as a JS number), so cohorts are always defined server-side:
  // by the Genie SQL (auto-promote) or by exact account_number strings
  // (box/lasso) — never by ids round-tripped through the client.
  const sessionIdRef = useRef<string>(
    (typeof crypto !== "undefined" && "randomUUID" in crypto)
      ? crypto.randomUUID()
      : `s-${Date.now()}-${Math.random().toString(36).slice(2)}`,
  );
  const sessionId = sessionIdRef.current;
  const [focusSummary, setFocusSummary] = useState<FocusSummary | null>(null);
  // Which focusVersion the current focusSummary was fetched for. The focus panel
  // count and frameCohort only use focusSummary when this matches focusVersion,
  // so an arriving authoritative summary for an already-superseded version is
  // dropped. -1 = no authoritative summary yet for the current version.
  const [summaryVersion, setSummaryVersion] = useState(-1);
  // One-level undo: the inputs that fully reproduce the last committed cohort,
  // so clearFocus can offer a "Focus cleared · Undo" toast.
  const currentFocusRef = useRef<FocusSnapshot | null>(null);
  const [undoSnapshot, setUndoSnapshot] = useState<FocusSnapshot | null>(null);
  const undoTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // A short human label for how the current focus group was defined (hex / drawn
  // / attributes / words). Shown as the rail header eyebrow. null = territory.
  const [focusLabel, setFocusLabel] = useState<string | null>(null);
  // Bumped whenever the cohort changes, so the points layer re-fetches its
  // server-computed `in_focus` flags. Bumped on the /set ack (not after
  // computeSummary) so the map/cells/points re-fetches fire immediately, without
  // waiting for the summary query.
  const [focusVersion, setFocusVersion] = useState(0);
  const focusVersionRef = useRef(0);
  // True from the instant a cohort change is REQUESTED (box drawn, hex clicked,
  // filters applied) until its /api/focus/set round-trip resolves. The rail keys
  // its loading state off this so the spinner shows immediately — `focusVersion`
  // only bumps after the set ack, which is after the write lands.
  const [focusPending, setFocusPending] = useState(false);
  const focusActive = !!focusSummary?.active;
  // Stable ref to the territory totals from the last authoritative summary.
  // Read inside writeFocus to avoid a stale focusSummary closure.
  const territoryRef = useRef({ locations: 0, customers: 0 });
  // Group analytics for the cohort — one source of truth for the headline count,
  // shared by the top context bar and the right-rail panel so both reveal it
  // together (see useGroupAnalytics).
  const { data: groupData, loading: groupLoading } = useGroupAnalytics(
    sessionId, focusActive, focusVersion, focusPending, filters,
  );
  // Define (replace) this session's cohort from a Genie SQL string, attribute
  // filters, a clicked hex, or an exact set of account_numbers. Stores the
  // returned summary and a label describing how it was chosen.
  const writeFocus = useCallback(
    async (
      def: FocusDef,
      label: string,
      // Optional client-side approximate count (premises). When provided, a
      // provisional focusSummary is set immediately so focusActive becomes true
      // and the map/cells/points re-fetches fire before /set even returns.
      // The authoritative summary (from /api/focus/summary) replaces it later.
      provisionalLocations?: number,
    ) => {
      // Snapshot this cohort for one-level undo. selectedCell is derived
      // from def.hex (caller already knows it); selectionPoly is read from
      // closure — in the hexes/box path this effect runs after render so it's
      // current; in the hex-click path selectionPoly is already null (the caller
      // clears it synchronously before calling writeFocus, but since state
      // updates are batched we can't read the new value here — we use null
      // directly for hex clicks because def.hex is present).
      currentFocusRef.current = {
        def,
        label,
        provisional: provisionalLocations,
        selectedCell: def.hex?.cellId ?? null,
        selectionPoly: def.hex ? null : selectionPoly,
      };
      // Invalidate any pending undo toast — a new cohort supersedes it.
      setUndoSnapshot(null);
      if (undoTimerRef.current) { clearTimeout(undoTimerRef.current); undoTimerRef.current = null; }

      setFocusLabel(label);
      setFocusPending(true);

      // For client-known selections (box/lasso over dots, hex click), make
      // focusActive true immediately so the map starts recoloring without waiting
      // for the /set round-trip. The provisional summary has no extent (can't
      // frame yet); summaryVersion stays behind focusVersion until the
      // authoritative summary lands, so the focus panel count stays provisional.
      if (provisionalLocations !== undefined) {
        setFocusSummary({
          active: true,
          cohortLocations: provisionalLocations,
          cohortCustomers: provisionalLocations,
          territoryLocations: territoryRef.current.locations,
          territoryCustomers: territoryRef.current.customers,
          extent: null,
          grain: null,
          subjectKey: null,
        });
      }

      try {
        const resp = await fetch("/api/focus/set", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId, ...def }),
        });
        const data = await resp.json();
        if (!resp.ok || data.error) throw new Error(data.error || `Request failed (${resp.status})`);

        // Bump focusVersion on the write ack (not after computeSummary), so
        // map/cells/points re-fetches fire immediately. The summary is fetched
        // in parallel below.
        focusVersionRef.current += 1;
        const captured = focusVersionRef.current;
        setFocusVersion(captured);
        // Set focusActive for non-optimistic paths (sql/filters cohorts) where
        // we don't have a provisional summary yet.
        if (provisionalLocations === undefined) {
          setFocusSummary({ active: true, cohortLocations: 0, cohortCustomers: 0,
            territoryLocations: territoryRef.current.locations,
            territoryCustomers: territoryRef.current.customers,
            extent: null, grain: null, subjectKey: null });
        }
        setFocusPending(false);

        // Fetch authoritative summary in parallel with the map re-fetches that
        // the focusVersion bump just kicked off.
        fetch(`/api/focus/summary?sessionId=${encodeURIComponent(sessionId)}`)
          .then((r) => r.json())
          .then((s: FocusSummary & { error?: string }) => {
            // Drop if a newer selection already superseded this one.
            if (focusVersionRef.current !== captured) return;
            if (!s.error) {
              territoryRef.current = { locations: s.territoryLocations, customers: s.territoryCustomers };
              // Reflect the authoritative summary even when it's empty
              // (active:false → the cohort resolved to zero members, so we fall
              // back to territory) rather than leaving a stale provisional count.
              setFocusSummary(s);
            }
            // ALWAYS advance summaryVersion — even for an empty cohort or a
            // summary error. The hex-tier reveal gate (cohortRevealReady) keys on
            // summaryVersion === focusVersion; if we skipped it for an empty/failed
            // summary the choropleth would stay blanked and "Updating…" would spin
            // forever (the "0 premises then stuck" bug).
            setSummaryVersion(captured);
          })
          .catch((e) => {
            console.error("[focus/summary]", e instanceof Error ? e.message : e);
            // Don't strand the reveal gate if the summary fetch itself fails.
            if (focusVersionRef.current === captured) setSummaryVersion(captured);
          });
      } catch (e) {
        console.error("[focus/set]", e instanceof Error ? e.message : e);
        setFocusPending(false);
      }
    },
    // selectionPoly is included so the hexes/box snapshot captures the correct
    // poly at the time the box-commit useEffect runs (after render).
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [sessionId, selectionPoly],
  );

  const clearFocus = useCallback(async () => {
    // Stash the current cohort before wiping it so the undo toast can replay it.
    if (currentFocusRef.current) {
      const snap = currentFocusRef.current;
      setUndoSnapshot(snap);
      if (undoTimerRef.current) clearTimeout(undoTimerRef.current);
      undoTimerRef.current = setTimeout(() => {
        setUndoSnapshot(null);
        undoTimerRef.current = null;
      }, 7000);
    }
    currentFocusRef.current = null;
    setFocusPending(true);
    setFocusSummary(null);
    setFocusLabel(null);
    focusVersionRef.current += 1;
    setFocusVersion(focusVersionRef.current);
    setSummaryVersion(-1);
    try {
      await fetch("/api/focus/clear", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId }),
      });
    } catch (e) {
      console.error("[focus/clear]", e instanceof Error ? e.message : e);
    } finally {
      setFocusPending(false);
    }
  }, [sessionId]);

  // One-level undo: replay the snapshot captured at the last writeFocus call.
  const restoreFocus = useCallback(() => {
    const s = undoSnapshot;
    if (!s) return;
    if (undoTimerRef.current) { clearTimeout(undoTimerRef.current); undoTimerRef.current = null; }
    setUndoSnapshot(null);
    setSelectionPoly(s.selectionPoly);
    setSelectedCell(s.selectedCell);
    writeFocus(s.def, s.label, s.provisional);
  }, [undoSnapshot, writeFocus]);

  // Turn the current attribute filters into the focus cohort (territory-wide,
  // resolved server-side from the same predicate the map uses).
  const applyFiltersAsFocus = useCallback(() => {
    const n = activeFilterCount(filters);
    writeFocus({ filters: filterStrings(filters) }, `${n} attribute${n === 1 ? "" : "s"}`);
  }, [writeFocus, filters]);

  // The most recent turn that matched a customer set drives the map dots + KPI
  // scope; analytical turns leave any prior dots in place.
  const genieCustomers = useMemo(() => {
    for (let i = genieTurns.length - 1; i >= 0; i--) {
      const c = genieTurns[i].customers;
      if (c && c.length > 0) return c;
    }
    return EMPTY_ROWS;
  }, [genieTurns]);
  const genieActive = genieCustomers.length > 0;

  const baseLayer = LAYERS.find((l) => l.id === layerId) || LAYERS[0];
  // Complaint-theme focus is a FILTER, not a recolor: the cells/dots/KPIs all
  // narrow to customers with that complaint (see effectiveComplaintTheme below).
  // The layer keeps coloring by complaints_per_1k; we just relabel to make the
  // active filter obvious.
  const layer = (layerId === "complaints_per_1k" && complaintTheme)
    ? {
        ...baseLayer,
        label: `${COMPLAINT_THEME_LABEL[complaintTheme] || "Theme"} complaints`,
        description: `Filtered to customers with “${COMPLAINT_THEME_LABEL[complaintTheme] || complaintTheme}” complaints — volume per 1,000 of those customers, last 90 days.`,
      }
    : baseLayer;
  // The theme filter only applies while the Complaint-volume layer (and its
  // Theme dropdown) is showing, so switching layers never leaves a hidden filter.
  const effectiveComplaintTheme = layerId === "complaints_per_1k" ? complaintTheme : "";
  // Hex density: when the user hasn't pinned a level, follow the per-zoom auto
  // resolution (the choropleth stays auto-granular as you zoom). Once they move
  // the slider, `hexResOverride` pins an absolute level so every slider position
  // is a distinct, live H3 resolution — no offset clamping. The "Auto" button
  // clears the pin to return to zoom-following.
  const resolution = hexResOverride ?? h3ResolutionForZoom(zoom);
  // Auto/Dots/Hexes — pins the representation at any zoom instead of the
  // automatic cross-fade. Genie answers and the live-outage layer own their
  // own rendering (buildGenieLayers/buildLiveLayers, and their own hex
  // choropleth), so the toggle is locked to "auto" while either is active —
  // pinning a mode there wouldn't do anything since those paths never
  // consult it, and it should read as "off" rather than silently no-op.
  const [renderMode, setRenderMode] = useState<"auto" | "dots" | "hex">("auto");
  const renderModeLocked = genieActive || !!layer.isLiveOutage;
  const effectiveRenderMode = renderModeLocked ? "auto" : renderMode;
  // The master viewing grain — drives the headline count, dot selection
  // semantics (a click groups by this grain), and which inspector opens by
  // default. Promoted to the Explorer header so the user declares intent
  // up-front rather than discovering it mid-drill.
  const [grain, setGrain] = useState<Grain>("premise");
  // Remembers the grain active before a snap-to-customer, so returning to a
  // premise-capable layer can restore it. null = no pending restore.
  const preSnapGrainRef = useRef<'premise' | 'customer' | null>(null);
  // Dots are meaningful (visible / selectable) once the cross-fade begins.
  // Uses settled `zoom` so toolbars don't flicker mid-gesture.
  const dotsVisible =
    effectiveRenderMode === "dots" ? true :
    effectiveRenderMode === "hex"  ? false :
    zoom >= DOTS_FADE_START;
  // Rounded live zoom for the dot-opacity cross-fade — 0.1-zoom granularity
  // keeps the fade smooth while limiting React re-renders during the gesture.
  const fadeZoom = Math.round(liveZoom * 10) / 10;
  // Layer-level opacity for the customer-dots deck layer — a cheap uniform,
  // so both the fade and a pinned mode cost nothing per frame (no per-point
  // attribute recompute).
  const dotOpacity = useMemo(() => {
    if (effectiveRenderMode === "dots") return 1;
    if (effectiveRenderMode === "hex") return 0;
    return dotOpacityForZoom(fadeZoom);
  }, [effectiveRenderMode, fadeZoom]);
  // Hex fill/line opacity, mirroring dotOpacity: pinned Dots hides the
  // choropleth entirely, pinned Hexes holds it at full strength at any zoom,
  // and Auto keeps today's zoom cross-fade.
  const hexFillOpacity = effectiveRenderMode === "dots" ? 0 : effectiveRenderMode === "hex" ? HEX_FILL_OPACITY_PINNED : HEX_FILL_OPACITY;
  const hexLineOpacity = effectiveRenderMode === "dots" ? 0 : effectiveRenderMode === "hex" ? HEX_LINE_OPACITY_PINNED : HEX_LINE_OPACITY;

  // ── Programs list (for the layer's program picker)
  const programs = useC360Query<ProgramRow>("programs_list", {});

  // Default to a program when switching to a program layer.
  useEffect(() => {
    const programList = rows(programs.data);
    if (layer.needsProgram && !programId && programList.length > 0) {
      setProgramId(programList[0].program_id);
    }
  }, [layer.needsProgram, programId, programs.data]);

  // ── Choropleth cell aggregates. These run through warehouse-direct routes
  // (/api/genie/cells, /api/genie/program-cells) rather than AppKit's analytics
  // path: at fine H3 resolution a viewport holds 20k+ cells (several MB), which
  // the analytics SSE transport silently truncates at ~1 MB — so the finer
  // slider steps appeared to do nothing (the map kept the last coarse grid).
  // The custom routes have no such cap. Loading state here; the fetch effects
  // (just after baseCache/programCache below) write results into those caches.
  const [baseCellsLoading, setBaseCellsLoading] = useState(false);
  const [baseCellsError, setBaseCellsError] = useState<string | null>(null);
  // Bumping this forces the cells fetch to re-fire (user-triggered Retry after
  // a terminal error).
  const [cellsRetrySeq, setCellsRetrySeq] = useState(0);
  const [programCellsLoading, setProgramCellsLoading] = useState(false);
  const programCellsActive = layer.needsProgram && !!programId && !!bounds;

  // ── Active outages (live) layer state. Cells + dots come from warehouse-direct
  // routes (same cap reasoning as the base layer); incidents are few, so they
  // ride the analytics() SSE path. All only matter while the live layer shows.
  const liveActive = !!layer.isLiveOutage && !!bounds;
  const [activeCellsLoading, setActiveCellsLoading] = useState(false);
  const incidentsQuery = useC360Query<ActiveOutageIncidentRow>(
    "exec_active_outage_incidents", layer.isLiveOutage ? {} : null,
  );
  const activeIncidents = useMemo<ActiveOutageIncidentRow[]>(
    () => (layer.isLiveOutage ? rows(incidentsQuery.data) : []),
    [layer.isLiveOutage, incidentsQuery.data],
  );

  // ── Full service-territory extent (run once) — drives the "Service
  // territory" button so it fits the map to every customer in the dataset.
  const territoryQuery = useC360Query<TerritoryRow>("exec_territory_bounds", {});
  const territoryBounds = useMemo<Bounds | null>(() => {
    const r = rows(territoryQuery.data)[0];
    if (!r) return null;
    return { south: num(r.min_lat), north: num(r.max_lat), west: num(r.min_lon), east: num(r.max_lon) };
  }, [territoryQuery.data]);

  // ── Individual customer points — only fetched in "points" mode at the
  // "dots" tier, where the viewport is small enough to be bounded.
  // Viewport points for the "dots" tier. Loaded from the custom /api/genie/points
  // route, which hits the SQL warehouse directly — no AppKit 1 MB response cap,
  // so we render the full local population (not a top-N), up to a generous cap.
  // Fetch viewport points once zoomed in enough that the population is
  // bounded — slightly before the fade window so dots are ready to resolve in.
  // The live-outage layer renders its own (red) dots from a separate fetch, so
  // the normal customer-dot fetch is skipped there — otherwise every pan issued
  // a large /api/genie/points query whose rows are never rendered. Pinned
  // Dots mode forces the fetch at any zoom (that's the point of the pin);
  // this is also exactly the case where the viewport can hold the whole
  // territory, so it's paired with a uniform spatial sample below.
  const wantDots = effectiveRenderMode === "dots" || zoom >= POINTS_FETCH_ZOOM;
  const pointsActive = wantDots && !!bounds && !layer.isLiveOutage;
  // A forced wide-area density view (zoomed out further than points normally
  // load) needs a spatially uniform sample instead of the attention-ranked
  // top-N, or the dots would look like attention clusters, not population.
  // Tracked as its own boolean (not folded into pointsActive) so crossing
  // POINTS_FETCH_ZOOM while pinned to Dots re-fetches with the right sample
  // even though pointsActive stays true the whole time.
  const wantUniformSample = effectiveRenderMode === "dots" && zoom < POINTS_FETCH_ZOOM;
  const [pointsLoading, setPointsLoading] = useState(false);
  const [pointsError, setPointsError] = useState<string | null>(null);
  // The true in-viewport customer count (pre-cap) and whether /points had to
  // truncate to it — drives the "Showing X of Y" honesty pill below.
  const [pointsTotal, setPointsTotal] = useState(0);
  const [pointsSampled, setPointsSampled] = useState(false);
  useViewportFetch<PointRow>({
    route: "/api/genie/points",
    tag: "points",
    active: pointsActive,
    responseKey: "customers",
    setLoading: setPointsLoading,
    setError: setPointsError,
    body: () => {
      // When a program layer is active, ask for per-customer adoption flags
      // (is_enrolled / has_der) so the dots can be colored binary + compared
      // against the program's DER signal.
      const program_id = layer.needsProgram && programId ? programId : undefined;
      // Carry the session id only while a cohort is active, so each dot comes
      // back with its `in_focus` flag (server-side join — no id list crosses).
      const sid = focusActive ? sessionId : undefined;
      return {
        ...bounds, ...filterStrings(debouncedFilters), complaint_theme: effectiveComplaintTheme, program_id,
        sessionId: sid, limit: POINTS_LIMIT, sample: wantUniformSample ? "uniform" : "attention",
      };
    },
    onData: (rows) => setPointsCache({
      rows,
      focusVersion: focusActive ? focusVersion : -1,
    }),
    onMeta: (data) => {
      setPointsTotal(typeof data.total === "number" ? data.total : 0);
      setPointsSampled(!!data.sampled);
    },
    // focusActive is deliberately NOT a dep (only read at dispatch, above):
    // writeFocus flips focusActive true OPTIMISTICALLY, before /api/focus/set has
    // written the session's rows. Triggering on it would fire a cohort-scoped
    // fetch against an unwritten focus set (empty/stale in_focus). focusVersion
    // bumps only on the /set ack, so it's the correct sole cohort-change trigger
    // for both commit and clear — keep focusActive out of this list.
    deps: [pointsActive, wantUniformSample, bounds, debouncedFilters, layer.needsProgram, programId, effectiveComplaintTheme, sessionId, focusVersion],
  });

  // Hold the last successful query result so cells stay rendered while
  // the next query is in flight. Without this, every pan/zoom briefly
  // clears the map between params-change and data-arrival. We also
  // remember the *resolution* the cached cells were computed at — the
  // current `resolution` may have advanced since (the user kept
  // scrolling), and we want drill clicks to use the cell's true
  // resolution, not the latest.
  // focusVersion the rows were fetched under; -1 = territory (no cohort). Lets
  // us tell "cells on screen reflect the active cohort" from "cohort just
  // changed, still showing the previous fetch's rows" (see cohortCellsReady).
  type BaseCache = { rows: CellRow[]; resolution: number; focusVersion: number };
  type ProgramCache = { rows: ProgramCellRow[]; resolution: number; programId: string | null };

  const [baseCache, setBaseCache] = useState<BaseCache>({ rows: [], resolution, focusVersion: -1 });
  const [programCache, setProgramCache] = useState<ProgramCache>({ rows: [], resolution, programId: null });
  // focusVersion the rows were fetched under; -1 = territory (no cohort) —
  // same "hold the last good frame" pattern as BaseCache, so per-dot
  // `in_focus` dimming doesn't apply until rows carrying it actually land
  // (see cohortPointsReady below).
  type PointsCache = { rows: PointRow[]; focusVersion: number };
  const [pointsCache, setPointsCache] = useState<PointsCache>({ rows: [], focusVersion: -1 });
  // Latest points, readable from stable callbacks (pivotSubject) without
  // widening their dep arrays — used to resolve a pivot target's coords when
  // the caller didn't supply them.
  const pointsCacheRef = useRef(pointsCache);
  pointsCacheRef.current = pointsCache;
  type ActiveCellCache = { rows: ActiveOutageCellRow[]; resolution: number };
  const [activeCellCache, setActiveCellCache] = useState<ActiveCellCache>({ rows: [], resolution });
  const [activeOutagePointsCache, setActiveOutagePointsCache] = useState<ActiveOutagePointRow[]>([]);

  // The drilled customer's customer_id, resolved from the anchor. When the
  // anchor was set from a map-dot click it's already known; when it came from a
  // list-row select (account_number only) we resolve it from the loaded points
  // by matching the account. customer_id is the ONLY key that spans a
  // multi-site customer's separate per-site accounts, so the highlight below
  // keys on it to light every premise (not just the clicked one).
  const drillCustomerId = useMemo<string | null>(() => {
    if (drillSubject?.kind !== "customer") return null;
    if (drillAnchor?.customerId) return drillAnchor.customerId;
    const acct = drillAnchor?.accountNumber ?? drillSubject.accountNumber;
    const hit = pointsCache.rows.find((p) => p.account_number === acct);
    return hit?.customer_id ?? null;
  }, [drillSubject, drillAnchor, pointsCache.rows]);

  // True when `d` (a map point carrying account_number + premise_number) is
  // the drilled subject, whichever kind it is — the single place the
  // client-side identities get compared against the current drill subject.
  // Premise grain matches the one premise; Customer grain matches EVERY premise
  // sharing the customer_id (falling back to account_number only until the id
  // resolves), so a multi-site customer lights all of its dots.
  const isDrillMatch = useCallback((d: { account_number: string; premise_number?: string; customer_id?: string }): boolean => {
    if (!drillSubject) return false;
    if (drillSubject.kind === "premise") return d.premise_number === drillSubject.premiseNumber;
    // Unreachable: owner is never a drill subject — the "Property owner" line
    // routes to the full-profile drawer (setFullSubject), not drillSubject. The
    // branch is kept only to narrow the union.
    if (drillSubject.kind === "owner") return false;
    if (drillCustomerId && d.customer_id) return d.customer_id === drillCustomerId;
    return d.account_number === drillSubject.accountNumber;
  }, [drillSubject, drillCustomerId]);

  // Grain toggle re-scopes an OPEN drill (user expectation: flip to Customer →
  // the whole customer lights up and the rail switches to the customer card;
  // flip back to Premise → return to the originally-clicked location). Keyed
  // off the anchor so the two views stay two facets of one selection rather
  // than resetting. No anchor (nothing drilled) → the toggle only affects
  // counts and the NEXT click, as before.
  useEffect(() => {
    if (!drillAnchor) return;
    setDrillSubject((cur) => {
      if (!cur) return cur;
      if (grain === "premise") {
        if (!drillAnchor.premiseNumber || cur.kind === "premise") return cur;
        return { kind: "premise", premiseNumber: drillAnchor.premiseNumber };
      }
      // grain === "customer"
      if (!drillAnchor.accountNumber || cur.kind === "customer") return cur;
      return { kind: "customer", accountNumber: drillAnchor.accountNumber };
    });
    // grain is the trigger; drillAnchor is read but must not re-fire this.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [grain]);

  // Rail pivot (the premise ↔ customer chip, or the multi-site premise picker):
  // switching the subject in the rail is the mirror image of flipping the grain
  // toggle, so it must move the master grain WITH it — the header selector then
  // reflects whatever entity the rail is now showing. We update the anchor to
  // the pivot target first (a picker-chosen premise can differ from the
  // originally-clicked one), so the grain-flip effect above resolves to the same
  // subject and leaves this selection intact rather than clobbering it.
  const pivotSubject = useCallback((s: InspectorSubject) => {
    if (s.kind === "premise") {
      setDrillAnchor((a) => ({ accountNumber: a?.accountNumber ?? null, premiseNumber: s.premiseNumber, customerId: a?.customerId ?? null }));
      setGrain("premise");
      // Fly the camera to the picked location. A pivot to a specific premise
      // (e.g. the multi-site picker's "other" home) is a jump to a place, and
      // that place is often off-screen — so re-centre, don't just swap the rail
      // card. The blue drill halo then rings it once its dot loads at the new
      // viewport. Coords come from the caller (roster) or, failing that, the
      // loaded points.
      const m = mapRef.current;
      if (m) {
        let lat: number | null | undefined = s.lat;
        let lon: number | null | undefined = s.lon;
        if (lat == null || lon == null) {
          const hit = pointsCacheRef.current.rows.find((p) => p.premise_number === s.premiseNumber);
          if (hit) { lat = num(hit.latitude); lon = num(hit.longitude); }
        }
        if (lat != null && lon != null && Number.isFinite(lat) && Number.isFinite(lon)) {
          m.flyTo({ center: [lon, lat], zoom: Math.max(m.getZoom(), 13.5), duration: 900 });
        }
      }
    } else if (s.kind === "customer") {
      setDrillAnchor((a) => ({ accountNumber: s.accountNumber, premiseNumber: a?.premiseNumber ?? null, customerId: a?.customerId ?? null }));
      setGrain("customer");
    }
    // owner isn't a grain — the toggle only spans premise/customer, so leave it.
    setDrillSubject(s);
  }, []);

  // True once the cells actually on screen were fetched for the *current*
  // cohort — false during the round-trip after a cohort change, when the
  // GeoJSON is still the previous (territory) cell set. Cohort-only visuals
  // (outline/dim) must wait for this, or they flash across the stale cells.
  const cohortCellsReady =
    focusActive && !focusPending && baseCache.focusVersion === focusVersion;

  // Same guard for the dots layer: true once the on-screen points were
  // fetched for the current cohort (carry a real `in_focus` flag). Until
  // then, per-dot cohort dimming must not apply — see the `lit` computation
  // in the customer-dots layer below.
  const cohortPointsReady =
    focusActive && !focusPending && pointsCache.focusVersion === focusVersion;

  // All-ready barrier: the authoritative count and extent (shown in the focus
  // panel) are only revealed once BOTH the map layers AND the summary have
  // landed for the current version — so count, dot recolor, and rail headline
  // flip as one change, not three separate pops.
  // summaryVersion === focusVersion means the authoritative summary arrived.
  const cohortReady =
    cohortCellsReady && cohortPointsReady && summaryVersion === focusVersion;

  // Hex-tier reveal barrier. In the hex tier, points are never fetched
  // (pointsActive is false when zoomed out), so cohortPointsReady is always false
  // and cohortReady never fires. Use this instead to gate the blank-then-reveal.
  // True once BOTH the cohort-scoped cells AND the authoritative summary have landed.
  const cohortRevealReady = cohortCellsReady && summaryVersion === focusVersion;
  // While a cohort is active but cells+summary haven't revealed yet, blank the
  // choropleth so the old territory hexes vanish immediately on commit. The
  // cells-selected outline (driven by selectedCell on the same source) still
  // renders from the old geojson because we zero opacity on cells-fill/cells-line
  // rather than replacing the source — see the Layer paint below.
  //
  // Hex tier ONLY: blank-then-reveal is a choropleth behavior. In
  // the dots tier the reveal is governed by cohortReady (which includes points),
  // so gating to !dotsVisible keeps a dots-tier box/commit from flashing the hex
  // "Updating…" cue and from blanking cells the dots view doesn't even show.
  //
  // A box/lasso region (selectionPoly present) is excluded too: the drawn hexes
  // are already traced by the blue selection outline (cells-selected-multi), so
  // blanking every fill underneath reads as a jarring colors-vanish-then-pop
  // flicker. Holding the current fill lets the cohort-scoped cells cross-fade in
  // place when they land. A single hex CLICK (selectedCell, no poly) keeps the
  // original blank-then-reveal so the territory clearly gives way to the cell.
  const cellsRevealPending = !dotsVisible && focusActive && !cohortRevealReady && !selectionPoly;

  // Base choropleth cells, warehouse-direct (no 1 MB cap). We capture the
  // resolution/programId at request time and store it alongside the rows so
  // drill clicks use the grid that's actually on screen, not the latest.
  // The live-outage layer paints its own choropleth (active-outage cells), so
  // the base cells aren't rendered there — `active` is false and we skip it.
  // `resolution` is snapshotted at dispatch (see useViewportFetch) so drill
  // clicks use the grid actually on screen, not the latest as you keep scrolling.
  useViewportFetch<CellRow>({
    route: "/api/genie/cells",
    tag: "cells",
    active: !!bounds && !layer.isLiveOutage,
    responseKey: "cells",
    setLoading: setBaseCellsLoading,
    setError: setBaseCellsError,
    // Scope the choropleth to the cohort when a focus group is active, so
    // the cells recolor to cohort-only aggregates the instant the cohort
    // changes — no pan/zoom (or the click that used to clear the focus)
    // required. Cells with no cohort members fall through the existing
    // low-n gray guard (MIN_CUSTOMERS_FOR_COLOR) and go transparent.
    body: () => ({
      resolution, ...bounds, ...filterStrings(debouncedFilters), complaint_theme: effectiveComplaintTheme,
      sessionId: focusActive ? sessionId : undefined,
      grain,
    }),
    onData: (rows) => setBaseCache({
      rows,
      resolution,
      focusVersion: focusActive ? focusVersion : -1,
    }),
    // focusActive intentionally omitted (read at dispatch via the body's
    // `sessionId: focusActive ? …`). It flips true OPTIMISTICALLY in writeFocus
    // before /api/focus/set writes the session rows; keying the fetch on it would
    // race the write and return 0 cohort cells, emptying baseCache → a "Loading
    // map…" flash (visible over dots too, since that cue isn't dots-gated) and a
    // blank-hex gap. focusVersion bumps only on the /set ack, so it alone drives
    // both the commit and clear refetches at the right time.
    deps: [bounds, resolution, debouncedFilters, effectiveComplaintTheme, layer.isLiveOutage, sessionId, focusVersion, cellsRetrySeq, grain],
  });

  // Program-layer cells, same cap-free path. Only fires when a program layer
  // is active with a selected program.
  // resolution + programId snapshotted at dispatch (see useViewportFetch), so
  // the cache records the grid/program the rows were actually computed for.
  useViewportFetch<ProgramCellRow>({
    route: "/api/genie/program-cells",
    tag: "program-cells",
    active: !!programCellsActive,
    responseKey: "cells",
    setLoading: setProgramCellsLoading,
    body: () => ({ program_id: programId, resolution, ...bounds, ...filterStrings(debouncedFilters), grain }),
    onData: (rows) => setProgramCache({ rows, resolution, programId }),
    deps: [programCellsActive, bounds, programId, resolution, debouncedFilters, grain],
  });

  // Active-outage "% currently out" cells, warehouse-direct. Only while the
  // live layer is active.
  useViewportFetch<ActiveOutageCellRow>({
    route: "/api/genie/active-outage-cells",
    tag: "active-outage-cells",
    active: liveActive,
    responseKey: "cells",
    setLoading: setActiveCellsLoading,
    body: () => ({ resolution, ...bounds }),
    onData: (rows) => setActiveCellCache({ rows, resolution }),
    deps: [liveActive, bounds, resolution],
  });

  // Currently-out customer dots for the viewport (live layer, dots tier).
  useViewportFetch<ActiveOutagePointRow>({
    route: "/api/genie/active-outage-points",
    tag: "active-outage-points",
    active: liveActive && zoom >= POINTS_FETCH_ZOOM,
    responseKey: "points",
    body: () => ({ ...bounds }),
    onData: (rows) => setActiveOutagePointsCache(rows),
    deps: [liveActive, bounds, zoom],
  });


  // The cells visible on the map may be from a different resolution
  // than the current zoom (during the gap between zooming and the new
  // query returning). Clear the selection in that case to avoid a
  // stale highlight on a cell that no longer exists.
  useEffect(() => {
    setSelectedCell(null);
  }, [baseCache.resolution, programCache.resolution, activeCellCache.resolution]);

  // ── Dev instrumentation ───────────────────────────────────────────────────
  // First cells rendered (base layer, first time rows arrive from empty).
  const firstCellsRenderedRef = useRef(false);
  useEffect(() => {
    if (!firstCellsRenderedRef.current && baseCache.rows.length > 0) {
      firstCellsRenderedRef.current = true;
      perfMark("c360:cells:first-rendered");
      perfMeasure("c360:cells:first-rendered", "c360:app-shell-interactive");
      if (import.meta.env.DEV) console.info("[c360 perf] First cells rendered");
    }
  }, [baseCache.rows.length]);

  // Warm layer change (any change after first cells rendered).
  const prevLayerId = useRef(layerId);
  useEffect(() => {
    if (firstCellsRenderedRef.current && layerId !== prevLayerId.current) {
      prevLayerId.current = layerId;
      perfMark("c360:warm-layer-change");
    }
  }, [layerId]);

  // Warm filter change (debounced filter settles to a new value after first render).
  const prevDebouncedFilters = useRef(debouncedFilters);
  useEffect(() => {
    if (firstCellsRenderedRef.current && debouncedFilters !== prevDebouncedFilters.current) {
      prevDebouncedFilters.current = debouncedFilters;
      perfMark("c360:warm-filter-change");
    }
  }, [debouncedFilters]);

  const baseGeojson = useMemo(() => cellsToGeoJSON(baseCache.rows), [baseCache.rows]);
  const programGeojson = useMemo(() => cellsToGeoJSON(programCache.rows), [programCache.rows]);
  const activeOutageGeojson = useMemo(() => cellsToGeoJSON(activeCellCache.rows), [activeCellCache.rows]);

  // Which cell family backs the active layer. One place to pick the geojson,
  // the raw aggregate rows, and the resolution those cells were computed at,
  // instead of repeating the isLiveOutage / needsProgram ternary at each site.
  const layerData: { geojson: ReturnType<typeof cellsToGeoJSON>; rows: any[]; resolution: number } =
    layer.isLiveOutage ? { geojson: activeOutageGeojson, rows: activeCellCache.rows, resolution: activeCellCache.resolution }
    : layer.needsProgram ? { geojson: programGeojson, rows: programCache.rows, resolution: programCache.resolution }
    : { geojson: baseGeojson, rows: baseCache.rows, resolution: baseCache.resolution };

  const geojson = layerData.geojson;
  // The focus footprint as polygons (cohort cells at the current resolution).
  // Effective resolution for drill clicks = resolution of the cells
  // currently on screen (cache), NOT the live zoom-derived value.
  const effectiveResolution = layerData.resolution;

  // The aggregate rows that drive both the choropleth and the deck.gl
  // heatmap/hex tiers. Base and program rows both carry h3_index +
  // n_customers + the active numeric property, so the layers treat them
  // uniformly through `layer.property`.
  const activeRows: any[] = layerData.rows;

  // Zoom changed the target H3 resolution and the finer/coarser grid hasn't
  // arrived yet, so the hexes on screen are the wrong size and about to swap.
  // We surface a centered "Updating…" cue while that fetch is in flight — the
  // grid otherwise sits unchanged for a second, then snaps, which reads as a
  // jarring after-the-fact jump. NOTE: feedback is additive DOM only; we do not
  // touch the hex layer's paint or interactivity (doing so breaks click-drill).
  // Hex tier ONLY (!dotsVisible): once dots carry the view the choropleth is
  // faded out, so its background re-resolve should never flash the centered cue
  // — a box/lasso commit over dots already renders correctly and only the rail
  // is fetching (cellsRevealPending is likewise gated to the hex tier below).
  const gridResChanging =
    !dotsVisible &&
    (baseCellsLoading || (layer.needsProgram && programCellsLoading) || (layer.isLiveOutage && activeCellsLoading)) &&
    activeRows.length > 0 &&
    effectiveResolution !== resolution;

  // Dynamic min/max for numeric layers so the gradient always covers the
  // actual data range. Computed from the rows so both the grid paint
  // expression and the deck color ramp share one scale. Categorical n/a.
  const { minVal, maxVal } = useMemo(() => {
    if (layer.kind === "categorical") return { minVal: 0, maxVal: 1 };
    let mn = Infinity, mx = -Infinity;
    for (const r of activeRows) {
      const v = num(r[layer.property]);
      if (Number.isFinite(v)) { if (v < mn) mn = v; if (v > mx) mx = v; }
    }
    if (!Number.isFinite(mn) || !Number.isFinite(mx)) return { minVal: 0, maxVal: 1 };
    if (mn === mx) return { minVal: mn, maxVal: mn + 1 };
    return { minVal: mn, maxVal: mx };
  }, [activeRows, layer]);

  // For complaint volume at premise grain: percent of complaints in the current
  // viewport that couldn't be pinned to a specific premise (for legend footnote).
  const unmappedPct = useMemo(() => {
    if (layerId !== "complaints_per_1k" || grain !== "premise" || baseCache.rows.length === 0) return 0;
    const pinned   = baseCache.rows.reduce((s, r) => s + (r.sum_complaints_90d ?? 0), 0);
    const unmapped = baseCache.rows.reduce((s, r) => s + (r.n_complaints_unmapped ?? 0), 0);
    const total = pinned + unmapped;
    return total > 0 ? Math.round(100 * unmapped / total) : 0;
  }, [layerId, grain, baseCache.rows]);

  // The zoomed-out view is the value choropleth (`cells-fill`, painted by
  // `fillColor` below): each H3 hexagon shaded by its ACTUAL metric value on
  // the fixed legend scale, refining res5→res9 as you zoom. A hex's color is
  // its value and never shifts with zoom — so there's no incoherent recolor,
  // no density blob, no polka-dot lattice. The cells fade out (HEX_*_OPACITY)
  // as the customer dots fade in. No per-frame React state needed.

  // Customers inside the committed selection shape.
  const selectedCustomers = useMemo(() => {
    if (!selectionPoly || selectionPoly.length < 3) return [] as PointRow[];
    return pointsCache.rows.filter((p) =>
      pointInPolygon(num(p.longitude), num(p.latitude), selectionPoly),
    );
  }, [selectionPoly, pointsCache.rows]);
  const selectedIds = useMemo(
    () => new Set(selectedCustomers.map((c) => c.account_number)),
    [selectedCustomers],
  );

  // Zoomed-out, the same box/lasso selects the HEXES that overlap the shape
  // (dots aren't loaded yet). Overlap-inclusive: any hex touching the shape
  // boundary is included, not just hexes whose centroid is inside.
  const selectedHexes = useMemo(() => {
    if (dotsVisible || !selectionPoly || selectionPoly.length < 3) return [] as CellRow[];
    return baseCache.rows.filter((r) => {
      // cellToBoundary returns [lat,lng]; the selection ring is [lng,lat] — flip.
      const ring = cellToBoundary(String(r.h3_index)).map(([lat, lng]) => [lng, lat]) as [number, number][];
      return polygonsIntersect(ring, selectionPoly);
    });
  }, [dotsVisible, selectionPoly, baseCache.rows]);
  const selectedHexIds = useMemo(() => selectedHexes.map((r) => r.h3_index), [selectedHexes]);

  // Grain-following spread detection: after a hex/box commit under Customer
  // grain, the cohort may light hexes beyond the drawn area because premise_id is
  // NULL, so every hex holding any premise of the cohort's customers is lit.
  // Detect this by comparing the number of colored cohort cells on screen against
  // how many cells were in the drawn selection.
  const cohortCellsShown = useMemo(() =>
    baseCache.rows.filter((r) => num(r.n_customers) >= MIN_CUSTOMERS_FOR_COLOR).length,
  [baseCache.rows]);
  const selectionSpreadAcrossHexes =
    grain === "customer" && cohortCellsReady &&
    cohortCellsShown > (selectedCell ? 1 : selectedHexIds.length);

  // Reset dismiss flag whenever the spread condition disappears (grain flip, clear).
  useEffect(() => {
    if (!selectionSpreadAcrossHexes) setSpreadNoteDismissed(false);
  }, [selectionSpreadAcrossHexes]);

  // A committed box/lasso becomes a cohort definer, split by tier: over dots,
  // the exact account_numbers (resolved to customer_id server-side — no lossy
  // id round-trip); zoomed out, the highlighted hexes themselves (WYSIWYG —
  // the cohort is exactly what's outlined under the shape). Deduped by
  // polygon identity via a ref so it fires once per new selection, not on
  // every pan (which only re-derives selectedCustomers/selectedHexes, leaving
  // selectionPoly unchanged).
  const lastFocusPolyRef = useRef<[number, number][] | null>(null);
  useEffect(() => {
    if (!selectionPoly) { lastFocusPolyRef.current = null; return; }
    if (selectionPoly === lastFocusPolyRef.current) return;
    lastFocusPolyRef.current = selectionPoly;
    if (dotsVisible) {
      // Grain-following, mirroring the hex branches: under Premise grain
      // the cohort is EXACTLY the drawn premises (send premise_number → the
      // server writes a real premise_id, so `in_focus` lights only those dots).
      // Under Customer grain, send account_number → the cohort spreads to every
      // premise of the drawn customers (premise_id NULL server-side), which is
      // the intended multi-site behavior. Using premise_number (never the
      // BIGINT premise_id) keeps the client on the string identity throughout.
      if (grain === "premise") {
        const prems = Array.from(new Set(selectedCustomers.map((c) => c.premise_number).filter(Boolean)));
        if (prems.length > 0) {
          writeFocus({ premiseNumbers: prems, grain }, "Drawn area", prems.length);
        }
      } else {
        const accts = selectedCustomers.map((c) => c.account_number);
        if (accts.length > 0) {
          // Count distinct premises (premise_number) for the optimistic display.
          const approxLocations = new Set(selectedCustomers.map((c) => c.premise_number)).size;
          writeFocus({ accountNumbers: accts, grain }, "Drawn area", approxLocations);
        }
      }
    } else {
      const cells = selectedHexIds;
      if (cells.length > 0) {
        // num(): the warehouse-direct /cells route returns n_customers as a
        // JSON string, so a bare `s + r.n_customers` string-concatenates
        // ("0"+"5" → "05") and yields a garbage provisional count. Coerce first.
        const approxLocations = selectedHexes.reduce((s, r) => s + num(r.n_customers), 0);
        // Send grain so the server can implement grain-following spread.
        writeFocus({ hexes: cells, hexRes: effectiveResolution, grain }, cells.length === 1 ? "This hex" : `${cells.length} hexes`, approxLocations || undefined);
      }
    }
    // selectedCustomers/selectedHexIds/writeFocus intentionally omitted: keying
    // on the polygon identity is what scopes this to a fresh selection commit;
    // selectedHexIds/effectiveResolution/grain are read at commit time.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectionPoly, dotsVisible]);

  // ── Context-bar scope. There's one scope now: the focus group (a chosen
  // cohort, or the whole territory by default). The viewport is just navigation.
  const scope: { label: string; kind: "viewport" | "selection" } =
    focusActive ? { label: focusLabel || "Focus group", kind: "selection" }
    : { label: "Service territory", kind: "viewport" };

  const submitAsk = useCallback(async (overrideQuestion?: string) => {
    // Accepts an explicit question (e.g. an empty-state suggestion chip) so
    // callers don't have to round-trip through askInput state — setAskInput
    // followed by submitAsk() in the same handler would still see the old
    // askInput, since this callback's closure only refreshes on next render.
    const q = (overrideQuestion ?? askInput).trim();
    if (!q || asking) return;
    const turnId = Date.now();
    setAsking(true);
    setAskInput("");
    setChatOpen(true);
    // Show the question + a "thinking" answer immediately so the user always
    // sees that their question registered while Genie runs.
    setGenieTurns((prev) => [...prev, { id: turnId, question: q, status: "thinking" }]);
    setAskElapsed(0);
    const t0 = Date.now();
    const timer = setInterval(() => setAskElapsed(Math.round((Date.now() - t0) / 1000)), 500);
    const patch = (p: Partial<GenieTurn>) =>
      setGenieTurns((prev) => prev.map((t) => (t.id === turnId ? { ...t, ...p } : t)));
    try {
      const resp = await fetch("/api/genie/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          question: q,
          conversationId: genieConversationId,
          // "Ask the map" defaults to the focus group when one is active (the
          // server tells Genie it's a labeled segment and to default to it, but
          // to honor "compare" / "vs territory" / "everyone" phrasing in the
          // question itself). With no cohort, it runs across the whole territory.
          sessionId: focusActive ? sessionId : undefined,
        }),
      });
      const data = await resp.json();
      if (!resp.ok || data.error) throw new Error(data.error || `Request failed (${resp.status})`);
      setGenieConversationId(data.conversationId ?? genieConversationId);
      if (data.hasCustomerId && (data.customerIds || []).length > 0) {
        // Customer-set answer → dots on the map + group in the right rail.
        // Drop any single-customer drill / hex focus so the group panel wins
        // (same precedence rule as drawing a fresh box/lasso).
        setDrillSubject(null);
        setSelectedCell(null);
        patch({
          status: "done",
          customers: (data.customers ?? []) as PointRow[],
          count: data.count,
          truncated: !!data.truncated,
          text: data.text || undefined,
        });
        // Auto-promote the answer to the focus cohort (query-defined, so it
        // scales). Only customer-set answers reach here — a "compare vs
        // territory" question returns aggregates, not a customer set, so it
        // never lands in this branch to be wrongly promoted.
        if (typeof data.sql === "string" && data.sql.trim()) {
          writeFocus({ sql: data.sql }, q.length > 40 ? `${q.slice(0, 40)}…` : q);
        }
      } else if (data.text || (data.rows && data.rows.length > 0)) {
        // Analytical / aggregate answer → text + result table in the chat.
        patch({
          status: "done",
          text: data.text || "",
          columns: (data.columns || []) as string[],
          rows: (data.rows || []) as (string | null)[][],
        });
      } else {
        patch({ status: "error", error: "No answer for that. Try rephrasing, or zoom to the area you mean." });
      }
    } catch (e) {
      patch({ status: "error", error: e instanceof Error ? e.message : String(e) });
    } finally {
      clearInterval(timer);
      setAsking(false);
    }
  }, [askInput, asking, genieConversationId, focusActive, sessionId, writeFocus]);

  const resetGenie = useCallback(() => {
    setGenieTurns([]);
    setGenieConversationId(null);
  }, []);

  // Keep the conversation scrolled to the latest turn.
  useEffect(() => {
    const el = chatBodyRef.current;
    if (el && chatOpen) el.scrollTop = el.scrollHeight;
  }, [genieTurns, asking, chatOpen]);

  // ── Program-adoption lens ─────────────────────────────────────────
  // Active when a program layer + a program is picked (and not showing a Genie
  // answer). Dots are then colored binary by adoption status rather than by the
  // attention gradient. derComparison turns on the enrolled-vs-detected
  // discrepancy categories — driven by whether the PROGRAM targets a DER signal
  // (e.g. an EV program), NOT by whether the current viewport happens to hold a
  // detected customer. Otherwise the lens would silently collapse to plain
  // binary whenever you zoomed into a sparse area with no EVs in frame.
  const programMode = !!(layer.needsProgram && programId) && !genieActive;
  // Live-outage mode owns its own dot + incident rendering (red out-dots +
  // open-incident markers), so the normal dot/attention machinery is bypassed.
  const liveMode = !!layer.isLiveOutage && !genieActive;
  const derLabel = useMemo(() => {
    if (!programMode) return null;
    const p = rows(programs.data).find((x) => x.program_id === programId);
    return derLabelForProgram(p?.program_name, programId || undefined);
  }, [programMode, programs.data, programId]);
  const derComparison = programMode && derLabel != null;

  // Passed to the group inspector so it shows the Program section (funnel,
  // trend, recommended targets) for the active lens. Null = no program lens.
  const programLens = useMemo(
    () => (programMode && programId ? { programId, derLabel } : null),
    [programMode, programId, derLabel],
  );

  // Dot coloring follows the active lens: each dot is shaded by the customer's
  // own value for the layer metric (complaints, outage minutes). Falls back to
  // the composite attention_score for layers without a per-customer field.
  // Program mode owns its own (adoption) coloring, so dotMetric is null there.
  const dotMetric = useMemo(() => (programMode ? null : (layer.dotMetric ?? null)), [programMode, layer]);
  const dotField = (dotMetric?.field ?? "attention_score") as keyof PointRow;
  const dotReversed = dotMetric?.reversed ?? false;
  const dotScale = useMemo(() => {
    const src = genieActive ? genieCustomers : pointsCache.rows;
    let mn = Infinity, mx = -Infinity;
    for (const p of src) { const v = num(p[dotField] as number); if (v < mn) mn = v; if (v > mx) mx = v; }
    if (!Number.isFinite(mn)) { mn = 0; mx = 1; }
    if (mn === mx) mx = mn + 1;
    return { min: mn, max: mx };
  }, [dotField, pointsCache.rows, genieActive, genieCustomers]);

  // Viewport tallies for the program legend: how the visible dots split across
  // adoption status. Only meaningful while dots are showing.
  const programCounts = useMemo(() => {
    let enrolledDetected = 0, detectedOnly = 0, enrolledOnly = 0, neither = 0;
    if (programMode) {
      for (const p of pointsCache.rows) {
        const e = !!p.is_enrolled, d = !!p.has_der;
        if (e && d) enrolledDetected++;
        else if (d) detectedOnly++;
        else if (e) enrolledOnly++;
        else neither++;
      }
    }
    return { enrolledDetected, detectedOnly, enrolledOnly, neither };
  }, [programMode, pointsCache.rows]);

  // The shape to render: the in-progress drawing, or the committed selection.
  const drawRing = useMemo<[number, number][] | null>(() => {
    if (selectTool === "box" && drawPts.length === 2) {
      const [a, b] = drawPts;
      return [[a[0], a[1]], [b[0], a[1]], [b[0], b[1]], [a[0], b[1]]];
    }
    if (selectTool === "lasso" && drawPts.length >= 2) return drawPts;
    return null;
  }, [selectTool, drawPts]);
  const shapeToRender = selectionPoly || drawRing;

  // deck.gl layers for "points" mode. The zoomed-out view is the MapLibre
  // value choropleth (cells-fill), so deck only carries the interactive
  // customer dots (fading in by zoom) and the selection shape.
  const deckLayers = useMemo(() => {
    // A blue halo around the drilled customer so the individual focus reads at
    // a glance (paired with dimming every other dot below).
    // Ring all matched dots — a customer-grain selection spans multiple premises,
    // all of which should be outlined (not just the first one found).
    const drillRing = (pts: PointRow[]) => new ScatterplotLayer<PointRow>({
      id: "drill-highlight",
      data: pts,
      getPosition: (d) => [num(d.longitude), num(d.latitude)],
      getFillColor: [0, 0, 0, 0],
      stroked: true,
      getLineColor: [79, 143, 247, 255],
      lineWidthUnits: "pixels",
      getLineWidth: 2.5,
      radiusUnits: "pixels",
      getRadius: 11,
      radiusMinPixels: 9,
      radiusMaxPixels: 13,
      pickable: false,
    });

    const mn = dotScale.min, mx = dotScale.max, span = mx - mn || 1;

    // A Genie answer overrides the zoom tier: render exactly the matched
    // customers as dots at any zoom, colored by the active lens metric.
    const buildGenieLayers = () => {
      const matched = genieCustomers;
      const gDrillPoints = drillSubject ? matched.filter((p) => isDrillMatch(p)) : null;
      const genieLayers: any[] = [
        new ScatterplotLayer<PointRow>({
          id: "genie-dots",
          data: matched,
          getPosition: (d) => [num(d.longitude), num(d.latitude)],
          getFillColor: (d) => {
            const [r, g, b] = colorForValue(num(d[dotField] as number), mn, mx, dotReversed);
            // Dim every dot except the drilled one when an individual is in focus.
            const dim = !!drillSubject && !isDrillMatch(d);
            return [r, g, b, dim ? 40 : 200];
          },
          getRadius: (d) => CUSTOMER_DOT_RADIUS + ((num(d[dotField] as number) - mn) / span) * CUSTOMER_DOT_RADIUS * 1.6,
          radiusUnits: "pixels",
          radiusMinPixels: 2,
          radiusMaxPixels: 7,
          stroked: false,
          pickable: !selectTool,
          autoHighlight: true,
          highlightColor: [79, 143, 247, 230],
          onClick: (info) => {
            const o = info.object as PointRow | undefined;
            // Dot click resolves to the selected grain's inspector, recording
            // the full identity so a later grain flip re-scopes this selection.
            if (o) selectFromPoint(o, grain);
            return true;
          },
          updateTriggers: { getFillColor: [mn, mx, dotField, dotReversed, drillSubject], getRadius: [mn, mx, dotField] },
        }),
      ];
      if (gDrillPoints && gDrillPoints.length > 0) genieLayers.push(drillRing(gDrillPoints));
      return genieLayers;
    };

    // Active outages (live) layer: open-incident markers (visible at every zoom
    // as the storm overview) + currently-out customer dots that fade in as you
    // zoom past the hex → dots hand-off. The "% currently out" hex choropleth is
    // drawn by MapLibre (cells-fill); deck only carries these live overlays.
    const buildLiveLayers = () => {
      const liveLayers: any[] = [];
      const dotOpacity = dotOpacityForZoom(fadeZoom);
      if (dotOpacity > 0 && activeOutagePointsCache.length > 0) {
        liveLayers.push(new ScatterplotLayer<ActiveOutagePointRow>({
          id: "active-out-dots",
          data: activeOutagePointsCache,
          opacity: dotOpacity,
          getPosition: (d) => [num(d.longitude), num(d.latitude)],
          // Critical-care customers who are out get an amber dot (priority
          // restoration); everyone else is red.
          getFillColor: (d) => (d.critical_care_flag ? [255, 205, 40, 235] : [239, 68, 68, 225]),
          getRadius: (d) => (d.critical_care_flag ? CUSTOMER_DOT_RADIUS * 1.6 : CUSTOMER_DOT_RADIUS),
          radiusUnits: "pixels",
          radiusMinPixels: 2,
          radiusMaxPixels: 6,
          stroked: false,
          pickable: !selectTool,
          autoHighlight: true,
          highlightColor: [255, 255, 255, 200],
          onClick: (info) => {
            const o = info.object as ActiveOutagePointRow | undefined;
            if (o) selectPremise(o.premise_number);
            return true;
          },
          updateTriggers: { getFillColor: [], getRadius: [] },
        }));
      }
      // Open-incident markers: sized by customers out, red when major-event.
      liveLayers.push(new ScatterplotLayer<ActiveOutageIncidentRow>({
        id: "active-incidents",
        data: activeIncidents,
        getPosition: (d) => [num(d.centroid_lon), num(d.centroid_lat)],
        getFillColor: (d) => (bool(d.is_major_event_day) ? [185, 28, 28, 230] : [249, 115, 22, 220]),
        getLineColor: [255, 255, 255, 235],
        stroked: true,
        lineWidthUnits: "pixels",
        getLineWidth: 1.5,
        getRadius: (d) => 8 + Math.sqrt(num(d.n_customers_out)) * 1.6,
        radiusUnits: "pixels",
        radiusMinPixels: 7,
        radiusMaxPixels: 36,
        pickable: true,
        autoHighlight: true,
        highlightColor: [255, 255, 255, 120],
      }));
      return liveLayers;
    };

    if (genieActive && genieCustomers.length > 0) return buildGenieLayers();
    if (liveMode) return buildLiveLayers();

    // Below the fade window, or before points have loaded, the density cloud
    // (a native MapLibre heatmap) carries the view by itself — deck draws
    // nothing. As we cross DOTS_FADE_START the dots fade in on top of the
    // still-glowing cloud, so the field never has a gap. (`dotOpacity` is the
    // memo above — it also covers the pinned Dots/Hexes render modes.)
    // The drawn selection shape renders at any zoom (over dots OR hexes), so the
    // box/lasso is visible while selecting a zoomed-out region too.
    const shapeLayer = shapeToRender && shapeToRender.length >= 2
      ? new PolygonLayer<[number, number][]>({
          id: "selection-shape",
          data: [shapeToRender],
          getPolygon: (d) => d as any,
          filled: true,
          getFillColor: [79, 143, 247, 28],
          stroked: true,
          getLineColor: [79, 143, 247, 220],
          getLineWidth: 2,
          lineWidthUnits: "pixels",
          pickable: false,
        })
      : null;
    if (dotOpacity <= 0 || pointsCache.rows.length === 0) return shapeLayer ? [shapeLayer] : [];

    const hasSel = selectedIds.size > 0;
    const hasDrill = !!drillSubject;
    // Precomputed RGB for the program-adoption lens (avoids per-point hex parse).
    const paEnrolledDetected = hexToRgb(PROGRAM_ADOPTION_PALETTE.enrolledDetected);
    const paDetectedOnly = hexToRgb(PROGRAM_ADOPTION_PALETTE.detectedOnly);
    const paEnrolledOnly = hexToRgb(PROGRAM_ADOPTION_PALETTE.enrolledOnly);
    const paNeither = hexToRgb(PROGRAM_ADOPTION_PALETTE.neither);
    const layers: any[] = [
      new ScatterplotLayer<PointRow>({
        id: "customer-dots",
        data: pointsCache.rows,
        // Layer-level opacity drives the cross-fade — a cheap uniform, so the
        // fade costs nothing per frame (no per-point attribute recompute).
        opacity: dotOpacity,
        getPosition: (d) => [num(d.longitude), num(d.latitude)],
        getFillColor: (d) => {
          // Focus dimming: when an individual is drilled, only that dot stays
          // lit; otherwise a box/lasso selection dims the customers outside it.
          const inSel = hasDrill
            ? isDrillMatch(d)
            : (!hasSel || selectedIds.has(d.account_number));
          // A live cohort additionally dims everything outside it, so the focus
          // set pops over the territory (server-side `in_focus` per dot). Gated
          // on cohortPointsReady (not focusActive) so during the round-trip
          // after a cohort change — before any loaded dot carries a real
          // `in_focus` — dimming holds the previous paint instead of blanking
          // the whole layer for a beat (see cohortPointsReady above).
          const lit = inSel && (!cohortPointsReady || !!d.in_focus);
          // Program lens: binary adoption status (optionally cross-referenced
          // against the program's DER signal), NOT the attention gradient.
          if (programMode) {
            const e = !!d.is_enrolled, det = !!d.has_der;
            let rgb: RGB; let relevant: boolean;
            if (derComparison) {
              if (e && det)   { rgb = paEnrolledDetected; relevant = true; }
              else if (det)   { rgb = paDetectedOnly;     relevant = true; }
              else if (e)     { rgb = paEnrolledOnly;     relevant = true; }
              else            { rgb = paNeither;          relevant = false; }
            } else {
              if (e)          { rgb = paEnrolledDetected; relevant = true; }
              else            { rgb = paNeither;          relevant = false; }
            }
            const a = relevant ? 235 : 26;
            return [rgb[0], rgb[1], rgb[2], lit ? a : Math.min(a, 18)];
          }
          const [r, g, b] = colorForValue(num(d[dotField] as number), mn, mx, dotReversed);
          return [r, g, b, lit ? 235 : 30];
        },
        // Crisp markers that grow a little with the active metric. In program
        // mode, the relevant (enrolled / detected) dots are enlarged to pop.
        getRadius: (d) => {
          if (programMode) {
            const relevant = derComparison ? (!!d.is_enrolled || !!d.has_der) : !!d.is_enrolled;
            return relevant ? CUSTOMER_DOT_RADIUS_METERS * 1.5 : CUSTOMER_DOT_RADIUS_METERS * 0.8;
          }
          return CUSTOMER_DOT_RADIUS_METERS + ((num(d[dotField] as number) - mn) / span) * CUSTOMER_DOT_RADIUS_METERS;
        },
        // Ground-scale radius so density reads correctly at every zoom (see
        // CUSTOMER_DOT_RADIUS_METERS) — radiusMin/MaxPixels still clamp the
        // rendered size in screen space, same as when this was pixel-based.
        radiusUnits: "meters",
        radiusMinPixels: 1.5,
        radiusMaxPixels: CUSTOMER_DOT_MAX_PX,
        stroked: false,
        // Disable picking while drawing so a drag-release doesn't also
        // fire a dot click → open drill panel.
        pickable: !selectTool,
        autoHighlight: true,
        highlightColor: [79, 143, 247, 230],
        onClick: (info) => {
          const o = info.object as PointRow | undefined;
          // Dot click resolves to the selected grain's inspector.
          if (o) {
            if (grain === "premise") selectPremise(o.premise_number);
            else selectCustomer(o.account_number);
          }
          return true;
        },
        updateTriggers: {
          getFillColor: [mn, mx, dotField, dotReversed, hasSel, selectedIds, programMode, derComparison, drillSubject, cohortPointsReady, focusVersion],
          getRadius: [mn, mx, dotField, programMode, derComparison],
        },
      }),
    ];
    // Halo all matched dots — a customer-grain selection spans multiple premises.
    if (hasDrill) {
      const dps = pointsCache.rows.filter((p) => isDrillMatch(p));
      if (dps.length > 0) layers.push(drillRing(dps));
    }
    if (shapeLayer) layers.push(shapeLayer);
    return layers;
  }, [fadeZoom, dotOpacity, pointsCache.rows, selectPremise, selectCustomer, selectFromPoint, isDrillMatch,
      selectTool, selectedIds, shapeToRender, genieActive, genieCustomers,
      programMode, derComparison, drillSubject, dotField, dotReversed, dotScale,
      cohortPointsReady, focusVersion, grain,
      liveMode, activeOutagePointsCache, activeIncidents]);

  // Tooltip for deck layers (hex + dots). Heatmap isn't pickable.
  const getDeckTooltip = useCallback((info: any) => {
    const o = info.object;
    if (!o) return null;
    if (info.layer?.id === "customer-dots" || info.layer?.id === "genie-dots") {
      const p = o as PointRow;
      // Lead with the value the dot is colored by, so the color is legible.
      const metricLine = dotMetric
        ? `${dotMetric.label}: ${fmtNum(num(p[dotMetric.field as keyof PointRow] as number), 0)}${dotMetric.unit}`
        : null;
      const tags = [
        p.payment_stressed_flag ? "payment stress" : null,
        p.complaint_risk_tier === "high" || p.complaint_risk_tier === "elevated"
          ? `${p.complaint_risk_tier} complaint risk${p.complaint_risk_category ? ` (${p.complaint_risk_category})` : ""}`
          : null,
        p.churn_risk_band === "high" ? "dissatisfied" : null,
        p.critical_care_flag ? "critical care" : null,
        num(p.recent_complaint_count_90d) >= 2 ? `${p.recent_complaint_count_90d} complaints` : null,
      ].filter(Boolean).join(" · ");
      return `${metricLine ? metricLine + "\n" : ""}${p.customer_class} · ${p.engagement_tier} engagement${tags ? "\n" + tags : ""}`;
    }
    if (info.layer?.id === "active-incidents") {
      const i = o as ActiveOutageIncidentRow;
      const cc = num(i.n_critical_care_out) > 0 ? `\n${fmtNum(i.n_critical_care_out)} critical-care` : "";
      return `${fmtNum(i.n_customers_out)} customers out · ${(i.cause_code || "").replace(/_/g, " ")}\nCrew: ${(i.crew_status || "").replace(/_/g, " ")} · ETA ~${fmtDuration(i.eta_minutes)}${cc}`;
    }
    if (info.layer?.id === "active-out-dots") {
      const p = o as ActiveOutagePointRow;
      const cc = p.critical_care_flag ? "\ncritical care · priority restoration" : "";
      return `Out for ${fmtDuration(p.minutes_out_so_far)} · ${(p.cause_code || "").replace(/_/g, " ")}\nCrew: ${(p.crew_status || "").replace(/_/g, " ")}${cc}`;
    }
    if (info.layer?.id === "h3-hex") {
      const v = layer.kind === "categorical"
        ? (o.dominant_theme || "none").replace(/_/g, " ")
        : `${fmtNum(num(o[layer.property]), 1)}${layer.unit}`;
      return `${fmtNum(num(o.n_customers))} customers · ${layer.label}: ${v}`;
    }
    return null;
  }, [layer, dotMetric]);

  // MapLibre paint expression for the choropleth.
  const fillColor = useMemo(() => {
    if (layer.kind === "categorical") {
      return categoricalColorExpression(layer.property);
    }
    return numericColorExpression(layer.property, minVal, maxVal, layer.kind === "numeric_reversed");
  }, [layer, minVal, maxVal]);

  // Only update zoom + bounds when the gesture FINISHES. During a pan
  // or zoom we keep the previous params (= previous data on screen),
  // so the cells don't disappear mid-gesture.
  // Track zoom continuously (every frame of the gesture) purely to drive the
  // dot cross-fade opacity. Bounds + the settled `zoom` still update only on
  // move-end, so data fetches don't fire mid-gesture.
  const onMove = useCallback((evt: ViewStateChangeEvent) => {
    setLiveZoom(evt.viewState.zoom);
  }, []);

  // Buffered viewport fetch: `bounds` (what we actually query with) is the
  // viewport padded by VIEWPORT_PAD, and we skip updating it entirely — no
  // refetch — while the new viewport is still covered by the last padded
  // bbox we loaded. Small pans reuse data already on hand (no edge blanking,
  // no extra warehouse round trip); a pan/zoom that escapes the padded area
  // still fetches, padded again around the new viewport.
  // Seeded with the same initial estimate as `bounds` so the first onMoveEnd
  // (after the basemap loads) only re-fetches if the real viewport differs.
  const lastFetchedBoundsRef = useRef<Bounds | null>(initialBoundsFromView());

  const onMoveEnd = useCallback((evt: ViewStateChangeEvent) => {
    const map = evt.target;
    const b = map.getBounds();
    const viewport: Bounds = {
      south: b.getSouth(),
      north: b.getNorth(),
      west:  b.getWest(),
      east:  b.getEast(),
    };
    setZoom(evt.viewState.zoom);
    setLiveZoom(evt.viewState.zoom);
    if (lastFetchedBoundsRef.current && boundsContain(lastFetchedBoundsRef.current, viewport)) return;
    const padded = padBounds(viewport, VIEWPORT_PAD);
    lastFetchedBoundsRef.current = padded;
    setBounds(padded);
  }, []);

  // Holds the ResizeObserver attached in onLoad below (disconnected on
  // unmount by the effect right after it).
  const resizeObserverRef = useRef<ResizeObserver | null>(null);

  // Refine bounds with the exact MapLibre viewport once the basemap has loaded.
  // The initial query was already dispatched from `initialBoundsFromView()`;
  // this update corrects for any difference between the estimate and the real
  // container size, and populates `lastFetchedBoundsRef` with exact values.
  const onLoad = useCallback(() => {
    const map = mapRef.current;
    if (!map) return;
    const b = map.getBounds();
    const padded = padBounds({
      south: b.getSouth(),
      north: b.getNorth(),
      west:  b.getWest(),
      east:  b.getEast(),
    }, VIEWPORT_PAD);
    lastFetchedBoundsRef.current = padded;
    setBounds(padded);
    // Belt-and-braces 2D lock: trackpad pinch can still add bearing even with
    // dragRotate/touchPitch disabled on <Map>, so kill rotation at the gesture
    // handler too.
    const maplibreMap = map.getMap();
    maplibreMap.touchZoomRotate.disableRotation();

    // Dev-only escape hatch for inspecting MapLibre's transform/canvas state
    // directly (e.g. after a tab round-trip). Stripped from production bundles.
    if (import.meta.env.DEV) (window as any).__c360map = maplibreMap;

    // Guard against MapLibre losing sync with its container — e.g. the
    // drill-rail opening/closing while Explorer is visible, or (belt and
    // braces alongside App.css's .is-hidden, which keeps the container's box
    // non-degenerate while a different nav view is showing) any resize that
    // slips through anyway. Attached here, not in an empty-deps effect: react-
    // map-gl instantiates the MapLibre instance in a microtask after mount, so
    // an effect that reads mapRef.current with `[]` deps runs before it exists
    // and permanently no-ops (confirmed root cause of the old dead observer).
    const el = maplibreMap.getContainer();
    const ro = new ResizeObserver(() => {
      if (el.clientWidth > 0 && el.clientHeight > 0) maplibreMap.resize();
    });
    ro.observe(el);
    resizeObserverRef.current = ro;
  }, []);

  useEffect(() => () => resizeObserverRef.current?.disconnect(), []);

  // Explicit resize on the hidden -> visible edge (tab return). Fix 1
  // (.explorer-root.is-hidden) already keeps the container non-degenerate the
  // whole time, so this is a cheap safety net — harmless when dimensions
  // haven't actually changed — for anything the ResizeObserver above doesn't
  // catch, e.g. the interleaved deck.gl overlay needing its own redraw fired
  // after the transition.
  useEffect(() => {
    if (!visible) return;
    const raf = requestAnimationFrame(() => mapRef.current?.getMap()?.resize());
    return () => cancelAnimationFrame(raf);
  }, [visible]);

  const onMapClick = useCallback((e: MapLayerMouseEvent) => {
    // Hex click: in the zoomed-out choropleth (dots not yet showing), clicking a
    // hexagon makes that cell's customers the focus group (like draw / attributes
    // / words — just another way to choose it). Once dots are visible deck owns
    // picking, and during a Genie answer the cells are hidden — so ignore both.
    if (genieActive || dotsVisible) return;
    const features = e.features || [];
    const cellFeature = features.find((f) => f.layer?.id === "cells-fill");
    const h3 = typeof cellFeature?.properties?.h3_index === "string"
      ? (cellFeature.properties.h3_index as string) : null;
    const clickedCell = h3 ? baseCache.rows.find((r) => r.h3_index === h3) : undefined;
    // A cell is "populated" if it exists in the current cell set with at least
    // MIN_CUSTOMERS_FOR_COLOR customers. A cohort-blanked cell (no row in the
    // cohort-scoped geojson), a gray/empty cell, or a click that missed any cell
    // entirely all fall into the empty-click path (→ clear to territory).
    // NOTE: we test here, never by disabling cells-fill interactivity — that
    // would break click-drill through the layer to underlying map features.
    const hitPopulatedHex = !!clickedCell && num(clickedCell.n_customers) >= MIN_CUSTOMERS_FOR_COLOR;

    if (!hitPopulatedHex) {
      // Empty click (blank space, gray cell, or cohort-blanked cell) → clear to
      // territory, exactly like the dots tier. Undoable via toast. Also drop
      // any box/lasso region: selectionPoly drives BOTH the blue selection box and
      // the per-hex blue outlines (selectedHexes), so leaving it set would strand
      // those outlines on the map after the focus is gone. lastFocusPolyRef reset
      // so an identical redraw still re-commits.
      setSelectedCell(null);
      setSelectionPoly(null);
      setDrawPts([]);
      lastFocusPolyRef.current = null;
      if (focusActive) clearFocus();
      return;
    }

    // Populated hex → commit it as the focus, superseding any prior box shape
    // WITHOUT dropping the focus (don't call clearSelection, which also nulls
    // selectedCell and would kill the outline for this frame).
    setSelectionPoly(null);
    setDrawPts([]);
    lastFocusPolyRef.current = null;
    if (h3 === selectedCell) return; // already focused — avoid needless round-trip
    setSelectedCell(h3);
    setDrillSubject(null);
    writeFocus(
      { hex: { cellId: h3!, resolution: effectiveResolution }, grain },
      "This hex",
      clickedCell!.n_customers,
    );
  }, [genieActive, dotsVisible, focusActive, clearFocus, writeFocus, effectiveResolution, baseCache.rows, selectedCell, grain]);

  const onMapMouseDown = useCallback((e: MapLayerMouseEvent) => {
    if (!selectTool) return;
    drawingRef.current = true;
    setDrawPts([[e.lngLat.lng, e.lngLat.lat]]);
    setSelectionPoly(null);
  }, [selectTool]);

  const onMapMouseMove = useCallback((e: MapLayerMouseEvent) => {
    if (!drawingRef.current || !selectTool) return;
    const pt: [number, number] = [e.lngLat.lng, e.lngLat.lat];
    setDrawPts((prev) => (selectTool === "box" ? [prev[0] || pt, pt] : [...prev, pt]));
  }, [selectTool]);

  const onMapMouseUp = useCallback(() => {
    if (!drawingRef.current) return;
    drawingRef.current = false;
    setDrawPts((prev) => {
      let poly: [number, number][] | null = null;
      if (selectTool === "box" && prev.length === 2) {
        const [a, b] = prev;
        poly = [[a[0], a[1]], [b[0], a[1]], [b[0], b[1]], [a[0], b[1]]];
      } else if (selectTool === "lasso" && prev.length >= 3) {
        poly = prev;
      }
      if (poly) {
        setSelectionPoly(poly);
        // A fresh group/region supersedes whatever single customer or hex was
        // last focused — otherwise that panel keeps winning the render
        // precedence and the user never sees what they just drew.
        setDrillSubject(null);
        setSelectedCell(null);
      }
      return [];
    });
    setSelectTool(null); // exit the tool but keep the selection
  }, [selectTool]);

  const clearSelection = useCallback(() => {
    setSelectionPoly(null);
    setDrawPts([]);
    setSelectTool(null);
    setSelectedCell(null);
  }, []);

  // Click on empty map (no dot) to dismiss the current focus. deck only calls
  // this top-level onClick when no pickable object was hit (the dot layer's
  // onClick returns true and stops here), so dot selection is unaffected.
  // Clicking INSIDE an active selection shape is left alone — that's
  // interacting with the group; only a click OUTSIDE it clears.
  const onDeckClick = useCallback((info: any) => {
    if (info?.object || selectTool) return; // hit a dot, or mid-draw
    // In the hex tier, MapLibre's cells-fill owns all click handling (onMapClick).
    // deck must not race onMapClick — a simultaneous fire causes non-deterministic
    // focus clears or double-commits. Guard here so deck is fully silent in hex view.
    if (!dotsVisible && !genieActive) return;
    const c = info?.coordinate;
    if (selectionPoly && c && pointInPolygon(c[0], c[1], selectionPoly)) return;
    if (selectionPoly) { clearSelection(); setDrillSubject(null); return; }
    if (genieCustomers.length > 0) { resetGenie(); setDrillSubject(null); return; }
    if (drillSubject) { closeDrill(); }
  }, [selectTool, dotsVisible, genieActive, selectionPoly, genieCustomers.length, drillSubject, clearSelection, resetGenie, closeDrill]);

  // "Frame territory" — pure navigation: fit the camera to every customer in the
  // dataset. Always available; does NOT touch the focus group (clearing is a
  // separate, explicit action so reframing the map never drops your cohort).
  const frameTerritory = useCallback(() => {
    const m = mapRef.current;
    if (!m) return;
    if (territoryBounds) {
      m.fitBounds(
        [[territoryBounds.west, territoryBounds.south], [territoryBounds.east, territoryBounds.north]],
        { padding: 48, duration: 800 },
      );
    } else {
      m.flyTo({ center: [INITIAL_VIEW.longitude, INITIAL_VIEW.latitude], zoom: INITIAL_VIEW.zoom, duration: 800 });
    }
  }, [territoryBounds]);

  // "Clear focus" — drop the focus group entirely (the drawn shape, any Genie
  // answer, and the cohort), returning metrics to the whole-territory default.
  // Leaves the camera where it is so you keep your place; use Frame territory to
  // reframe the macro view.
  const clearFocusGroup = useCallback(() => {
    clearSelection();
    resetGenie();
    clearFocus();
    // Attribute filters are a separate live-slice state (see nActiveFilters /
    // the top-bar filter chip) — clear them too, or "Clear focus" would leave
    // the map silently narrowed even though the tooltip promises a return to
    // the whole territory.
    setFilters(emptyFilterState());
  }, [clearSelection, resetGenie, clearFocus]);

  // "Frame cohort" — fit the map to the focus set's extent, but keep the zoom in
  // the DOTS range so the focus group stays visible as highlighted dots. Without
  // a zoom floor, framing a spread cohort drops below DOTS_FADE_START and the map
  // swaps to the full-color hex choropleth — which hides what's actually selected.
  const frameCohort = useCallback(() => {
    const ext = focusSummary?.extent;
    const m = mapRef.current;
    if (!m || !ext) return;
    const bbox: [[number, number], [number, number]] = [[ext.west, ext.south], [ext.east, ext.north]];
    const cam = typeof m.cameraForBounds === "function" ? m.cameraForBounds(bbox, { padding: 64 }) : null;
    if (cam && typeof cam.zoom === "number" && cam.center) {
      // Clamp into [DOTS_FADE_END, 13]: never zoom out into the hex view, never
      // over-zoom a tiny cohort. A cohort wider than the dots view shows its
      // dense centre as dots; the user can pan to see the rest.
      m.flyTo({ center: cam.center, zoom: Math.min(Math.max(cam.zoom, DOTS_FADE_END), 13), duration: 800 });
    } else {
      m.fitBounds(bbox, { padding: 64, duration: 800, maxZoom: 13 });
    }
  }, [focusSummary]);

  // Top-bar search picked a customer, or the profile drawer asked to show all
  // locations for a multi-site customer: drop any group/genie context, fly/fit
  // the map to them, and open their individual drill. Keyed on the request
  // timestamp so re-picking the same customer still re-focuses.
  useEffect(() => {
    if (!focus) return;
    // Drawer location-switch: sync to one premise without tearing down the
    // active cohort/genie context. pivotSubject flies the camera and sets the
    // drill (blue halo), reusing the same path as the in-map rail pivot.
    if (focus.premiseNumber && !focus.account) {
      pivotSubject({ kind: "premise", premiseNumber: focus.premiseNumber, lat: focus.lat, lon: focus.lon });
      return;
    }
    clearSelection();
    resetGenie();
    if (focus.account) setDrillSubject({ kind: "customer", accountNumber: focus.account });
    const m = mapRef.current;
    if (!m) return;
    // Multiple premises (e.g. a chain customer's sites): fit the camera to
    // their extent instead of flying to one point. Unlike frameCohort, no
    // zoom FLOOR here — sites can be spread across counties, and forcing a
    // minimum zoom would crop some out of view. Only cap the max zoom so a
    // tightly-clustered set doesn't over-zoom.
    const pts = focus.points && focus.points.length > 1 ? focus.points : null;
    if (pts) {
      const lons = pts.map((p) => p.lon);
      const lats = pts.map((p) => p.lat);
      const bbox: [[number, number], [number, number]] = [
        [Math.min(...lons), Math.min(...lats)],
        [Math.max(...lons), Math.max(...lats)],
      ];
      const cam = typeof m.cameraForBounds === "function" ? m.cameraForBounds(bbox, { padding: 80 }) : null;
      if (cam && typeof cam.zoom === "number" && cam.center) {
        m.flyTo({ center: cam.center, zoom: Math.min(cam.zoom, 13), duration: 900 });
      } else {
        m.fitBounds(bbox, { padding: 80, duration: 900, maxZoom: 13 });
      }
    } else if (Number.isFinite(focus.lat) && Number.isFinite(focus.lon)) {
      m.flyTo({ center: [focus.lon, focus.lat], zoom: Math.max(zoom, 13.5), duration: 900 });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focus?.ts]);

  return (
    <div className="explorer-shell">
      <div className="explorer-context-bar">
        <div className="context-scope">
          <span className={`context-dot ${scope.kind}`} />
          {focusActive ? (
            <>
              {/* The scope label IS the focus-group identity; the count shows
                  once here (deduped from the launcher button) and in lockstep
                  with the rail header. */}
              <span className="context-scope-label"><strong>{scope.label}</strong></span>
              {groupData && (
                <span className={`context-count${groupLoading ? " is-refreshing" : ""}`}>
                  {formatUnitCount(
                    fmtNum(grain === "customer" ? (groupData.distinctCustomers ?? groupData.total ?? 0) : (groupData.total ?? 0)),
                    grain === "customer" ? (groupData.distinctCustomers ?? groupData.total ?? 0) : (groupData.total ?? 0),
                    grain === "customer" ? "customer" : "premise",
                  )}
                </span>
              )}
            </>
          ) : (
            <span className="context-scope-label"><strong>Service territory</strong></span>
          )}
        </div>
        {/* Master grain selector — drives the headline count, dot selection
            semantics, and the default inspector that opens on a dot click. */}
        <div className="grain-selector" title="Choose the entity your clicks and counts refer to">
          <span className="map-select-label">View by</span>
          {(["customer", "premise"] as const).map((g) => {
            const grainSupported = (layer.supportedGrains ?? ['premise', 'customer']).includes(g);
            return (
              <button
                key={g}
                type="button"
                className={`map-select-btn ${grain === g ? "active" : ""} ${!grainSupported ? "disabled" : ""}`}
                aria-disabled={!grainSupported}
                title={!grainSupported ? "This layer's metric is customer-level — grain locked to Customer" : undefined}
                onClick={() => {
                  if (!grainSupported) return;
                  preSnapGrainRef.current = null;
                  setGrain(g);
                }}
              >
                {g === "customer" ? "Customer" : "Premise"}
              </button>
            );
          })}
        </div>
        <div className="context-actions">
          {/* Attribute filters are a live view-slice independent of the focus
              cohort (nActiveFilters can be > 0 with no focus group active) —
              surface them here so the narrowing is never invisible at the top
              level. Clicking ✕ resets filters only; the cohort (if any) is
              untouched. */}
          {nActiveFilters > 0 && (
            <button
              type="button"
              className="context-btn"
              onClick={() => setFilters(emptyFilterState())}
              title={`Map is sliced by: ${filterSummary}. Click to clear.`}
            >
              ⧩ {nActiveFilters} attribute{nActiveFilters > 1 ? "s" : ""} ✕
            </button>
          )}
          <button
            type="button"
            className="context-btn"
            onClick={frameTerritory}
            title="Zoom the map to fit the entire service territory"
          >
            ⤢ Frame territory
          </button>
          {focusActive && (
            <button
              type="button"
              className="context-btn"
              onClick={frameCohort}
              disabled={!focusSummary?.extent}
              title="Zoom the map to fit the focus group"
            >
              ⤢ Frame focus
            </button>
          )}
          {focusActive && (
            <button
              type="button"
              className="context-btn"
              onClick={clearFocusGroup}
              title="Clear the focus group — metrics return to the whole territory"
            >
              ✕ Clear focus
            </button>
          )}
          <div className="focus-launcher">
            <button
              type="button"
              className={`context-btn primary ${focusPanelOpen ? "open" : ""}`}
              onClick={() => setFocusPanelOpen((o) => !o)}
              title={focusActive
                ? "Edit the focus group, or define a new one (words, attributes, or drawing)"
                : "Build a focus group: in words, by attributes, or by drawing on the map"}
            >
              {focusActive ? "✎ Edit focus" : "⊕ Build focus group"}
            </button>
          </div>
        </div>
      </div>
    <div className="explorer-map-wrap">
      <div className="explorer-map-container">
        <div className="map-toolbar">
          <div className="map-layer-picker">
            <label>Layer</label>
            <select value={layerId} onChange={(e) => {
              const newId = e.target.value;
              const spec = LAYERS.find((l) => l.id === newId);
              const supported = spec?.supportedGrains ?? (['premise', 'customer'] as const);
              const g = grain as 'premise' | 'customer';
              if (!supported.includes(g)) {
                // New layer doesn't support current grain — snap to customer and remember.
                preSnapGrainRef.current = g;
                setGrain(supported[0] as Grain);
              } else if (preSnapGrainRef.current !== null && supported.includes(preSnapGrainRef.current)) {
                // Returning from a customer-only layer — restore the remembered grain.
                setGrain(preSnapGrainRef.current as Grain);
                preSnapGrainRef.current = null;
              }
              setLayerId(newId);
            }}>
              {LAYERS.map((l) => (
                <option key={l.id} value={l.id}>{l.label}</option>
              ))}
            </select>
            {(baseCellsLoading || pointsLoading || (layer.needsProgram && programCellsLoading) || (layer.isLiveOutage && activeCellsLoading)) && (
              <span className="map-loading-pip" title="Updating…" />
            )}
            {pointsError && !pointsLoading && (
              <span className="map-loading-pip" style={{ background: "var(--red, #ef4444)", animation: "none" }} title="Customer dots unavailable — pan or zoom to retry" />
            )}
          </div>
          {/* Complaint volume can be focused on one complaint theme — pick a
              sub-category to recolor the map by just that theme's volume. */}
          {layerId === "complaints_per_1k" && (
            <div className="map-program-picker">
              <label>Theme</label>
              <select value={complaintTheme} onChange={(e) => setComplaintTheme(e.target.value)}>
                <option value="">All complaints</option>
                {COMPLAINT_THEME_GROUPS.map((g) => (
                  <optgroup key={g.category} label={g.category}>
                    {g.options.map((o) => (
                      <option key={o.value} value={o.value}>{o.label}</option>
                    ))}
                  </optgroup>
                ))}
              </select>
            </div>
          )}
          {/* Program sub-selection sits on its OWN row beneath the layer
              picker — program names are long, so keeping it inline pushed the
              select out past the toolbar box and over the map. */}
          {layer.needsProgram && (
            <div className="map-program-picker">
              <label>Program</label>
              <select
                value={programId || ""}
                onChange={(e) => setProgramId(e.target.value)}
                disabled={programs.loading}
              >
                {rows(programs.data).map((p) => (
                  <option key={p.program_id} value={p.program_id}>{p.program_name}</option>
                ))}
              </select>
            </div>
          )}
          {/* The render mode (density cloud vs. individual dots) is already
              obvious from the map and spelled out by the legend, so we don't
              prepend a Density/Dots chip to the layer description. */}
          <div className="map-layer-desc">
            <span className="map-layer-desc-text">{
              grain === "premise"
                ? layer.id === "complaints_per_1k" ? "Complaints per 1,000 premises in the last 90 days. ~35% of complaints can't be attributed to a specific address and are excluded from this count."
                : layer.id === "outage_exposure"   ? "Average outage minutes per premise in the last 90 days."
                : layer.id === "program_enrolled"  ? "Per-premise dots colored by enrollment in the selected program. Only the enrolled site lights up for multi-site customers. Zoomed out, a hex grid shaded by enrollment rate."
                : layer.description
                : layer.description
            }</span>
          </div>
          {/* Force dots or hexes at any zoom, instead of the automatic
              cross-fade. Disabled (and reads as Auto) during a Genie answer
              or the live-outage layer — both own their own rendering, so
              pinning a mode there wouldn't do anything. */}
          <div
            className="map-render-mode"
            title={renderModeLocked ? "Not available for this view" : "Force dots or hexes at any zoom, or follow the automatic zoom fade"}
          >
            <span className="map-select-label">Show</span>
            {(["auto", "dots", "hex"] as const).map((m) => (
              <button
                key={m}
                type="button"
                className={`map-select-btn ${effectiveRenderMode === m ? "active" : ""}`}
                disabled={renderModeLocked}
                onClick={() => setRenderMode(m)}
              >
                {m === "auto" ? "Auto" : m === "dots" ? "Dots" : "Hexes"}
              </button>
            ))}
          </div>
          {/* Hex-density slider — present whenever the hex choropleth is the
              view (zoomed out in Auto, or pinned to Hexes at any zoom; never
              during a Genie answer). Each position is an absolute H3
              resolution (5 coarse → 9 fine), so every notch visibly re-bins the
              grid. "Auto" returns to the per-zoom default. */}
          {!genieActive && (effectiveRenderMode === "hex" || (effectiveRenderMode === "auto" && !dotsVisible)) && (
            <div className="map-density" title="Set the hex size. Coarser = bigger regions, finer = smaller blocks. Auto follows the zoom level.">
              <span className="map-density-label">Hex density</span>
              <span className="map-density-end">coarser</span>
              <input
                type="range"
                min={HEX_RES_MIN}
                max={HEX_RES_MAX}
                step={1}
                value={resolution}
                onChange={(e) => setHexResOverride(Number(e.target.value))}
                aria-label="Hex density"
              />
              <span className="map-density-end">finer</span>
              {/* Persistent "Auto" toggle. Rendered whether or not a level is
                  pinned so the slider track doesn't reflow when it appears.
                  Highlighted (is-on) while the hex size follows the zoom; muted
                  but clickable once the user has pinned a level, where clicking
                  it returns to the per-zoom default. */}
              <button
                type="button"
                className={`map-density-reset${hexResOverride === null ? " is-on" : ""}`}
                onClick={() => setHexResOverride(null)}
                aria-pressed={hexResOverride === null}
                title={hexResOverride === null
                  ? "On — hex size follows the zoom level"
                  : "Back to the automatic size for this zoom"}
              >
                Auto
              </button>
              {/* Live readout of the resolution the slider currently maps to, so
                  the hex size on the map is legible. "finest"/"coarsest" marks the
                  ends of the available range (res 5/9). */}
              <span className="map-density-readout" title="Current hex size">
                {hexResReadout(resolution)}
              </span>
            </div>
          )}
          {/* Honesty guardrail: when the viewport's true customer count
              exceeds the /points cap, say so instead of silently truncating —
              seeing 15,000 dots with no count reads as "that's everyone". */}
          {pointsSampled && (
            <div className="map-sample-pill" title="Zoom in or narrow filters to see every customer in view">
              Showing {fmtNum(pointsCache.rows.length)} of {fmtNum(pointsTotal)}
            </div>
          )}
          {/* While a draw tool is armed (from the Focus group panel), show a
              hint + a way to cancel right on the map. */}
          {selectTool && (
            <div className="map-select-bar">
              <span className="map-select-label">Drawing — drag on the map to select {dotsVisible ? "customers" : "region"}</span>
              <button type="button" className="map-select-clear" onClick={clearSelection}>Cancel</button>
            </div>
          )}
        </div>

        {/* Grain-spread note: transient, dismissible. Shown only in the
            hex tier when a Customer-grain selection lit hexes beyond the drawn
            area (because premise_id is NULL → every hex holding any premise of
            the cohort's customers lights up). */}
        {!dotsVisible && selectionSpreadAcrossHexes && !spreadNoteDismissed && (
          <div className="map-spread-note" role="status">
            <span>Customer grain — these customers' premises in other areas are highlighted too.</span>
            <button
              type="button"
              className="map-spread-note-dismiss"
              onClick={() => setSpreadNoteDismissed(true)}
              aria-label="Dismiss"
            >×</button>
          </div>
        )}

        {/* Undo toast: shown after an accidental empty-click clear.
            Auto-dismisses after 7 s; clicking Undo replays the last cohort. */}
        {undoSnapshot && (
          <div className="map-undo-toast" role="status">
            <span>Focus cleared</span>
            <button type="button" className="map-undo-btn" onClick={restoreFocus}>Undo</button>
          </div>
        )}

        {/* Center-screen cue while the H3 grid is re-resolving on zoom, or
            while a hex cohort commit is in the blank-then-reveal gap.
            Purely additive (pointer-events: none). */}
        {(gridResChanging || cellsRevealPending) && (
          <div className="map-center-loading" role="status" aria-live="polite">
            <span className="map-center-spinner" />
            <span>Updating…</span>
          </div>
        )}

        {/* First-load spinner: no prior data, warehouse request in flight.
            Pointer-events: none so it doesn't block map interaction. */}
        {baseCellsLoading && baseCache.rows.length === 0 && !baseCellsError && (
          <div className="map-center-loading" role="status" aria-live="polite" style={{ pointerEvents: "none" }}>
            <span className="map-center-spinner" />
            <span>Loading map…</span>
          </div>
        )}

        {/* Terminal error — prior data (if any) still shown; Retry available. */}
        {baseCellsError && !baseCellsLoading && (
          <div
            className="map-center-loading"
            role="alert"
            style={{ pointerEvents: "auto", cursor: "default", flexDirection: "column", gap: 8, borderRadius: 12, padding: "14px 20px" }}
          >
            <span style={{ fontSize: 12, opacity: 0.8 }}>Map data unavailable</span>
            <button
              type="button"
              className="theme-toggle"
              onClick={() => { setBaseCellsError(null); setCellsRetrySeq((n) => n + 1); }}
            >
              Retry
            </button>
          </div>
        )}

        <Map
          ref={mapRef}
          initialViewState={INITIAL_VIEW}
          mapStyle={BASEMAP}
          onMove={onMove}
          onMoveEnd={onMoveEnd}
          onLoad={onLoad}
          onClick={onMapClick}
          onMouseDown={onMapMouseDown}
          onMouseMove={onMapMouseMove}
          onMouseUp={onMapMouseUp}
          dragPan={selectTool === null}
          cursor={selectTool ? "crosshair" : undefined}
          interactiveLayerIds={!genieActive && !dotsVisible ? ["cells-fill"] : []}
          dragRotate={false}
          touchPitch={false}
          pitchWithRotate={false}
          maxPitch={0}
          minZoom={6}
          maxZoom={16}
          style={{ width: "100%", height: "100%" }}
        >
          <NavigationControl position="top-right" showCompass={false} />
          <ScaleControl position="bottom-right" unit="imperial" />
          {/* Value choropleth — each H3 hexagon shaded by the active lens's
              real metric value on the fixed legend scale. This is the
              zoomed-out view; it sits under the deck.gl dots (interleaved
              deck layers render above style layers) and fades out as the
              dots fade in. Hidden during a Genie answer, where the matched
              dots are the whole story. */}
          {!genieActive && (
            <Source id="cells" type="geojson" data={geojson as any}>
              <Layer
                id="cells-fill"
                type="fill"
                paint={{
                  // No dimming: when a focus group is active the /cells query
                  // itself is scoped to the cohort (see the cells fetch above),
                  // so this fill IS the cohort view already — "where" and "how
                  // much" in one layer, on the same legend scale.
                  // cellsRevealPending: zero opacity hides stale territory fills
                  // immediately on commit while cells-selected (same source) keeps
                  // rendering the clicked-hex outline from the old geojson.
                  "fill-color": fillColor as any,
                  "fill-opacity": cellsRevealPending ? 0 : hexFillOpacity,
                  "fill-opacity-transition": { duration: 160, delay: 0 },
                }}
              />
              <Layer
                id="cells-line"
                type="line"
                paint={{
                  "line-color": "rgba(255,255,255,0.22)",
                  "line-width": 0.5,
                  "line-opacity": cellsRevealPending ? 0 : hexLineOpacity,
                }}
              />
              {/* Outline the drilled hex so the focus reads on the map. */}
              <Layer
                id="cells-selected"
                type="line"
                filter={selectedCell ? ["==", ["get", "h3_index"], selectedCell] : ["==", ["get", "h3_index"], "__none__"]}
                paint={{ "line-color": "#4f8ff7", "line-width": 2.5 }}
              />
              {/* Outline every hex inside a box/lasso region selection. */}
              <Layer
                id="cells-selected-multi"
                type="line"
                filter={selectedHexIds.length > 0
                  ? ["in", ["get", "h3_index"], ["literal", selectedHexIds]]
                  : ["==", ["get", "h3_index"], "__none__"]}
                paint={{ "line-color": "#4f8ff7", "line-width": 1.5, "line-opacity": 0.9 }}
              />
              {/* Cohort accent outline — when a focus group is active every
                  returned (non-gray) cell IS a cohort cell (the query is
                  already scoped), so this traces the cohort's edge straight
                  from the same source, no extra round-trip. Tracing the edge
                  (not filling) avoids blanketing the whole territory for a
                  spread-out cohort and hiding the real metric colors. */}
              <Layer
                id="cells-cohort-outline"
                type="line"
                filter={cohortCellsReady
                  ? [">=", ["to-number", ["coalesce", ["get", "n_customers"], 0]], MIN_CUSTOMERS_FOR_COLOR]
                  : ["==", ["get", "h3_index"], "__none__"]}
                paint={{ "line-color": "#4f8ff7", "line-width": 1.2, "line-opacity": COHORT_OUTLINE_OPACITY }}
              />
            </Source>
          )}
          {/* pickingRadius: the meters-based dot radius (see CUSTOMER_DOT_RADIUS_METERS)
              clamps to its 1.5px min at zoom ~12-13, versus the old fixed-pixel
              dots which always rendered 4-8px — a few pixels of picking slack
              keeps dot clicks reliable at that zoom without changing the
              rendered (visual) size. */}
          {/* getCursor: deck.gl overwrites the canvas cursor on every pointermove,
              so <Map cursor="crosshair"> is ineffective while deck is mounted.
              Drive it from deck instead so the crosshair holds while a draw tool
              is armed. getDragging/isHovering are the standard deck cursor args. */}
          <DeckOverlay
            interleaved
            layers={deckLayers}
            getTooltip={getDeckTooltip}
            onClick={onDeckClick}
            pickingRadius={4}
            getCursor={({ isDragging }: { isDragging: boolean }) =>
              selectTool ? "crosshair" : isDragging ? "grabbing" : "grab"}
          />
        </Map>

        <MapLegend
          layer={layer}
          grain={grain}
          minVal={minVal}
          maxVal={maxVal}
          unmappedPct={unmappedPct}
          program={programMode && dotsVisible ? {
            derComparison, derLabel, counts: programCounts,
          } : null}
          dots={(dotsVisible || genieActive) && !programMode && !liveMode ? {
            label: dotMetric?.label ?? "Customer attention",
            unit: dotMetric?.unit ?? "",
            min: dotScale.min, max: dotScale.max,
            reversed: dotReversed, attention: !dotMetric,
          } : null}
          live={liveMode ? {
            dotsVisible,
            outInView: activeOutagePointsCache.length,
            incidents: activeIncidents.length,
          } : null}
        />

        <div className={`map-chat ${chatOpen ? "open" : "collapsed"}`}>
            <div
              className="map-chat-header"
              onClick={() => setChatOpen((o) => !o)}
              role="button"
              title={chatOpen ? "Collapse chat" : "Expand chat"}
            >
              <span className="map-chat-title"><span className="ask-map-spark">✦</span> Ask the map</span>
              <div className="map-chat-header-actions">
                {genieTurns.length > 0 && (
                  <button
                    type="button"
                    className="map-chat-reset"
                    onClick={(e) => { e.stopPropagation(); resetGenie(); }}
                    title="Clear the conversation"
                  >
                    Clear
                  </button>
                )}
                <span className="map-chat-chevron">{chatOpen ? "▾" : "▸"}</span>
              </div>
            </div>

            {chatOpen && (
              <div className="map-chat-body" ref={chatBodyRef}>
                {genieTurns.length === 0 ? (
                  <div className="map-chat-empty">
                    <div className="map-chat-empty-hint">
                      {focusActive
                        ? "Your focus group is the default scope — ask about them, or say “vs the whole territory” to compare."
                        : "Ask about the whole territory — or build a focus group (hex, draw, filters) and ask about just them."}
                    </div>
                    <div className="chat-suggestions">
                      {ASK_MAP_EXAMPLES.map((q) => (
                        <button
                          key={q}
                          type="button"
                          className="chat-suggestion"
                          disabled={asking}
                          onClick={() => submitAsk(q)}
                        >
                          {q}
                        </button>
                      ))}
                    </div>
                  </div>
                ) : (
                  genieTurns.map((t) => (
                    <div key={t.id} className="chat-turn">
                      <div className="chat-q">{t.question}</div>
                      <div className="chat-a">
                        {t.status === "thinking" && (
                          <div className="chat-thinking">
                            <span className="chat-dots"><i /><i /><i /></span>
                            Querying the lakehouse… {askElapsed}s
                          </div>
                        )}
                        {t.status === "error" && <div className="chat-err">{t.error}</div>}
                        {t.status === "done" && <ChatAnswer turn={t} />}
                      </div>
                    </div>
                  ))
                )}
              </div>
            )}

            {/* Scope is conversational: answers default to the focus group when
                one is set, but you can just ask "…vs the whole territory" or
                about anything else and Genie adapts. No mode toggle. */}
            <div
              className="map-chat-scope"
              title={focusActive
                ? "Answers default to your focus group. Ask “vs the whole territory” (or anything broader) and Genie will adapt."
                : "Pick a focus group (hex / draw / attributes) to make it the default scope for your questions."}
            >
              <span className={`context-dot ${focusActive ? "selection" : "viewport"}`} />
              {focusActive
                ? "Answers focus on your group"
                : "Answers cover the whole territory"}
            </div>

            {/* The chat bar is always visible (even collapsed) so you can ask
                without expanding the panel first; the conversation history is what
                the header toggle shows/hides. */}
            <form className="map-chat-input" onSubmit={(e) => { e.preventDefault(); submitAsk(); }}>
              <input
                placeholder={genieTurns.length ? "Ask a follow-up…" : "e.g. customers who complain about high bills"}
                value={askInput}
                onChange={(e) => setAskInput(e.target.value)}
                disabled={asking}
              />
              <button type="submit" disabled={asking || !askInput.trim()}>{asking ? `…${askElapsed}s` : "Ask"}</button>
            </form>
        </div>
      </div>

      {drillSubject?.kind === "premise" ? (
        // Drilling INTO one subject is the only thing that overrides the
        // focus group in the rail (it's a detail view, not a scope). A dot
        // click resolves here by default — the pivot
        // chip switches to the Customer card below without leaving the rail.
        <PremiseDrillCard
          premiseNumber={drillSubject.premiseNumber}
          onClose={closeDrill}
          onOpenFull={onJumpToSubject}
          onPivot={pivotSubject}
          backToGroup={focusActive}
        />
      ) : drillSubject?.kind === "customer" ? (
        <CustomerDrillPanel
          accountNumber={drillSubject.accountNumber}
          // The premise this customer was drilled INTO from (if any) — the
          // anchor still holds it after the pivot, so the customer card can
          // offer a one-click return to exactly where the user started.
          originPremiseNumber={drillAnchor?.premiseNumber ?? null}
          onClose={closeDrill}
          onOpenFull={onJumpToSubject}
          onPivot={pivotSubject}
          backToGroup={focusActive}
        />
      ) : (
        // The rail ALWAYS reflects the focus group — the chosen cohort (hex /
        // draw / attributes / words) or, by default, the whole service territory.
        <FocusPanel
          data={groupData}
          loading={groupLoading}
          focusActive={focusActive}
          label={focusLabel}
          grain={grain}
          onSelectCustomer={selectCustomer}
          onSelectPremise={selectPremise}
          program={programLens}
        />
      )}

      {/* The "Build focus group" builder opens as an overlay pinned to the
          right rail's footprint (same width, same column) — it's the panel that
          the rail's metrics answer to, so it takes over that space while open. */}
      {focusPanelOpen && (
        <>
          <div className="focus-panel-scrim" onClick={() => setFocusPanelOpen(false)} />
          <div className="focus-panel">
            <div className="focus-panel-head">
              <span>Focus group</span>
              <button type="button" className="map-chat-reset" onClick={() => setFocusPanelOpen(false)}>Done</button>
            </div>

            {focusActive && focusSummary ? (
              <div className="focus-status active">
                <span className="focus-status-count">
                  {cohortReady ? (
                    <>
                      <strong>{fmtNum(focusSummary.cohortLocations)}</strong> of {fmtNum(focusSummary.territoryLocations)} {unitLabel(focusSummary.territoryLocations, "premise")} in focus
                    </>
                  ) : focusSummary.cohortLocations > 0 ? (
                    // Provisional count while layers + summary are loading —
                    // shown immediately for optimistic selections so the panel
                    // isn't blank while the warehouse round-trips complete.
                    <><strong>~{fmtNum(focusSummary.cohortLocations)}</strong> in focus (counting…)</>
                  ) : (
                    <>Counting…</>
                  )}
                </span>
                <div className="focus-status-actions">
                  {/* Frame focus lives on the top bar now — no need to
                      duplicate it here. */}
                  <button type="button" className="focus-chip-btn focus-chip-clear" onClick={clearFocus} title="Clear the focus group">Clear</button>
                </div>
              </div>
            ) : nActiveFilters > 0 ? (
              <div className="focus-status empty">
                No focus group yet — your {nActiveFilters} attribute filter{nActiveFilters > 1 ? "s" : ""} {nActiveFilters > 1 ? "are" : "is"} slicing
                the map live; use {nActiveFilters > 1 ? "them" : "it"} as a focus group below, or{" "}
                <button type="button" className="focus-chip-btn focus-chip-clear" onClick={() => setFilters(emptyFilterState())}>clear {nActiveFilters > 1 ? "them" : "it"}</button>.
              </div>
            ) : (
              <div className="focus-status empty">No focus group yet — define one with any method below.</div>
            )}

            <div className="focus-section">
              <div className="focus-section-label">① Describe in words</div>
              <form className="focus-ask" onSubmit={(e) => { e.preventDefault(); submitAsk(); setFocusPanelOpen(false); }}>
                <input
                  placeholder={genieTurns.length ? "Ask a follow-up…" : "e.g. customers who complain about high bills"}
                  value={askInput}
                  onChange={(e) => setAskInput(e.target.value)}
                  disabled={asking}
                />
                <button type="submit" disabled={asking || !askInput.trim()}>{asking ? `…${askElapsed}s` : "Ask"}</button>
              </form>
            </div>

            <div className="focus-section">
              <div className="focus-section-label">
                ② Pick attributes
                {nActiveFilters > 0 && (
                  <button type="button" className="map-chat-reset" onClick={() => setFilters(emptyFilterState())}>Clear all</button>
                )}
              </div>
              <FilterGroup
                label="Customer class"
                options={CUSTOMER_CLASS_OPTIONS}
                selected={filters.customerClass}
                onToggle={(v) => setFilters((f) => ({ ...f, customerClass: togglePartition(f.customerClass, v) }))}
              />
              <FilterGroup
                label="Usage vs peers"
                options={USAGE_BAND_OPTIONS}
                selected={filters.usageBand}
                onToggle={(v) => setFilters((f) => ({ ...f, usageBand: togglePartition(f.usageBand, v) }))}
              />
              <FilterGroup
                label="Engagement"
                options={ENGAGEMENT_OPTIONS}
                selected={filters.engagement}
                onToggle={(v) => setFilters((f) => ({ ...f, engagement: togglePartition(f.engagement, v) }))}
              />
              <FilterGroup
                label="Issue flags (any)"
                options={ISSUE_FLAG_OPTIONS}
                selected={filters.issueFlags}
                onToggle={(v) => setFilters((f) => ({ ...f, issueFlags: toggleSet(f.issueFlags, v) }))}
              />
              <div className="focus-hint-sm">Add a flag to require it — none = no restriction.</div>
              <button
                type="button"
                className="context-btn primary focus-apply"
                onClick={applyFiltersAsFocus}
                disabled={nActiveFilters === 0}
                title="Make these attributes your focus group"
              >
                Use {nActiveFilters ? `${nActiveFilters} attribute${nActiveFilters > 1 ? "s" : ""}` : "attributes"} as focus group
              </button>
            </div>

            <div className="focus-section">
              <div className="focus-section-label">③ Draw on map</div>
              <div className="focus-draw">
                <button
                  type="button"
                  className={`map-select-btn ${selectTool === "box" ? "active" : ""}`}
                  onClick={() => { setSelectTool("box"); setFocusPanelOpen(false); }}
                >
                  ▭ Box
                </button>
                <button
                  type="button"
                  className={`map-select-btn ${selectTool === "lasso" ? "active" : ""}`}
                  onClick={() => { setSelectTool("lasso"); setFocusPanelOpen(false); }}
                >
                  ◯ Lasso
                </button>
                {(selectionPoly || selectTool) && (
                  <button type="button" className="map-select-clear" onClick={clearSelection}>Clear shape</button>
                )}
              </div>
              <div className="focus-hint-sm">{dotsVisible ? "Then drag on the map to select customers." : "Then drag on the map to select this region's hexes."}</div>
            </div>
          </div>
        </>
      )}
    </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Legend
// ────────────────────────────────────────────────────────────────────

interface ProgramLegend {
  derComparison: boolean;
  derLabel: string | null;
  counts: { enrolledDetected: number; detectedOnly: number; enrolledOnly: number; neither: number };
}

function MapLegend({ layer, grain, minVal, maxVal, unmappedPct, program, dots, live }: {
  layer: LayerSpec; grain: Grain; minVal: number; maxVal: number; unmappedPct?: number; program?: ProgramLegend | null;
  // When dots are the view (non-program), they're colored per-customer by the
  // active metric — so the legend shows that metric's own scale, not the hex
  // choropleth rate. `attention` flags the composite-score fallback.
  dots?: { label: string; unit: string; min: number; max: number; reversed: boolean; attention: boolean } | null;
  // Active outages (live) layer: red = currently out, amber = critical-care out,
  // orange marker = open incident. Counts are for the current viewport.
  live?: { dotsVisible: boolean; outInView: number; incidents: number } | null;
}) {
  if (live) {
    return (
      <div className="map-legend">
        <div className="map-legend-title">
          {layer.label}
          <span className="map-legend-sub"> · real-time OMS snapshot</span>
        </div>
        {live.dotsVisible ? (
          <div className="map-legend-adoption">
            <div className="legend-adopt-row">
              <span className="legend-swatch" style={{ background: "#ef4444" }} />
              <span className="legend-adopt-label">Currently out of power</span>
              <span className="legend-adopt-count">{fmtNum(live.outInView)}</span>
            </div>
            <div className="legend-adopt-row">
              <span className="legend-swatch" style={{ background: "#ffcd28" }} />
              <span className="legend-adopt-label">Critical-care · priority restore</span>
              <span className="legend-adopt-count" />
            </div>
            <div className="legend-adopt-row">
              <span className="legend-swatch" style={{ background: "#f97316" }} />
              <span className="legend-adopt-label">Open incident (marker)</span>
              <span className="legend-adopt-count">{fmtNum(live.incidents)}</span>
            </div>
          </div>
        ) : (
          <>
            <div className="legend-bar" style={{ background: `linear-gradient(to right, ${NUMERIC_LEGEND_GRADIENT})` }} />
            <div className="legend-axis">
              <span>{fmtNum(minVal, 0)}%</span>
              <span>{fmtNum(maxVal, 0)}% out</span>
            </div>
            <div className="map-legend-foot">{fmtNum(live.incidents)} open incidents</div>
          </>
        )}
      </div>
    );
  }
  if (dots && !program) {
    const gradient = dots.reversed ? NUMERIC_LEGEND_GRADIENT_REVERSED : NUMERIC_LEGEND_GRADIENT;
    return (
      <div className="map-legend">
        <div className="map-legend-title">
          {dots.label}
          <span className="map-legend-sub"> · {dots.attention ? "composite score" : grain === "premise" && (layer.supportedGrains ?? ['premise', 'customer']).includes('premise') ? "per premise · 90d" : "per customer · 90d"}</span>
        </div>
        <div className="legend-bar" style={{ background: `linear-gradient(to right, ${gradient})` }} />
        <div className="legend-axis">
          {dots.attention
            ? (<><span>Routine</span><span>Needs attention</span></>)
            : (<><span>{fmtNum(dots.min, 0)}{dots.unit}</span><span>{fmtNum(dots.max, 0)}{dots.unit}</span></>)}
        </div>
      </div>
    );
  }
  // Program-adoption lens (dots showing): adoption is binary, so the legend is
  // categorical — not a gradient. When the program has a DER signal we also
  // show the enrolled-vs-detected discrepancy categories.
  if (program) {
    const der = program.derLabel || "device";
    const c = program.counts;
    // Every row leads with the enrollment state (Enrolled / Not enrolled) so
    // the two "Enrolled ·" rows group above the two "Not enrolled ·" rows and
    // read in parallel — the device-signal clause is always second.
    const chips = program.derComparison
      ? [
          { color: PROGRAM_ADOPTION_PALETTE.enrolledDetected, label: `Enrolled · ${der} detected`,       n: c.enrolledDetected },
          { color: PROGRAM_ADOPTION_PALETTE.enrolledOnly,     label: `Enrolled · no ${der} detected`,    n: c.enrolledOnly },
          { color: PROGRAM_ADOPTION_PALETTE.detectedOnly,     label: `Not enrolled · ${der} detected`,   n: c.detectedOnly },
          { color: PROGRAM_ADOPTION_PALETTE.neither,          label: `Not enrolled · no ${der} detected`, n: c.neither },
        ]
      : [
          { color: PROGRAM_ADOPTION_PALETTE.enrolledDetected, label: "Enrolled", n: c.enrolledDetected + c.enrolledOnly },
          { color: PROGRAM_ADOPTION_PALETTE.neither,          label: "Not enrolled", n: c.detectedOnly + c.neither },
        ];
    return (
      <div className="map-legend">
        <div className="map-legend-title">
          {layer.label}
          {program.derComparison && <span className="map-legend-sub"> · vs {der} detected</span>}
        </div>
        <div className="map-legend-adoption">
          {chips.map((ch) => (
            <div key={ch.label} className="legend-adopt-row">
              <span className="legend-swatch" style={{ background: ch.color }} />
              <span className="legend-adopt-label">{ch.label}</span>
              <span className="legend-adopt-count">{fmtNum(ch.n)}</span>
            </div>
          ))}
        </div>
        <div className="map-legend-foot">In view</div>
      </div>
    );
  }
  if (layer.kind === "categorical") {
    const themes = Object.entries(THEME_PALETTE).filter(([k]) => k !== "none");
    return (
      <div className="map-legend">
        <div className="map-legend-title">{layer.label}</div>
        <div className="map-legend-categorical">
          {themes.map(([key, color]) => (
            <div key={key} className="legend-chip">
              <span className="legend-swatch" style={{ background: color }} />
              <span>{key.replace(/_/g, " ")}</span>
            </div>
          ))}
        </div>
      </div>
    );
  }
  const gradient = layer.kind === "numeric_reversed"
    ? NUMERIC_LEGEND_GRADIENT_REVERSED
    : NUMERIC_LEGEND_GRADIENT;
  // A "rate per X" metric (unitNote set) reads the unit once in the title and
  // shows bare axis numbers — so we don’t repeat e.g. "/1K (90d)" on every tick.
  const axisUnit = layer.unitNote ? "" : layer.unit;
  // Complaint volume re-grains at premise grain — reflect that in the unit note.
  const effectiveUnitNote = (layer.id === "complaints_per_1k" && grain === "premise")
    ? "per 1,000 premises · 90d"
    : layer.unitNote;
  // Bucket-2 layers (customer-native, no premise truth): their supportedGrains
  // locks them to customer, so this note only appears in edge-case races. Keep it
  // as a backstop.
  const showCustomerAttributedNote = layer.customerAttributed && grain !== "customer";
  // Complaint volume at premise grain: ~35% of complaints have no premise_id.
  // Show the live fraction so the legend is honest about coverage.
  const showUnmappedNote = layer.id === "complaints_per_1k" && grain === "premise" && (unmappedPct ?? 0) > 0;
  return (
    <div className="map-legend">
      <div className="map-legend-title">
        {layer.label}
        {effectiveUnitNote && <span className="map-legend-sub"> · {effectiveUnitNote}</span>}
      </div>
      <div className="legend-bar" style={{ background: `linear-gradient(to right, ${gradient})` }} />
      <div className="legend-axis">
        <span>{fmtNum(minVal, 1)}{axisUnit}</span>
        <span>{fmtNum(maxVal, 1)}{axisUnit}</span>
      </div>
      {showCustomerAttributedNote && (
        <div className="map-legend-foot">Always per customer — complaints aren’t re-scoped to {grain === "premise" ? "premises" : "accounts"}</div>
      )}
      {showUnmappedNote && (
        <div className="map-legend-foot">~{unmappedPct}% of complaints in view couldn’t be pinned to a specific address</div>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// KPI strip — viewport-reactive scorecard for the active context
// ────────────────────────────────────────────────────────────────────

type KpiTone = "good" | "warn" | "bad" | "neutral";

// Threshold-based tone so the strip reads the *meaning* of each number rather
// than painting a fixed color regardless of value. Red is reserved for
// genuinely bad numbers; healthy slices read green, so a CCO looking at a good
// neighborhood doesn't see a wall of alarm. Thresholds are bracketed around
// the territory-wide averages (payment stress ≈27%, dissatisfaction ≈18%,
// digital adoption ≈36, outage ≈96 min/cust) so the macro view lands in amber
// and individual areas swing green↔red as they actually differ.

// Higher value = worse (payment stress, dissatisfaction, outage minutes).
function toneHigherWorse(v: number, goodMax: number, badMin: number): KpiTone {
  if (v <= goodMax) return "good";
  if (v >= badMin) return "bad";
  return "warn";
}
// Higher value = better (digital adoption).
function toneHigherBetter(v: number, goodMin: number, badMax: number): KpiTone {
  if (v >= goodMin) return "good";
  if (v <= badMax) return "bad";
  return "warn";
}


// Collapsible card used to stack the inspector's many sections. Each remembers
// its own open state so the user can tailor the rail to what they care about.
function Section({ title, subtitle, defaultOpen = true, children }: {
  title: string; subtitle?: string; defaultOpen?: boolean; children: ReactNode;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="card cell-drill-section inspector-section">
      <button type="button" className="inspector-section-head" onClick={() => setOpen((o) => !o)}>
        <span className="inspector-section-title">
          {title}{subtitle && <span className="inspector-section-sub"> · {subtitle}</span>}
        </span>
        <span className="inspector-section-chevron">{open ? "▾" : "▸"}</span>
      </button>
      {open && <div className="inspector-section-body">{children}</div>}
    </div>
  );
}

// A categorical breakdown rendered as labeled proportion bars.
function DistBars({ label, items, total }: {
  label: string; items: { label: string; n: number }[]; total: number;
}) {
  return (
    <div className="dist-group">
      <div className="dist-group-label">{label}</div>
      {items.map((it) => {
        const pct = total ? Math.round((it.n / total) * 100) : 0;
        return (
          <div key={it.label} className="dist-row">
            <div className="dist-name">{it.label}</div>
            <div className="dist-track"><span className="dist-fill" style={{ width: `${pct}%` }} /></div>
            <div className="dist-pct">{pct}%</div>
          </div>
        );
      })}
    </div>
  );
}

// Server-enriched group analytics from /api/genie/group — counts, issue mix,
// segment mix, demographics, property, and load for the focus group. Computed
// entirely server-side (by session cohort or territory), so it needs no loaded
// dots and works at any zoom.
interface GroupDistBucket { bucket: string; n: number; }
interface GroupSampleRow {
  account_number: string;
  premise_number: string;
  customer_class: string;
  engagement_tier: string;
  usage_band: string;
  payment_stressed_flag: boolean;
  churn_risk_band: string;
  critical_care_flag: boolean;
  recent_complaint_count_90d: number;
  recent_outage_minutes_90d: number;
  // The owning party of this row's premise, if any (bridge_premise_owner).
  owner_number: string | null;
  owner_display_name: string | null;
}
interface GroupAnalytics {
  n: number;
  total?: number;
  // Same cohort at customer grain — `total` is service
  // locations (the default unit); this collapses multi-site customers to one.
  distinctCustomers?: number;
  // Same cohort at owner grain — a chain or landlord's premises
  // collapse to one owner.
  distinctOwners?: number;
  residential?: number;
  commercial?: number;
  truncated: boolean;
  issues?: {
    payment_stressed: number; churn_high: number; critical_care: number;
    liheap: number; complaints_2plus: number; heavy_outages: number;
    total_complaints_90d: number; avg_digital_adoption: number; avg_outage_min: number;
  };
  load: { groupKwh: number | null; territoryKwh: number | null; groupPeerP75: number | null };
  distributions: Record<string, GroupDistBucket[]>;
  themes?: { sub_category: string; n: number }[];
  sample?: GroupSampleRow[];
}

// Human-readable label for a raw distribution bucket value.
function prettyBucket(s: string): string {
  if (!s || s === "Unknown") return "Unknown";
  if (/^(under|over)_\d+k$/.test(s)) { const [p, a] = s.split("_"); return `${p === "under" ? "Under" : "Over"} $${a}`; }
  if (/^\d+k_\d+k$/.test(s)) return `$${s.replace("_", "–")}`;   // 25k_50k → $25k–50k
  if (/^\d+_plus$/.test(s)) return s.replace("_plus", "+");      // 65_plus → 65+
  if (/^\d+_\d+$/.test(s)) return s.replace("_", "–");           // 35_44 → 35–44
  let out = s.replace(/_/g, " ").replace(/([a-z])([A-Z])/g, "$1 $2"); // snake + camel → spaced
  if (/^[a-z]+$/.test(s)) out = out.charAt(0).toUpperCase() + out.slice(1); // high → High
  return out;
}

// A server distribution rendered as proportion bars (prettified labels). Hidden
// when the dimension is empty.
function ServerDist({ label, buckets, total }: { label: string; buckets?: GroupDistBucket[]; total: number }) {
  if (!buckets || buckets.length === 0) return null;
  return <DistBars label={label} items={buckets.map((b) => ({ label: prettyBucket(b.bucket), n: b.n }))} total={total} />;
}

// ────────────────────────────────────────────────────────────────────
// FocusPanel — the single right-rail panel. It ALWAYS reflects the focus group:
// the chosen cohort (hex / draw / attributes / words, via focus_set) or, by
// default, the whole service territory. Driven entirely by server analytics
// keyed on the session cohort, so it works at any zoom with no loaded dots.
// ────────────────────────────────────────────────────────────────────
function FocusPanel({
  data, loading, focusActive, label, grain, onSelectCustomer, onSelectPremise, program,
}: {
  // Group analytics + loading come from the parent's useGroupAnalytics, the same
  // source feeding the top context bar — so the count reveals in lockstep here.
  data: GroupAnalytics | null;
  loading: boolean;
  focusActive: boolean;
  label: string | null;
  // The master grain from the top-level selector — drives the headline and
  // which subject a rail row drills into.
  grain: Grain;
  onSelectCustomer: (id: string) => void;
  onSelectPremise: (premiseNumber: string) => void;
  program?: { programId: string; derLabel: string | null } | null;
}) {
  const eyebrow = focusActive ? (label || "Focus group") : "Service territory";

  if (!data) {
    return (
      <aside className="cell-drill empty">
        {loading ? (
          <div className="empty-state loading">
            <span className="rail-spinner" />
            Loading metrics…
          </div>
        ) : (
          <div className="empty-state">No metrics available.</div>
        )}
      </aside>
    );
  }

  const n = data.n || 0;
  const total = data.total ?? n;
  const distinctCustomers = data.distinctCustomers ?? total;
  // Headline follows the master grain. Account grain maps to distinctCustomers
  // (accounts ≈ customers in the current analytics model; a dedicated
  // distinctAccounts from the server can be added when needed).
  const primaryCount = grain === "customer" ? distinctCustomers : total;
  // Secondary line: show premise count when grain isn't premise and it diverges.
  const secondaryCount = total;
  const secondaryUnit: CountUnit = "premise";
  const grainUnit: CountUnit = grain === "customer" ? "customer" : "premise";
  // Multi-highlight hint: shown when Customer grain lights >1 premise so the
  // user who wanted a single location knows to switch grain.
  const showGrainHint = focusActive && grain === "customer" && distinctCustomers < total;
  const iss = data.issues;
  const pct = (c: number) => (n > 0 ? Math.round((c / n) * 100) : 0);

  const vitals: { label: string; value: string; tone: KpiTone }[] = iss ? [
    { label: "Digital adoption", value: `${fmtNum(iss.avg_digital_adoption, 0)}/100`, tone: toneHigherBetter(iss.avg_digital_adoption, 55, 35) },
    { label: "Outage min/cust",  value: fmtNum(iss.avg_outage_min, 0),                tone: toneHigherWorse(iss.avg_outage_min, 45, 120) },
    { label: "Complaints 90d",   value: fmtNum(iss.total_complaints_90d, 0),          tone: "neutral" },
  ] : [];

  const issueRows = iss ? [
    { label: "Payment stress",  count: iss.payment_stressed, tone: toneHigherWorse(pct(iss.payment_stressed), 18, 35) },
    { label: "Dissatisfied",    count: iss.churn_high,       tone: toneHigherWorse(pct(iss.churn_high), 12, 25) },
    { label: "Critical care",   count: iss.critical_care,    tone: "neutral" as KpiTone },
    { label: "LIHEAP-eligible", count: iss.liheap,           tone: "neutral" as KpiTone },
    { label: "≥2 complaints",   count: iss.complaints_2plus, tone: toneHigherWorse(pct(iss.complaints_2plus), 10, 25) },
    { label: "Heavy outages",   count: iss.heavy_outages,    tone: toneHigherWorse(pct(iss.heavy_outages), 10, 25) },
  ] : [];

  const d = data.distributions;
  const loadKwh = data.load.groupKwh;
  const terrKwh = data.load.territoryKwh;
  const peerP75 = data.load.groupPeerP75;
  const loadChip = loadKwh != null && terrKwh != null
    ? `${loadKwh >= terrKwh ? "+" : "−"}${fmtNum(Math.abs(loadKwh - terrKwh))} kWh vs territory` : "";
  const peerPct = loadKwh != null && peerP75 != null && peerP75 > 0 ? Math.round((loadKwh / peerP75) * 100) : null;
  const peerTone = peerPct == null ? "neutral" : peerPct > 110 ? "bad" : peerPct < 90 ? "good" : "neutral";
  const sample = data.sample ?? [];

  return (
    <aside className={`cell-drill${loading ? " is-refreshing" : ""}`}>
      <div className="cell-drill-header">
        <div>
          <div className="cell-drill-eyebrow">
            {eyebrow}
            {loading && <span className="rail-updating"><span className="rail-spinner" />Updating…</span>}
          </div>
          <h3>{formatUnitCount(fmtNum(primaryCount), primaryCount, grainUnit)}</h3>
          <div className="subtle">
            {fmtNum(data.residential ?? 0)} residential · {fmtNum(data.commercial ?? 0)} commercial
            {data.truncated ? " · sampled" : ""}
            {/* Show premise count as secondary when grain isn't premise and they diverge. */}
            {grain !== "premise" && secondaryCount !== primaryCount && (
              <> · {formatUnitCount(fmtNum(secondaryCount), secondaryCount, secondaryUnit)}</>
            )}
          </div>
        </div>
      </div>
      {/* Grain hint: Customer grain lights every premise for the cohort's customers,
          including locations outside any area you drew or clicked. */}
      {showGrainHint && (
        <div className="grain-hint">
          {distinctCustomers === 1
            ? <>Showing all {fmtNum(total)} premises for this customer.{" "}</>
            : <>Customer grain: showing all {fmtNum(total)} premises for these {fmtNum(distinctCustomers)} customers — including locations outside the area you selected.{" "}</>
          }
          Switch to <strong>Premise</strong> grain above to focus only on the selected area.
        </div>
      )}

      {vitals.length > 0 && (
        <div className="group-vitals">
          {vitals.map((it) => (
            <div key={it.label} className="gv">
              <div className="gv-label">{it.label}</div>
              <div className={`gv-val tone-${it.tone}`}>{it.value}</div>
            </div>
          ))}
        </div>
      )}

      {issueRows.length > 0 && (
        <Section title="Issue mix">
          <div className="delta-grid">
            {issueRows.map((s) => (
              <div key={s.label} className="delta-row">
                <div className="delta-label">{s.label}</div>
                <div className="delta-value">{pct(s.count)}%</div>
                <div className={`delta-comp tone-${s.tone}`}>{fmtNum(s.count)} of {fmtNum(n)}</div>
              </div>
            ))}
          </div>
        </Section>
      )}

      {(data.themes ?? []).length > 0 && (
        <Section title="Top complaint themes" subtitle="90d">
          <ul className="theme-list">
            {(data.themes ?? []).map((t) => (
              <li key={t.sub_category}>
                <span className="theme-name">{t.sub_category.replace(/_/g, " ")}</span>
                <span className="theme-count">{fmtNum(t.n)}</span>
              </li>
            ))}
          </ul>
        </Section>
      )}

      <Section title="Segment mix">
        <ServerDist label="Customer class"       buckets={d.customer_class}  total={n} />
        <ServerDist label="Usage vs peers"        buckets={d.usage_band}      total={n} />
        <ServerDist label="Engagement"            buckets={d.engagement_tier} total={n} />
        <ServerDist label="Dissatisfaction risk"  buckets={d.churn_risk_band} total={n} />
      </Section>

      {program && <ProgramSection programId={program.programId} derLabel={program.derLabel} customers={EMPTY_ROWS} onSelectCustomer={onSelectCustomer} />}

      <Section title="Demographics">
        <ServerDist label="Income band"             buckets={d.income_band}         total={n} />
        <ServerDist label="Age (head of household)" buckets={d.age_band_hoh}         total={n} />
        <ServerDist label="Household size"          buckets={d.household_size}       total={n} />
        <ServerDist label="Account tenure"          buckets={d.account_tenure_band}  total={n} />
      </Section>

      <Section title="Property & load">
        <ServerDist label="Building type"    buckets={d.building_subtype} total={n} />
        <ServerDist label="Heating fuel"     buckets={d.heating_fuel}     total={n} />
        <ServerDist label="Envelope quality" buckets={d.envelope_quality} total={n} />
        <ServerDist label="Build vintage"    buckets={d.vintage}          total={n} />
        <div className="delta-grid" style={{ marginTop: 10 }}>
          <div className="delta-row">
            <div className="delta-label">Avg monthly use</div>
            <div className="delta-value">{fmtKwh(loadKwh)}</div>
            {loadChip && <div className="delta-comp tone-neutral">{loadChip}</div>}
          </div>
          <div className="delta-row">
            <div className="delta-label">Usage vs peer p75</div>
            <div className="delta-value">{peerPct != null ? `${peerPct}%` : "—"}</div>
            <div className={`delta-comp tone-${peerTone}`}>
              {peerPct == null ? "—" : peerPct > 110 ? "above peers" : peerPct < 90 ? "below peers" : "in line with peers"}
            </div>
          </div>
        </div>
      </Section>

      <Section
        title={grain === "premise" ? "Premises" : "Customers"}
        subtitle={total > sample.length ? `top ${fmtNum(sample.length)} of ${fmtNum(total)}` : fmtNum(sample.length)}
      >
        <ul className="cell-customer-list">
          {sample.map((c) => (
            <li
              key={c.account_number}
              className="cell-customer-row"
              onClick={() => (grain === "premise" ? onSelectPremise(c.premise_number) : onSelectCustomer(c.account_number))}
              title={grain === "premise" ? "Drill into this premise" : "Drill into this customer"}
            >
              <div className="name">Account {shortId(c.account_number)}</div>
              <div className="meta">{c.customer_class} · {c.engagement_tier} eng · {c.usage_band} use</div>
              <div className="badges">
                {c.payment_stressed_flag && <span className="badge alert">Payment stress</span>}
                {c.churn_risk_band === "high" && <span className="badge alert">Dissatisfied</span>}
                {c.critical_care_flag && <span className="badge info">Critical care</span>}
                {num(c.recent_complaint_count_90d) >= 2 && <span className="badge warn">{c.recent_complaint_count_90d} complaints</span>}
                {num(c.recent_outage_minutes_90d) > 240 && <span className="badge warn">Outages</span>}
              </div>
            </li>
          ))}
        </ul>
      </Section>
    </aside>
  );
}

// ────────────────────────────────────────────────────────────────────
// Program section — shown in the group panel when a program lens is active.
// Group-scoped adoption comes from the dots' is_enrolled/has_der flags; the
// program-wide funnel, enrollment trend, and recommended targets come from the
// mkt_* queries. This folds in the former standalone Marketing view.
// ────────────────────────────────────────────────────────────────────

interface ProgramKpisRow {
  program_name: string;
  n_enrolled_total: number; n_eligible: number; pct_adoption: number;
  n_eligible_not_enrolled: number; total_kwh_saved: number; total_rebate_paid: number;
}
interface CampaignTargetRow {
  account_number: string; service_address: string; service_city: string; county: string;
  customer_class: string; engagement_tier: string;
  high_user_flag: boolean; liheap_eligible: boolean; payment_stressed_flag: boolean;
  avg_monthly_kwh_12mo: number; fit_score: number;
}
interface EnrollMonthlyRow { program_id: string; year_month: string; n_enrolled: number; }

function ProgramSection({
  programId, derLabel, customers, onSelectCustomer,
}: {
  programId: string;
  derLabel: string | null;
  customers: PointRow[];
  onSelectCustomer: (id: string) => void;
}) {
  const params = useMemo(() => ({ program_id: sql.string(programId) }), [programId]);
  const kpisQ = useC360Query<ProgramKpisRow>("mkt_program_kpis", params);
  const targetsQ = useC360Query<CampaignTargetRow>("mkt_recommended_targets", params);
  const monthlyQ = useC360Query<EnrollMonthlyRow>("mkt_enrollment_monthly", {});
  const kpis = rows(kpisQ.data)[0];
  const targets = rows(targetsQ.data);

  // Group-scoped adoption from the dots already loaded (carry is_enrolled /
  // has_der only when a program lens is active). Null for groups without flags.
  const group = useMemo(() => {
    const withFlags = customers.filter((c) => c.is_enrolled !== undefined);
    if (withFlags.length === 0) return null;
    let enrolled = 0, detected = 0, gap = 0;
    for (const c of withFlags) {
      if (c.is_enrolled) enrolled++;
      if (c.has_der) detected++;
      if (c.has_der && !c.is_enrolled) gap++;
    }
    return { n: withFlags.length, enrolled, detected, gap };
  }, [customers]);

  const trend = useMemo(() => {
    return rows(monthlyQ.data).filter((r) => r.program_id === programId)
      .map((r) => ({ month: r.year_month, n: num(r.n_enrolled) }))
      .sort((a, b) => a.month.localeCompare(b.month));
  }, [monthlyQ.data, programId]);

  const det = derLabel || "target device";
  const pct = (x: number) => (group && group.n ? Math.round((x / group.n) * 100) : 0);

  return (
    <Section title="Program" subtitle={kpis?.program_name}>
      {group && (
        <>
          <div className="dist-group-label">In this group</div>
          <div className="delta-grid">
            <div className="delta-row">
              <div className="delta-label">Enrolled</div>
              <div className="delta-value">{pct(group.enrolled)}%</div>
              <div className="delta-comp tone-neutral">{fmtNum(group.enrolled)} of {fmtNum(group.n)}</div>
            </div>
            <div className="delta-row">
              <div className="delta-label">{det} detected</div>
              <div className="delta-value">{pct(group.detected)}%</div>
              <div className="delta-comp tone-neutral">{fmtNum(group.detected)} of {fmtNum(group.n)}</div>
            </div>
            <div className="delta-row">
              <div className="delta-label">{det}, not enrolled</div>
              <div className="delta-value">{fmtNum(group.gap)}</div>
              <div className="delta-comp tone-bad">retargeting opportunity</div>
            </div>
          </div>
        </>
      )}

      {kpis && (
        <>
          <div className="dist-group-label" style={{ marginTop: 10 }}>Program-wide</div>
          <div className="delta-grid">
            <div className="delta-row">
              <div className="delta-label">Adoption</div>
              <div className="delta-value">{fmtNum(kpis.pct_adoption, 1)}%</div>
              <div className="delta-comp tone-neutral">{fmtNum(kpis.n_enrolled_total)} of {fmtNum(kpis.n_eligible)} eligible</div>
            </div>
            <div className="delta-row">
              <div className="delta-label">Eligible, not enrolled</div>
              <div className="delta-value">{fmtNum(kpis.n_eligible_not_enrolled)}</div>
              <div className="delta-comp tone-neutral">addressable base</div>
            </div>
            <div className="delta-row">
              <div className="delta-label">Energy saved</div>
              <div className="delta-value">{fmtKwh(kpis.total_kwh_saved)}</div>
              <div className="delta-comp tone-good">to date</div>
            </div>
          </div>
        </>
      )}

      {trend.length > 1 && (
        <>
          <div className="dist-group-label" style={{ marginTop: 10 }}>Monthly enrollments</div>
          <div style={{ width: "100%", height: 56 }}>
            <ResponsiveContainer>
              <LineChart data={trend}>
                <Line type="monotone" dataKey="n" stroke="var(--accent)" strokeWidth={1.5} dot={false} />
              </LineChart>
            </ResponsiveContainer>
          </div>
        </>
      )}

      <div className="dist-group-label" style={{ marginTop: 10 }}>Recommended targets</div>
      {targetsQ.loading ? (
        <div className="loading">Loading…</div>
      ) : targets.length === 0 ? (
        <div className="subtle">No high-fit candidates not yet enrolled.</div>
      ) : (
        <ul className="cell-customer-list">
          {targets.slice(0, 10).map((t) => (
            <li
              key={t.account_number}
              className="cell-customer-row"
              onClick={() => onSelectCustomer(t.account_number)}
              title="Drill into this customer"
            >
              <div className="name">Fit {t.fit_score} · {t.service_address}</div>
              <div className="meta">
                {localityText({ city: t.service_city, county: t.county })} · {t.customer_class} · {fmtKwh(t.avg_monthly_kwh_12mo)}/mo
              </div>
              <div className="badges">
                {bool(t.high_user_flag) && <span className="badge warn">High usage</span>}
                {bool(t.payment_stressed_flag) && <span className="badge alert">Payment stress</span>}
                {bool(t.liheap_eligible) && <span className="badge info">LIHEAP</span>}
              </div>
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}

// ────────────────────────────────────────────────────────────────────
// Chat answer bubble — renders one Genie turn's response inside the chat:
// a matched-customer summary, and/or a text narrative + compact result table.
// ────────────────────────────────────────────────────────────────────

function ChatAnswer({ turn }: { turn: GenieTurn }) {
  const { text, columns, rows, customers, truncated } = turn;
  const hasTable = !!columns && columns.length > 0 && !!rows && rows.length > 0;
  const matched = customers && customers.length > 0;
  // `customers` is premise-grain (one row per current premise — a multi-site
  // commercial customer paints a dot on every site, see enrichCustomers()),
  // so it matches the map dots and the rail headline. The distinct-customer
  // count is derived from the same rows (not turn.count, which is Genie's raw
  // customer_id count) so the sentence always agrees with what's on screen.
  const premiseCount = customers?.length ?? 0;
  const customerCount = customers ? new Set(customers.map((c) => c.customer_id)).size : 0;
  const grainsDiverge = matched && customerCount !== premiseCount;
  return (
    <>
      {matched && (
        <div className="chat-a-text">
          Found{truncated ? " the first" : ""}{" "}
          <strong>{formatUnitCount(fmtNum(customerCount), customerCount, "customer")}</strong>
          {grainsDiverge && (
            <> across <strong>{formatUnitCount(fmtNum(premiseCount), premiseCount, "premise")}</strong></>
          )} — highlighted on
          the map and listed on the right. Pan/zoom or ask a follow-up to narrow further.
        </div>
      )}
      {text && (
        <div className="chat-a-text chat-a-md">
          <ReactMarkdown remarkPlugins={[remarkGfm]}>{text}</ReactMarkdown>
        </div>
      )}
      {hasTable && (
        <div className="chat-table-wrap">
          <table className="genie-answer-table">
            <thead>
              <tr>{columns!.map((c) => <th key={c}>{c.replace(/_/g, " ")}</th>)}</tr>
            </thead>
            <tbody>
              {rows!.slice(0, 50).map((r, i) => (
                <tr key={i}>{r.map((v, j) => <td key={j}>{v ?? "—"}</td>)}</tr>
              ))}
            </tbody>
          </table>
          {rows!.length > 50 && <div className="chat-table-more">first 50 rows</div>}
        </div>
      )}
      {!matched && !text && !hasTable && (
        <div className="chat-a-text subtle">Genie didn't return a displayable answer. Try rephrasing.</div>
      )}
    </>
  );
}

