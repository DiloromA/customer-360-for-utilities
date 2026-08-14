import { useState, useMemo, useEffect, lazy, Suspense } from "react";
import { PanelLeftClose, PanelLeftOpen } from "lucide-react";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@databricks/appkit-ui/react";
import { useC360Query } from "./queryUtils";
import { sql } from "@databricks/appkit-ui/js";
import { rows } from "./queryUtils";
import { ExplorerMap, type MapFocusRequest } from "./ExplorerMap";
import { PremiseDetail, PivotChips, LinkageStrip, shortId, type InspectorSubject, type PremiseRosterEntry } from "./PremiseInspector";
import { OwnerDetail } from "./OwnerInspector";
import { UTILITY_NAME, PRODUCT_NAME } from "./config";
import { localityText } from "./filters";
import { NavRail } from "./nav/NavRail";
import { useNavState } from "./nav/useNavState";
import { DEFAULT_VIEW } from "./nav/navConfig";
// Non-Explorer views are lazy-loaded so their chart/graph code doesn't land
// on the Explorer's critical path. Each chunk is fetched on first nav click.
const DataModelView = lazy(() => import("./views/DataModelView").then((m) => ({ default: m.DataModelView })));
const DocumentationView = lazy(() => import("./views/DocumentationView").then((m) => ({ default: m.DocumentationView })));
const MetricsCatalogView = lazy(() => import("./views/MetricsCatalogView").then((m) => ({ default: m.MetricsCatalogView })));
const CsatView = lazy(() => import("./views/CsatView").then((m) => ({ default: m.CsatView })));
import {
  Bar,
  LineChart,
  Line,
  ComposedChart,
  Legend,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  CartesianGrid,
} from "recharts";

// ────────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────────

interface PickerRow {
  account_number: string | null;   // null for commercial_parent org results
  customer_number: string;
  customer_name: string | null;    // fictional org label for commercial_parent
  customer_class: string;
  service_address: string | null;  // null for commercial_parent org results
  service_city: string | null;
  county: string | null;
  engagement_tier: string;
  payment_stressed_flag: boolean;
  high_user_flag: boolean;
  usage_band: string;
  churn_risk_band: string;
  critical_care_flag: boolean;
  liheap_eligible: boolean;
  recent_complaint_count_90d: number;
  recent_outage_minutes_90d: number;
  portfolio_premise_count: number | null; // non-null for commercial_parent
  latitude?: number;
  longitude?: number;
  archetype?: string;
}

interface HeaderRow {
  account_number: string;
  premise_number: string;
  customer_number: string;
  customer_class: string;
  // Identity for the profile title: org name for commercial parties, NULL for
  // residential (fall back to the in-focus address). See customer_header.sql.
  customer_name: string | null;
  customer_type: string;
  language_preference: string;
  critical_care_flag: boolean;
  liheap_eligible: boolean;
  payment_stressed_flag: boolean;
  payment_late_flag: boolean;
  high_user_flag: boolean;
  engagement_tier: string;
  digital_adoption_score: number;
  churn_risk_band: string;
  recent_outage_minutes_90d: number;
  recent_outage_events_90d: number;
  recent_complaint_count_90d: number;
  avg_monthly_kwh_12mo: number;
  peer_p75_avg_monthly_kwh: number;
  peer_building_subtype: string;
  peer_sqft_band: string;
  customer_since_date: string;
  tenant_since: string | null;
  previous_customer_until: string | null;
  previous_customer_count: number;
  rate_display_name: string;
  autopay_enrolled: boolean;
  paperless_enrolled: boolean;
  preferred_channel: string;
  account_tenure_band: string;
  account_status: string;
  // Predicted 30-day complaint risk (ml_complaint_predictor). Null = unscored.
  complaint_risk_pct: number | null;
  complaint_risk_tier: string | null;
  complaint_risk_category: string | null;
  complaint_risk_drivers: string | null;
  complaint_risk_action: string | null;
  // Unregistered-EV detection (ml_ev_detector). ev_on_record is the
  // ground-truth has_ev — likely_flag true + on_record false is the
  // "consumption pattern matches, nothing on file" disagreement. PV lives
  // on the Premise inspector (premise_header.sql).
  ev_probability_pct: number | null;
  ev_likely_flag: boolean | null;
  ev_on_record: boolean | null;
  service_address: string;
  service_city: string;
  service_state: string;
  service_zip: string;
  county: string;
  building_subtype: string;
  sqft: number;
  year_built: number;
  heating_fuel: string;
  envelope_quality: string;
  // Linkage context (customer_header.sql): what sits below/around this grain.
  current_premises: number | null;
  current_accounts: number | null;
  parent_org_name: string | null;
}

interface BillRow {
  bill_id: string;
  bill_period_end: string;
  total_kwh: number;
  current_charges: number;
  previous_balance: number;
  total_amount_due: number;
  payment_status: string;
  bill_shock_pct: number | null;
  yoy_kwh_change_pct: number | null;
  amount_paid: number | null;
  days_late: number | null;
  peer_avg_kwh: number | null;
  peer_p75_kwh: number | null;
}

interface ComplaintRow {
  complaint_id: string;
  complaint_date: string;
  channel: string;
  category: string;
  sub_category: string;
  severity: string;
  sentiment_label: string;
  resolution_status: string;
  verbatim_language: string;
  verbatim_text: string;
}

interface OutageRow {
  impact_id: string;
  outage_id: string;
  affected_start: string;
  minutes_out: number;
  cause_code: string;
  weather_category: string;
  is_major_event_day: boolean;
  duration_bucket: string;
  priority_restoration_flag: boolean;
  premise_number: string;
}

interface RecommendationRow {
  program_id: string;
  program_name: string;
  program_type: string;
  rebate_amount_usd: number;
  avg_annual_kwh_saved: number;
  relevance_score: number;
}

// Real-time: is this customer's premise currently without power? 0 or 1 row.
interface ActiveOutageRow {
  active_outage_id: string;
  out_since: string;
  estimated_restoration_at: string;
  minutes_out_so_far: number;
  priority_restoration_flag: boolean;
  cause_code: string;
  weather_category: string;
  crew_status: string;
  n_customers_out: number;
}

// A DER device AMI/DER data shows at the premise paired with an active program
// targeting it the customer hasn't enrolled in — the per-customer version of
// the exec map's "device detected · not enrolled" opportunity.
interface DerOpportunityRow {
  device_type: string;
  device_subtype: string | null;
  system_size_kwh_or_dc: number | null;
  program_id: string;
  program_name: string;
  program_type: string;
  rebate_amount_usd: number;
  avg_annual_kwh_saved: number;
}

// Human label for a DER device_type (matches the exec map's derLabelForProgram).
function derDeviceLabel(deviceType: string): string {
  switch (deviceType) {
    case "EV":          return "EV";
    case "HEAT_PUMP":   return "Heat pump";
    case "SMART_TSTAT": return "Smart thermostat";
    case "PV":          return "Solar PV";
    default:            return deviceType;
  }
}

interface LoadProfileRow {
  hour_of_day: number;
  avg_kwh: number;
  median_kwh: number;
  p90_kwh: number;
  n_days: number;
}

// One service event on the customer's account timeline: move-in / move-out / rate
// switch / meter swap (from fact_service_event). Events not belonging to the
// current account (is_current_account = false) are a prior customer's.
interface TimelineRow {
  service_event_id: number;
  event_type: string;
  event_date: string;
  detail: string | null;
  account_id: number | null;
  meter_id: number | null;
  service_agreement_id: number | null;
  // The site each event happened at — this timeline spans every premise the
  // customer has held, so a multi-site customer's rows carry different addresses.
  service_address: string | null;
  service_city: string | null;
  is_current_account: boolean;
}

// One account/premise tenancy for the "Accounts & Premises" tab — the full
// bridge_account_premise history (current AND closed) for every account this
// customer holds, not just the deep-linked one.
interface AccountPremiseRow {
  account_number: string;
  account_group: string;
  parent_account_number: string | null;
  account_status: string;
  rate_display_name: string | null;
  account_premise_link_id: number | null;
  service_address: string | null;
  service_city: string | null;
  service_state: string | null;
  link_start_date: string | null;
  link_end_date: string | null;
  is_current: boolean | null;
  tenancy_type: string | null;
  link_termination_reason: string | null;
}

interface MeterHistoryRow {
  premise_id: number;
  service_address: string | null;
  meter_number: string;
  installation_date: string;
  removal_date: string | null;
  removal_reason_code: string | null;
  is_current: boolean;
  installation_status: string;
}

interface RateHistoryRow {
  account_number: string;
  agreement_seq: number;
  rate_display_name: string | null;
  rate_schedule: string;
  effective_date: string;
  termination_date: string | null;
  is_current: boolean;
  termination_reason: string | null;
}

interface ProfileChangeRow {
  effective_from: string;
  entity: string;
  account_number: string | null;
  change_label: string;
}

interface CustomerLocationRow {
  premise_id: number;
  service_address: string | null;
  latitude: number;
  longitude: number;
}


// ────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────

// Databricks SQL returns DECIMAL/numeric fields as strings over JSON.
// num() coerces safely so .toFixed / .toLocaleString never throw and
// blank the page.
function num(n: number | string | null | undefined): number | null {
  if (n == null || n === "") return null;
  const v = typeof n === "string" ? Number(n) : n;
  return Number.isFinite(v) ? v : null;
}
// Same story as num() above but for BOOLEAN columns: Databricks SQL returns
// them as the literal strings "true"/"false" over JSON, and "false" is a
// truthy non-empty string in JS — a bare `if (c.some_flag)` is always true.
// Every BOOLEAN-typed query column MUST be run through bool() before a
// truthy check.
function bool(b: boolean | string | null | undefined): boolean {
  return b === true || b === "true";
}
function fmtUSD(n: number | string | null | undefined) {
  const v = num(n);
  if (v == null) return "—";
  return `$${v.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
}
function fmtKwh(n: number | string | null | undefined) {
  const v = num(n);
  if (v == null) return "—";
  return `${Math.round(v).toLocaleString()} kWh`;
}
function fmtPct(n: number | string | null | undefined) {
  const v = num(n);
  if (v == null) return "—";
  return `${(v * 100).toFixed(0)}%`;
}
function fmtDate(s: string | null | undefined) {
  if (!s) return "—";
  return new Date(s).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}
function statusBadgeClass(status: string): string {
  if (status === "unpaid") return "alert";
  if (status === "paid_partial") return "warn";
  if (status === "paid_late") return "info";
  return "good";
}
function severityBadgeClass(s: string): string {
  if (s === "high") return "alert";
  if (s === "medium") return "warn";
  return "neutral";
}

// Customer-filter vocabulary (options, FilterGroup, SQL serialization) lives
// in ./filters and is shared with the Explorer map rail.

// ────────────────────────────────────────────────────────────────────
// Main App
// ────────────────────────────────────────────────────────────────────

type Theme = "dark" | "light";

// Lakeshore Power & Light mark — a lightning bolt (power) over a lake wave
// (lakeshore) in a gradient badge. Inline SVG so it themes with the app and
// ships with no asset.
function BrandLogo() {
  return (
    <svg className="brand-mark" width="30" height="30" viewBox="0 0 30 30" role="img" aria-label="Lakeshore Power & Light">
      <defs>
        <linearGradient id="ls-badge" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#22d3ee" />
          <stop offset="1" stopColor="#2563eb" />
        </linearGradient>
      </defs>
      <rect x="1" y="1" width="28" height="28" rx="8" fill="url(#ls-badge)" />
      <path d="M16.5 5 L9 16.5 H13.5 L12 25 L21 13 H15.5 Z" fill="#fff" />
      <path d="M5.5 22.5 q2.4 -2 4.8 0 t4.8 0 t4.8 0" stroke="#e0f2fe" strokeWidth="1.5" fill="none" strokeLinecap="round" opacity="0.85" />
    </svg>
  );
}

export default function App() {
  const [theme, setTheme] = useState<Theme>(
    () => (localStorage.getItem("c360-theme") as Theme) || "dark"
  );
  // The full profile drawer, shown wide over the map. There's no standalone
  // customer/premise tab — the map is the sole canvas, and a subject is
  // either the condensed rail card or this expanded drawer. Subject-typed
  // (premise vs customer) — a dot click opens the Premise inspector
  // by default, and the pivot chip switches subjects without closing the
  // drawer.
  const [fullSubject, setFullSubject] = useState<InspectorSubject | null>(null);
  // A fly-to + select request handed to the map from the top-bar search.
  const [focus, setFocus] = useState<MapFocusRequest | null>(null);
  const nav = useNavState();

  // Drawer pivot: switch the profile subject AND keep the map behind in sync.
  // Switching to a specific location (e.g. the multi-site picker's "other"
  // home) flies the map to that premise and rings it — so when the user closes
  // the drawer the map is already centred on where they navigated, not stranded
  // on the premise they started from. Coords ride along on the premise subject
  // (from the roster); absent coords → subject change only, no map move.
  const pivotFull = (s: InspectorSubject) => {
    setFullSubject(s);
    if (s.kind === "premise" && s.lat != null && s.lon != null) {
      setFocus({ premiseNumber: s.premiseNumber, lat: s.lat, lon: s.lon, ts: Date.now() });
    }
  };

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem("c360-theme", theme);
  }, [theme]);

  useEffect(() => { document.title = PRODUCT_NAME; }, []);

  return (
    <div className={`app no-picker${nav.collapsed ? " nav-collapsed" : ""}`}>
      <header className="topbar">
        <div className="topbar-brand">
          <button
            type="button"
            className="nav-collapse-toggle"
            onClick={nav.toggleCollapsed}
            aria-expanded={!nav.collapsed}
            aria-label={nav.collapsed ? "Expand navigation" : "Collapse navigation"}
            title={nav.collapsed ? "Expand navigation (Ctrl/Cmd+B)" : "Collapse navigation (Ctrl/Cmd+B)"}
          >
            {nav.collapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
          </button>
          <BrandLogo />
          <span className="brand-utility-name">{UTILITY_NAME}</span>
        </div>
        <div className="topbar-product">{PRODUCT_NAME}</div>
        <div className="topbar-controls">
          <TopbarSearch
            onPick={(row) => {
              setFullSubject(null);
              nav.setActiveView(DEFAULT_VIEW);
              // commercial_parent rows have no premise and no lat/lon, so skip
              // the map fly-to rather than fabricate coordinates.
              if (row.latitude != null && row.longitude != null) {
                setFocus({
                  account: row.account_number ?? undefined,
                  lat: Number(row.latitude),
                  lon: Number(row.longitude),
                  ts: Date.now(),
                });
              }
            }}
          />
          <button className="theme-toggle" onClick={() => setTheme(theme === "dark" ? "light" : "dark")}>
            {theme === "dark" ? "☀ Light" : "☾ Dark"}
          </button>
        </div>
      </header>

      <NavRail
        activeView={nav.activeView}
        onSelect={nav.setActiveView}
        collapsed={nav.collapsed}
      />

      <main className="main">
        {/* Hidden-but-mounted (not unmounted) keeps ExplorerMap's viewport,
            focus-set cohort, and Genie conversation alive across nav switches.
            visibility:hidden + position:absolute (not display:none) so the
            map container never collapses to 0x0 — see .explorer-root.is-hidden. */}
        <div className={`explorer-root${nav.activeView === DEFAULT_VIEW ? "" : " is-hidden"}`}>
          <ExplorerMap onJumpToSubject={setFullSubject} focus={focus} visible={nav.activeView === DEFAULT_VIEW} />
        </div>
        <Suspense fallback={<div className="loading" style={{ padding: 32 }}>Loading…</div>}>
          {nav.activeView === "data-model" && <DataModelView />}
          {nav.activeView === "documentation" && (
            <DocumentationView
              onOpenDataModel={() => nav.setActiveView("data-model")}
              onOpenMetricsCatalog={() => nav.setActiveView("metrics-catalog")}
            />
          )}
          {nav.activeView === "metrics-catalog" && <MetricsCatalogView />}
          {nav.activeView === "csat" && <CsatView onJumpToSubject={setFullSubject} />}
        </Suspense>
      </main>

      {fullSubject && (
        <div className="cust-drawer-scrim" onClick={() => setFullSubject(null)}>
          <aside className="cust-drawer" onClick={(e) => e.stopPropagation()}>
            <div className="cust-drawer-head">
              <button className="cell-back" onClick={() => setFullSubject(null)}>← Back to map</button>
              <span className="cust-drawer-title">
                {fullSubject.kind === "premise" ? "Premise profile"
                  : fullSubject.kind === "owner" ? "Owner profile"
                  : "Customer profile"}
              </span>
            </div>
            <div className="cust-drawer-body">
              {fullSubject.kind === "premise" ? (
                <PremiseDetail premiseNumber={fullSubject.premiseNumber} onPivot={pivotFull} />
              ) : fullSubject.kind === "owner" ? (
                <OwnerDetail
                  ownerNumber={fullSubject.ownerNumber}
                  onPivot={pivotFull}
                  onShowAllLocations={(points) => {
                    if (points.length === 0) return;
                    setFullSubject(null);
                    nav.setActiveView(DEFAULT_VIEW);
                    setFocus({ lat: points[0].lat, lon: points[0].lon, points, ts: Date.now() });
                  }}
                />
              ) : (
                <CustomerDetail
                  accountNumber={fullSubject.accountNumber}
                  onPivot={pivotFull}
                  onShowAllLocations={(points) => {
                    if (points.length === 0) return;
                    const account = fullSubject.accountNumber;
                    setFullSubject(null);
                    nav.setActiveView(DEFAULT_VIEW);
                    setFocus({
                      account,
                      lat: points[0].lat,
                      lon: points[0].lon,
                      points,
                      ts: Date.now(),
                    });
                  }}
                />
              )}
            </div>
          </aside>
        </div>
      )}
    </div>
  );
}

// Top-bar customer search — autocomplete over the full current base
// (customer_search). On pick, hands a fly-to + select request up to the map.
function TopbarSearch({ onPick }: { onPick: (row: PickerRow) => void }) {
  const [search, setSearch] = useState("");
  const [open, setOpen] = useState(false);
  const trimmed = search.trim();
  const isSearching = trimmed.length >= 2;
  const searchParams = useMemo(() => ({ search_term: sql.string(trimmed) }), [trimmed]);
  const searchQuery = useC360Query<PickerRow>(
    "customer_search",
    isSearching ? searchParams : { search_term: sql.string("__none__") },
  );
  const searchRows = isSearching ? rows(searchQuery.data) : [];

  return (
    <div className="topbar-search">
      <input
        type="search"
        className="topbar-search-input"
        placeholder="Search address, city, or account…"
        value={search}
        onChange={(e) => { setSearch(e.target.value); setOpen(true); }}
        onFocus={() => setOpen(true)}
        onBlur={() => setTimeout(() => setOpen(false), 150)}
      />
      {open && isSearching && (
        <div className="topbar-search-results">
          {searchQuery.loading && <div className="loading">Searching…</div>}
          {!searchQuery.loading && searchRows.length === 0 && <div className="empty-state">No matches.</div>}
          {searchRows.slice(0, 30).map((r) => (
            <button
              key={r.account_number ?? r.customer_number}
              type="button"
              className="search-result-row"
              // mousedown (not click) so the pick registers before the input's
              // blur closes the dropdown.
              onMouseDown={(e) => { e.preventDefault(); onPick(r); setSearch(""); setOpen(false); }}
            >
              {r.customer_name
                ? <div className="name">{r.customer_name}</div>
                : <div className="name">{r.service_address}</div>
              }
              <div className="meta">
                {r.customer_name
                  ? `${r.portfolio_premise_count ?? ""} sites · ${r.customer_class}`
                  : `${localityText({ city: r.service_city, county: r.county })} · ${r.customer_class} · ${r.engagement_tier} eng`
                }
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// One current service location, for the Premise pivot chip's location switcher.
interface CustomerPremiseRow {
  premise_number: string;
  service_address: string | null;
  service_city: string | null;
  service_state: string | null;
  latitude: number | null;
  longitude: number | null;
}

// ────────────────────────────────────────────────────────────────────
// Customer detail (full profile, shown in the over-map drawer)
// ────────────────────────────────────────────────────────────────────

function CustomerDetail({
  accountNumber, onShowAllLocations, onPivot,
}: {
  accountNumber: string;
  onShowAllLocations: (points: { lat: number; lon: number }[]) => void;
  onPivot: (subject: InspectorSubject) => void;
}) {
  const params = useMemo(() => ({ account_number: sql.string(accountNumber) }), [accountNumber]);

  const header = useC360Query<HeaderRow>("customer_header", params);
  const bills = useC360Query<BillRow>("customer_bills", params);
  const complaints = useC360Query<ComplaintRow>("customer_complaints", params);
  const outages = useC360Query<OutageRow>("customer_outages", params);
  const recos = useC360Query<RecommendationRow>("customer_recommendations", params);
  const derOpps = useC360Query<DerOpportunityRow>("customer_der_opportunities", params);
  const timeline = useC360Query<TimelineRow>("customer_timeline", params);
  const activeOutage = useC360Query<ActiveOutageRow>("customer_active_outage", params);
  // Current-premise roster for the Premise pivot chip's location switcher —
  // matches the compact rail card (CustomerDrillPanel), so the multi-site
  // dropdown that appears there also appears in the full profile.
  const premisesQ = useC360Query<CustomerPremiseRow>("customer_premises", params);
  const premiseRoster: PremiseRosterEntry[] = useMemo(
    () => rows(premisesQ.data).map((r) => ({
      premiseNumber: r.premise_number,
      address: r.service_address,
      lat: r.latitude,
      lon: r.longitude,
    })),
    [premisesQ.data],
  );

  const headerRows = rows(header.data);
  const activeOutageRows = rows(activeOutage.data);

  if (header.loading) return <div className="loading">Loading customer…</div>;
  if (header.error)   return <div className="error">{String(header.error)}</div>;
  if (headerRows.length === 0) return <div className="empty-state">No data</div>;

  const c = headerRows[0];

  return (
    <>
      <HeaderStrip c={c} />
      <PivotChips
        subject={{ kind: "customer", accountNumber }}
        locationLabel={c.service_address}
        premiseNumber={c.premise_number}
        premiseRoster={premiseRoster}
        onPivot={onPivot}
      />
      <LinkageStrip grain="customer" premises={c.current_premises} parentOrg={c.parent_org_name} />
      <AlertsBanner c={c} derOpps={rows(derOpps.data)} activeOutage={activeOutageRows[0] ?? null} />
      <Tabs defaultValue="overview" className="profile-tabs">
        <TabsList>
          <TabsTrigger value="overview">Overview</TabsTrigger>
          <TabsTrigger value="accounts">Accounts &amp; Premises</TabsTrigger>
        </TabsList>
        <TabsContent value="overview">
          <CoachCard recos={rows(recos.data)} recosLoading={recos.loading} />
          <TimelineCard rows={rows(timeline.data)} loading={timeline.loading} />
          <BillChart rows={rows(bills.data)} loading={bills.loading} />
          <LoadProfileCard accountNumber={accountNumber} bills={rows(bills.data)} />
          <ComplaintCard rows={rows(complaints.data)} loading={complaints.loading} />
          <OutageCard rows={rows(outages.data)} loading={outages.loading} />
        </TabsContent>
        <TabsContent value="accounts">
          <AccountsPremisesTab accountNumber={accountNumber} onShowAllLocations={onShowAllLocations} />
        </TabsContent>
      </Tabs>
    </>
  );
}

// ────────────────────────────────────────────────────────────────────
// Alerts banner — the customer's key issues at a glance
// ────────────────────────────────────────────────────────────────────

function AlertsBanner({ c, derOpps, activeOutage }: { c: HeaderRow; derOpps: DerOpportunityRow[]; activeOutage?: ActiveOutageRow | null }) {
  const items: { tone: "alert" | "warn" | "info"; text: string; detail: string }[] = [];

  // Real-time: currently without power. Leads the banner — the most urgent
  // thing to surface when the customer calls in.
  if (activeOutage) {
    const outMin = Math.round(num(activeOutage.minutes_out_so_far)!);
    const outStr = outMin >= 60 ? `${Math.floor(outMin / 60)}h ${outMin % 60}m` : `${outMin}m`;
    const eta = activeOutage.estimated_restoration_at
      ? new Date(activeOutage.estimated_restoration_at).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
      : "TBD";
    items.push({
      tone: "alert",
      text: "⚡ Currently without power",
      detail: `Out for ${outStr} (${(activeOutage.cause_code || "").replace(/_/g, " ")}). Crew ${(activeOutage.crew_status || "").replace(/_/g, " ")} · estimated restoration ~${eta}. ${(num(activeOutage.n_customers_out) ?? 0).toLocaleString()} customers affected on this incident.${bool(activeOutage.priority_restoration_flag) ? " Critical-care — prioritized for restoration." : ""}`,
    });
  }

  if (bool(c.payment_stressed_flag)) {
    items.push({
      tone: "alert",
      text: "Payment stress",
      detail: "Has unpaid or partially-paid bills in the last 12 months, or a balance over $200.",
    });
  }
  if (bool(c.payment_late_flag)) {
    items.push({
      tone: "warn",
      text: "Paid late",
      detail: "Has paid one or more bills past the due date in the last 12 months.",
    });
  }
  if (bool(c.high_user_flag)) {
    items.push({
      tone: "warn",
      text: "High usage",
      detail: `This site's average monthly use (${fmtKwh(c.avg_monthly_kwh_12mo)}) is above the 75th percentile for similar sites — same building type & size band (${fmtKwh(c.peer_p75_avg_monthly_kwh)}).`,
    });
  }
  if (bool(c.critical_care_flag)) {
    items.push({
      tone: "alert",
      text: "Critical-care medical",
      detail: "Customer is registered for priority outage restoration (medical equipment depends on power).",
    });
  }
  if (bool(c.liheap_eligible)) {
    items.push({
      tone: "info",
      text: "Low-Income Home Energy Assistance (LIHEAP) eligible",
      detail: "Customer's income qualifies them for the federal LIHEAP program — offer enrollment if not yet active.",
    });
  }
  if (c.churn_risk_band === "high") {
    items.push({
      tone: "alert",
      text: "High dissatisfaction risk",
      detail: "CX legacy score indicates this customer is likely to escalate — a regulator (PSC) complaint, social-media post, or formal dissatisfaction.",
    });
  } else if (c.churn_risk_band === "medium") {
    items.push({
      tone: "warn",
      text: "Moderate dissatisfaction risk",
      detail: "CX legacy score indicates some dissatisfaction signal.",
    });
  }
  // Predicted complaint risk — the ml_complaint_predictor score on the
  // customer's latest billing cycle. Unlike the legacy CX churn band above,
  // this is forward-looking (P(complaint in the next 30 days)) and comes with
  // the drivers + the outreach playbook for the most likely category.
  if (c.complaint_risk_tier === "high" || c.complaint_risk_tier === "elevated") {
    const parts = [
      `Model puts this customer in the ${c.complaint_risk_tier === "high" ? "top 5%" : "top 20%"} for a complaint in the next 30 days (${c.complaint_risk_pct}% predicted).`,
      c.complaint_risk_category ? `Most likely category: ${c.complaint_risk_category}.` : "",
      c.complaint_risk_drivers ? `Drivers: ${c.complaint_risk_drivers}.` : "",
      c.complaint_risk_action ? `Suggested action: ${c.complaint_risk_action}.` : "",
    ].filter(Boolean);
    items.push({
      tone: c.complaint_risk_tier === "high" ? "alert" : "warn",
      text: c.complaint_risk_tier === "high"
        ? "High complaint risk (predicted)"
        : "Elevated complaint risk (predicted)",
      detail: parts.join(" "),
    });
  }
  if (num(c.recent_outage_minutes_90d)! > 240) {
    items.push({
      tone: "warn",
      text: "Heavy outage exposure (90d)",
      detail: `${c.recent_outage_events_90d} events totaling ${c.recent_outage_minutes_90d} minutes out in the last 90 days.`,
    });
  }
  if (num(c.recent_complaint_count_90d)! >= 2) {
    items.push({
      tone: "warn",
      text: `${c.recent_complaint_count_90d} recent complaints`,
      detail: "Multiple complaints in the last 90 days — see Complaints section below.",
    });
  }
  // EV detection (ml_ev_detector). Distinct from the "detected · not
  // enrolled" cards below, which fire on DER the utility already has on
  // record for a program-adoption angle: this is the model's own read of
  // the consumption pattern, badged differently depending on whether it
  // matches what's on file. The interesting case is a likely install with
  // NO record at all — possible unregistered ownership, not just a missed
  // rebate — so that gets the louder "warn" tone; a likely install that
  // matches the record is a quieter confirmation. EV moves with the
  // customer (unlike PV, which is physically a premise attribute and now
  // lives on the Premise inspector — see premise_header.sql).
  if (bool(c.ev_likely_flag) && !bool(c.ev_on_record)) {
    items.push({
      tone: "warn",
      text: "Likely unregistered EV (predicted)",
      detail: `Consumption pattern (sharp evening/overnight charging load) is consistent with EV ownership — ${c.ev_probability_pct}% predicted — but there's no EV on record for this customer. Worth raising the EV rate options on the call.`,
    });
  } else if (bool(c.ev_likely_flag) && bool(c.ev_on_record)) {
    items.push({
      tone: "info",
      text: "Detected EV (confirmed)",
      detail: `Consumption pattern is consistent with EV charging — ${c.ev_probability_pct}% predicted — matching the DER record on file for this customer.`,
    });
  }
  // DER-detected program opportunities. AMI/DER data shows the device, but the
  // customer isn't enrolled in a program that targets it — the same "detected ·
  // not enrolled" the exec map flags, surfaced here as a concrete call action.
  for (const o of derOpps) {
    const device = derDeviceLabel(o.device_type);
    const sub = o.device_subtype ? ` (${o.device_subtype})` : "";
    items.push({
      tone: "info",
      text: `${device} detected — not enrolled`,
      detail: `AMI/DER data shows ${device.toLowerCase()}${sub} at this premise. Offer the ${o.program_name}${o.rebate_amount_usd ? ` (${fmtUSD(o.rebate_amount_usd)} rebate)` : ""} — not yet enrolled.`,
    });
  }

  if (items.length === 0) {
    return (
      <div className="alerts-banner ok">
        <span className="badge good">No active issues</span>
        <span className="alerts-detail">Payment current, usage in expected range, no recent complaints or unusual outages.</span>
      </div>
    );
  }

  const worst = items.some((i) => i.tone === "alert") ? "alert" : "warn";
  return (
    <div className={`alerts-banner ${worst}`}>
      <div className="alerts-title">Next actions &amp; insights</div>
      <div className="alerts-grid">
        {items.map((i, idx) => (
          <div key={idx} className={`alert-tile tone-${i.tone}`}>
            <div className="alert-tile-text">{i.text}</div>
            <div className="alert-tile-detail">{i.detail}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Top program offers — best-matching programs for this customer
// ────────────────────────────────────────────────────────────────────

function CoachCard({
  recos, recosLoading,
}: { recos: RecommendationRow[]; recosLoading: boolean }) {
  // Only the top 3 recommendations are shown.
  const top = recos.slice(0, 3);

  return (
    <div className="card coach-card">
      <h2>Top program offers</h2>
      {recosLoading && <div className="loading">Loading…</div>}
      {!recosLoading && top.length === 0 && (
        <div className="subtle">No matching programs for this customer's segment.</div>
      )}
      {top.length > 0 && (
        <ul className="coach-list">
          {top.map((r) => (
            <li key={r.program_id}>
              <strong>{r.program_name}</strong>
              <span className="subtle"> — {r.program_type}, {fmtUSD(r.rebate_amount_usd)} rebate, ~{fmtKwh(r.avg_annual_kwh_saved)} saved / yr</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Service-event timeline — the customer's journey at this premise
// ────────────────────────────────────────────────────────────────────

const SERVICE_EVENT_META: Record<string, { label: string; icon: string }> = {
  move_in:     { label: "Moved in",     icon: "→" },
  move_out:    { label: "Moved out",    icon: "←" },
  rate_switch: { label: "Rate switch",  icon: "⇄" },
  meter_swap:  { label: "Meter swap",   icon: "⏱" },
};

function TimelineCard({ rows, loading }: { rows: TimelineRow[]; loading: boolean }) {
  // This timeline spans every premise the customer has held. When more than one
  // address appears, stamp each row with its site — otherwise two move-ins at a
  // second home (or before/after a relocation) read as an impossible sequence.
  const multiSite = new Set(rows.map((r) => r.service_address).filter(Boolean)).size > 1;
  return (
    <div className="card">
      <h2>Service Timeline ({rows.length})</h2>
      <div className="subtle" style={{ marginBottom: 8 }}>
        Move-in / move-out, rate switches, and meter swaps across this customer's
        service locations — the events behind the bills, outages and complaints below.
      </div>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No service events on file.</div>}
      {rows.length > 0 && (
        <ul className="theme-list">
          {rows.map((r) => {
            const meta = SERVICE_EVENT_META[r.event_type] || { label: r.event_type.replace(/_/g, " "), icon: "•" };
            // "Previous customer" only applies to events on a DIFFERENT account.
            // Physical, account-less events (meter swaps) belong to no customer —
            // is_current_account is null for them, so gate on a real account_id.
            const isPriorCustomer = r.account_id != null && !bool(r.is_current_account);
            return (
              <li key={r.service_event_id}>
                <span className="theme-name">
                  <span style={{ marginRight: 6 }}>{meta.icon}</span>
                  {meta.label}
                  {r.detail ? ` — ${r.detail}` : ""}
                  {multiSite && r.service_address && (
                    <span className="subtle" style={{ marginLeft: 6 }}>· 📍 {r.service_address}</span>
                  )}
                  {isPriorCustomer && <span className="badge neutral" style={{ marginLeft: 6 }}>previous customer</span>}
                </span>
                <span className="theme-count">{fmtDate(r.event_date)}</span>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Accounts & Premises tab — full tenancy/meter/rate history. Keyed by
// CUSTOMER (via each query's own account_number -> customer_id resolution),
// not just the one account deep-linked into, so chain customers show every
// site and a mover (once modeled) would show every tenancy.
// ────────────────────────────────────────────────────────────────────

function AccountsPremisesTab({
  accountNumber, onShowAllLocations,
}: { accountNumber: string; onShowAllLocations: (points: { lat: number; lon: number }[]) => void }) {
  const params = useMemo(() => ({ account_number: sql.string(accountNumber) }), [accountNumber]);

  const accountsPremises = useC360Query<AccountPremiseRow>("customer_accounts_premises", params);
  const meters = useC360Query<MeterHistoryRow>("customer_meter_history", params);
  const rates = useC360Query<RateHistoryRow>("customer_rate_history", params);
  const changes = useC360Query<ProfileChangeRow>("customer_profile_changes", params);
  const locations = useC360Query<CustomerLocationRow>("customer_locations", params);

  const accountGroups = useMemo(() => {
    const byAccount = new Map<string, AccountPremiseRow[]>();
    for (const r of rows(accountsPremises.data)) {
      const list = byAccount.get(r.account_number) || [];
      list.push(r);
      byAccount.set(r.account_number, list);
    }
    return Array.from(byAccount.entries());
  }, [accountsPremises.data]);

  const metersByPremise = useMemo(() => {
    const byPremise = new Map<string, MeterHistoryRow[]>();
    for (const r of rows(meters.data)) {
      const key = r.service_address || String(r.premise_id);
      const list = byPremise.get(key) || [];
      list.push(r);
      byPremise.set(key, list);
    }
    return Array.from(byPremise.entries());
  }, [meters.data]);

  const locationPoints = rows(locations.data).map((l) => ({ lat: Number(l.latitude), lon: Number(l.longitude) }));

  return (
    <>
      <div className="card">
        <div className="card-toolbar">
          <h2>Accounts &amp; Tenancies ({accountGroups.length})</h2>
          <button
            type="button"
            className="sel-action primary"
            style={{ flex: "0 0 auto" }}
            disabled={locationPoints.length === 0}
            onClick={() => onShowAllLocations(locationPoints)}
          >
            Show all premises ({locationPoints.length})
          </button>
        </div>
        <div className="subtle" style={{ marginBottom: 8 }}>
          Every account this customer holds, and every premise it has ever been
          linked to — current AND closed tenancies (unlike the header's
          current-only view). Chain customers show N site accounts under a
          consolidated corporate bill.
        </div>
        {accountsPremises.loading && <div className="loading">Loading…</div>}
        {!accountsPremises.loading && accountGroups.length === 0 && (
          <div className="empty-state">No accounts on file.</div>
        )}
        {accountGroups.map(([acctNum, rows]) => {
          const head = rows[0];
          const tenancies = rows.filter((r) => r.account_premise_link_id != null);
          return (
            <div key={acctNum} style={{ marginBottom: 14 }}>
              <div className="subtle" style={{ marginBottom: 4 }}>
                <strong>{acctNum}</strong> — {head.account_group.replace(/_/g, " ")}
                {head.parent_account_number ? (
                  <span title={head.parent_account_number}> · parent {shortId(head.parent_account_number)}</span>
                ) : ""}
                {" · "}{head.rate_display_name || "—"}{" "}
                <span className={`badge ${head.account_status === "active" ? "good" : "neutral"}`}>{head.account_status}</span>
              </div>
              {tenancies.length > 0 ? (
                <table>
                  <thead>
                    <tr>
                      <th>Address</th><th>Move in</th><th>Move out</th><th>Tenancy</th><th>Status</th><th>Termination reason</th>
                    </tr>
                  </thead>
                  <tbody>
                    {tenancies.map((r) => (
                      <tr key={r.account_premise_link_id}>
                        <td>{r.service_address}{r.service_city ? `, ${r.service_city}` : ""}</td>
                        <td>{fmtDate(r.link_start_date)}</td>
                        <td>{fmtDate(r.link_end_date)}</td>
                        <td>{(r.tenancy_type || "—").replace(/_/g, " ")}</td>
                        <td><span className={`badge ${bool(r.is_current) ? "good" : "neutral"}`}>{bool(r.is_current) ? "current" : "closed"}</span></td>
                        <td>{(r.link_termination_reason || "—").replace(/_/g, " ")}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              ) : (
                <div className="subtle">No premise link — consolidated corporate bill.</div>
              )}
            </div>
          );
        })}
      </div>

      <div className="card">
        <h2>Meter Installation History ({rows(meters.data).length})</h2>
        {meters.loading && <div className="loading">Loading…</div>}
        {!meters.loading && metersByPremise.length === 0 && (
          <div className="empty-state">No meter installs on file.</div>
        )}
        {metersByPremise.map(([address, rows]) => (
          <div key={address} style={{ marginBottom: 10 }}>
            <div className="subtle" style={{ marginBottom: 4 }}><strong>{address}</strong></div>
            <table>
              <thead>
                <tr><th>Meter</th><th>Installed</th><th>Removed</th><th>Reason</th><th>Status</th></tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.meter_number}>
                    <td>{r.meter_number.slice(0, 12)}…</td>
                    <td>{fmtDate(r.installation_date)}</td>
                    <td>{fmtDate(r.removal_date)}</td>
                    <td>{(r.removal_reason_code || "—").replace(/_/g, " ")}</td>
                    <td><span className={`badge ${bool(r.is_current) ? "good" : "neutral"}`}>{bool(r.is_current) ? "current" : "removed"}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ))}
      </div>

      <div className="card">
        <h2>Rate History ({rows(rates.data).length})</h2>
        {rates.loading && <div className="loading">Loading…</div>}
        {!rates.loading && rows(rates.data).length === 0 && (
          <div className="empty-state">No service agreements on file.</div>
        )}
        {rows(rates.data).length > 0 && (
          <table>
            <thead>
              <tr><th>Account</th><th>Rate</th><th>Effective</th><th>Terminated</th><th>Status</th><th>Reason</th></tr>
            </thead>
            <tbody>
              {rows(rates.data).map((r) => (
                <tr key={`${r.account_number}-${r.agreement_seq}`}>
                  <td>{r.account_number}</td>
                  <td>{r.rate_display_name || r.rate_schedule}</td>
                  <td>{fmtDate(r.effective_date)}</td>
                  <td>{fmtDate(r.termination_date)}</td>
                  <td><span className={`badge ${bool(r.is_current) ? "good" : "neutral"}`}>{bool(r.is_current) ? "current" : "terminated"}</span></td>
                  <td>{(r.termination_reason || "—").replace(/_/g, " ")}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card">
        <h2>Profile Changes ({rows(changes.data).length})</h2>
        <div className="subtle" style={{ marginBottom: 8 }}>
          Tracked attribute transitions from the SCD Type 2 history tables —
          critical-care registration and account status changes.
        </div>
        {changes.loading && <div className="loading">Loading…</div>}
        {!changes.loading && rows(changes.data).length === 0 && (
          <div className="empty-state">No tracked changes on file.</div>
        )}
        {rows(changes.data).length > 0 && (
          <ul className="theme-list">
            {rows(changes.data).map((c, idx) => (
              <li key={idx}>
                <span className="theme-name">
                  {c.change_label}{c.account_number ? <span title={c.account_number}> — {shortId(c.account_number)}</span> : ""}
                </span>
                <span className="theme-count">{fmtDate(c.effective_from)}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </>
  );
}

// ────────────────────────────────────────────────────────────────────
// Header strip
// ────────────────────────────────────────────────────────────────────

// Customer-grain header. The title identifies the CUSTOMER, not a premise:
// commercial parties lead with their org name; residential (no name in this
// dataset) falls back to the in-focus site address, explicitly framed as one
// of N locations so a multi-site customer never reads as "the customer = this
// one address". Building / usage / peer facts are site-grained and live on the
// site-scoped cards below (and the Premise profile a pivot away) — never here.
function HeaderStrip({ c }: { c: HeaderRow }) {
  const nPremises = num(c.current_premises) ?? 0;
  const nAccounts = num(c.current_accounts) ?? 0;
  const multiSite = nPremises > 1 || nAccounts > 1;
  const hasName = !!(c.customer_name && c.customer_name.trim());
  const title = hasName ? c.customer_name : c.service_address;
  return (
    <div className="header-strip">
      <div>
        <div className="cell-drill-eyebrow">
          Customer{nPremises > 1 ? ` · 1 of ${nPremises.toLocaleString()} locations` : ""}
        </div>
        <h1>{hasName ? "🏢" : "📍"} {title}</h1>
        <div className="subtle">
          {c.customer_class} · Customer #{shortId(c.customer_number)} · since {fmtDate(c.tenant_since || c.customer_since_date)}
        </div>
        <div className="subtle">
          {localityText({ city: c.service_city, county: c.county, state: c.service_state })}
        </div>
        {multiSite && (
          <div className="subtle" style={{ marginTop: 6 }}>
            {nPremises.toLocaleString()} service location{nPremises === 1 ? "" : "s"} · {nAccounts.toLocaleString()} account{nAccounts === 1 ? "" : "s"}
          </div>
        )}
      </div>
      <div className="kpi">
        <div className="label">Rate</div>
        <div className="value">{c.rate_display_name}</div>
        <div className="label" style={{ marginTop: 8 }}>Status</div>
        <div className="value">{c.account_status} • {c.account_tenure_band}</div>
        <div className="label" style={{ marginTop: 8 }}>Channel</div>
        <div className="value">{c.preferred_channel}</div>
      </div>
      <div className="kpi">
        <div className="label">Digital adoption</div>
        <div className="value">{c.digital_adoption_score}/100</div>
        <div className="label" style={{ marginTop: 8 }}>Outage exposure (90d)</div>
        <div className="value">{c.recent_outage_events_90d} events / {c.recent_outage_minutes_90d} min</div>
        <div className="label" style={{ marginTop: 8 }}>Complaints (90d)</div>
        <div className="value">{c.recent_complaint_count_90d}</div>
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Bill chart
// ────────────────────────────────────────────────────────────────────

function BillChart({
  rows, loading,
}: { rows: BillRow[]; loading: boolean }) {
  const data = rows.map((r) => ({
    month:  r.bill_period_end.slice(0, 7),
    kwh:    r.total_kwh,
    peer:   num(r.peer_p75_kwh),
    bill:   r.current_charges,
    shock:  r.bill_shock_pct,
    status: r.payment_status,
  }));

  return (
    <div className="card">
      <h2>24-Month Usage vs Peer Benchmark</h2>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length > 0 && (
        <>
          <div style={{ width: "100%", height: 260 }}>
            <ResponsiveContainer>
              <ComposedChart data={data} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="month" tick={{ fontSize: 10 }} />
                <YAxis tick={{ fontSize: 10 }} />
                <Tooltip cursor={{ fill: "var(--panel-2)" }} />
                <Legend wrapperStyle={{ fontSize: 11, paddingTop: 4 }} />
                <Bar
                  name="This customer (kWh)"
                  dataKey="kwh"
                  fill="var(--chart-1)"
                />
                <Line
                  name="Peer p75 — same building type & sqft band"
                  type="monotone"
                  dataKey="peer"
                  stroke="var(--accent)"
                  strokeWidth={2}
                  dot={{ r: 2, fill: "var(--accent)" }}
                />
              </ComposedChart>
            </ResponsiveContainer>
          </div>
          <table style={{ marginTop: 12 }}>
            <thead>
              <tr>
                <th>Month</th><th>kWh</th><th>Bill</th><th>YoY</th><th>Shock</th><th>Status</th>
              </tr>
            </thead>
            <tbody>
              {rows.slice(-6).reverse().map((r) => (
                <tr key={r.bill_id}>
                  <td>{r.bill_period_end.slice(0, 7)}</td>
                  <td>{fmtKwh(r.total_kwh)}</td>
                  <td>{fmtUSD(r.current_charges)}</td>
                  <td>{fmtPct(r.yoy_kwh_change_pct)}</td>
                  <td>{fmtPct(r.bill_shock_pct)}</td>
                  <td><span className={`badge ${statusBadgeClass(r.payment_status)}`}>{r.payment_status}</span></td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Load profile (hourly shape for a chosen month + day type)
// ────────────────────────────────────────────────────────────────────

function LoadProfileCard({
  accountNumber, bills,
}: { accountNumber: string; bills: BillRow[] }) {
  // Months come from the bills table so the dropdown only offers months
  // we actually have data for. Default to the most-recent bill month.
  const months = useMemo(() => {
    const set = new Set(bills.map((b) => b.bill_period_end.slice(0, 7)));
    return Array.from(set).sort();
  }, [bills]);

  const [month, setMonth] = useState<string>("");
  const [dayType, setDayType] = useState<"weekday" | "weekend">("weekday");

  useEffect(() => {
    if (!month && months.length > 0) setMonth(months[months.length - 1]);
  }, [months, month]);

  const params = useMemo(
    () => ({
      account_number: sql.string(accountNumber),
      year_month: sql.string(month || ""),
      day_type: sql.string(dayType),
    }),
    [accountNumber, month, dayType],
  );

  const profile = useC360Query<LoadProfileRow>("customer_load_profile", params);

  return (
    <div className="card">
      <div className="card-toolbar">
        <h2>Hourly Load Profile</h2>
        <div style={{ display: "flex", gap: 8 }}>
          <select value={month} onChange={(e) => setMonth(e.target.value)}>
            {months.map((m) => <option key={m} value={m}>{m}</option>)}
          </select>
          <select value={dayType} onChange={(e) => setDayType(e.target.value as "weekday" | "weekend")}>
            <option value="weekday">Weekday avg</option>
            <option value="weekend">Weekend avg</option>
          </select>
        </div>
      </div>
      {profile.loading && <div className="loading">Loading…</div>}
      {profile.error && <div className="error">{String(profile.error)}</div>}
      {!profile.loading && rows(profile.data).length > 0 && (
        <div style={{ width: "100%", height: 220 }}>
          <ResponsiveContainer>
            <LineChart data={rows(profile.data)}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="hour_of_day" tick={{ fontSize: 10 }}
                     tickFormatter={(h) => `${h}:00`} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip cursor={{ fill: "var(--panel-2)" }} />
              <Line type="monotone" dataKey="avg_kwh" stroke="var(--chart-1)" strokeWidth={2} dot={false} name="avg kWh" />
              <Line type="monotone" dataKey="p90_kwh" stroke="var(--chart-2)" strokeWidth={1} strokeDasharray="3 3" dot={false} name="p90" />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}
      {!profile.loading && rows(profile.data).length === 0 && (
        <div className="empty-state">No hourly readings for this period.</div>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Complaints
// ────────────────────────────────────────────────────────────────────

function ComplaintCard({
  rows, loading,
}: { rows: ComplaintRow[]; loading: boolean }) {
  return (
    <div className="card">
      <h2>Recent Complaints ({rows.length})</h2>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No complaints on file.</div>}
      {rows.map((r) => (
        <div className="complaint-card" key={r.complaint_id}>
          <div className="meta">
            <span>{fmtDate(r.complaint_date)}</span>
            <span>•</span>
            <span>{r.channel}</span>
            <span>•</span>
            <span>{r.category} / {r.sub_category}</span>
            <span><span className={`badge ${severityBadgeClass(r.severity)}`}>{r.severity}</span></span>
            <span><span className={`badge ${r.sentiment_label === "very_negative" ? "alert" : "warn"}`}>{r.sentiment_label}</span></span>
            <span><span className={`badge ${r.resolution_status === "resolved" ? "good" : r.resolution_status === "escalated" ? "alert" : "neutral"}`}>{r.resolution_status}</span></span>
            {r.verbatim_language === "es" && <span><span className="badge info">ES</span></span>}
          </div>
          <div className="verbatim">"{r.verbatim_text}"</div>
        </div>
      ))}
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Outages
// ────────────────────────────────────────────────────────────────────

function OutageCard({
  rows, loading,
}: { rows: OutageRow[]; loading: boolean }) {
  return (
    <div className="card">
      <h2>Outage History ({rows.length})</h2>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No outages recorded.</div>}
      {rows.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Date</th>
              <th>Duration</th>
              <th>Cause</th>
              <th>Weather</th>
              <th>Tags</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const hrs = Math.floor(r.minutes_out / 60);
              const mins = r.minutes_out % 60;
              const dur = hrs > 0 ? `${hrs}h ${mins}m` : `${mins}m`;
              return (
                <tr key={r.impact_id}>
                  <td>{fmtDate(r.affected_start)}</td>
                  <td>{dur}</td>
                  <td>{r.cause_code.replace(/_/g, " ")}</td>
                  <td>{r.weather_category.replace(/_/g, " ")}</td>
                  <td style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                    {bool(r.is_major_event_day) && (
                      <span className="badge warn" title="Major Event Day — excluded from standard reliability metrics">
                        Major event
                      </span>
                    )}
                    {bool(r.priority_restoration_flag) && (
                      <span className="badge info" title="Priority restoration: this customer's premise was prioritized (e.g. critical-care medical, hospital)">
                        Priority restored
                      </span>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}

