import { useMemo, useState } from "react";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@databricks/appkit-ui/react";
import { useC360Query } from "../queryUtils";
import { sql } from "@databricks/appkit-ui/js";
import { rows } from "../queryUtils";
import {
  ResponsiveContainer, LineChart, Line, BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend,
} from "recharts";
import type { InspectorSubject } from "../PremiseInspector";

// Customer Satisfaction & Experience view. Three tabs: Overview (KPI band, CSAT
// trend, channel breakdown, journey breakdown, segmentation), Drivers &
// Follow-up (driver analysis, operational correlation, survey health with an
// NPS response-rate denominator), and Voice of Customer (verbatim feed +
// closed-loop detractor follow-up queue) — the Voice of Customer panels are
// the ones that deep-link into the customer drawer, via the onJumpToSubject
// prop (mirrors ExplorerMap's
// onJumpToSubject/App.tsx's setFullSubject). Reads entirely from existing
// curated facts (fact_csr_interactions, fact_survey_responses,
// fact_customer_billing, ml_complaint_risk_scores) plus the ref_cx_targets
// seed and the fact_survey_invitations aggregate — no new survey pipeline.
//
// CSAT/FCR/AHT source fact_csr_interactions.csat_score_1_5 directly: it's
// populated on every interaction (not the ~10% independently surveyed via
// fact_survey_responses), so it's the complete, unsampled series.
//
// The Drivers & Follow-up panels deliberately query the star schema, not metric_csat — they
// bucket row-level operational fields (wait_time_seconds, transfer_count,
// nearest-bill bill_shock_pct), which is outside the aggregate-only
// metric-view constraint (see each query file's header).

type TimeRange = "recent12" | "prior12" | "all";
type Segment = "all" | "residential" | "commercial";

interface DemoConfigRow {
  as_of_date: string;
  history_months: number | string;
}

// Fallback used only until demo_config loads (matches the bundle's default
// as_of_date/history_months — see databricks.yml).
const DEFAULT_AS_OF_DATE = "2018-12-31";
const DEFAULT_HISTORY_MONTHS = 24;

function addMonths(dateStr: string, months: number): string {
  const d = new Date(`${dateStr}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + months);
  return d.toISOString().slice(0, 10);
}
function addDays(dateStr: string, days: number): string {
  const d = new Date(`${dateStr}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

interface KpiRow {
  csat_n: number;
  csat_top2box_pct: number | string | null;
  csat_mean: number | string | null;
  csat_target: number | string | null;
  csat_jdpower: number | string | null;
  csat_acsi: number | string | null;
  nps_n: number;
  nps_score: number | string | null;
  nps_target: number | string | null;
  fcr_n: number;
  fcr_pct: number | string | null;
  fcr_target: number | string | null;
  aht_seconds: number | string | null;
  aht_target: number | string | null;
}
interface TrendRow {
  year_month: string;
  n: number;
  top2box_pct: number | string | null;
  csat_target: number | string | null;
}
interface ChannelRow { media_type: string; n: number; top2box_pct: number | string | null; mean_score: number | string | null; }
interface JourneyRow { queue: string; journey: string; n: number; top2box_pct: number | string | null; mean_score: number | string | null; }
interface SegmentRow { dim_type: string; dim_value: string | null; n: number; top2box_pct: number | string | null; mean_score: number | string | null; }
interface DriverRow {
  driver_type: string;
  bucket: string;
  bucket_order: number;
  n: number;
  top2box_pct: number | string | null;
  mean_score: number | string | null;
  sqm_dimension: string | null;
  sqm_avg_score: number | string | null;
}
interface CorrelationRow {
  driver_type: string;
  bucket: string;
  bucket_order: number;
  n: number;
  avg_score_0_10: number | string | null;
  nps_score: number | string | null;
  top2box_pct: number | string | null;
}
interface SurveyHealthRow {
  metric_type: string;
  period_label: string;
  period_order: number;
  survey_type: string | null;
  survey_id: string | null;
  n: number | string;
  n_invited: number | string | null;
  n_responded: number | string | null;
  response_rate_pct: number | string | null;
}
interface VerbatimRow {
  survey_response_id: string;
  response_date: string;
  score_0_10: number | string | null;
  nps_bucket: string;
  comment_text: string;
  comment_sentiment: string | null;
  comment_theme: string | null;
  account_number: string | null;
}
interface FollowupRow {
  survey_response_id: string;
  response_date: string;
  survey_type: string;
  score_0_10: number | string | null;
  comment_text: string | null;
  agent_id: string | null;
  account_number: string | null;
  complaint_risk_tier: string | null;
  complaint_risk_category: string | null;
}

function num(v: number | string | null | undefined): number | null {
  if (v == null || v === "") return null;
  const n = typeof v === "string" ? Number(v) : v;
  return Number.isFinite(n) ? n : null;
}
function fmt1(v: number | string | null | undefined, suffix = ""): string {
  const n = num(v);
  return n == null ? "—" : `${n.toFixed(1)}${suffix}`;
}
function fmtSeconds(v: number | string | null | undefined): string {
  const n = num(v);
  if (n == null) return "—";
  const m = Math.floor(n / 60);
  const s = Math.round(n % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}

type Tone = "good" | "warn" | "bad" | "neutral";
function toneVsTarget(value: number | null, target: number | null, higherIsBetter: boolean): Tone {
  if (value == null || target == null) return "neutral";
  const diff = higherIsBetter ? value - target : target - value;
  if (diff >= 0) return "good";
  if (diff >= -0.05 * Math.max(Math.abs(target), 1)) return "warn";
  return "bad";
}

function KpiTile({
  label, value, sub, target, tone,
}: { label: string; value: string; sub?: string; target?: string | null; tone: Tone }) {
  return (
    <div className="csat-kpi-tile">
      <div className="csat-kpi-label">{label}</div>
      <div className={`csat-kpi-value tone-${tone}`}>{value}</div>
      {sub && <div className="csat-kpi-sub">{sub}</div>}
      {target != null && <div className={`csat-kpi-delta tone-${tone}`}>Target: {target}</div>}
    </div>
  );
}

const SEGMENT_GROUPS: { key: string; label: string }[] = [
  { key: "customer_class", label: "Residential vs Commercial" },
  { key: "tenure_band", label: "Account Tenure" },
  { key: "county", label: "County" },
];

function SegmentBreakdown({ rows }: { rows: SegmentRow[] }) {
  return (
    <>
      {SEGMENT_GROUPS.map((g) => {
        const groupRows = rows.filter((r) => r.dim_type === g.key && r.dim_value);
        if (groupRows.length === 0) return null;
        return (
          <div className="dist-group" key={g.key}>
            <div className="dist-group-label">{g.label}</div>
            {groupRows.map((r) => {
              const pct = Math.max(0, Math.min(100, num(r.top2box_pct) ?? 0));
              return (
                <div className="dist-row" key={String(r.dim_value)}>
                  <span className="dist-name">{r.dim_value}</span>
                  <span className="dist-track">
                    <span className="dist-fill" style={{ width: `${pct}%` }} />
                  </span>
                  <span className="dist-pct">{fmt1(r.top2box_pct, "%")}</span>
                </div>
              );
            })}
          </div>
        );
      })}
    </>
  );
}

const DRIVER_GROUPS: { key: string; label: string }[] = [
  { key: "wait_time_bucket", label: "By Wait Time" },
  { key: "transfer_count", label: "By Transfer Count" },
  { key: "fcr", label: "By First-Call Resolution" },
];

function DriverBreakdown({ rows }: { rows: DriverRow[] }) {
  return (
    <>
      {DRIVER_GROUPS.map((g) => {
        const groupRows = rows
          .filter((r) => r.driver_type === g.key)
          .slice()
          .sort((a, b) => a.bucket_order - b.bucket_order);
        if (groupRows.length === 0) return null;
        return (
          <div className="dist-group" key={g.key}>
            <div className="dist-group-label">{g.label}</div>
            {groupRows.map((r) => {
              const pct = Math.max(0, Math.min(100, num(r.top2box_pct) ?? 0));
              return (
                <div className="dist-row" key={r.bucket}>
                  <span className="dist-name">{r.bucket}</span>
                  <span className="dist-track">
                    <span className="dist-fill" style={{ width: `${pct}%` }} />
                  </span>
                  <span className="dist-pct">{fmt1(r.top2box_pct, "%")} · n={r.n}</span>
                </div>
              );
            })}
          </div>
        );
      })}
    </>
  );
}

function SqmSubscoreBreakdown({ rows }: { rows: DriverRow[] }) {
  const subRows = rows.filter((r) => r.driver_type === "sqm_subscore");
  const buckets = Array.from(new Set(subRows.map((r) => r.bucket))).sort((a, b) => {
    const ao = subRows.find((r) => r.bucket === a)?.bucket_order ?? 0;
    const bo = subRows.find((r) => r.bucket === b)?.bucket_order ?? 0;
    return ao - bo;
  });
  if (subRows.length === 0) return null;
  return (
    <>
      {buckets.map((bucket) => {
        const bucketRows = subRows.filter((r) => r.bucket === bucket);
        const n = bucketRows[0]?.n ?? 0;
        return (
          <div className="dist-group" key={bucket}>
            <div className="dist-group-label">{bucket} (n={n}, 5% QA-sampled calls)</div>
            {bucketRows.map((r) => {
              const score = num(r.sqm_avg_score) ?? 0;
              const pct = Math.max(0, Math.min(100, (score / 5) * 100));
              return (
                <div className="dist-row" key={r.sqm_dimension}>
                  <span className="dist-name">{r.sqm_dimension}</span>
                  <span className="dist-track">
                    <span className="dist-fill" style={{ width: `${pct}%` }} />
                  </span>
                  <span className="dist-pct">{fmt1(r.sqm_avg_score, "/5")}</span>
                </div>
              );
            })}
          </div>
        );
      })}
    </>
  );
}

const SURVEY_TYPE_LABELS: Record<string, string> = {
  nps_relationship: "NPS",
  csat_transactional: "CSAT",
  sqm_call_evaluation: "SQM",
};

function fmtDate(v: string | null | undefined): string {
  if (!v) return "—";
  return v.slice(0, 10);
}

function ThemeFrequency({ rows }: { rows: VerbatimRow[] }) {
  const counts = new Map<string, number>();
  for (const r of rows) {
    const theme = r.comment_theme || "uncategorized";
    counts.set(theme, (counts.get(theme) ?? 0) + 1);
  }
  const total = rows.length || 1;
  const entries = Array.from(counts.entries()).sort((a, b) => b[1] - a[1]);
  if (entries.length === 0) return null;
  return (
    <div className="dist-group">
      <div className="dist-group-label">Theme frequency (this feed)</div>
      {entries.map(([theme, n]) => {
        const pct = Math.max(0, Math.min(100, (n / total) * 100));
        return (
          <div className="dist-row" key={theme}>
            <span className="dist-name">{theme}</span>
            <span className="dist-track">
              <span className="dist-fill" style={{ width: `${pct}%` }} />
            </span>
            <span className="dist-pct">{n}</span>
          </div>
        );
      })}
    </div>
  );
}

function VerbatimFeed({
  rows, onJumpToSubject,
}: { rows: VerbatimRow[]; onJumpToSubject: (subject: InspectorSubject) => void }) {
  if (rows.length === 0) return <div className="empty-state">No comments in this period.</div>;
  return (
    <div>
      {rows.map((r) => (
        <div className="complaint-card" key={r.survey_response_id}>
          <div className="meta">
            <span>{fmtDate(r.response_date)}</span>
            <span>•</span>
            <span>{r.nps_bucket} · {fmt1(r.score_0_10)}/10</span>
            <span>
              <span className={`badge ${r.comment_sentiment === "negative" ? "alert" : r.comment_sentiment === "positive" ? "good" : "neutral"}`}>
                {r.comment_sentiment ?? "neutral"}
              </span>
            </span>
            {r.comment_theme && <span><span className="badge neutral">{r.comment_theme}</span></span>}
          </div>
          <div className="verbatim">"{r.comment_text}"</div>
          {r.account_number && (
            <button type="button" className="link-button" onClick={() => onJumpToSubject({ kind: "customer", accountNumber: r.account_number as string })}>
              Open profile →
            </button>
          )}
        </div>
      ))}
    </div>
  );
}

function FollowupQueue({
  rows, onJumpToSubject,
}: { rows: FollowupRow[]; onJumpToSubject: (subject: InspectorSubject) => void }) {
  if (rows.length === 0) return <div className="empty-state">No detractor responses in this period.</div>;
  return (
    <table className="csat-health-table">
      <thead>
        <tr>
          <th>Date</th>
          <th>Survey</th>
          <th>Score</th>
          <th>Comment</th>
          <th>Predicted risk</th>
          <th>Agent</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.survey_response_id}>
            <td>{fmtDate(r.response_date)}</td>
            <td>{SURVEY_TYPE_LABELS[r.survey_type] ?? r.survey_type}</td>
            <td>{fmt1(r.score_0_10)}/10</td>
            <td>{r.comment_text ?? "—"}</td>
            <td>
              {r.complaint_risk_tier
                ? <span className={`badge ${r.complaint_risk_tier === "high" ? "alert" : "neutral"}`}>{r.complaint_risk_tier}{r.complaint_risk_category ? ` · ${r.complaint_risk_category}` : ""}</span>
                : "—"}
            </td>
            <td>{r.agent_id ?? "—"}</td>
            <td>
              {r.account_number && (
                <button type="button" className="link-button" onClick={() => onJumpToSubject({ kind: "customer", accountNumber: r.account_number as string })}>
                  Open profile →
                </button>
              )}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export function CsatView({ onJumpToSubject }: { onJumpToSubject: (subject: InspectorSubject) => void }) {
  const demoConfig = useC360Query<DemoConfigRow>("demo_config", {});
  const demoConfigRow = rows(demoConfig.data)[0];
  const asOfDate = demoConfigRow?.as_of_date ?? DEFAULT_AS_OF_DATE;
  const historyMonths = num(demoConfigRow?.history_months) ?? DEFAULT_HISTORY_MONTHS;

  // "recent12"/"prior12" split the display window into its trailing 12
  // months and the 12 months before that (config-driven from
  // demo_config's as_of_date/history_months).
  const rangeBounds = useMemo<Record<TimeRange, [string, string]>>(() => {
    const windowStart = addDays(addMonths(asOfDate, -historyMonths), 1);
    const midpoint = addMonths(asOfDate, -12);
    return {
      all: [windowStart, asOfDate],
      recent12: [addDays(midpoint, 1), asOfDate],
      prior12: [windowStart, midpoint],
    };
  }, [asOfDate, historyMonths]);

  const [range, setRange] = useState<TimeRange>("all");
  const [segment, setSegment] = useState<Segment>("all");
  const [dateFrom, dateTo] = rangeBounds[range];

  const scopedParams = useMemo(
    () => ({ date_from: sql.string(dateFrom), date_to: sql.string(dateTo), segment: sql.string(segment) }),
    [dateFrom, dateTo, segment],
  );
  const unscopedParams = useMemo(
    () => ({ date_from: sql.string(dateFrom), date_to: sql.string(dateTo) }),
    [dateFrom, dateTo],
  );

  const kpis = useC360Query<KpiRow>("csat_kpis", scopedParams);
  const trend = useC360Query<TrendRow>("csat_trend", scopedParams);
  const channel = useC360Query<ChannelRow>("csat_by_channel", scopedParams);
  const journey = useC360Query<JourneyRow>("csat_by_journey", scopedParams);
  const segments = useC360Query<SegmentRow>("csat_by_segment", unscopedParams);
  const drivers = useC360Query<DriverRow>("csat_drivers", scopedParams);
  const correlation = useC360Query<CorrelationRow>("csat_operational_correlation", scopedParams);
  const surveyHealth = useC360Query<SurveyHealthRow>("csat_survey_health", scopedParams);
  const verbatims = useC360Query<VerbatimRow>("csat_verbatims", scopedParams);
  const followup = useC360Query<FollowupRow>("csat_followup_queue", scopedParams);

  const k = rows(kpis.data)[0];
  const trendData = rows(trend.data).map((r) => ({
    year_month: r.year_month,
    top2box: num(r.top2box_pct),
    target: num(r.csat_target),
  }));

  const driverRows = rows(drivers.data);

  const outageRows = rows(correlation.data)
    .filter((r) => r.driver_type === "outage_exposure")
    .slice()
    .sort((a, b) => a.bucket_order - b.bucket_order)
    .map((r) => ({ bucket: r.bucket, nps_score: num(r.nps_score) }));
  const billShockRows = rows(correlation.data)
    .filter((r) => r.driver_type === "bill_shock")
    .slice()
    .sort((a, b) => a.bucket_order - b.bucket_order)
    .map((r) => ({ bucket: r.bucket, top2box_pct: num(r.top2box_pct) }));

  const healthRows = rows(surveyHealth.data);
  const volumeRows = healthRows.filter((r) => r.metric_type === "volume");
  const rateRows = healthRows
    .filter((r) => r.metric_type === "response_rate")
    .slice()
    .sort((a, b) => a.period_order - b.period_order);
  const volumePeriods = Array.from(new Set(volumeRows.map((r) => r.period_label))).sort();
  const volumeChartData = volumePeriods.map((period) => {
    const row: Record<string, string | number> = { period_label: period };
    for (const r of volumeRows.filter((v) => v.period_label === period)) {
      row[r.survey_type ?? "unknown"] = num(r.n) ?? 0;
    }
    return row;
  });

  const verbatimRows = rows(verbatims.data);
  const followupRows = rows(followup.data);

  return (
    <div className="csat-view">
      <div className="csat-view-head">
        <h1>Customer Satisfaction &amp; Experience</h1>
      </div>

      <div className="data-model-toolbar">
        <span className="data-model-field">
          <span>Period</span>
          <select value={range} onChange={(e) => setRange(e.target.value as TimeRange)}>
            <option value="all">{rangeBounds.all[0]} – {rangeBounds.all[1]} (all)</option>
            <option value="recent12">{rangeBounds.recent12[0]} – {rangeBounds.recent12[1]}</option>
            <option value="prior12">{rangeBounds.prior12[0]} – {rangeBounds.prior12[1]}</option>
          </select>
        </span>
        <span className="data-model-field">
          <span>Segment</span>
          <select value={segment} onChange={(e) => setSegment(e.target.value as Segment)}>
            <option value="all">All customers</option>
            <option value="residential">Residential</option>
            <option value="commercial">Commercial</option>
          </select>
        </span>
      </div>

      <Tabs defaultValue="overview" className="csat-tabs">
        <TabsList>
          <TabsTrigger value="overview">Overview</TabsTrigger>
          <TabsTrigger value="drivers">Drivers &amp; Follow-up</TabsTrigger>
          <TabsTrigger value="voice">Voice of Customer</TabsTrigger>
        </TabsList>
        <TabsContent value="overview">

      <div className="card">
        <h2>Companion Metrics</h2>
        {kpis.loading && !k && <div className="loading">Loading…</div>}
        {kpis.error && <div className="error">{String(kpis.error)}</div>}
        {k && (
          <>
            <div className="csat-kpi-band">
              <KpiTile
                label="CSAT (top-2-box)"
                value={fmt1(k.csat_top2box_pct, "%")}
                sub={`mean ${fmt1(k.csat_mean, "/5")} · n=${k.csat_n}`}
                target={num(k.csat_target) != null ? fmt1(k.csat_target, "%") : null}
                tone={toneVsTarget(num(k.csat_top2box_pct), num(k.csat_target), true)}
              />
              <KpiTile
                label="NPS"
                value={fmt1(k.nps_score)}
                sub={`n=${k.nps_n}`}
                target={num(k.nps_target) != null ? fmt1(k.nps_target) : null}
                tone={toneVsTarget(num(k.nps_score), num(k.nps_target), true)}
              />
              <KpiTile
                label="FCR"
                value={fmt1(k.fcr_pct, "%")}
                sub={`n=${k.fcr_n}`}
                target={num(k.fcr_target) != null ? fmt1(k.fcr_target, "%") : null}
                tone={toneVsTarget(num(k.fcr_pct), num(k.fcr_target), true)}
              />
              <KpiTile
                label="AHT"
                value={fmtSeconds(k.aht_seconds)}
                sub="avg handle time (m:ss)"
                target={num(k.aht_target) != null ? fmtSeconds(k.aht_target) : null}
                tone={toneVsTarget(num(k.aht_seconds), num(k.aht_target), false)}
              />
            </div>
            {(num(k.csat_jdpower) != null || num(k.csat_acsi) != null) && (
              <p className="subtle" style={{ marginTop: 10 }}>
                External CSAT benchmarks — J.D. Power: {fmt1(k.csat_jdpower)} · ACSI: {fmt1(k.csat_acsi)}
              </p>
            )}
          </>
        )}
      </div>

      <div className="card">
        <h2>CSAT Trend</h2>
        {trend.loading && <div className="loading">Loading…</div>}
        {!trend.loading && trendData.length > 0 && (
          <div style={{ width: "100%", height: 240 }}>
            <ResponsiveContainer>
              <LineChart data={trendData} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="year_month" tick={{ fontSize: 10 }} />
                <YAxis tick={{ fontSize: 10 }} domain={[0, 100]} />
                <Tooltip cursor={{ fill: "var(--panel-2)" }} />
                <Legend wrapperStyle={{ fontSize: 11, paddingTop: 4 }} />
                <Line name="Top-2-box CSAT %" type="monotone" dataKey="top2box" stroke="var(--chart-1)" strokeWidth={2} dot={{ r: 2 }} />
                <Line name="Target" type="monotone" dataKey="target" stroke="var(--accent)" strokeWidth={1.5} strokeDasharray="4 3" dot={false} />
              </LineChart>
            </ResponsiveContainer>
          </div>
        )}
        {!trend.loading && trendData.length === 0 && <div className="empty-state">No responses in this period.</div>}
      </div>

      <div className="card">
        <h2>CSAT by Channel</h2>
        <p className="csat-honest-note">
          Contact-center channels only (voice / chat / email / sms) — web, app, and field-service
          touchpoints aren't instrumented yet.
        </p>
        {channel.loading && <div className="loading">Loading…</div>}
        {!channel.loading && rows(channel.data).length > 0 && (
          <div style={{ width: "100%", height: 220 }}>
            <ResponsiveContainer>
              <BarChart data={rows(channel.data)} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="media_type" tick={{ fontSize: 11 }} />
                <YAxis tick={{ fontSize: 10 }} domain={[0, 100]} />
                <Tooltip cursor={{ fill: "var(--panel-2)" }} />
                <Bar name="Top-2-box CSAT %" dataKey="top2box_pct" fill="var(--chart-1)" />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
        {!channel.loading && rows(channel.data).length === 0 && <div className="empty-state">No data.</div>}
      </div>

      <div className="card">
        <h2>CSAT by Journey / Transaction Type</h2>
        {journey.loading && <div className="loading">Loading…</div>}
        {!journey.loading && rows(journey.data).length > 0 && (
          <div style={{ width: "100%", height: 260 }}>
            <ResponsiveContainer>
              <BarChart data={rows(journey.data)} layout="vertical" margin={{ top: 8, right: 24, bottom: 0, left: 8 }}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis type="number" domain={[0, 100]} tick={{ fontSize: 10 }} />
                <YAxis type="category" dataKey="journey" width={140} tick={{ fontSize: 11 }} />
                <Tooltip cursor={{ fill: "var(--panel-2)" }} />
                <Bar name="Top-2-box CSAT %" dataKey="top2box_pct" fill="var(--chart-2)" />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
        {!journey.loading && rows(journey.data).length === 0 && <div className="empty-state">No data.</div>}
      </div>

      <div className="card">
        <h2>Segmentation</h2>
        {segments.loading && <div className="loading">Loading…</div>}
        {!segments.loading && rows(segments.data).length > 0 && <SegmentBreakdown rows={rows(segments.data)} />}
        {!segments.loading && rows(segments.data).length === 0 && <div className="empty-state">No data.</div>}
      </div>

        </TabsContent>
        <TabsContent value="drivers">

      <div className="card">
        <h2>Driver Analysis</h2>
        <p className="csat-honest-note">
          What moves the score: full-population cuts by wait time, transfers, and first-call
          resolution, plus SQM sub-score correlation (empathy/knowledge/greeting) on the 5% QA-sampled
          call slice.
        </p>
        {drivers.loading && <div className="loading">Loading…</div>}
        {!drivers.loading && driverRows.length > 0 && (
          <>
            <DriverBreakdown rows={driverRows} />
            <SqmSubscoreBreakdown rows={driverRows} />
          </>
        )}
        {!drivers.loading && driverRows.length === 0 && <div className="empty-state">No data.</div>}
      </div>

      <div className="card">
        <h2>Operational Correlation</h2>
        {correlation.loading && <div className="loading">Loading…</div>}
        {!correlation.loading && (outageRows.length > 0 || billShockRows.length > 0) && (
          <div className="csat-correlation-grid">
            <div>
              <h3>NPS vs. Recent Outage Exposure</h3>
              <div style={{ width: "100%", height: 200 }}>
                <ResponsiveContainer>
                  <BarChart data={outageRows} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
                    <CartesianGrid strokeDasharray="3 3" />
                    <XAxis dataKey="bucket" tick={{ fontSize: 10 }} />
                    <YAxis tick={{ fontSize: 10 }} />
                    <Tooltip cursor={{ fill: "var(--panel-2)" }} />
                    <Bar name="NPS Score" dataKey="nps_score" fill="var(--chart-1)" />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>
            <div>
              <h3>CSAT vs. Bill Shock (nearest bill)</h3>
              <div style={{ width: "100%", height: 200 }}>
                <ResponsiveContainer>
                  <BarChart data={billShockRows} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
                    <CartesianGrid strokeDasharray="3 3" />
                    <XAxis dataKey="bucket" tick={{ fontSize: 10 }} />
                    <YAxis tick={{ fontSize: 10 }} domain={[0, 100]} />
                    <Tooltip cursor={{ fill: "var(--panel-2)" }} />
                    <Bar name="Top-2-box CSAT %" dataKey="top2box_pct" fill="var(--chart-2)" />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>
          </div>
        )}
        {!correlation.loading && outageRows.length === 0 && billShockRows.length === 0 && (
          <div className="empty-state">No data.</div>
        )}
      </div>

      <div className="card">
        <h2>Survey Health</h2>
        <p className="csat-honest-note">
          Response volume by survey type. Response rate is shown for NPS quarterly surveys only —
          CSAT and SQM have no invited/declined population modeled, so their volume is shown without
          an implied rate.
        </p>
        {surveyHealth.loading && <div className="loading">Loading…</div>}
        {!surveyHealth.loading && volumeChartData.length > 0 && (
          <div style={{ width: "100%", height: 220 }}>
            <ResponsiveContainer>
              <BarChart data={volumeChartData} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="period_label" tick={{ fontSize: 10 }} />
                <YAxis tick={{ fontSize: 10 }} />
                <Tooltip cursor={{ fill: "var(--panel-2)" }} />
                <Legend wrapperStyle={{ fontSize: 11, paddingTop: 4 }} />
                <Bar name={SURVEY_TYPE_LABELS.nps_relationship} dataKey="nps_relationship" stackId="vol" fill="var(--chart-1)" />
                <Bar name={SURVEY_TYPE_LABELS.csat_transactional} dataKey="csat_transactional" stackId="vol" fill="var(--chart-2)" />
                <Bar name={SURVEY_TYPE_LABELS.sqm_call_evaluation} dataKey="sqm_call_evaluation" stackId="vol" fill="var(--chart-3)" />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
        {!surveyHealth.loading && volumeChartData.length === 0 && <div className="empty-state">No data.</div>}

        {rateRows.length > 0 && (
          <table className="csat-health-table">
            <thead>
              <tr>
                <th>Survey</th>
                <th>Launch period</th>
                <th>Invited</th>
                <th>Responded</th>
                <th>Response rate</th>
              </tr>
            </thead>
            <tbody>
              {rateRows.map((r) => (
                <tr key={r.survey_id}>
                  <td>{r.survey_id}</td>
                  <td>{r.period_label}</td>
                  <td>{r.n_invited}</td>
                  <td>{r.n_responded}</td>
                  <td>{fmt1(r.response_rate_pct, "%")}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

        </TabsContent>
        <TabsContent value="voice">

      <div className="card">
        <h2>Voice of Customer</h2>
        <p className="csat-honest-note">
          Open-ended NPS comments (~5% of NPS responses generate one; CSAT/SQM don't). Theme tags via
          ai_classify against the same category taxonomy the complaint dashboards use.
        </p>
        {verbatims.loading && <div className="loading">Loading…</div>}
        {!verbatims.loading && <ThemeFrequency rows={verbatimRows} />}
        {!verbatims.loading && <VerbatimFeed rows={verbatimRows} onJumpToSubject={onJumpToSubject} />}
      </div>

      <div className="card">
        <h2>Closed-Loop Follow-up Queue</h2>
        <p className="csat-honest-note">
          Detractor-scored responses (NPS ≤6, CSAT 1-2/5, SQM &lt;60), predicted 30-day complaint risk
          shown inline — a detractor who is also flagged high-risk is the priority call-back.
        </p>
        {followup.loading && <div className="loading">Loading…</div>}
        {!followup.loading && <FollowupQueue rows={followupRows} onJumpToSubject={onJumpToSubject} />}
      </div>

        </TabsContent>
      </Tabs>
    </div>
  );
}
