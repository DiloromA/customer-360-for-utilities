import { useEffect, useMemo, useState, type CSSProperties } from "react";
import { useC360Query } from "./queryUtils";
import { sql } from "@databricks/appkit-ui/js";
import { rows } from "./queryUtils";
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
// inspector by default, with the current customer one pivot away. This
// file owns everything net-new for that subject type: the shared subject
// union, the pivot-chip breadcrumb, the compact rail card (parallels
// ExplorerMap.tsx's CustomerDrillPanel), and the full drawer view
// (parallels App.tsx's CustomerDetail).
//
// Ownership (bridge_premise_owner) is a relationship line, not a navigation grain.
// ────────────────────────────────────────────────────────────────────

export type InspectorSubject =
  | { kind: "customer"; accountNumber: string }
  // Optional coords let a pivot fly the map straight to the location — a
  // picked second home is often off-screen. Absent → the map falls back to
  // finding the premise among the loaded dots.
  | { kind: "premise"; premiseNumber: string; lat?: number | null; lon?: number | null }
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
  current_account_number: string | null;
  current_customer_number: string | null;
  current_customer_class: string | null;
  tenant_since: string | null;
  previous_customer_until: string | null;
  previous_customer_count: number;
  pv_probability_pct: number | null;
  pv_likely_flag: boolean | string | null;
  pv_on_record: boolean | string | null;
  pv_on_record_elsewhere: boolean | string | null;
  owner_number: string | null;
  owner_display_name: string | null;
  // How the ownership edge is grounded — drives whether/how the owner surfaces:
  //   owner_occupied     → the resident owns their home; suppressed (redundant).
  //   landlord_agreement → a distinct landlord party; shown as a landlord line.
  //   owner_pays         → a commercial chain; routed into the hierarchy line.
  owner_basis: "owner_occupied" | "landlord_agreement" | "owner_pays" | null;
  // Linkage context: how many current premises/accounts the CURRENT customer
  // of this premise holds (null on a vacant premise) — see premise_header.sql.
  customer_current_premises: number | null;
  customer_current_accounts: number | null;
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

interface PremiseComplaintRow {
  complaint_id: string;
  complaint_date: string;
  channel: string;
  category: string;
  sub_category: string | null;
  severity: string;
  sentiment_label: string;
  resolution_status: string;
  resolution_minutes: number | null;
  triggering_bill_amount: number | null;
  trailing_12_avg_bill: number | null;
  bill_shock_pct: number | null;
  outage_minutes_30d: number | null;
  verbatim_language: string | null;
  verbatim_text: string | null;
  driver_bill_id: string | null;
  driver_outage_id: string | null;
  premise_attribution_method: string;
  filer_account_number: string | null;
  filer_customer_number: string | null;
}

interface PremiseServicePointRow {
  service_point_number: string;
  commodity: string;
  phase_code: string | null;
  nominal_service_voltage: number | null;
  current_meter_number: string | null;
  meter_installed_date: string | null;
  installation_status: string | null;
}

interface ServicePointMeterRow {
  meter_number: string;
  installation_date: string | null;
  removal_date: string | null;
  is_current: boolean | string;
  installation_status: string | null;
  removal_reason_code: string | null;
  manufacturer: string | null;
  model_number: string | null;
  communication_protocol: string | null;
  meter_status: string | null;
}

interface PremiseWorkOrderRow {
  work_order_id: string;
  work_type: string;
  status: string;
  priority: string | null;
  created_at: string | null;
  scheduled_at: string | null;
  completed_at: string | null;
  customer_number: string | null;
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
// Hierarchy breadcrumb — the [ 📍 Premise ▸ 👤 Customer ] navigation
// shared by the rail card and the full drawer. Drills downward only;
// ownership is a relationship line on the Premise detail, not a grain.
// ────────────────────────────────────────────────────────────────────

/** One current service location, for the Premise chip's picker. */
export interface PremiseRosterEntry {
  premiseNumber: string;
  address: string | null;
  // Coords so a picked location re-centres the map (see InspectorSubject).
  lat?: number | null;
  lon?: number | null;
}

export function PivotChips({
  subject, locationLabel, premiseNumber, originPremiseNumber = null, currentAccountNumber, premiseRoster, onPivot,
}: {
  subject: InspectorSubject;
  // The premise's address, when known — label for the Premise chip.
  locationLabel?: string | null;
  // The premise to pivot to from a customer subject (this account's site).
  premiseNumber?: string | null;
  // On a customer view, the premise this customer was drilled INTO from. When
  // set, the Premise chip becomes an explicit "back" to exactly that location
  // (address-labeled, ↩ glyph) rather than a lateral toggle — so a premise →
  // customer hop is a reversible round-trip. On multi-site customers the
  // location picker stays reachable via a separate caret, with the origin
  // pinned to the top.
  originPremiseNumber?: string | null;
  // The current customer to pivot to from a premise subject; null/undefined
  // when the premise is vacant.
  currentAccountNumber?: string | null;
  // The customer's full current-premise roster. When it holds >1 entry the
  // Premise chip becomes a "N Premises ▾" picker instead of a single-site
  // pivot — folding the multi-site count INTO the chip (no separate line).
  premiseRoster?: PremiseRosterEntry[];
  onPivot: (s: InspectorSubject) => void;
}) {
  const [pickerOpen, setPickerOpen] = useState(false);
  const roster = premiseRoster ?? [];
  const multi = roster.length > 1;
  const canGoCurrentCustomer = subject.kind === "premise" ? !!currentAccountNumber : subject.kind === "customer";

  // "Back to origin" mode: on the customer view, with a known premise we came
  // from. The chip body returns straight there; multi-site keeps the picker on
  // a side caret.
  const hasOrigin = subject.kind === "customer" && originPremiseNumber != null;
  const originAddress = hasOrigin
    ? (roster.find((r) => r.premiseNumber === originPremiseNumber)?.address
        || locationLabel
        || `Premise ${shortId(originPremiseNumber as string)}`)
    : null;
  // Origin first in the picker, so "where I came from" is the top choice.
  const orderedRoster = hasOrigin
    ? [...roster].sort((a, b) =>
        a.premiseNumber === originPremiseNumber ? -1 : b.premiseNumber === originPremiseNumber ? 1 : 0)
    : roster;

  // The main chip acts as the picker toggle only when multi-site AND we have no
  // explicit origin to go back to (with an origin, the body is a direct back
  // and the caret owns the picker).
  const bodyOpensPicker = subject.kind === "customer" && multi && !hasOrigin;

  // Premise chip label: on the premise view it's the address; on a customer
  // view it's the origin address (back mode), else "N Premises" (multi) or
  // "Premise".
  const premiseChipLabel = subject.kind === "premise"
    ? (locationLabel || "Premise")
    : hasOrigin
      ? originAddress
      : multi
        ? `${roster.length} Premises`
        : "Premise";

  return (
    <div className="pivot-chips">
      <div className="pivot-chip-wrap">
        <button
          type="button"
          className={`pivot-chip ${subject.kind === "premise" ? "active" : ""}${hasOrigin ? " is-back" : ""}`}
          // A customer-view chip needs somewhere to go: an origin, the picker
          // (multi), or a single representative premise.
          disabled={subject.kind === "customer" && !hasOrigin && !multi && premiseNumber == null}
          aria-haspopup={bodyOpensPicker ? "listbox" : undefined}
          aria-expanded={bodyOpensPicker ? pickerOpen : undefined}
          onClick={() => {
            if (subject.kind === "premise") return;
            if (hasOrigin) {
              const o = roster.find((r) => r.premiseNumber === originPremiseNumber);
              onPivot({ kind: "premise", premiseNumber: originPremiseNumber as string, lat: o?.lat, lon: o?.lon });
              return;
            }
            if (multi) { setPickerOpen((o) => !o); return; }
            if (premiseNumber != null) onPivot({ kind: "premise", premiseNumber });
          }}
          title={hasOrigin ? `Back to ${originAddress}` : bodyOpensPicker ? "Choose a location" : (locationLabel || "Premise")}
        >
          {hasOrigin ? "↩ " : ""}📍 {premiseChipLabel}
          {bodyOpensPicker && <span className="pivot-caret">▾</span>}
        </button>
        {/* Multi-site + back mode: a separate caret still opens the full picker,
            since "back" only covers the one origin location. */}
        {hasOrigin && multi && (
          <button
            type="button"
            className="pivot-chip pivot-caret-btn"
            aria-haspopup="listbox"
            aria-expanded={pickerOpen}
            aria-label={`All ${roster.length} locations`}
            title={`All ${roster.length} locations`}
            onClick={() => setPickerOpen((o) => !o)}
          >
            <span className="pivot-caret">▾</span>
          </button>
        )}
        {pickerOpen && multi && subject.kind === "customer" && (
          <>
            <div className="pivot-picker-scrim" onClick={() => setPickerOpen(false)} />
            <ul className="pivot-picker" role="listbox">
              {orderedRoster.map((r) => {
                const isOrigin = hasOrigin && r.premiseNumber === originPremiseNumber;
                return (
                  <li key={r.premiseNumber} role="option" aria-selected={isOrigin}>
                    <button
                      type="button"
                      className={`pivot-picker-item${isOrigin ? " is-origin" : ""}`}
                      onClick={() => { setPickerOpen(false); onPivot({ kind: "premise", premiseNumber: r.premiseNumber, lat: r.lat, lon: r.lon }); }}
                    >
                      📍 {r.address || `Premise ${shortId(r.premiseNumber)}`}
                      {isOrigin && <span className="pivot-picker-origin-tag">came from</span>}
                    </button>
                  </li>
                );
              })}
            </ul>
          </>
        )}
      </div>
      <span className="pivot-sep">▸</span>
      <button
        type="button"
        className={`pivot-chip ${subject.kind === "customer" ? "active" : ""}`}
        disabled={!canGoCurrentCustomer}
        onClick={() => {
          if (subject.kind === "customer") return;
          if (currentAccountNumber) onPivot({ kind: "customer", accountNumber: currentAccountNumber });
        }}
        title={subject.kind === "customer" ? subject.accountNumber : currentAccountNumber || undefined}
      >
        👤 {subject.kind === "customer"
          ? `Customer · ${shortId(subject.accountNumber)}`
          : currentAccountNumber
            ? `Customer · ${shortId(currentAccountNumber)}`
            : "Vacant"}
      </button>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Linkage strip — hierarchy context under the pivot chips, for facts the
// chips themselves DON'T already carry (so it never restates them):
//   • Customer grain — the premise count now lives in the Premise chip
//     ("N Premises ▾"), so the strip only surfaces the commercial-hierarchy
//     "Part of <org>" tag when there is one. Nothing otherwise.
//   • Premise grain — "1 of N premises for this customer" locates this site
//     within the portfolio (the chip on this view shows the address, not the
//     count), plus the parent-org tag.
// parentOrg is the natural home for the future "View hierarchy →" entry point.
// ────────────────────────────────────────────────────────────────────

export function LinkageStrip({
  grain, premises, parentOrg,
}: {
  grain: "customer" | "premise";
  premises: number | null | undefined;
  parentOrg?: string | null;
}) {
  const np = premises ?? 0;
  if (np <= 0) return null; // vacant premise / no linkage resolved
  const multi = np > 1;

  // On the customer view the count is in the chip; the only thing left worth a
  // line is the parent-org tag. No parent → render nothing (no redundancy).
  if (grain === "customer" && !parentOrg) return null;

  return (
    <div className={`linkage-strip${multi ? " is-multi" : ""}`}>
      {grain === "premise" && (
        <span className="linkage-counts">
          {multi ? (
            <span className="linkage-node active">1 of {np.toLocaleString()} premises for this customer</span>
          ) : (
            <span className="linkage-node">Sole premise for this customer</span>
          )}
        </span>
      )}
      {parentOrg && (
        <span className="linkage-parent" title={`Part of ${parentOrg}`}>
          🏢 Part of {parentOrg}
        </span>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────
// Ownership line — basis-aware. Ownership is three genuinely different
// relationships (bridge_premise_owner.basis), so a single "Property owner"
// label misleads. We surface each only where it's informative:
//   • owner_occupied     — the resident owns the home; the owner IS the
//     current customer, so a line here is redundant → render nothing.
//   • landlord_agreement — a distinct landlord party the tenant pays; the
//     one case worth calling out explicitly → landlord line.
//   • owner_pays         — a commercial chain that owns its sites; framed as
//     a portfolio/hierarchy relationship, not a flat "owner". Reuses the
//     Owner inspector (the chain's premise portfolio) as today's target; the
//     dedicated hierarchy view is a separate, later effort.
// onOpen receives the owner subject; callers wire it to their navigation
// (full-drawer open vs. in-rail pivot).
// ────────────────────────────────────────────────────────────────────

export function OwnershipLine({
  p, onOpen, style,
}: {
  p: Pick<PremiseHeaderRow, "owner_number" | "owner_display_name" | "owner_basis">;
  onOpen: (subject: InspectorSubject) => void;
  style?: CSSProperties;
}) {
  // owner_occupied is the resident themselves — suppress. No owner on file → nothing.
  if (!p.owner_number || p.owner_basis === "owner_occupied") return null;

  const isLandlord = p.owner_basis === "landlord_agreement";
  const icon = isLandlord ? "🏠" : "🏢";
  const label = isLandlord ? "Landlord / property manager" : "Commercial portfolio";
  const linkText = p.owner_display_name || `${isLandlord ? "Owner" : "Portfolio"} ${shortId(p.owner_number)}`;

  return (
    <div className="ownership-line subtle" style={style}>
      {icon} {label}:{" "}
      <button
        type="button"
        className="link-button"
        onClick={() => onOpen({ kind: "owner", ownerNumber: p.owner_number as string })}
      >
        {linkText}
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
  if (!p.current_account_number) {
    alerts.push({ tone: "neutral", text: "Currently vacant" });
  }
  // PV is physically a premise attribute (the roof it's bolted to), so the
  // detection badge lives here rather than on the Customer inspector now
  // that the Premise inspector exists — see customer_header.sql's history.
  // The detection signal itself is customer-grain (features sum ALL of the
  // customer's service points), so a multi-site customer whose PV is
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
  const header = useC360Query<PremiseHeaderRow>("premise_header", params);
  const timeline = useC360Query<PremiseTimelineRow>("premise_timeline", params);
  const outages = useC360Query<PremiseOutageRow>("premise_outages", params);
  const der = useC360Query<PremiseDerRow>("premise_der", params);
  const servicePoints = useC360Query<PremiseServicePointRow>("premise_service_points", params);

  const headerRows = rows(header.data);

  if (header.loading || headerRows.length === 0) {
    return (
      <aside className="cell-drill">
        <div className="cell-drill-header">
          <h3>{header.loading ? "Loading premise…" : "Premise not found"}</h3>
          {closeBtn}
        </div>
      </aside>
    );
  }

  const p = headerRows[0];
  const tl = rows(timeline.data);
  const out = rows(outages.data);
  const derList = rows(der.data);
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
        currentAccountNumber={p.current_account_number}
        onPivot={onPivot}
      />

      <LinkageStrip
        grain="premise"
        premises={p.customer_current_premises}
      />

      <OwnershipLine p={p} onOpen={onOpenFull} />

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
            <div className="delta-label">Tenant since</div>
            <div className="delta-value">{fmtDate(p.tenant_since)}</div>
            <div className="delta-comp tone-neutral">{p.current_customer_class ? `${p.current_customer_class.toLowerCase()} customer` : "vacant"}</div>
          </div>
          {p.previous_customer_count > 0 && (
            <div className="delta-row">
              <div className="delta-label">Prior tenancies</div>
              <div className="delta-value">{p.previous_customer_count}</div>
              <div className="delta-comp tone-neutral">until {fmtDate(p.previous_customer_until)}</div>
            </div>
          )}
        </div>
      </div>

      <div className="card cell-drill-section">
        <h4>Tenancy timeline ({tl.length})</h4>
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
                  {r.account_id != null && !bool(r.is_current_account) && <span className="badge neutral" style={{ marginLeft: 6 }}>previous customer</span>}
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

      {(servicePoints.loading || rows(servicePoints.data).length > 0) && (
        <div className="card cell-drill-section">
          <h4>Service Points ({rows(servicePoints.data).length})</h4>
          {servicePoints.loading ? (
            <div className="loading">Loading…</div>
          ) : (
            <ul className="theme-list">
              {rows(servicePoints.data).map((sp) => (
                <li key={sp.service_point_number}>
                  <span className="theme-name">
                    {sp.service_point_number}
                    {sp.phase_code ? ` · ${sp.phase_code}` : ""}
                    {sp.nominal_service_voltage ? ` · ${sp.nominal_service_voltage}V` : ""}
                  </span>
                  <span className="theme-count">{sp.current_meter_number || "—"}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

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
          {p.current_account_number
            ? <>Tenant since {fmtDate(p.tenant_since)}{p.current_customer_class ? ` • ${p.current_customer_class.toLowerCase()}` : ""}</>
            : "Currently vacant"}
        </div>
        {p.previous_customer_count > 0 && p.previous_customer_until && (
          <div className="subtle" style={{ marginTop: 2 }}>
            Previous customer until {fmtDate(p.previous_customer_until)}
            {p.previous_customer_count > 1 ? ` (${p.previous_customer_count} prior tenancies)` : ""}
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
        Billed usage at this address — spans customers, since load is a
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

  const profile = useC360Query<PremiseLoadProfileRow>("premise_load_profile", params);

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
              <XAxis dataKey="hour_of_day" tick={{ fontSize: 10 }} tickFormatter={(h) => `${h}:00`} />
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

function PremiseTimelineCard({ rows, loading }: { rows: PremiseTimelineRow[]; loading: boolean }) {
  return (
    <div className="card">
      <h2>Tenancy Timeline ({rows.length})</h2>
      <div className="subtle" style={{ marginBottom: 8 }}>
        Move-in / move-out, rate switches, and meter swaps at this address —
        including prior customers, since this view is keyed to the premise.
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
                {r.account_id != null && !bool(r.is_current_account) && <span className="badge neutral" style={{ marginLeft: 6 }}>previous customer</span>}
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
        customers, unlike a customer's EV (which moves with them).
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

function PremiseComplaintsCard({ rows, loading }: { rows: PremiseComplaintRow[]; loading: boolean }) {
  return (
    <div className="card">
      <h2>Complaints at this premise ({rows.length})</h2>
      <div className="subtle" style={{ marginBottom: 8 }}>
        Attributable complaints only — each tagged with the customer who filed it.
        Unresolved-attribution complaints appear on the customer record instead.
      </div>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No attributable complaints on file.</div>}
      {rows.length > 0 && (
        <ul className="theme-list">
          {rows.map((r) => (
            <li key={r.complaint_id}>
              <span className="theme-name">
                {fmtDate(r.complaint_date)} · {(r.category || "").replace(/_/g, " ")}
                {r.sub_category ? ` / ${r.sub_category.replace(/_/g, " ")}` : ""}
                {r.filer_customer_number && (
                  <span className="badge neutral" style={{ marginLeft: 6 }} title={r.filer_account_number || undefined}>
                    {shortId(r.filer_customer_number)}
                  </span>
                )}
              </span>
              <span className="theme-count">{(r.sentiment_label || "").replace(/_/g, " ")}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function ServicePointMeterHistory({ spNumber }: { spNumber: string }) {
  const params = useMemo(() => ({ service_point_number: sql.string(spNumber) }), [spNumber]);
  const result = useC360Query<ServicePointMeterRow>("service_point_meters", params);
  const meterRows = rows(result.data);
  if (result.loading) return <div className="loading" style={{ fontSize: 12 }}>Loading meters…</div>;
  if (meterRows.length === 0) return <div className="subtle" style={{ fontSize: 12 }}>No meter history.</div>;
  return (
    <ul className="theme-list" style={{ marginTop: 4, fontSize: 12 }}>
      {meterRows.map((m) => (
        <li key={m.meter_number}>
          <span className="theme-name">
            {m.meter_number}
            {bool(m.is_current) && <span className="badge good" style={{ marginLeft: 4 }}>active</span>}
            {m.manufacturer ? ` · ${m.manufacturer}` : ""}
            {m.model_number ? ` ${m.model_number}` : ""}
          </span>
          <span className="theme-count">
            {fmtDate(m.installation_date)}{m.removal_date ? ` – ${fmtDate(m.removal_date)}` : ""}
          </span>
        </li>
      ))}
    </ul>
  );
}

function PremiseServicePointsCard({ rows: spRows, loading }: { rows: PremiseServicePointRow[]; loading: boolean }) {
  const [expanded, setExpanded] = useState<string | null>(null);
  return (
    <div className="card">
      <h2>Service Points ({spRows.length})</h2>
      <div className="subtle" style={{ marginBottom: 8 }}>
        Metered delivery points at this address. Sub-metered commercial premises
        have multiple service points. Click a row to see meter swap history.
      </div>
      {loading && <div className="loading">Loading…</div>}
      {!loading && spRows.length === 0 && <div className="empty-state">No service points on file.</div>}
      {spRows.length > 0 && (
        <ul className="theme-list">
          {spRows.map((sp) => (
            <li key={sp.service_point_number}>
              <button
                type="button"
                className="link-button"
                style={{ textAlign: "left", fontWeight: "normal" }}
                onClick={() => setExpanded(expanded === sp.service_point_number ? null : sp.service_point_number)}
              >
                <span className="theme-name">
                  {sp.service_point_number}
                  {sp.phase_code ? ` · ${sp.phase_code}` : ""}
                  {sp.nominal_service_voltage ? ` · ${sp.nominal_service_voltage}V` : ""}
                  {sp.current_meter_number ? ` → ${sp.current_meter_number}` : ""}
                </span>
              </button>
              {expanded === sp.service_point_number && (
                <ServicePointMeterHistory spNumber={sp.service_point_number} />
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function PremiseWorkOrdersCard({ rows, loading }: { rows: PremiseWorkOrderRow[]; loading: boolean }) {
  if (!loading && rows.length === 0) return null;
  return (
    <div className="card">
      <h2>Work Orders ({rows.length})</h2>
      {loading && <div className="loading">Loading…</div>}
      {rows.length > 0 && (
        <ul className="theme-list">
          {rows.map((wo) => (
            <li key={wo.work_order_id}>
              <span className="theme-name">
                {(wo.work_type || "").replace(/_/g, " ")}
                {wo.priority ? ` · ${wo.priority.toLowerCase()}` : ""}
                {wo.customer_number && (
                  <span className="badge neutral" style={{ marginLeft: 6 }} title={wo.customer_number}>
                    {shortId(wo.customer_number)}
                  </span>
                )}
              </span>
              <span className="theme-count">
                {fmtDate(wo.completed_at || wo.scheduled_at || wo.created_at)} · {(wo.status || "").replace(/_/g, " ")}
              </span>
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
  const header = useC360Query<PremiseHeaderRow>("premise_header", params);
  const bills = useC360Query<PremiseBillRow>("premise_bills", params);
  const timeline = useC360Query<PremiseTimelineRow>("premise_timeline", params);
  const outages = useC360Query<PremiseOutageRow>("premise_outages", params);
  const der = useC360Query<PremiseDerRow>("premise_der", params);
  const complaints = useC360Query<PremiseComplaintRow>("premise_complaints", params);
  const servicePoints = useC360Query<PremiseServicePointRow>("premise_service_points", params);
  const workOrders = useC360Query<PremiseWorkOrderRow>("premise_work_orders", params);

  const headerRows = rows(header.data);

  if (header.loading) return <div className="loading">Loading premise…</div>;
  if (header.error) return <div className="error">{String(header.error)}</div>;
  if (headerRows.length === 0) return <div className="empty-state">No data</div>;

  const p = headerRows[0];

  return (
    <>
      <PremiseHeaderStrip p={p} />
      <PivotChips
        subject={{ kind: "premise", premiseNumber }}
        locationLabel={p.service_address}
        currentAccountNumber={p.current_account_number}
        onPivot={onPivot}
      />
      <LinkageStrip
        grain="premise"
        premises={p.customer_current_premises}
      />
      <OwnershipLine p={p} onOpen={onPivot} style={{ padding: "6px 16px" }} />
      <PremiseAlertsBanner p={p} />
      <PremiseUsageChart rows={rows(bills.data)} loading={bills.loading} />
      <PremiseLoadProfileCard premiseNumber={premiseNumber} bills={rows(bills.data)} />
      <PremiseServicePointsCard rows={rows(servicePoints.data)} loading={servicePoints.loading} />
      <PremiseTimelineCard rows={rows(timeline.data)} loading={timeline.loading} />
      <PremiseOutageCard rows={rows(outages.data)} loading={outages.loading} />
      <PremiseComplaintsCard rows={rows(complaints.data)} loading={complaints.loading} />
      <PremiseDerCard rows={rows(der.data)} loading={der.loading} />
      <PremiseWorkOrdersCard rows={rows(workOrders.data)} loading={workOrders.loading} />
    </>
  );
}
