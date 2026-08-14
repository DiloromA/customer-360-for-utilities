import { useMemo } from "react";
import { useC360Query } from "../queryUtils";
import { sql } from "@databricks/appkit-ui/js";
import { rows } from "../queryUtils";
import { PivotChips, LinkageStrip, type InspectorSubject, type PremiseRosterEntry } from "../PremiseInspector";
import { localityText } from "../filters";

// ────────────────────────────────────────────────────────────────────
// Local formatting helpers (mirrors of ExplorerMap.tsx, intentionally
// not shared — each consumer can diverge without coupling)
// ────────────────────────────────────────────────────────────────────

function num(n: number | string | null | undefined): number {
  if (n == null) return 0;
  const v = typeof n === "string" ? Number(n) : n;
  return Number.isFinite(v) ? v : 0;
}
// useC360Query returns BOOLEAN columns as "true"/"false" strings.
function bool(b: boolean | string | null | undefined): boolean {
  return b === true || b === "true";
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
function fmtUSD(n: number | string | null | undefined): string {
  if (n == null) return "—";
  const v = typeof n === "string" ? Number(n) : n;
  if (!Number.isFinite(v)) return "—";
  return `$${v.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
}
function fmtDate(s: string | null | undefined): string {
  if (!s) return "—";
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

// ────────────────────────────────────────────────────────────────────
// Row types
// ────────────────────────────────────────────────────────────────────

interface DrillHeaderRow {
  account_number: string;
  premise_number: string;
  service_address: string; service_city: string; service_state: string; service_zip: string;
  county: string;
  customer_class: string;
  building_subtype: string; sqft: number; year_built: number;
  customer_since_date: string;
  engagement_tier: string; digital_adoption_score: number;
  churn_risk_band: string;
  payment_stressed_flag: boolean; payment_late_flag: boolean; high_user_flag: boolean;
  critical_care_flag: boolean; liheap_eligible: boolean;
  avg_monthly_kwh_12mo: number; peer_p75_avg_monthly_kwh: number;
  recent_outage_minutes_90d: number; recent_outage_events_90d: number;
  recent_complaint_count_90d: number;
  rate_display_name: string; account_status: string;
  complaint_risk_pct: number | null; complaint_risk_tier: string | null;
  complaint_risk_category: string | null;
  // Linkage context (customer_header.sql): what sits below/around this grain.
  current_premises: number | null; current_accounts: number | null;
  parent_org_name: string | null;
}
interface DrillComplaintRow {
  complaint_id: string; complaint_date: string; channel: string;
  category: string; sub_category: string; severity: string;
  sentiment_label: string; resolution_status: string;
  verbatim_text: string; verbatim_language: string;
}
interface DrillOutageRow {
  impact_id: string; affected_start: string; minutes_out: number;
  cause_code: string; weather_category: string;
  is_major_event_day: boolean; priority_restoration_flag: boolean;
}
interface DrillRecoRow {
  program_id: string; program_name: string; program_type: string;
  rebate_amount_usd: number; avg_annual_kwh_saved: number; relevance_score: number;
}
interface DrillPremiseRow {
  premise_number: string;
  service_address: string | null;
  service_city: string | null;
  service_state: string | null;
  latitude: number | null;
  longitude: number | null;
}

// ────────────────────────────────────────────────────────────────────
// Component
// ────────────────────────────────────────────────────────────────────

export function CustomerDrillPanel({
  accountNumber, originPremiseNumber = null, onClose, onOpenFull, onPivot, backToGroup = false,
}: {
  accountNumber: string;
  // The premise this customer was drilled into from (null if opened directly,
  // e.g. a customer picked by name). When set, the Premise chip returns to
  // exactly this location rather than the account's representative premise —
  // so a premise → customer hop is a reversible round-trip, not a dead end.
  originPremiseNumber?: string | null;
  onClose: () => void;
  onOpenFull: (subject: InspectorSubject) => void;
  onPivot: (subject: InspectorSubject) => void;
  // When this individual was drilled from inside a group, closing returns to
  // that group — so the affordance reads "← Group" instead of a bare ×.
  backToGroup?: boolean;
}) {
  const closeBtn = backToGroup
    ? <button className="cell-back" onClick={onClose} title="Back to the group">← Group</button>
    : <button className="cell-close" onClick={onClose}>×</button>;
  const params = useMemo(() => ({ account_number: sql.string(accountNumber) }), [accountNumber]);
  const header = useC360Query<DrillHeaderRow>("customer_header", params);
  const complaints = useC360Query<DrillComplaintRow>("customer_complaints", params);
  const outages = useC360Query<DrillOutageRow>("customer_outages", params);
  const recos = useC360Query<DrillRecoRow>("customer_recommendations", params);
  // Current-premise roster for the Premise chip's location picker (only used
  // when the customer holds >1 current premise).
  const premisesQ = useC360Query<DrillPremiseRow>("customer_premises", params);
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

  if (header.loading || headerRows.length === 0) {
    return (
      <aside className="cell-drill">
        <div className="cell-drill-header">
          <h3>{header.loading ? "Loading customer…" : "Customer not found"}</h3>
          {closeBtn}
        </div>
      </aside>
    );
  }

  const c = headerRows[0];
  const cmp = rows(complaints.data);
  const out = rows(outages.data);
  const recoList = rows(recos.data);

  const alerts: { tone: string; text: string }[] = [];
  if (bool(c.payment_stressed_flag)) alerts.push({ tone: "alert", text: "Payment stress" });
  if (c.complaint_risk_tier === "high") alerts.push({ tone: "alert", text: `Complaint risk ${c.complaint_risk_pct}%` });
  else if (c.complaint_risk_tier === "elevated") alerts.push({ tone: "warn", text: `Complaint risk ${c.complaint_risk_pct}%` });
  if (c.churn_risk_band === "high") alerts.push({ tone: "alert", text: "Dissatisfaction risk" });
  if (bool(c.critical_care_flag)) alerts.push({ tone: "info", text: "Critical-care medical" });
  if (bool(c.liheap_eligible)) alerts.push({ tone: "info", text: "LIHEAP-eligible" });
  if (bool(c.high_user_flag)) alerts.push({ tone: "warn", text: "High usage" });
  if (num(c.recent_outage_minutes_90d) > 240) alerts.push({ tone: "warn", text: "Heavy outages" });
  if (bool(c.payment_late_flag)) alerts.push({ tone: "warn", text: "Paid late" });

  const peerP75 = num(c.peer_p75_avg_monthly_kwh);
  const usagePct = peerP75 > 0 ? Math.round((num(c.avg_monthly_kwh_12mo) / peerP75) * 100) : null;

  return (
    <aside className="cell-drill">
      <div className="cell-drill-header">
        <div>
          <div className="cell-drill-eyebrow">Customer drill-down</div>
          <h3>{c.service_address}</h3>
          <div className="subtle">
            {localityText({ city: c.service_city, county: c.county, state: c.service_state })} · {c.customer_class}
          </div>
          <div className="subtle">
            {(c.building_subtype || "").replace(/_/g, " ")} · {fmtNum(c.sqft)} sqft · {c.rate_display_name}
          </div>
        </div>
        {closeBtn}
      </div>

      <PivotChips
        subject={{ kind: "customer", accountNumber }}
        locationLabel={c.service_address}
        // Prefer the premise we drilled in from, so the Premise chip is a
        // true "back" to the user's starting point; fall back to the account's
        // representative premise when opened directly (no origin).
        premiseNumber={originPremiseNumber ?? c.premise_number}
        originPremiseNumber={originPremiseNumber}
        premiseRoster={premiseRoster}
        onPivot={onPivot}
      />

      <LinkageStrip
        grain="customer"
        premises={c.current_premises}
        parentOrg={c.parent_org_name}
      />

      {alerts.length > 0 && (
        <div className="drill-flags">
          {alerts.map((a, i) => <span key={i} className={`badge ${a.tone}`}>{a.text}</span>)}
        </div>
      )}

      <div className="card cell-drill-section">
        <h4>Key signals</h4>
        <div className="delta-grid">
          <div className="delta-row">
            <div className="delta-label">Avg monthly use</div>
            <div className="delta-value">{fmtKwh(c.avg_monthly_kwh_12mo)}</div>
            <div className={`delta-comp ${usagePct != null && usagePct > 110 ? "tone-bad" : "tone-neutral"}`}>
              {usagePct != null ? `${usagePct}% of peer p75` : "—"}
            </div>
          </div>
          <div className="delta-row">
            <div className="delta-label">Digital adoption</div>
            <div className="delta-value">{fmtNum(c.digital_adoption_score)}/100</div>
            <div className="delta-comp tone-neutral">{c.engagement_tier} engagement</div>
          </div>
          <div className="delta-row">
            <div className="delta-label">Outages (90d)</div>
            <div className="delta-value">{fmtNum(c.recent_outage_events_90d)} events</div>
            <div className="delta-comp tone-neutral">{fmtNum(c.recent_outage_minutes_90d)} min out</div>
          </div>
          <div className="delta-row">
            <div className="delta-label">Complaints (90d)</div>
            <div className="delta-value">{fmtNum(c.recent_complaint_count_90d)}</div>
            <div className="delta-comp tone-neutral">{c.account_status}</div>
          </div>
        </div>
      </div>

      <div className="card cell-drill-section">
        <h4>Complaints ({cmp.length})</h4>
        {complaints.loading ? (
          <div className="loading">Loading…</div>
        ) : cmp.length === 0 ? (
          <div className="subtle">No complaints on file.</div>
        ) : (
          cmp.map((r) => (
            <div className="complaint-card" key={r.complaint_id}>
              <div className="meta">
                <span>{fmtDate(r.complaint_date)}</span>
                <span>·</span>
                <span>{r.category} / {r.sub_category.replace(/_/g, " ")}</span>
                <span className={`badge ${r.severity === "high" ? "alert" : r.severity === "medium" ? "warn" : "neutral"}`}>{r.severity}</span>
                <span className={`badge ${r.resolution_status === "resolved" ? "good" : r.resolution_status === "escalated" ? "alert" : "neutral"}`}>{r.resolution_status}</span>
              </div>
              <div className="verbatim">"{r.verbatim_text}"</div>
            </div>
          ))
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
              const mins = num(r.minutes_out);
              const h = Math.floor(mins / 60), m = mins % 60;
              return (
                <li key={r.impact_id}>
                  <span className="theme-name">{fmtDate(r.affected_start)} · {r.cause_code.replace(/_/g, " ")}</span>
                  <span className="theme-count">{h > 0 ? `${h}h ${m}m` : `${m}m`}</span>
                </li>
              );
            })}
          </ul>
        )}
      </div>

      <div className="card cell-drill-section">
        <h4>Best-fit programs</h4>
        {recos.loading ? (
          <div className="loading">Loading…</div>
        ) : recoList.length === 0 ? (
          <div className="subtle">No matching programs for this segment.</div>
        ) : (
          <ul className="theme-list">
            {recoList.slice(0, 4).map((r) => (
              <li key={r.program_id}>
                <span className="theme-name">{r.program_name}</span>
                <span className="theme-count">{fmtUSD(r.rebate_amount_usd)}</span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="selection-actions">
        <button className="sel-action primary" onClick={() => onOpenFull({ kind: "customer", accountNumber })}>
          Expand full profile →
        </button>
      </div>
    </aside>
  );
}
