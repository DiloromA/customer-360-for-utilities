import { useEffect, useMemo, useState } from "react";
import { useAnalyticsQuery } from "@databricks/appkit-ui/react";
import { sql } from "@databricks/appkit-ui/js";
import {
  Bar,
  Line,
  LineChart,
  ComposedChart,
  Legend,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  CartesianGrid,
} from "recharts";
import { localityText } from "./filters";

// ────────────────────────────────────────────────────────────────────
// The map's atom is the premise (a physical
// service location), not the customer — a dot-click should open a Premise
// inspector by default, with the current occupant one pivot away. This
// file owns everything net-new for that subject type: the shared subject
// union, the pivot-chip breadcrumb, the compact rail card (parallels
// ExplorerMap.tsx's CustomerDrillPanel), and the full drawer view
// (parallels App.tsx's CustomerDetail). See docs/entity-grain-design.md §6.
//
// The third pivot, Owner (bridge_premise_owner), lives in OwnerInspector.tsx.
// ────────────────────────────────────────────────────────────────────

export type InspectorSubject =
  | { kind: "customer"; accountNumber: string }
  | { kind: "premise"; premiseNumber: string }
  | { kind: "owner"; ownerNumber: string };

// ── formatting helpers ──────────────────────────────────────────────
// Small local copies rather than importing from App.tsx/ExplorerMap.tsx —
// matches the existing convention (ExplorerMap.tsx already keeps its own
// copies rather than sharing with App.tsx) and avoids a circular import
// (App.tsx imports this file).

// md5 natural keys (32 hex chars) are pivot affordances, not labels — show
// a short scannable form and put the full id in a tooltip.
export function shortId(s: string): string {
  return s.length > 12 ? `${s.slice(0, 4)}…${s.slice(-4)}` : s;
}
function num(n: number | string | null | undefined): number | null {
  if (n == null || n === "") return null;
  const v = typeof n === "string" ? Number(n) : n;
  return Number.isFinite(v) ? v : null;
}
// Databricks SQL returns BOOLEAN columns as the literal strings "true"/
// "false" over JSON — bare truthy checks are always true. Route every
// BOOLEAN-typed column through this first.
function bool(b: boolean | string | null | undefined): boolean {
  return b === true || b === "true";
}
function fmtNum(n: number | string | null | undefined): string {
  const v = num(n);
  return v == null ? "—" : Math.round(v).toLocaleString();
}
function fmtKwh(n: number | string | null | undefined): string {
  const v = num(n);
  return v == null ? "—" : `${Math.round(v).toLocaleString()} kWh`;
}
function fmtDate(s: string | null | undefined): string {
  if (!s) return "—";
  return new Date(s).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

// ── query row shapes ────────────────────────────────────────────────

interface PremiseHeaderRow {
  premise_number: string;
  occupancy_class: string;
  primary_occupancy: string;
  building_subtype: string;
  sqft: number;
  year_built: number;
  heating_fuel: string;
  envelope_quality: string;
  hvac_system_type: string;
  county: string;
  climate_zone: string;
  service_address: string;
  service_city: string;
  service_state: string;
  service_zip: string;
  occupant_account_number: string | null;
  occupant_customer_number: string | null;
  occupant_customer_class: string | null;
  tenant_since: string | null;
  previous_occupant_until: string | null;
  previous_occupant_count: number;
  pv_probability_pct: number | null;
  pv_likely_flag: boolean | string | null;
  pv_on_record: boolean | string | null;
  pv_on_record_elsewhere: boolean | string | null;
  owner_number: string | null;
  owner_display_name: string | null;
}

interface PremiseTimelineRow {
  service_event_id: number;
  event_type: string;
  event_date: string;
  detail: string | null;
  account_id: number | null;
  meter_id: number | null;
  service_agreement_id: number | null;
  is_current_account: boolean | string;
}

interface PremiseOutageRow {
  impact_id: string;
  outage_id: string;
  affected_start: string;
  affected_end: string;
  minutes_out: number;
  priority_restoration_flag: boolean | string;
  cause_code: string;
  weather_category: string;
  is_major_event_day: boolean | string;
  duration_bucket: string;
  circuit_affected_count: number;
}

interface PremiseDerRow {
  device_type: string;
  device_subtype: string | null;
  system_size_kwh_or_dc: number | null;
  install_date: string | null;
}

interface PremiseBillRow {
  bill_id: string;
  bill_period_end: string;
  total_kwh: number;
  current_charges: number;
  payment_status: string;
  bill_shock_pct: number | null;
  yoy_kwh_change_pct: number | null;
  peer_avg_kwh: number | null;
  peer_p75_kwh: number | null;
}

interface PremiseLoadProfileRow {
  hour_of_day: number;
  avg_kwh: number;
  median_kwh: number;
  p90_kwh: number;
  n_days: number;
}

// ────────────────────────────────────────────────────────────────────
// Pivot chips — the [ 📍 Premise ▸ 👤 Occupant ] breadcrumb shared by
// the rail card and the full drawer. Two independent axes stay separate
// per entity-grain §6.1: this is "which entity", tabs are "which facet".
// ────────────────────────────────────────────────────────────────────

export function PivotChips({
  subject, locationLabel, premiseNumber, occupantAccountNumber, ownerNumber, ownerDisplayName, onPivot,
}: {
  subject: InspectorSubject;
  // The premise's address, when known — label for the Premise chip.
  locationLabel?: string | null;
  // The premise to pivot to from a customer subject (this account's site).
  premiseNumber?: string | null;
  // The current occupant to pivot to from a premise subject; null/undefined
  // when the premise is vacant.
  occupantAccountNumber?: string | null;
  // The owner-of-record to pivot to from a premise subject
  // (bridge_premise_owner); null/undefined when no ownership edge is on file.
  // Only reachable from a premise subject — the owner is a portfolio (many
  // premises), so there's no single Location/Occupant to pivot back to from
  // it via this breadcrumb; use the portfolio roster instead.
  ownerNumber?: string | null;
  ownerDisplayName?: string | null;
  onPivot: (s: InspectorSubject) => void;
}) {
  const isOwner = subject.kind === "owner";
  const canGoLocation = subject.kind === "customer" ? premiseNumber != null : subject.kind === "premise";
  const canGoOccupant = subject.kind === "premise" ? !!occupantAccountNumber : subject.kind === "customer";
  const canGoOwner = subject.kind === "premise" ? !!ownerNumber : isOwner;
  return (
    <div className="pivot-chips">
      <button
        type="button"
        className={`pivot-chip ${subject.kind === "premise" ? "active" : ""}`}
        disabled={!canGoLocation}
        onClick={() => {
          if (subject.kind === "premise") return;
          if (premiseNumber != null) onPivot({ kind: "premise", premiseNumber });
        }}
        title={locationLabel || "Premise"}
      >
        📍 {subject.kind === "premise" ? (locationLabel || "Premise") : "Premise"}
      </button>
      <span className="pivot-sep">▸</span>
      <button
        type="button"
        className={`pivot-chip ${subject.kind === "customer" ? "active" : ""}`}
        disabled={!canGoOccupant}
        onClick={() => {
          if (subject.kind === "customer") return;
          if (occupantAccountNumber) onPivot({ kind: "customer", accountNumber: occupantAccountNumber });
        }}
        title={subject.kind === "customer" ? subject.accountNumber : occupantAccountNumber || undefined}
      >
        👤 {subject.kind === "customer"
          ? `Occupant · ${shortId(subject.accountNumber)}`
          : occupantAccountNumber
            ? `Occupant · ${shortId(occupantAccountNumber)}`
            : "Vacant"}
      </button>
      <span className="pivot-sep">▸</span>
      <button
        type="button"
        className={`pivot-chip ${isOwner ? "active" : ""}`}
        disabled={!canGoOwner}
        onClick={() => {
          if (isOwner) return;
          if (ownerNumber) onPivot({ kind: "owner", ownerNumber });
        }}
        title={ownerDisplayName || (isOwner ? subject.ownerNumber : ownerNumber) || undefined}
      >
        🏢 {isOwner
          ? (ownerDisplayName || `Owner · ${shortId(subject.ownerNumber)}`)
          : ownerNumber
            ? (ownerDisplayName || `Owner · ${shortId(ownerNumber)}`)
            // "No owner on file" is only accurate once premise_header.sql has
            // actually looked it up; from a customer subject we simply haven't
            // (no customer->owner edge — reach it via the premise pivot).
            : subject.kind === "premise" ? "No owner on file" : "Owner"}
      </button>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Shared "what matters" alert derivation — building status + PV
// detection, in the same tone/badge vocabulary CustomerDrillPanel and
// AlertsBanner already use.
// ────────────────────────────────────────────────────────────────────

function premiseAlerts(p: PremiseHeaderRow): { tone: string; text: string; detail?: string }[] {
  const alerts: { tone: string; text: string; detail?: string }[] = [];
  if (!p.occupant_account_number) {
    alerts.push({ tone: "neutral", text: "Currently vacant" });
  }
  // PV is physically a premise attribute (the roof it's bolted to), so the
  // detection badge lives here rather than on the Customer inspector now
  // that the Premise inspector exists — see customer_header.sql's history.
  // The detection signal itself is customer-grain (features sum ALL of the
  // occupant's service points), so a multi-site occupant whose PV is
  // registered at their OTHER premise gets no badge here — asserting
  // anything about THIS roof from that signal would be a guess.
  if (bool(p.pv_likely_flag) && bool(p.pv_on_record)) {
    alerts.push({
      tone: "info",
      text: "Detected PV (confirmed)",
      detail: `Consumption pattern is consistent with rooftop solar (${p.pv_probability_pct}% predicted), matching the interconnection record on file.`,
    });
  } else if (bool(p.pv_likely_flag) && !bool(p.pv_on_record) && !bool(p.pv_on_record_elsewhere)) {
    alerts.push({
      tone: "warn",
      text: `Likely unregistered PV (${p.pv_probability_pct}%)`,
      detail: "Consumption pattern (suppressed midday load) is consistent with rooftop solar, but no interconnection record is on file. Possible unregistered self-install — recommend a site check.",
    });
  }
  return alerts;
}

// ────────────────────────────────────────────────────────────────────
// Compact rail card — parallels ExplorerMap.tsx's CustomerDrillPanel.
// ────────────────────────────────────────────────────────────────────

export function PremiseDrillCard({
  premiseNumber, onClose, onOpenFull, onPivot, backToGroup = false,
}: {
  premiseNumber: string;
  onClose: () => void;
  onOpenFull: (subject: InspectorSubject) => void;
  onPivot: (subject: InspectorSubject) => void;
  backToGroup?: boolean;
}) {
  const closeBtn = backToGroup
    ? <button className="cell-back" onClick={onClose} title="Back to the group">← Group</button>
    : <button className="cell-close" onClick={onClose}>×</button>;

  const params = useMemo(() => ({ premise_number: sql.string(premiseNumber) }), [premiseNumber]);
  const header = useAnalyticsQuery<PremiseHeaderRow>("premise_header", params);
  const timeline = useAnalyticsQuery<PremiseTimelineRow>("premise_timeline", params);
  const outages = useAnalyticsQuery<PremiseOutageRow>("premise_outages", params);
  const der = useAnalyticsQuery<PremiseDerRow>("premise_der", params);

  if (header.loading || (header.data || []).length === 0) {
    return (
      <aside className="cell-drill">
        <div className="cell-drill-header">
          <h3>{header.loading ? "Loading premise…" : "Premise not found"}</h3>
          {closeBtn}
        </div>
      </aside>
    );
  }

  const p = (header.data as PremiseHeaderRow[])[0];
  const tl = (timeline.data || []) as PremiseTimelineRow[];
  const out = (outages.data || []) as PremiseOutageRow[];
  const derList = (der.data || []) as PremiseDerRow[];
  const alerts = premiseAlerts(p);

  return (
    <aside className="cell-drill">
      <div className="cell-drill-header">
        <div>
          <div className="cell-drill-eyebrow">Premise drill-down</div>
          <h3>{p.service_address}</h3>
          <div className="subtle">
            {localityText({ city: p.service_city, county: p.county, state: p.service_state })}
          </div>
          <div className="subtle">
            {(p.building_subtype || "").replace(/_/g, " ")} · {fmtNum(p.sqft)} sqft · built {p.year_built || "—"}
          </div>
        </div>
        {closeBtn}
      </div>

      <PivotChips
        subject={{ kind: "premise", premiseNumber }}
        locationLabel={p.service_address}
        occupantAccountNumber={p.occupant_account_number}
        ownerNumber={p.owner_number}
        ownerDisplayName={p.owner_display_name}
        onPivot={onPivot}
      />

      {alerts.length > 0 && (
        <div className="drill-flags">
          {alerts.map((a, i) => <span key={i} className={`badge ${a.tone}`} title={a.detail}>{a.text}</span>)}
        </div>
      )}

      <div className="card cell-drill-section">
        <h4>Building</h4>
        <div className="delta-grid">
          <div className="delta-row">
            <div className="delta-label">Envelope</div>
            <div className="delta-value">{(p.envelope_quality || "—").replace(/_/g, " ")}</div>
            <div className="delta-comp tone-neutral">{(p.heating_fuel || "—").replace(/_/g, " ")} heat</div>
          </div>
          <div className="delta-row">
            <div className="delta-label">Occupant since</div>
            <div className="delta-value">{fmtDate(p.tenant_since)}</div>
            <div className="delta-comp tone-neutral">{p.occupant_customer_class ? `${p.occupant_customer_class.toLowerCase()} occupant` : "vacant"}</div>
          </div>
          {p.previous_occupant_count > 0 && (
            <div className="delta-row">
              <div className="delta-label">Prior tenancies</div>
              <div className="delta-value">{p.previous_occupant_count}</div>
              <div className="delta-comp tone-neutral">until {fmtDate(p.previous_occupant_until)}</div>
            </div>
          )}
        </div>
      </div>

      <div className="card cell-drill-section">
        <h4>Occupant timeline ({tl.length})</h4>
        {timeline.loading ? (
          <div className="loading">Loading…</div>
        ) : tl.length === 0 ? (
          <div className="subtle">No service events on file.</div>
        ) : (
          <ul className="theme-list">
            {tl.slice(0, 6).map((r) => (
              <li key={r.service_event_id}>
                <span className="theme-name">
                  {r.event_type.replace(/_/g, " ")}{r.detail ? ` — ${r.detail}` : ""}
                  {!bool(r.is_current_account) && <span className="badge neutral" style={{ marginLeft: 6 }}>previous occupant</span>}
                </span>
                <span className="theme-count">{fmtDate(r.event_date)}</span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="card cell-drill-section">
        <h4>Outage history ({out.length})</h4>
        {outages.loading ? (
          <div className="loading">Loading…</div>
        ) : out.length === 0 ? (
          <div className="subtle">No outages recorded.</div>
        ) : (
          <ul className="theme-list">
            {out.slice(0, 8).map((r) => {
              const mins = num(r.minutes_out) ?? 0;
              const h = Math.floor(mins / 60), m = mins % 60;
              return (
                <li key={r.impact_id}>
                  <span className="theme-name">{fmtDate(r.affected_start)} · {(r.cause_code || "").replace(/_/g, " ")}</span>
                  <span className="theme-count">{h > 0 ? `${h}h ${m}m` : `${m}m`}</span>
                </li>
              );
            })}
          </ul>
        )}
      </div>

      <div className="card cell-drill-section">
        <h4>DER installed ({derList.length})</h4>
        {der.loading ? (
          <div className="loading">Loading…</div>
        ) : derList.length === 0 ? (
          <div className="subtle">No detected devices on file.</div>
        ) : (
          <ul className="theme-list">
            {derList.map((d, i) => (
              <li key={i}>
                <span className="theme-name">{d.device_type}{d.device_subtype ? ` (${d.device_subtype})` : ""}</span>
                <span className="theme-count">{fmtDate(d.install_date)}</span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="selection-actions">
        <button className="sel-action primary" onClick={() => onOpenFull({ kind: "premise", premiseNumber })}>
          Expand full profile →
        </button>
      </div>
    </aside>
  );
}

// ────────────────────────────────────────────────────────────────────
// Full drawer view — parallels App.tsx's CustomerDetail.
// ────────────────────────────────────────────────────────────────────

function PremiseHeaderStrip({ p }: { p: PremiseHeaderRow }) {
  return (
    <div className="header-strip">
      <div>
        <h1>{p.service_address}</h1>
        <div className="subtle">
          {localityText({ city: p.service_city, county: p.county, state: p.service_state })}
        </div>
        <div className="subtle">
          {(p.building_subtype || "").replace(/_/g, " ")} • {fmtNum(p.sqft)} sqft • built {p.year_built || "—"} • {(p.heating_fuel || "—").replace(/_/g, " ")} heat
        </div>
        <div className="subtle" style={{ marginTop: 6 }}>
          {p.occupant_account_number
            ? <>Occupant since {fmtDate(p.tenant_since)}{p.occupant_customer_class ? ` • ${p.occupant_customer_class.toLowerCase()}` : ""}</>
            : "Currently vacant"}
        </div>
        {p.previous_occupant_count > 0 && p.previous_occupant_until && (
          <div className="subtle" style={{ marginTop: 2 }}>
            Previous occupant until {fmtDate(p.previous_occupant_until)}
            {p.previous_occupant_count > 1 ? ` (${p.previous_occupant_count} prior tenancies)` : ""}
          </div>
        )}
      </div>
      <div className="kpi">
        <div className="label">Envelope</div>
        <div className="value">{(p.envelope_quality || "—").replace(/_/g, " ")}</div>
        <div className="label" style={{ marginTop: 8 }}>HVAC</div>
        <div className="value">{(p.hvac_system_type || "—").replace(/_/g, " ")}</div>
        <div className="label" style={{ marginTop: 8 }}>Climate zone</div>
        <div className="value">{p.climate_zone || "—"}</div>
      </div>
    </div>
  );
}

function PremiseAlertsBanner({ p }: { p: PremiseHeaderRow }) {
  const alerts = premiseAlerts(p);
  if (alerts.length === 0) {
    return (
      <div className="alerts-banner ok">
        <span className="badge good">No active issues</span>
        <span className="alerts-detail">Occupied, no unregistered DER detected.</span>
      </div>
    );
  }
  const worst = alerts.some((a) => a.tone === "alert") ? "alert" : alerts.some((a) => a.tone === "warn") ? "warn" : "info";
  return (
    <div className={`alerts-banner ${worst}`}>
      <div className="alerts-title">Next actions &amp; insights</div>
      <div className="alerts-grid">
        {alerts.map((a, i) => (
          <div key={i} className={`alert-tile tone-${a.tone}`}>
            <div className="alert-tile-text">{a.text}</div>
            <div className="alert-tile-detail">{a.detail || ""}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

function PremiseUsageChart({ rows, loading }: { rows: PremiseBillRow[]; loading: boolean }) {
  const data = rows.map((r) => ({
    month: r.bill_period_end.slice(0, 7),
    kwh: r.total_kwh,
    peer: num(r.peer_p75_kwh),
  }));
  return (
    <div className="card">
      <h2>24-Month Usage vs Peer Benchmark</h2>
      <div className="subtle" style={{ marginBottom: 8 }}>
        Billed usage at this address — spans occupants, since load is a
        property of the physical service point.
      </div>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No billing history for this premise.</div>}
      {!loading && rows.length > 0 && (
        <div style={{ width: "100%", height: 240 }}>
          <ResponsiveContainer>
            <ComposedChart data={data} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="month" tick={{ fontSize: 10 }} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip cursor={{ fill: "var(--panel-2)" }} />
              <Legend wrapperStyle={{ fontSize: 11, paddingTop: 4 }} />
              <Bar name="This premise (kWh)" dataKey="kwh" fill="var(--chart-1)" />
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
      )}
    </div>
  );
}

function PremiseLoadProfileCard({
  premiseNumber, bills,
}: { premiseNumber: string; bills: PremiseBillRow[] }) {
  // Months come from the bills table so the dropdown only offers months we
  // actually have data for. Default to the most-recent bill month.
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
      premise_number: sql.string(premiseNumber),
      year_month: sql.string(month || ""),
      day_type: sql.string(dayType),
    }),
    [premiseNumber, month, dayType],
  );

  const profile = useAnalyticsQuery<PremiseLoadProfileRow>("premise_load_profile", params);

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
      {!profile.loading && (profile.data || []).length > 0 && (
        <div style={{ width: "100%", height: 220 }}>
          <ResponsiveContainer>
            <LineChart data={profile.data || []}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="hour_of_day" tick={{ fontSize: 10 }} tickFormatter={(h) => `${h}:00`} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip cursor={{ fill: "var(--panel-2)" }} />
              <Line type="monotone" dataKey="avg_kwh" stroke="var(--chart-1)" strokeWidth={2} dot={false} name="avg kWh" />
              <Line type="monotone" dataKey="p90_kwh" stroke="var(--chart-2)" strokeWidth={1} strokeDasharray="3 3" dot={false} name="p90" />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}
      {!profile.loading && (profile.data || []).length === 0 && (
        <div className="empty-state">No hourly readings for this period.</div>
      )}
    </div>
  );
}

function PremiseTimelineCard({ rows, loading }: { rows: PremiseTimelineRow[]; loading: boolean }) {
  return (
    <div className="card">
      <h2>Occupant Timeline ({rows.length})</h2>
      <div className="subtle" style={{ marginBottom: 8 }}>
        Move-in / move-out, rate switches, and meter swaps at this address —
        including prior occupants, since this view is keyed to the premise.
      </div>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No service events on file.</div>}
      {rows.length > 0 && (
        <ul className="theme-list">
          {rows.map((r) => (
            <li key={r.service_event_id}>
              <span className="theme-name">
                {r.event_type.replace(/_/g, " ")}
                {r.detail ? ` — ${r.detail}` : ""}
                {!bool(r.is_current_account) && <span className="badge neutral" style={{ marginLeft: 6 }}>previous occupant</span>}
              </span>
              <span className="theme-count">{fmtDate(r.event_date)}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function PremiseOutageCard({ rows, loading }: { rows: PremiseOutageRow[]; loading: boolean }) {
  return (
    <div className="card">
      <h2>Outage History ({rows.length})</h2>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No outages recorded.</div>}
      {rows.length > 0 && (
        <table>
          <thead>
            <tr><th>Date</th><th>Duration</th><th>Cause</th><th>Weather</th><th>Tags</th></tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const mins = num(r.minutes_out) ?? 0;
              const h = Math.floor(mins / 60), m = mins % 60;
              return (
                <tr key={r.impact_id}>
                  <td>{fmtDate(r.affected_start)}</td>
                  <td>{h > 0 ? `${h}h ${m}m` : `${m}m`}</td>
                  <td>{(r.cause_code || "—").replace(/_/g, " ")}</td>
                  <td>{(r.weather_category || "—").replace(/_/g, " ")}</td>
                  <td>
                    {bool(r.is_major_event_day) && <span className="badge warn">major event</span>}
                    {bool(r.priority_restoration_flag) && <span className="badge info" style={{ marginLeft: 4 }}>priority</span>}
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

function PremiseDerCard({ rows, loading }: { rows: PremiseDerRow[]; loading: boolean }) {
  return (
    <div className="card">
      <h2>DER Installed ({rows.length})</h2>
      <div className="subtle" style={{ marginBottom: 8 }}>
        Devices physically detected at this address — persists across
        occupants, unlike a customer's EV (which moves with them).
      </div>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No detected devices on file.</div>}
      {rows.length > 0 && (
        <ul className="theme-list">
          {rows.map((d, i) => (
            <li key={i}>
              <span className="theme-name">
                {d.device_type}{d.device_subtype ? ` (${d.device_subtype})` : ""}
                {d.system_size_kwh_or_dc ? ` · ${fmtKwh(d.system_size_kwh_or_dc)}` : ""}
              </span>
              <span className="theme-count">{fmtDate(d.install_date)}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function PremiseDetail({
  premiseNumber, onPivot,
}: {
  premiseNumber: string;
  onPivot: (subject: InspectorSubject) => void;
}) {
  const params = useMemo(() => ({ premise_number: sql.string(premiseNumber) }), [premiseNumber]);
  const header = useAnalyticsQuery<PremiseHeaderRow>("premise_header", params);
  const bills = useAnalyticsQuery<PremiseBillRow>("premise_bills", params);
  const timeline = useAnalyticsQuery<PremiseTimelineRow>("premise_timeline", params);
  const outages = useAnalyticsQuery<PremiseOutageRow>("premise_outages", params);
  const der = useAnalyticsQuery<PremiseDerRow>("premise_der", params);

  if (header.loading) return <div className="loading">Loading premise…</div>;
  if (header.error) return <div className="error">{String(header.error)}</div>;
  if (!header.data || header.data.length === 0) return <div className="empty-state">No data</div>;

  const p = header.data[0];

  return (
    <>
      <PremiseHeaderStrip p={p} />
      <PivotChips
        subject={{ kind: "premise", premiseNumber }}
        locationLabel={p.service_address}
        occupantAccountNumber={p.occupant_account_number}
        ownerNumber={p.owner_number}
        ownerDisplayName={p.owner_display_name}
        onPivot={onPivot}
      />
      <PremiseAlertsBanner p={p} />
      <PremiseUsageChart rows={bills.data || []} loading={bills.loading} />
      <PremiseLoadProfileCard premiseNumber={premiseNumber} bills={bills.data || []} />
      <PremiseTimelineCard rows={timeline.data || []} loading={timeline.loading} />
      <PremiseOutageCard rows={outages.data || []} loading={outages.loading} />
      <PremiseDerCard rows={der.data || []} loading={der.loading} />
    </>
  );
}
