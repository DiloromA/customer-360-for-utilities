// "Ask the Map" — a custom AppKit plugin exposing POST /api/genie/ask.
//
// It proxies the Databricks Genie Conversation API: each call either starts a
// conversation or continues one (multi-turn, so "of those customers…" narrows
// the prior answer), waits for the answer, and returns the `customer_id`s in
// the result. The Executive map intersects those ids with the customer dots it
// already holds to render the narrowed population.
//
// Auth: runs as the app's service principal — resolveToken() in ./dbx PREFERS
// the SP's `all-apis` OAuth token (which the Genie API requires) and only falls
// back to the forwarded user token, so map reads are SP-scoped. In local dev
// there's no SP or forwarded header — set DATABRICKS_HOST + DATABRICKS_TOKEN
// (e.g. `databricks auth token`) when running `npm run dev`.

import { Plugin, toPlugin, type IAppRouter } from "@databricks/appkit";
import type { Request, Response } from "express";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { resolveHost, resolveToken, runStatement, resolveCatalog, resolveSchema, sleep } from "./dbx";

const POLL_INTERVAL_MS = 1500;
const POLL_TIMEOUT_MS = 90_000;
const GENIE_ROW_CAP = 5000; // Genie's default query-result cap

// Hard cap on a client-supplied /points `limit` — keep in sync with
// POINTS_LIMIT in client/src/mapConstants.ts (the client requests this flat
// limit at every zoom). Sized to stay comfortably under the Statement
// Execution API's ~25 MiB INLINE disposition ceiling.
const POINTS_HARD_CAP = 35000;

// ── Reusing the analytics .sql files on the warehouse-direct path ──────────
// The exec_map_cells / exec_map_program_cells choropleth queries are also
// registered with AppKit's analytics() plugin, but that SSE transport caps a
// response at ~1 MB (see dbx.ts). At fine H3 resolution a viewport can hold
// 20k+ cells (several MB), so the analytics path silently truncates and the
// map keeps showing the last coarse grid. We instead run the SAME .sql files
// here via the Statement Execution API (no cap), inlining the :params after
// sanitizing them. The files live in config/queries/ and are copied into the
// deploy tree (see scripts/stage-deploy.sh). Their {{catalog}}/{{schema}}
// tokens are already substituted on disk at container startup by the app.yml
// launch command, so only the :params remain to fill here.
const QUERY_CACHE = new Map<string, string>();
const schema = resolveSchema();
function loadQuery(name: string): string {
  let sql = QUERY_CACHE.get(name);
  if (sql === undefined) {
    sql = readFileSync(join(process.cwd(), "config", "queries", `${name}.sql`), "utf8");
    QUERY_CACHE.set(name, sql);
  }
  return sql;
}

// SQL single-quoted string literal (doubles embedded quotes).
function sqlStr(v: string): string {
  return `'${v.replace(/'/g, "''")}'`;
}

// Replace each `:name` placeholder (word-boundary terminated, so `:east` never
// matches inside another token) with an already-built, already-sanitized raw
// SQL fragment.
function fillParams(sql: string, raws: Record<string, string>): string {
  let out = sql;
  for (const [name, raw] of Object.entries(raws)) {
    out = out.replace(new RegExp(`:${name}\\b`, "g"), raw);
  }
  return out;
}

// Filter comma-lists are inlined as string literals inside split(...) / equality
// checks; allow only the characters those tokens can legitimately contain.
function sanitizeFilterList(s?: string): string {
  return (s ?? "").replace(/[^A-Za-z0-9 ,_-]/g, "");
}

class GeniePlugin extends Plugin {
  protected envVars: string[] = [];
  name = "genie";

  injectRoutes(router: IAppRouter): void {
    router.post("/ask", async (req: Request, res: Response) => {
      try {
        const { question, conversationId, bounds, filters, sessionId } = (req.body ?? {}) as {
          question?: string;
          conversationId?: string;
          bounds?: { south?: number; north?: number; west?: number; east?: number };
          filters?: { customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string };
          sessionId?: string;
        };
        if (!question || typeof question !== "string") {
          res.status(400).json({ error: "Missing 'question'." });
          return;
        }
        // Two layers of on-screen context get prepended to the question:
        //  1. The focus cohort (if active) as a LABELED SEGMENT that Genie
        //     defaults to, but can compare against / step outside of based on the
        //     question's own wording — no rigid scope mode.
        //  2. The viewport bounding box + active filters, so "these customers /
        //     this area / here" resolves to the slice the user is looking at.
        const catalog = resolveCatalog();
        const askQuestion =
          buildFocusContext(catalog, sessionId) + buildMapContext(bounds, filters) + question;
        const spaceId = process.env.DATABRICKS_GENIE_SPACE_ID;
        if (!spaceId) {
          res.status(500).json({ error: "DATABRICKS_GENIE_SPACE_ID is not configured." });
          return;
        }
        const host = resolveHost();
        const token = await resolveToken(req, host);
        if (!host || !token) {
          res.status(500).json({
            error: "Workspace auth unavailable. In local dev set DATABRICKS_HOST and DATABRICKS_TOKEN.",
          });
          return;
        }
        const result = await askGenie({ host, token, spaceId, question: askQuestion, conversationId });
        // Enrich the matched ids with positions + attributes here (the route
        // has no AppKit param/event size caps), so the client can render dots
        // without shipping the whole territory or a giant id parameter.
        if (result.customerIds.length > 0) {
          const warehouseId = process.env.DATABRICKS_WAREHOUSE_ID;
          const catalog = resolveCatalog();
          result.customers = await enrichCustomers({ host, token, warehouseId, catalog, ids: result.customerIds });
        }
        res.json(result);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[genie/ask] error:", msg);
        res.status(500).json({ error: msg });
      }
    });

    // Viewport customer points, straight from the warehouse (no 1 MB cap).
    router.post("/points", async (req: Request, res: Response) => {
      try {
        const b = (req.body ?? {}) as Record<string, unknown>;
        const host = resolveHost();
        const token = await resolveToken(req, host);
        if (!host || !token) {
          res.status(500).json({ error: "Workspace auth unavailable." });
          return;
        }
        const { customers, total, sampled } = await fetchMapPoints({
          host, token,
          warehouseId: process.env.DATABRICKS_WAREHOUSE_ID,
          catalog: resolveCatalog(),
          south: Number(b.south), north: Number(b.north),
          west: Number(b.west), east: Number(b.east),
          customerClasses: b.customerClasses as string | undefined,
          usageBands: b.usageBands as string | undefined,
          engagementTiers: b.engagementTiers as string | undefined,
          issueFlags: b.issueFlags as string | undefined,
          complaintTheme: b.complaint_theme as string | undefined,
          programId: b.program_id as string | undefined,
          sessionId: b.sessionId as string | undefined,
          limit: Number(b.limit) || 35000,
          sample: b.sample === "uniform" ? "uniform" : "attention",
        });
        res.json({ customers, count: customers.length, total, sampled });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[genie/points] error:", msg);
        res.status(500).json({ error: msg });
      }
    });

    // Choropleth cells for the viewport — warehouse-direct so fine resolutions
    // (20k+ cells) aren't truncated by AppKit's ~1 MB analytics cap.
    router.post("/cells", async (req: Request, res: Response) => {
      try {
        const b = (req.body ?? {}) as Record<string, unknown>;
        const host = resolveHost();
        const token = await resolveToken(req, host);
        if (!host || !token) {
          res.status(500).json({ error: "Workspace auth unavailable." });
          return;
        }
        const cells = await fetchMapCells({
          host, token,
          warehouseId: process.env.DATABRICKS_WAREHOUSE_ID,
          resolution: Number(b.resolution),
          south: Number(b.south), north: Number(b.north),
          west: Number(b.west), east: Number(b.east),
          customerClasses: b.customerClasses as string | undefined,
          usageBands: b.usageBands as string | undefined,
          engagementTiers: b.engagementTiers as string | undefined,
          issueFlags: b.issueFlags as string | undefined,
          complaintTheme: b.complaint_theme as string | undefined,
          sessionId: b.sessionId as string | undefined,
        });
        res.json({ cells, count: cells.length });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[genie/cells] error:", msg);
        res.status(500).json({ error: msg });
      }
    });

    // Program-layer choropleth cells (enrollment / underserved) — same cap-free
    // path as /cells, with a program_id.
    router.post("/program-cells", async (req: Request, res: Response) => {
      try {
        const b = (req.body ?? {}) as Record<string, unknown>;
        const host = resolveHost();
        const token = await resolveToken(req, host);
        if (!host || !token) {
          res.status(500).json({ error: "Workspace auth unavailable." });
          return;
        }
        const cells = await fetchMapProgramCells({
          host, token,
          warehouseId: process.env.DATABRICKS_WAREHOUSE_ID,
          programId: String(b.program_id ?? ""),
          resolution: Number(b.resolution),
          south: Number(b.south), north: Number(b.north),
          west: Number(b.west), east: Number(b.east),
          customerClasses: b.customerClasses as string | undefined,
          usageBands: b.usageBands as string | undefined,
          engagementTiers: b.engagementTiers as string | undefined,
          issueFlags: b.issueFlags as string | undefined,
        });
        res.json({ cells, count: cells.length });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[genie/program-cells] error:", msg);
        res.status(500).json({ error: msg });
      }
    });

    // Active outages (live) layer — per-H3-cell "% currently out" choropleth.
    // Warehouse-direct, same cap reasoning as /cells.
    router.post("/active-outage-cells", async (req: Request, res: Response) => {
      try {
        const b = (req.body ?? {}) as Record<string, unknown>;
        const host = resolveHost();
        const token = await resolveToken(req, host);
        if (!host || !token) {
          res.status(500).json({ error: "Workspace auth unavailable." });
          return;
        }
        const cells = await fetchActiveOutageCells({
          host, token,
          warehouseId: process.env.DATABRICKS_WAREHOUSE_ID,
          resolution: Number(b.resolution),
          south: Number(b.south), north: Number(b.north),
          west: Number(b.west), east: Number(b.east),
        });
        res.json({ cells, count: cells.length });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[genie/active-outage-cells] error:", msg);
        res.status(500).json({ error: msg });
      }
    });

    // Active outages (live) layer — currently-out customer dots for the viewport.
    router.post("/active-outage-points", async (req: Request, res: Response) => {
      try {
        const b = (req.body ?? {}) as Record<string, unknown>;
        const host = resolveHost();
        const token = await resolveToken(req, host);
        if (!host || !token) {
          res.status(500).json({ error: "Workspace auth unavailable." });
          return;
        }
        const points = await fetchActiveOutagePoints({
          host, token,
          warehouseId: process.env.DATABRICKS_WAREHOUSE_ID,
          south: Number(b.south), north: Number(b.north),
          west: Number(b.west), east: Number(b.east),
        });
        res.json({ points, count: points.length });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[genie/active-outage-points] error:", msg);
        res.status(500).json({ error: msg });
      }
    });

    // Focus-group analytics: counts, issue mix, segment mix, demographics,
    // property + load for the right rail. Driven by a session cohort
    // ({ sessionId } — any focus group, since hex/draw/attributes/words all
    // materialize into focus_set), an exact account-number set, a viewport box,
    // or — with an empty body — the whole territory (the default focus group).
    // Hits the warehouse directly (no AppKit size cap).
    router.post("/group", async (req: Request, res: Response) => {
      try {
        const b = (req.body ?? {}) as Record<string, unknown>;
        const host = resolveHost();
        const token = await resolveToken(req, host);
        if (!host || !token) {
          res.status(500).json({ error: "Workspace auth unavailable." });
          return;
        }
        const analytics = await fetchGroupAnalytics({
          host, token,
          warehouseId: process.env.DATABRICKS_WAREHOUSE_ID,
          catalog: resolveCatalog(),
          sessionId: b.sessionId as string | undefined,
          accountNumbers: Array.isArray(b.accountNumbers) ? (b.accountNumbers as unknown[]).map(String) : undefined,
          bounds: b.south != null ? {
            south: Number(b.south), north: Number(b.north),
            west: Number(b.west), east: Number(b.east),
          } : undefined,
          customerClasses: b.customerClasses as string | undefined,
          usageBands: b.usageBands as string | undefined,
          engagementTiers: b.engagementTiers as string | undefined,
          issueFlags: b.issueFlags as string | undefined,
        });
        res.json(analytics);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[genie/group] error:", msg);
        res.status(500).json({ error: msg });
      }
    });
  }

  getEndpoints() {
    return {
      ask: "/api/genie/ask", points: "/api/genie/points", group: "/api/genie/group",
      cells: "/api/genie/cells", programCells: "/api/genie/program-cells",
      activeOutageCells: "/api/genie/active-outage-cells",
      activeOutagePoints: "/api/genie/active-outage-points",
    };
  }
}

interface AskResult {
  conversationId?: string;
  messageId?: string;
  status: string;
  label: string;
  customerIds: string[];
  customers?: Record<string, unknown>[];
  count: number;
  totalRowCount: number;
  truncated: boolean;
  hasCustomerId: boolean;
  text?: string;
  sql?: string;
  // Result table (capped) so analytical / aggregate answers without a
  // customer_id column (e.g. "what are they complaining about") can still be
  // shown instead of being treated as an error.
  columns?: string[];
  rows?: (string | null)[][];
}

// Columns every customer-point query returns (dots + tooltip + selection
// panel). Assumes aliases a = dim_account, c = dim_customer, h3 = dim_premise_h3.
// The dot identity is the human account_number (the deep-link key); customer_id
// is carried only so "Ask the map" can match Genie's returned customer set.
// Per-customer "attention" score — the dot sort + sample ranking. Single source
// of truth, reused wherever a query needs it (assumes alias c = dim_customer).
const ATTENTION_SCORE = `CASE WHEN c.payment_stressed_flag THEN 4 ELSE 0 END
         + CASE WHEN c.churn_risk_band = 'high' THEN 3 ELSE 0 END
         + LEAST(c.recent_complaint_count_90d, 5)
         + CASE WHEN c.recent_outage_minutes_90d >= 180 THEN 2 ELSE 0 END
         + CASE WHEN c.critical_care_flag THEN 2 ELSE 0 END`;

const POINT_COLS = `a.account_number, h3.premise_number, c.customer_id, h3.latitude, h3.longitude, c.customer_class, c.usage_band,
       c.engagement_tier, c.payment_stressed_flag, c.high_user_flag, c.churn_risk_band,
       c.critical_care_flag, c.liheap_eligible, c.recent_complaint_count_90d,
       c.recent_outage_minutes_90d, c.digital_adoption_score,
       ROUND(100 * cr.p_complaint_30d, 1) AS complaint_risk_pct,
       cr.risk_tier AS complaint_risk_tier,
       cr.top_category AS complaint_risk_category,
       ( ${ATTENTION_SCORE} ) AS attention_score`;

// Every statement that selects POINT_COLS must include this join — the
// predicted 30-day complaint risk (ml_complaint_predictor, latest cycle per
// customer). LEFT JOIN so unscored customers still render as dots.
const POINT_RISK_JOIN = (catalog: string, schema: string) =>
  `\n    LEFT JOIN ${catalog}.${schema}.ml_complaint_risk_scores cr ON cr.customer_id = c.customer_id`;

// Genie session keys are uuid-ish; only inline safe chars into the preamble SQL.
const FOCUS_SESSION_RE = /^[A-Za-z0-9_-]+$/;

// Build a preamble describing the active focus cohort as a LABELED SEGMENT (not
// a hard filter), so a single conversation can default to the cohort yet still
// compare it against the territory or step outside it — driven entirely by the
// question's own wording (no UI scope mode). Returns "" when no cohort is set.
// The cohort is reached via the app schema's app_focus_set for this session_id,
// so Genie (running on the SQL warehouse) joins to exactly this session's customers.
function buildFocusContext(
  catalog: string,
  sessionId: string | undefined,
): string {
  if (!sessionId || !FOCUS_SESSION_RE.test(sessionId)) return "";
  const ref =
    `a focus cohort defined as the premises in \`${catalog}.${schema}.app_focus_set\` ` +
    `where \`session_id = '${sessionId}'\` (join focus_set.customer_id = dim_customer.customer_id; ` +
    `when \`focus_set.premise_id\` is not null, also join ` +
    `\`focus_set.premise_id = bridge_account_premise.premise_id\` — a spatial hex/box selection ` +
    `covers only that premise, not the customer's other premises)`;
  const directive =
    `There is ${ref}.\n` +
    `- "these" / "the cohort" / "this group" / "them" → restrict to the cohort (join on customer_id).\n` +
    `- "compare" / "vs territory" / "overall" / "baseline" → contrast the cohort against all ` +
    `customers, labeling both segments.\n` +
    `- a question that names a different population (or explicitly asks to ignore the ` +
    `focus) → answer at that scope instead.\n` +
    `- otherwise default to restricting to the cohort.`;
  return `[FOCUS COHORT — ${directive}]\n\n`;
}

// Build a natural-language preamble describing what the user is currently
// looking at on the map (viewport bounding box + active filters), so phrases
// like "these customers", "this area", "here" resolve to that slice. Returns
// "" when there's no usable context (Genie then behaves as before).
function buildMapContext(
  bounds: { south?: number; north?: number; west?: number; east?: number } | undefined,
  filters: { customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string } | undefined,
): string {
  const fin = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : null);
  const parts: string[] = [];
  const s = fin(bounds?.south), n = fin(bounds?.north), w = fin(bounds?.west), e = fin(bounds?.east);
  if (s != null && n != null && w != null && e != null) {
    parts.push(
      `The user is viewing a specific area of the map. Phrases like "these customers", ` +
        `"this area", "here", "the customers shown" and "on screen" refer to customers whose ` +
        `premise (reach dim_premise_h3 via the current account: dim_customer → dim_account on customer_id ` +
        `→ dim_premise_h3 on premise_id, with bridge_account_premise.is_current = true) is within latitude ${s.toFixed(5)} to ${n.toFixed(5)} ` +
        `and longitude ${w.toFixed(5)} to ${e.toFixed(5)}. Unless the user explicitly asks to broaden ` +
        `the scope, restrict the answer to customers inside that bounding box.`,
    );
  }
  const toList = (v: unknown) =>
    typeof v === "string" && v.trim() ? v.split(",").map((x) => x.trim()).filter(Boolean) : [];
  const fl: string[] = [];
  const classes = toList(filters?.customerClasses);
  if (classes.length) fl.push(`customer_class in (${classes.join(", ")})`);
  const usage = toList(filters?.usageBands);
  if (usage.length) fl.push(`usage_band in (${usage.join(", ")})`);
  const eng = toList(filters?.engagementTiers);
  if (eng.length) fl.push(`engagement_tier in (${eng.join(", ")})`);
  const flags = toList(filters?.issueFlags);
  if (flags.length) fl.push(`issue flags active: ${flags.join(", ")}`);
  if (fl.length) parts.push(`The map is also filtered to: ${fl.join("; ")}. Apply these as additional filters.`);

  return parts.length ? `[MAP CONTEXT — ${parts.join(" ")}]\n\n` : "";
}

// Sanitize a comma list to safe tokens (defends the inlined SQL below).
function sanitizeList(s: string | undefined): string[] {
  if (!s) return [];
  return s.split(",").map((t) => t.trim()).filter((t) => /^[A-Za-z0-9_ -]+$/.test(t));
}

// Build the shared multi-dim filter predicate (matches exec_map_cells.sql / filters.tsx).
// Exported so the focus plugin can turn the same attribute filters into a
// cohort-defining query. Returns a leading " AND …" (or "") for appending.
export function buildFilterSql(f: { customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string }): string {
  const clauses: string[] = [];
  const classes = sanitizeList(f.customerClasses);
  if (classes.length) clauses.push(`c.customer_class IN (${classes.map((v) => `'${v}'`).join(",")})`);
  const usage = sanitizeList(f.usageBands);
  if (usage.length) clauses.push(`c.usage_band IN (${usage.map((v) => `'${v}'`).join(",")})`);
  const eng = sanitizeList(f.engagementTiers);
  if (eng.length) clauses.push(`c.engagement_tier IN (${eng.map((v) => `'${v}'`).join(",")})`);
  const flags = sanitizeList(f.issueFlags);
  if (flags.length) {
    const fc: string[] = [];
    if (flags.includes("payment_stress")) fc.push("c.payment_stressed_flag");
    if (flags.includes("critical_care")) fc.push("c.critical_care_flag");
    if (flags.includes("churn_high")) fc.push("c.churn_risk_band = 'high'");
    if (flags.includes("frequent_outages")) fc.push("c.recent_outage_minutes_90d >= 180");
    if (flags.includes("liheap")) fc.push("c.liheap_eligible");
    if (flags.includes("high_complaints")) fc.push("c.recent_complaint_count_90d >= 2");
    if (fc.length) clauses.push(`(${fc.join(" OR ")})`);
  }
  return clauses.length ? " AND " + clauses.join(" AND ") : "";
}

// Per-program adoption columns for the map's program-adoption lens. When a
// program is selected the dots are colored binary (enrolled / not) rather than
// by a metric gradient, and cross-referenced against the DER signal the
// program targets (EV / heat pump / smart thermostat / solar — detected from
// the DER-adoption data fed by AMI), so the map can surface discrepancies:
//   is_enrolled — actively enrolled or completed in this program (customer-grain:
//                 enrollment is a customer relationship, not a per-site install)
//   has_der     — THIS premise has the DER device the program is about (the
//                 "detected" signal). Premise-grain — DER is a physical install
//                 on the premise, so a multi-site customer only lights up the
//                 dots for the sites that actually have the device, matching the
//                 CSR right rail. Always false when the program has no DER mapping.
function buildProgramAdoption(catalog: string, programId: string): {
  cte: string; cols: string; joins: string;
} {
  const cte = `
    WITH prog AS (
      SELECT program_id,
        CASE
          WHEN program_id IN ('PRG-EV-CHARGER','PRG-TOU-EV') OR program_name ILIKE '%EV%'         THEN 'EV'
          WHEN program_id IN ('PRG-HP-REBATE','PRG-HPWH')    OR program_name ILIKE '%heat pump%'  THEN 'HEAT_PUMP'
          WHEN program_id IN ('PRG-SMART-TSTAT','PRG-BYOT')  OR program_name ILIKE '%thermostat%' THEN 'SMART_TSTAT'
          WHEN program_name ILIKE '%solar%' OR program_name ILIKE '%PV%'                          THEN 'PV'
          ELSE NULL
        END AS der_device_type
      FROM ${catalog}.${schema}.dim_program
      WHERE program_id = '${programId}'
    ),
    enr AS (
      SELECT DISTINCT customer_id
      FROM ${catalog}.${schema}.fact_program_enrollment
      WHERE program_id = '${programId}' AND enrollment_status IN ('active', 'completed')
    ),
    det AS (
      SELECT DISTINCT d.premise_id
      FROM ${catalog}.${schema}.fact_der_adoption d
      JOIN prog p ON d.device_type = p.der_device_type
    )`;
  const cols = `,\n           (enr.customer_id IS NOT NULL) AS is_enrolled,\n           (det.premise_id IS NOT NULL) AS has_der`;
  const joins = `\n    LEFT JOIN enr ON enr.customer_id = c.customer_id\n    LEFT JOIN det ON det.premise_id = b.premise_id`;
  return { cte, cols, joins };
}

// Customer points within a viewport, fetched straight from the warehouse so
// there's no 1 MB cap — the map can show the full local population, not a cap.
// Returns the true in-viewport `total` (pre-LIMIT, via a windowed COUNT(*)
// piggybacked on the main query — one round trip) alongside the returned
// `customers`, so the client can tell the user when it's looking at a sample
// rather than silently truncating.
async function fetchMapPoints(args: {
  host: string; token: string; warehouseId?: string; catalog: string;
  south: number; north: number; west: number; east: number;
  customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string;
  complaintTheme?: string;
  programId?: string;
  sessionId?: string;
  limit: number;
  // "attention" (default) ranks by attention_score — the right bias for an
  // exec triage view. "uniform" is a deterministic spatial hash sample, for
  // when the caller is rendering a wide-area DENSITY view (forced dots at
  // low zoom) where an attention-ranked top-N would look like attention
  // clusters, not population.
  sample?: "attention" | "uniform";
}): Promise<{ customers: Record<string, unknown>[]; total: number; sampled: boolean }> {
  const { host, token, warehouseId, catalog } = args;
  if (!warehouseId) throw new Error("DATABRICKS_WAREHOUSE_ID not set.");
  if (![args.south, args.north, args.west, args.east].every((n) => Number.isFinite(n))) {
    throw new Error("Invalid bounds.");
  }
  const lim = Math.min(Math.max(1, Math.floor(args.limit) || 0), POINTS_HARD_CAP);
  // Program-adoption lens: only when a valid program id is supplied.
  const pid = args.programId && /^[A-Za-z0-9_-]+$/.test(args.programId) ? args.programId : undefined;
  const prog = pid ? buildProgramAdoption(catalog, pid) : { cte: "", cols: "", joins: "" };
  // Focus-set membership: when a session is supplied, LEFT JOIN the session's
  // cohort so each dot carries `in_focus` (server-side — no id list crosses the
  // wire, so it scales to tens of thousands of points). The client dims dots
  // that are not in_focus when a cohort is active.
  const sid = args.sessionId && /^[A-Za-z0-9_-]+$/.test(args.sessionId) ? args.sessionId : undefined;
  const focusCol = sid ? `,\n           (fs.customer_id IS NOT NULL) AS in_focus` : "";
  const focusJoin = sid
    ? `\n    LEFT JOIN ${catalog}.${schema}.app_focus_set fs ON fs.customer_id = c.customer_id AND fs.session_id = '${sid}'` +
      `\n      AND (fs.premise_id IS NULL OR fs.premise_id = b.premise_id)`
    : "";
  // Complaint-theme focus: filter the dots to customers with a complaint of the
  // selected sub-category, mirroring exec_map_cells so dots + cells agree.
  const theme = args.complaintTheme && /^[A-Za-z0-9_]+$/.test(args.complaintTheme) ? args.complaintTheme : undefined;
  const themeClause = theme
    ? ` AND EXISTS (SELECT 1 FROM ${catalog}.${schema}.fact_customer_complaints cc CROSS JOIN ${catalog}.${schema}.curated_demo_config cfg WHERE cc.customer_id = c.customer_id AND cc.sub_category = '${theme}' AND cc.complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date)`
    : "";
  const uniform = args.sample === "uniform";
  // Deterministic on account_number (stable across pans at the same density,
  // spatially uniform → honest density) — bucket sized off the SAME
  // windowed total_count every row already carries, so this needs no
  // separate round trip to learn the total first.
  const sampleClause = uniform
    ? `pmod(hash(account_number), GREATEST(1, CEIL(total_count / ${lim}))) = 0`
    : "1=1";
  const orderByClause = uniform ? "account_number" : "attention_score DESC, account_number";
  // One dot per occupied premise = the current billing link (bridge is_current)
  // → its account (identity) and the occupant's profile (signals). `candidates`
  // is every in-viewport match (pre-LIMIT); `counted` attaches the true total
  // to every row via a window function so LIMIT can truncate the OUTPUT while
  // the caller still learns how many rows existed before truncation.
  const withPrefix = prog.cte ? `${prog.cte},\n` : "WITH ";
  const statement = `${withPrefix}candidates AS (
    SELECT ${POINT_COLS}${prog.cols}${focusCol}
    FROM ${catalog}.${schema}.dim_premise_h3 h3
    JOIN ${catalog}.${schema}.bridge_account_premise b ON b.premise_id = h3.premise_id AND b.is_current
    JOIN ${catalog}.${schema}.dim_account a ON a.account_id = b.account_id
    JOIN ${catalog}.${schema}.dim_customer c ON c.customer_id = b.customer_id${POINT_RISK_JOIN(catalog, schema)}${prog.joins}${focusJoin}
    WHERE h3.latitude  BETWEEN ${args.south} AND ${args.north}
      AND h3.longitude BETWEEN ${args.west} AND ${args.east}${buildFilterSql(args)}${themeClause}
  ),
  counted AS (
    SELECT *, COUNT(*) OVER () AS total_count FROM candidates
  )
  SELECT * FROM counted
  WHERE ${sampleClause}
  ORDER BY ${orderByClause}
  LIMIT ${lim}`;
  const rows = await runStatement(host, token, warehouseId, statement);
  const total = rows.length > 0 ? Number(rows[0].total_count) || rows.length : 0;
  const customers = rows.map(({ total_count, ...rest }) => rest);
  return { customers, total, sampled: total > customers.length };
}

// Shared bound/resolution prep + the common :param raws for the two choropleth
// queries. Bounds are inlined raw (the SQL only ever wraps them in
// CAST(... AS DOUBLE), so a finite number is safe unquoted).
function cellParamRaws(args: {
  resolution: number;
  south: number; north: number; west: number; east: number;
  customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string;
}): Record<string, string> {
  if (![args.south, args.north, args.west, args.east].every((n) => Number.isFinite(n))) {
    throw new Error("Invalid bounds.");
  }
  const res = Math.min(9, Math.max(5, Math.floor(args.resolution) || 7));
  return {
    resolution: String(res),
    south: String(args.south), north: String(args.north),
    west: String(args.west), east: String(args.east),
    customer_classes: sqlStr(sanitizeFilterList(args.customerClasses)),
    usage_bands:      sqlStr(sanitizeFilterList(args.usageBands)),
    engagement_tiers: sqlStr(sanitizeFilterList(args.engagementTiers)),
    issue_flags:      sqlStr(sanitizeFilterList(args.issueFlags)),
  };
}

// Per-H3-cell choropleth metrics for the viewport — same query AppKit's
// analytics path runs, but warehouse-direct so fine resolutions (20k+ cells)
// aren't truncated by the ~1 MB SSE cap.
async function fetchMapCells(args: {
  host: string; token: string; warehouseId?: string;
  resolution: number;
  south: number; north: number; west: number; east: number;
  customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string;
  complaintTheme?: string;
  sessionId?: string;
}): Promise<Record<string, unknown>[]> {
  const { host, token, warehouseId } = args;
  if (!warehouseId) throw new Error("DATABRICKS_WAREHOUSE_ID not set.");
  const raws = cellParamRaws(args);
  raws.complaint_theme = sqlStr((args.complaintTheme ?? "").replace(/[^A-Za-z0-9_]/g, ""));
  // Scope the choropleth to the session's focus-group cohort (app_focus_set)
  // when one is active, so cells recolor to cohort-only aggregates.
  raws.session_id = sqlStr(args.sessionId && /^[A-Za-z0-9_-]+$/.test(args.sessionId) ? args.sessionId : "");
  return runStatement(host, token, warehouseId, fillParams(loadQuery("exec_map_cells"), raws));
}

// Per-cell metrics for a single program (enrollment / underserved layers).
async function fetchMapProgramCells(args: {
  host: string; token: string; warehouseId?: string;
  programId: string;
  resolution: number;
  south: number; north: number; west: number; east: number;
  customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string;
}): Promise<Record<string, unknown>[]> {
  const { host, token, warehouseId } = args;
  if (!warehouseId) throw new Error("DATABRICKS_WAREHOUSE_ID not set.");
  if (!/^[A-Za-z0-9_-]+$/.test(args.programId)) throw new Error("Invalid program_id.");
  const raws = cellParamRaws(args);
  raws.program_id = sqlStr(args.programId);
  return runStatement(host, token, warehouseId, fillParams(loadQuery("exec_map_program_cells"), raws));
}

// Per-H3-cell "currently out of power" metrics for the Active outages (live)
// layer. Warehouse-direct (same cap reasoning as fetchMapCells).
async function fetchActiveOutageCells(args: {
  host: string; token: string; warehouseId?: string;
  resolution: number;
  south: number; north: number; west: number; east: number;
}): Promise<Record<string, unknown>[]> {
  const { host, token, warehouseId } = args;
  if (!warehouseId) throw new Error("DATABRICKS_WAREHOUSE_ID not set.");
  const raws = cellParamRaws(args);
  return runStatement(host, token, warehouseId, fillParams(loadQuery("exec_map_active_outage_cells"), raws));
}

// Currently-out customer dots for the viewport (Active outages layer).
async function fetchActiveOutagePoints(args: {
  host: string; token: string; warehouseId?: string;
  south: number; north: number; west: number; east: number;
}): Promise<Record<string, unknown>[]> {
  const { host, token, warehouseId } = args;
  if (!warehouseId) throw new Error("DATABRICKS_WAREHOUSE_ID not set.");
  if (![args.south, args.north, args.west, args.east].every((n) => Number.isFinite(n))) {
    throw new Error("Invalid bounds.");
  }
  const raws: Record<string, string> = {
    south: String(args.south), north: String(args.north),
    west: String(args.west), east: String(args.east),
  };
  return runStatement(host, token, warehouseId, fillParams(loadQuery("exec_active_outage_points"), raws));
}

interface GroupDistBucket { bucket: string; n: number; }
// A small per-customer row for the rail's "Customers" list (top by attention).
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
  // The owning party of this row's premise, if any (bridge_premise_owner)
  // — the drill target when the rail's unit toggle is set to "owner".
  owner_number: string | null;
  owner_display_name: string | null;
}
interface GroupAnalytics {
  n: number;        // grp rows — the denominator for issue/segment prevalence
  total: number;    // current service locations — the headline count (premise grain, matches map/KPIs)
  distinctCustomers: number; // same cohort at customer grain — multi-site customers collapse to one (entity-grain §4.4)
  // Same cohort at owner grain (entity-grain §4.4/§6.4) — a chain or
  // landlord's premises collapse to one owner.
  distinctOwners: number;
  residential: number;
  commercial: number;
  truncated: boolean;
  issues: {
    payment_stressed: number; churn_high: number; critical_care: number;
    liheap: number; complaints_2plus: number; heavy_outages: number;
    total_complaints_90d: number; avg_digital_adoption: number; avg_outage_min: number;
  };
  load: { groupKwh: number | null; territoryKwh: number | null; groupPeerP75: number | null };
  distributions: Record<string, GroupDistBucket[]>;
  themes: { sub_category: string; n: number }[];
  sample: GroupSampleRow[];
}

// Cap on inlined account numbers — a drawn group can be large; beyond this the
// distributions are still representative and we flag `truncated`.
const GROUP_ACCOUNT_CAP = 10000;

// Demographic + property distributions and load averages for a customer group,
// benchmarked against the whole-territory load average. The group is the exact
// account-number set when supplied (a box/lasso or Ask-the-map result), else
// the viewport bounds+filters slice. All aliases match the rest of this module:
// a = dim_account, c = dim_customer, p = dim_premise.
async function fetchGroupAnalytics(args: {
  host: string; token: string; warehouseId?: string; catalog: string;
  sessionId?: string;
  accountNumbers?: string[];
  bounds?: { south: number; north: number; west: number; east: number };
  customerClasses?: string; usageBands?: string; engagementTiers?: string; issueFlags?: string;
}): Promise<GroupAnalytics> {
  const { host, token, warehouseId, catalog } = args;
  if (!warehouseId) throw new Error("DATABRICKS_WAREHOUSE_ID not set.");
  const cc = `${catalog}.${schema}`;

  // Build the cohort's FROM…WHERE. Every mode exposes a/c/p (and restricts to the
  // current occupant per premise via bridge is_current). The cohort is whichever
  // way the user defined the focus group, in precedence: an explicit session
  // cohort (focus_set) → an account-number set → a viewport box → else the whole
  // territory (the default focus group when nothing is selected).
  let source: string;
  let truncated = false;
  const sid = args.sessionId && FOCUS_SESSION_RE.test(args.sessionId) ? args.sessionId : undefined;
  const safeAccts = (args.accountNumbers ?? []).filter((id) => /^[A-Za-z0-9_-]+$/.test(id));
  if (sid) {
    // Any focus cohort (hex / draw / attributes / words) — all materialize into
    // focus_set, so analytics is uniform regardless of how it was defined.
    source = `
      FROM ${catalog}.${schema}.app_focus_set fs
      JOIN ${cc}.bridge_account_premise b ON b.customer_id = fs.customer_id AND b.is_current
        AND (fs.premise_id IS NULL OR fs.premise_id = b.premise_id)
      JOIN ${cc}.dim_account a ON a.account_id = b.account_id
      JOIN ${cc}.dim_customer c ON c.customer_id = b.customer_id
      JOIN ${cc}.dim_premise p ON p.premise_id = b.premise_id
      WHERE fs.session_id = '${sid}'`;
  } else if (safeAccts.length > 0) {
    truncated = safeAccts.length > GROUP_ACCOUNT_CAP;
    const inList = safeAccts.slice(0, GROUP_ACCOUNT_CAP).map((id) => `'${id}'`).join(",");
    source = `
      FROM ${cc}.dim_account a
      JOIN ${cc}.bridge_account_premise b ON b.account_id = a.account_id AND b.is_current
      JOIN ${cc}.dim_customer c ON c.customer_id = b.customer_id
      JOIN ${cc}.dim_premise p ON p.premise_id = b.premise_id
      WHERE a.account_number IN (${inList})`;
  } else if (args.bounds && [args.bounds.south, args.bounds.north, args.bounds.west, args.bounds.east].every(Number.isFinite)) {
    const bn = args.bounds;
    source = `
      FROM ${cc}.dim_premise_h3 h3
      JOIN ${cc}.bridge_account_premise b ON b.premise_id = h3.premise_id AND b.is_current
      JOIN ${cc}.dim_account a ON a.account_id = b.account_id
      JOIN ${cc}.dim_customer c ON c.customer_id = b.customer_id
      JOIN ${cc}.dim_premise p ON p.premise_id = b.premise_id
      WHERE h3.latitude BETWEEN ${bn.south} AND ${bn.north}
        AND h3.longitude BETWEEN ${bn.west} AND ${bn.east}${buildFilterSql(args)}`;
  } else {
    // Territory default — the whole service territory (the implicit focus
    // group), narrowed by any live attribute filters (nActiveFilters > 0 with
    // no cohort active — see the top-bar filter chip) so the rail agrees with
    // the map's filtered-but-no-cohort state instead of always reporting
    // whole-territory numbers.
    source = `
      FROM ${cc}.bridge_account_premise b
      JOIN ${cc}.dim_account a ON a.account_id = b.account_id
      JOIN ${cc}.dim_customer c ON c.customer_id = b.customer_id
      JOIN ${cc}.dim_premise p ON p.premise_id = b.premise_id
      WHERE b.is_current${buildFilterSql(args)}`;
  }

  // One categorical breakdown per UNION member. COALESCE blanks → 'Unknown'
  // (commercial customers carry no household demographics). The first four dims
  // are the segment mix (class/usage/engagement/dissatisfaction); the rest are
  // demographics + property. vintage bands the build year.
  const distSql = `
    WITH grp AS (
      SELECT c.customer_class, c.usage_band, c.engagement_tier, c.churn_risk_band,
             c.income_band, c.age_band_hoh, c.household_size, a.account_tenure_band,
             p.building_subtype, p.heating_fuel, p.envelope_quality, p.year_built
      ${source}
    )
    SELECT 'customer_class' AS dim, COALESCE(CAST(customer_class AS STRING), 'Unknown') AS bucket, COUNT(*) AS n FROM grp GROUP BY 2
    UNION ALL SELECT 'usage_band', COALESCE(CAST(usage_band AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'engagement_tier', COALESCE(CAST(engagement_tier AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'churn_risk_band', COALESCE(CAST(churn_risk_band AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'income_band', COALESCE(CAST(income_band AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'age_band_hoh', COALESCE(CAST(age_band_hoh AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'household_size', CASE WHEN household_size IS NULL THEN 'Unknown' WHEN household_size >= 5 THEN '5+' ELSE CAST(household_size AS STRING) END, COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'account_tenure_band', COALESCE(CAST(account_tenure_band AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'building_subtype', COALESCE(CAST(building_subtype AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'heating_fuel', COALESCE(CAST(heating_fuel AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'envelope_quality', COALESCE(CAST(envelope_quality AS STRING), 'Unknown'), COUNT(*) FROM grp GROUP BY 2
    UNION ALL SELECT 'vintage', CASE WHEN year_built IS NULL THEN 'Unknown' WHEN year_built < 1950 THEN 'Pre-1950' WHEN year_built < 1980 THEN '1950–79' WHEN year_built < 2000 THEN '1980–99' WHEN year_built < 2010 THEN '2000–09' ELSE '2010+' END, COUNT(*) FROM grp GROUP BY 2`;

  // Headline counts + issue-mix tallies + load, in one scalar row. `total` is
  // the count of current service locations (premise grain — the headline), the
  // same unit the map cells, dots, KPI bar, and the residential/commercial split
  // all use, so every view agrees. Anchoring to locations (not distinct
  // customer_id) is deliberate: a multi-site commercial customer legitimately
  // occupies several current premises, and each is plotted on the map — so the
  // headline must match that grain (else "1 customer / 4 commercial"). `n`
  // (= grp rows) is the denominator issue/segment prevalence is computed against
  // on the client (identical to total here). `distinct_customers` is the same
  // cohort at customer grain, exposed alongside so the client can label both
  // units explicitly (entity-grain §4.4) instead of picking one silently.
  const aggSql = `
    WITH base AS (
      SELECT c.customer_id, c.customer_class, c.payment_stressed_flag, c.churn_risk_band,
             c.critical_care_flag, c.liheap_eligible, c.recent_complaint_count_90d,
             c.recent_outage_minutes_90d, c.digital_adoption_score,
             c.avg_monthly_kwh_12mo, c.peer_p75_avg_monthly_kwh, p.premise_id
      ${source}
    ),
    grp AS (
      SELECT base.*, bpo.party_id AS owner_party_id
      FROM base
      LEFT JOIN ${cc}.bridge_premise_owner bpo ON bpo.premise_id = base.premise_id AND bpo.is_current
    ),
    agg AS (
      SELECT COUNT(*) AS n,
             COUNT(*) AS total,
             COUNT(DISTINCT customer_id) AS distinct_customers,
             COUNT(DISTINCT owner_party_id) AS distinct_owners,
             SUM(CASE WHEN customer_class = 'Residential' THEN 1 ELSE 0 END) AS residential,
             SUM(CASE WHEN customer_class = 'Commercial'  THEN 1 ELSE 0 END) AS commercial,
             SUM(CASE WHEN payment_stressed_flag THEN 1 ELSE 0 END) AS payment_stressed,
             SUM(CASE WHEN churn_risk_band = 'high' THEN 1 ELSE 0 END) AS churn_high,
             SUM(CASE WHEN critical_care_flag THEN 1 ELSE 0 END) AS critical_care,
             SUM(CASE WHEN liheap_eligible THEN 1 ELSE 0 END) AS liheap,
             SUM(CASE WHEN recent_complaint_count_90d >= 2 THEN 1 ELSE 0 END) AS complaints_2plus,
             SUM(CASE WHEN recent_outage_minutes_90d >= 180 THEN 1 ELSE 0 END) AS heavy_outages,
             SUM(recent_complaint_count_90d)            AS total_complaints_90d,
             ROUND(AVG(digital_adoption_score))         AS avg_digital_adoption,
             ROUND(AVG(recent_outage_minutes_90d))      AS avg_outage_min,
             ROUND(AVG(avg_monthly_kwh_12mo))           AS group_kwh,
             ROUND(AVG(peer_p75_avg_monthly_kwh))       AS group_peer_p75
      FROM grp
    ),
    terr AS (
      SELECT ROUND(AVG(c.avg_monthly_kwh_12mo)) AS territory_kwh
      FROM ${cc}.bridge_account_premise b
      JOIN ${cc}.dim_customer c ON c.customer_id = b.customer_id
      WHERE b.is_current
    )
    SELECT agg.*, terr.territory_kwh FROM agg CROSS JOIN terr`;

  // Top customers by attention (same score the dots use), for the rail's list.
  // Wrapped so the owner lookup (bridge_premise_owner) is a plain LEFT
  // JOIN on the already-resolved premise_id, no change to any `source` branch.
  const sampleSql = `
    WITH base AS (
      SELECT a.account_number, p.premise_id, p.premise_number, c.customer_class, c.engagement_tier, c.usage_band,
             c.payment_stressed_flag, c.churn_risk_band, c.critical_care_flag,
             c.recent_complaint_count_90d, c.recent_outage_minutes_90d,
             ( ${ATTENTION_SCORE} ) AS attention_score
        ${source}
    )
    SELECT base.*, oc.customer_number AS owner_number, bpo.display_name AS owner_display_name
    FROM base
    LEFT JOIN ${cc}.bridge_premise_owner bpo ON bpo.premise_id = base.premise_id AND bpo.is_current
    LEFT JOIN ${cc}.dim_customer oc ON oc.customer_id = bpo.party_id
    ORDER BY attention_score DESC, account_number
    LIMIT 200`;

  // Top complaint themes for the cohort over the 90-day window (matches
  // exec_map_cell_themes, generalized from one cell to the whole focus group).
  const themesSql = `
    SELECT fcc.sub_category AS sub_category, COUNT(*) AS n
    FROM ${cc}.fact_customer_complaints fcc
    JOIN ( SELECT DISTINCT c.customer_id ${source} ) cust ON cust.customer_id = fcc.customer_id
    CROSS JOIN ${cc}.curated_demo_config cfg
    WHERE fcc.complaint_date BETWEEN DATE_SUB(cfg.as_of_date, cfg.complaint_window_days) AND cfg.as_of_date
    GROUP BY fcc.sub_category
    ORDER BY n DESC
    LIMIT 5`;

  const [distRows, aggRows, sampleRows, themeRows] = await Promise.all([
    runStatement(host, token, warehouseId, distSql),
    runStatement(host, token, warehouseId, aggSql),
    runStatement(host, token, warehouseId, sampleSql),
    runStatement(host, token, warehouseId, themesSql),
  ]);

  const distributions: Record<string, GroupDistBucket[]> = {};
  for (const r of distRows) {
    const dim = String(r.dim);
    (distributions[dim] ??= []).push({ bucket: String(r.bucket), n: Number(r.n) || 0 });
  }
  for (const k of Object.keys(distributions)) distributions[k].sort((x, y) => y.n - x.n);

  const ar = aggRows[0] ?? {};
  const numOrNull = (v: unknown) => (v == null || !Number.isFinite(Number(v)) ? null : Number(v));
  const boolOf = (v: unknown) => v === true || v === "true" || v === 1 || v === "1";
  const sample: GroupSampleRow[] = sampleRows.map((r) => ({
    account_number: String(r.account_number ?? ""),
    premise_number: String(r.premise_number ?? ""),
    customer_class: String(r.customer_class ?? ""),
    engagement_tier: String(r.engagement_tier ?? ""),
    usage_band: String(r.usage_band ?? ""),
    payment_stressed_flag: boolOf(r.payment_stressed_flag),
    churn_risk_band: String(r.churn_risk_band ?? ""),
    critical_care_flag: boolOf(r.critical_care_flag),
    recent_complaint_count_90d: Number(r.recent_complaint_count_90d) || 0,
    recent_outage_minutes_90d: Number(r.recent_outage_minutes_90d) || 0,
    owner_number: r.owner_number != null ? String(r.owner_number) : null,
    owner_display_name: r.owner_display_name != null ? String(r.owner_display_name) : null,
  }));

  return {
    n: Number(ar.n) || 0,
    total: Number(ar.total) || 0,
    distinctCustomers: Number(ar.distinct_customers) || 0,
    distinctOwners: Number(ar.distinct_owners) || 0,
    residential: Number(ar.residential) || 0,
    commercial: Number(ar.commercial) || 0,
    truncated,
    issues: {
      payment_stressed: Number(ar.payment_stressed) || 0,
      churn_high: Number(ar.churn_high) || 0,
      critical_care: Number(ar.critical_care) || 0,
      liheap: Number(ar.liheap) || 0,
      complaints_2plus: Number(ar.complaints_2plus) || 0,
      heavy_outages: Number(ar.heavy_outages) || 0,
      total_complaints_90d: Number(ar.total_complaints_90d) || 0,
      avg_digital_adoption: Number(ar.avg_digital_adoption) || 0,
      avg_outage_min: Number(ar.avg_outage_min) || 0,
    },
    load: {
      groupKwh: numOrNull(ar.group_kwh),
      territoryKwh: numOrNull(ar.territory_kwh),
      groupPeerP75: numOrNull(ar.group_peer_p75),
    },
    distributions,
    themes: themeRows.map((r) => ({ sub_category: String(r.sub_category ?? ""), n: Number(r.n) || 0 })),
    sample,
  };
}

// Resolve a set of customer_ids to positions + attributes (for "ask the map"
// results). Ids inlined after sanitizing to avoid parameter-size limits.
async function enrichCustomers(args: {
  host: string; token: string; warehouseId?: string; catalog: string; ids: string[];
}): Promise<Record<string, unknown>[]> {
  const { host, token, warehouseId, catalog } = args;
  if (!warehouseId) throw new Error("DATABRICKS_WAREHOUSE_ID not set (needed to resolve customer positions).");
  const safe = args.ids.filter((id) => /^[A-Za-z0-9_-]+$/.test(id));
  if (safe.length === 0) return [];
  const inList = safe.map((id) => `'${id}'`).join(",");
  // Genie answers in customer_id; resolve each matched customer to its CURRENT
  // account(s) + premise position (bridge is_current). Residential 1:1 → one
  // dot; a multi-site chain customer → a dot per site, which correctly paints
  // all of that customer's premises.
  const statement = `
    SELECT ${POINT_COLS}
    FROM ${catalog}.${schema}.dim_customer c
    JOIN ${catalog}.${schema}.bridge_account_premise b ON b.customer_id = c.customer_id AND b.is_current
    JOIN ${catalog}.${schema}.dim_account a ON a.account_id = b.account_id
    JOIN ${catalog}.${schema}.dim_premise_h3 h3 ON h3.premise_id = b.premise_id${POINT_RISK_JOIN(catalog, schema)}
    WHERE c.customer_id IN (${inList})`;
  return runStatement(host, token, warehouseId, statement);
}

async function askGenie(args: {
  host: string;
  token: string;
  spaceId: string;
  question: string;
  conversationId?: string;
}): Promise<AskResult> {
  const { host, token, spaceId, question, conversationId } = args;
  const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  const base = `${host}/api/2.0/genie/spaces/${spaceId}`;

  // 1) Start or continue the conversation.
  let cid = conversationId;
  let mid: string | undefined;
  if (cid) {
    const r = await fetch(`${base}/conversations/${cid}/messages`, {
      method: "POST", headers, body: JSON.stringify({ content: question }),
    });
    if (!r.ok) throw new Error(`create-message ${r.status}: ${await r.text()}`);
    const j: any = await r.json();
    mid = j.message_id ?? j.id ?? j.message?.id;
  } else {
    const r = await fetch(`${base}/start-conversation`, {
      method: "POST", headers, body: JSON.stringify({ content: question }),
    });
    if (!r.ok) throw new Error(`start-conversation ${r.status}: ${await r.text()}`);
    const j: any = await r.json();
    cid = j.conversation_id ?? j.conversation?.id;
    mid = j.message_id ?? j.message?.id;
  }

  // 2) Poll the message until it finishes.
  const deadline = Date.now() + POLL_TIMEOUT_MS;
  let msg: any;
  while (Date.now() < deadline) {
    const r = await fetch(`${base}/conversations/${cid}/messages/${mid}`, { headers });
    if (!r.ok) throw new Error(`poll ${r.status}: ${await r.text()}`);
    msg = await r.json();
    if (["COMPLETED", "FAILED", "CANCELLED"].includes(msg.status)) break;
    await sleep(POLL_INTERVAL_MS);
  }

  const attachments: any[] = msg?.attachments ?? [];
  const text: string | undefined = attachments.find((a) => a.text)?.text?.content;

  if (!msg || msg.status !== "COMPLETED") {
    return {
      conversationId: cid, messageId: mid, status: msg?.status ?? "TIMEOUT",
      label: text ?? question, customerIds: [], count: 0, totalRowCount: 0,
      truncated: false, hasCustomerId: false, text,
    };
  }

  // 3) Pull the query attachment's result and extract customer_id.
  const qAtt = attachments.find((a) => a.query);
  if (!qAtt) {
    return {
      conversationId: cid, messageId: mid, status: "NO_QUERY",
      label: text ?? question, customerIds: [], count: 0, totalRowCount: 0,
      truncated: false, hasCustomerId: false, text,
    };
  }
  const aid = qAtt.attachment_id;
  const rr = await fetch(`${base}/conversations/${cid}/messages/${mid}/attachments/${aid}/query-result`, { headers });
  if (!rr.ok) throw new Error(`query-result ${rr.status}: ${await rr.text()}`);
  const rj: any = await rr.json();
  const sr = rj.statement_response ?? rj;
  const cols: any[] = sr.manifest?.schema?.columns ?? [];
  const idIdx = cols.findIndex((c) => c.name === "customer_id");
  const rows: any[][] = sr.result?.data_array ?? [];
  const customerIds = idIdx >= 0
    ? (rows.map((row) => row[idIdx]).filter((v): v is string => typeof v === "string" && v.length > 0))
    : [];
  const totalRowCount: number = sr.manifest?.total_row_count ?? customerIds.length;

  // Compact result table for analytical answers (capped rows + columns).
  const columns = cols.map((c) => c.name as string);
  const sampleRows = rows.slice(0, 100).map((row) =>
    row.map((v) => (v == null ? null : String(v))),
  );

  return {
    conversationId: cid, messageId: mid, status: "COMPLETED",
    label: qAtt.query?.description ?? text ?? question,
    customerIds, count: customerIds.length, totalRowCount,
    truncated: totalRowCount >= GENIE_ROW_CAP,
    hasCustomerId: idIdx >= 0,
    text, sql: qAtt.query?.query,
    columns, rows: sampleRows,
  };
}

export const geniePlugin = toPlugin(GeniePlugin, "genie");
