import { useMemo } from "react";
import { useAnalyticsQuery } from "@databricks/appkit-ui/react";
import { sql } from "@databricks/appkit-ui/js";
import { PivotChips, shortId, type InspectorSubject } from "./PremiseInspector";

// ────────────────────────────────────────────────────────────────────
// The Owner/portfolio subject (docs/entity-grain-design.md §4.2, §6.2).
// bridge_premise_owner is a sparse, dated, account-backed
// owner->premise edge. Reached only via the Owner pivot chip from a Premise
// subject (an owner is a portfolio of many premises, so there's no single
// Location/Occupant to land here from directly) or by clicking a roster row.
// ────────────────────────────────────────────────────────────────────

// ── formatting helpers (small local copies — matches PremiseInspector.tsx's
// own convention of not importing these from App.tsx/ExplorerMap.tsx) ──────

function num(n: number | string | null | undefined): number | null {
  if (n == null || n === "") return null;
  const v = typeof n === "string" ? Number(n) : n;
  return Number.isFinite(v) ? v : null;
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

interface OwnerHeaderRow {
  owner_number: string;
  display_name: string | null;
  basis: string;
  owns_since: string | null;
  n_premises: number;
  n_currently_vacant: number;
  n_historical_vacancies: number;
  avg_monthly_kwh_portfolio: number | null;
}

interface OwnerPortfolioRow {
  premise_number: string;
  service_address: string;
  service_city: string | null;
  service_state: string | null;
  building_subtype: string | null;
  sqft: number | null;
  latitude: number;
  longitude: number;
  tenant_account_number: string | null;
  tenant_customer_number: string | null;
  occupancy_type: string;
  tenant_since: string | null;
  avg_monthly_kwh: number | null;
}

function basisLabel(basis: string): string {
  switch (basis) {
    case "owner_pays": return "Owner-pays (consolidated billing)";
    case "owner_occupied": return "Owner-occupied";
    case "landlord_agreement": return "Landlord agreement";
    default: return basis;
  }
}

// ────────────────────────────────────────────────────────────────────
// Compact rail card — parallels PremiseDrillCard/CustomerDrillPanel.
// ────────────────────────────────────────────────────────────────────

export function OwnerDrillCard({
  ownerNumber, onClose, onOpenFull, onPivot,
}: {
  ownerNumber: string;
  onClose: () => void;
  onOpenFull: (subject: InspectorSubject) => void;
  onPivot: (subject: InspectorSubject) => void;
}) {
  const params = useMemo(() => ({ owner_number: sql.string(ownerNumber) }), [ownerNumber]);
  const header = useAnalyticsQuery<OwnerHeaderRow>("owner_header", params);
  const portfolio = useAnalyticsQuery<OwnerPortfolioRow>("owner_portfolio", params);

  if (header.loading || (header.data || []).length === 0) {
    return (
      <aside className="cell-drill">
        <div className="cell-drill-header">
          <h3>{header.loading ? "Loading owner…" : "Owner not found"}</h3>
          <button className="cell-close" onClick={onClose}>×</button>
        </div>
      </aside>
    );
  }

  const o = (header.data as OwnerHeaderRow[])[0];
  const roster = (portfolio.data || []) as OwnerPortfolioRow[];

  return (
    <aside className="cell-drill">
      <div className="cell-drill-header">
        <div>
          <div className="cell-drill-eyebrow">Owner drill-down</div>
          <h3 title={o.display_name ? undefined : o.owner_number}>{o.display_name || `Owner ${shortId(o.owner_number)}`}</h3>
          <div className="subtle">{basisLabel(o.basis)}</div>
        </div>
        <button className="cell-close" onClick={onClose}>×</button>
      </div>

      <PivotChips subject={{ kind: "owner", ownerNumber }} onPivot={onPivot} />

      <div className="card cell-drill-section">
        <h4>Portfolio</h4>
        <div className="delta-grid">
          <div className="delta-row">
            <div className="delta-label">Premises owned</div>
            <div className="delta-value">{fmtNum(o.n_premises)}</div>
            <div className="delta-comp tone-neutral">
              {o.n_currently_vacant > 0 ? `${o.n_currently_vacant} currently vacant` : "all occupied"}
            </div>
          </div>
          <div className="delta-row">
            <div className="delta-label">Avg monthly usage</div>
            <div className="delta-value">{fmtKwh(o.avg_monthly_kwh_portfolio)}</div>
            <div className="delta-comp tone-neutral">across the portfolio</div>
          </div>
          {o.n_historical_vacancies > 0 && (
            <div className="delta-row">
              <div className="delta-label">Prior vacancies</div>
              <div className="delta-value">{o.n_historical_vacancies}</div>
              <div className="delta-comp tone-neutral">billing reverted to owner</div>
            </div>
          )}
        </div>
      </div>

      <div className="card cell-drill-section">
        <h4>Roster ({roster.length})</h4>
        {portfolio.loading ? (
          <div className="loading">Loading…</div>
        ) : (
          <ul className="theme-list">
            {roster.slice(0, 6).map((r) => (
              <li key={r.premise_number}>
                <span className="theme-name">
                  {r.service_address}
                  {r.occupancy_type === "vacant" && <span className="badge neutral" style={{ marginLeft: 6 }}>vacant</span>}
                </span>
                <span className="theme-count">{fmtKwh(r.avg_monthly_kwh)}</span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="selection-actions">
        <button className="sel-action primary" onClick={() => onOpenFull({ kind: "owner", ownerNumber })}>
          Expand full profile →
        </button>
      </div>
    </aside>
  );
}

// ────────────────────────────────────────────────────────────────────
// Full drawer view — parallels PremiseDetail/CustomerDetail.
// ────────────────────────────────────────────────────────────────────

function OwnerHeaderStrip({ o }: { o: OwnerHeaderRow }) {
  return (
    <div className="header-strip">
      <div>
        <h1 title={o.display_name ? undefined : o.owner_number}>{o.display_name || `Owner ${shortId(o.owner_number)}`}</h1>
        <div className="subtle">{basisLabel(o.basis)}</div>
        <div className="subtle" style={{ marginTop: 6 }}>
          Owner since {fmtDate(o.owns_since)} · {fmtNum(o.n_premises)} premises owned
        </div>
      </div>
      <div className="kpi">
        <div className="label">Currently vacant</div>
        <div className="value">{o.n_currently_vacant}</div>
        <div className="label" style={{ marginTop: 8 }}>Avg monthly usage</div>
        <div className="value">{fmtKwh(o.avg_monthly_kwh_portfolio)}</div>
      </div>
    </div>
  );
}

function OwnerAlertsBanner({ o }: { o: OwnerHeaderRow }) {
  // COUNT columns arrive as strings over JSON — coerce before comparing.
  const currentlyVacant = num(o.n_currently_vacant) ?? 0;
  const historicalVacancies = num(o.n_historical_vacancies) ?? 0;
  if (currentlyVacant === 0 && historicalVacancies === 0) {
    return (
      <div className="alerts-banner ok">
        <span className="badge good">Fully occupied</span>
        <span className="alerts-detail">No vacancies on file across the portfolio.</span>
      </div>
    );
  }
  const worst = currentlyVacant > 0 ? "warn" : "info";
  return (
    <div className={`alerts-banner ${worst}`}>
      <div className="alerts-title">Next actions &amp; insights</div>
      <div className="alerts-grid">
        {currentlyVacant > 0 && (
          <div className="alert-tile tone-warn">
            <div className="alert-tile-text">{currentlyVacant} premise(s) currently vacant</div>
            <div className="alert-tile-detail">No current occupant on file — billing would revert to the owner.</div>
          </div>
        )}
        {historicalVacancies > 0 && (
          <div className="alert-tile tone-info">
            <div className="alert-tile-text">{historicalVacancies} historical vacancy episode(s)</div>
            <div className="alert-tile-detail">The owner was briefly billing-responsible between tenants.</div>
          </div>
        )}
      </div>
    </div>
  );
}

function OwnerPortfolioTable({
  rows, loading, onShowAllLocations, onPivotToPremise,
}: {
  rows: OwnerPortfolioRow[];
  loading: boolean;
  onShowAllLocations: (points: { lat: number; lon: number }[]) => void;
  onPivotToPremise: (premiseNumber: string) => void;
}) {
  const points = rows.map((r) => ({ lat: Number(r.latitude), lon: Number(r.longitude) }));
  return (
    <div className="card">
      <div className="card-toolbar">
        <h2>Portfolio Roster ({rows.length})</h2>
        <button
          type="button"
          className="sel-action primary"
          style={{ flex: "0 0 auto" }}
          disabled={points.length === 0}
          onClick={() => onShowAllLocations(points)}
        >
          Light up portfolio ({points.length})
        </button>
      </div>
      {loading && <div className="loading">Loading…</div>}
      {!loading && rows.length === 0 && <div className="empty-state">No premises on file.</div>}
      {rows.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Address</th><th>Occupancy</th><th>Tenant</th><th>Since</th><th>Avg monthly kWh</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.premise_number}>
                <td>
                  <button type="button" className="link-button" onClick={() => onPivotToPremise(r.premise_number)}>
                    {r.service_address}{r.service_city ? `, ${r.service_city}` : ""}
                  </button>
                </td>
                <td>
                  {r.occupancy_type === "vacant"
                    ? <span className="badge neutral">vacant</span>
                    : (r.occupancy_type || "—").replace(/_/g, " ")}
                </td>
                <td>{r.tenant_account_number || "—"}</td>
                <td>{fmtDate(r.tenant_since)}</td>
                <td>{fmtKwh(r.avg_monthly_kwh)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

export function OwnerDetail({
  ownerNumber, onPivot, onShowAllLocations,
}: {
  ownerNumber: string;
  onPivot: (subject: InspectorSubject) => void;
  onShowAllLocations: (points: { lat: number; lon: number }[]) => void;
}) {
  const params = useMemo(() => ({ owner_number: sql.string(ownerNumber) }), [ownerNumber]);
  const header = useAnalyticsQuery<OwnerHeaderRow>("owner_header", params);
  const portfolio = useAnalyticsQuery<OwnerPortfolioRow>("owner_portfolio", params);

  if (header.loading) return <div className="loading">Loading owner…</div>;
  if (header.error) return <div className="error">{String(header.error)}</div>;
  if (!header.data || header.data.length === 0) return <div className="empty-state">No data</div>;

  const o = header.data[0];

  return (
    <>
      <OwnerHeaderStrip o={o} />
      <PivotChips subject={{ kind: "owner", ownerNumber }} onPivot={onPivot} />
      <OwnerAlertsBanner o={o} />
      <OwnerPortfolioTable
        rows={portfolio.data || []}
        loading={portfolio.loading}
        onShowAllLocations={onShowAllLocations}
        onPivotToPremise={(premiseNumber) => onPivot({ kind: "premise", premiseNumber })}
      />
    </>
  );
}
