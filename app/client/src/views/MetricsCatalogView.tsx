import { useCallback, useEffect, useState } from "react";
import { ExternalLink, RotateCcw, Ruler, Tag } from "lucide-react";

// Metrics Catalog: the governed
// metric_* UC metric views, served by GET /api/metrics/catalog (live
// information_schema introspection — always reflects the current count).
// Pairs with the Data Model view — that shows *where* metric views sit in
// the schema; this explains *what* each one computes.

interface MetricField {
  name: string;
  expr: string;
  comment: string | null;
}
interface MetricView {
  name: string;
  comment: string | null;
  ucUrl: string;
  source: string | null;
  dimensions: MetricField[];
  measures: MetricField[];
}
interface MetricsCatalogResponse {
  catalog: string;
  schema: string;
  generatedAt: string;
  views: MetricView[];
}

function FieldList({ fields, icon: Icon }: { fields: MetricField[]; icon: typeof Tag }) {
  if (fields.length === 0) return <p className="metric-field-empty">None</p>;
  return (
    <ul className="metric-field-list">
      {fields.map((f) => (
        <li key={f.name} title={f.comment ?? f.expr}>
          <Icon size={11} />
          <span>{f.name}</span>
        </li>
      ))}
    </ul>
  );
}

export function MetricsCatalogView() {
  const [data, setData] = useState<MetricsCatalogResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (refresh?: boolean) => {
    setLoading(true);
    setError(null);
    try {
      const qs = refresh ? "?refresh=1" : "";
      const resp = await fetch(`/api/metrics/catalog${qs}`);
      const json = await resp.json();
      if (!resp.ok || json.error) throw new Error(json.error || `Request failed (${resp.status})`);
      setData(json as MetricsCatalogResponse);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  if (loading && !data) return <div className="loading">Loading metrics catalog…</div>;
  if (error) return <div className="error">{error}</div>;
  if (!data || data.views.length === 0) return <div className="empty-state">No metric views found.</div>;

  return (
    <div className="metrics-catalog-view">
      <div className="data-model-toolbar">
        <span className="data-model-field">
          <span>{data.views.length} governed metric view{data.views.length === 1 ? "" : "s"}</span>
        </span>
        <button
          type="button" className="data-model-action"
          onClick={() => load(true)} title="Refresh metadata (bypass cache)"
        >
          <RotateCcw size={13} /> Refresh
        </button>
      </div>
      <div className="metrics-catalog-grid">
        {data.views.map((v) => (
          <div key={v.name} className="card metric-card">
            <div className="metric-card-header">
              <span className="metric-card-name">{v.name}</span>
              <a
                className="erd-node-link" href={v.ucUrl} target="_blank" rel="noreferrer"
                title="Open in Unity Catalog"
              >
                <ExternalLink size={12} />
              </a>
            </div>
            {v.comment && <p className="metric-card-comment">{v.comment}</p>}
            {v.source && <p className="metric-card-source">Source: {v.source}</p>}
            <div className="metric-card-fields">
              <div>
                <h3><Tag size={12} /> Dimensions ({v.dimensions.length})</h3>
                <FieldList fields={v.dimensions} icon={Tag} />
              </div>
              <div>
                <h3><Ruler size={12} /> Measures ({v.measures.length})</h3>
                <FieldList fields={v.measures} icon={Ruler} />
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
