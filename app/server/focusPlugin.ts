// "Focus set" — a custom AppKit plugin exposing /api/focus/{set,clear,summary}.
//
// The focus set is a per-session customer COHORT that drives the executive map:
// it highlights/dims dots, scopes KPIs, and gives "Ask the map" a labeled segment
// to reason about ("the cohort" vs "the territory"). It is carried in one Delta
// table `{catalog}.{schema}.app_focus_set` discriminated by `session_id` (a
// per-load client session key, NOT the Genie conversationId), so Genie — which
// runs on the SQL warehouse over UC and cannot read client state — can JOIN to
// exactly this session's cohort.
//
// Two ways to populate a cohort, both scale-safe (ids never round-trip the client):
//   - query-defined: hand us the SQL Genie ran (or a filter/lasso predicate query)
//     and we INSERT … REPLACE WHERE … SELECT customer_id FROM (<sql>). Handles 40k+.
//   - explicit ids: a small client selection passed as customer_id integers.
//
// Auth + SQL execution reuse the shared helpers in ./dbx. Runs as the app SP,
// which holds SELECT on the curated_* tables + SELECT/MODIFY on the app schema's
// app_focus_set (see app/scripts/grant-permissions.sh).

import { Plugin, toPlugin, type IAppRouter } from "@databricks/appkit";
import type { Request, Response } from "express";
import { resolveHost, resolveToken, runStatement, resolveCatalog, resolveSchema } from "./dbx";
import { buildFilterSql } from "./geniePlugin";
import { type GrainedFocusSummary, isValidGrain } from "./grainContract";

interface AttrFilters {
  customerClasses?: string;
  usageBands?: string;
  engagementTiers?: string;
  issueFlags?: string;
}

const FOCUS_TABLE = "focus_set";
const schema = resolveSchema();
// Guard the inlined cohort: a session can hold a large cohort, but cap explicit
// id inserts so a single VALUES statement stays sane. Query-defined cohorts have
// no such cap (the ids never leave the warehouse).
const EXPLICIT_ID_CAP = 20000;

// Session keys are uuid-ish; allow only safe chars so the
// literal can be inlined into SQL.
const SESSION_RE = /^[A-Za-z0-9_-]+$/;

// A stringified H3 cell id is hex digits (what h3_h3tostring() emits and what
// h3_stringtoh3() parses back); guard it before inlining into SQL.
const H3_CELL_RE = /^[0-9a-fA-F]+$/;

// Cap a drawn-region hex set's IN-list — a large lasso at fine resolution
// could cover thousands of cells. Query-defined cohorts (sql/filters) have no
// such cap since the ids never leave the warehouse; this is an inlined list.
const HEX_SET_CAP = 4000;

// True when at least one attribute filter is set (an empty filter set would
// select the whole territory, which is not a cohort).
function hasAnyFilter(f: AttrFilters): boolean {
  return [f.customerClasses, f.usageBands, f.engagementTiers, f.issueFlags]
    .some((v) => typeof v === "string" && v.trim().length > 0);
}

class FocusPlugin extends Plugin {
  protected envVars: string[] = [];
  name = "focus";

  injectRoutes(router: IAppRouter): void {
    // Populate (replace) this session's cohort. Body:
    //   { sessionId, sql? , customerIds?: (string|number)[] }
    // `sql` wins when both are present (query-defined is the scale-safe path).
    router.post("/set", async (req: Request, res: Response) => {
      try {
        const b = (req.body ?? {}) as {
          sessionId?: string;
          sql?: string;
          filters?: AttrFilters;
          hex?: { cellId?: string; resolution?: number };
          hexes?: string[];
          hexRes?: number;
          premiseNumbers?: (string | number)[];
          accountNumbers?: (string | number)[];
          customerIds?: (string | number)[];
          // Grain-contract fields: identify which grain and entity defined
          // this cohort. Stored in the table; used by computeSummary.
          grain?: string;
          subjectKey?: string;
        };
        const grain = isValidGrain(b.grain) ? b.grain : null;
        const subjectKey = (typeof b.subjectKey === "string" && b.subjectKey) ? b.subjectKey : null;
        const grainSql = grain ? `'${grain}'` : "CAST(NULL AS STRING)";
        const subjectKeySql = subjectKey ? `'${subjectKey.replace(/'/g, "''")}'` : "CAST(NULL AS STRING)";
        const sid = b.sessionId;
        if (!sid || !SESSION_RE.test(sid)) {
          res.status(400).json({ error: "Missing or invalid 'sessionId'." });
          return;
        }
        const ctx = await resolveCtx(req, res);
        if (!ctx) return;
        const { host, token, warehouseId, catalog } = ctx;
        const fq = `${catalog}.${schema}.app_${FOCUS_TABLE}`;

        // Six ways to define the cohort, in precedence order — none of which
        // round-trips a customer_id through the client (customer_id is a 19-digit
        // BIGINT that loses precision as a JS number):
        //   1. sql            — the Genie-generated query (auto-promote).
        //   2. filters        — attribute filters (class/usage/engagement/flags)
        //      turned into a territory-wide cohort query server-side.
        //   3. hex            — a clicked choropleth cell {cellId, resolution};
        //      the customers whose premise falls in that H3 cell (matches the map).
        //   4. hexes          — a box/lasso drawn over the zoomed-out choropleth
        //      {hexes[], hexRes}; the customers whose premise falls in any of
        //      those cells (WYSIWYG — matches exactly what's outlined).
        //   5. premiseNumbers — exact premise_number strings (box/lasso over dots
        //      under Premise grain); resolved to (customer_id, premise_id) so the
        //      cohort is EXACTLY the drawn premises, no cross-site spread.
        //   6. accountNumbers — exact account_number strings (box/lasso over dots
        //      under Customer grain); resolved to customer_id via dim_account with
        //      premise_id NULL, so the cohort spreads to all of a customer's sites.
        //   7. customerIds    — integer ids inlined as VALUES (server-internal use).
        let selectClause: string;
        if (typeof b.sql === "string" && b.sql.trim()) {
          // Query-defined: wrap the supplied SQL and project just customer_id.
          // Strip trailing semicolons so it nests cleanly as a subquery.
          const inner = b.sql.trim().replace(/;\s*$/, "");
          // This runs as the app service principal, so only accept a read
          // query (the Genie-generated SELECT/WITH). Reject anything that
          // isn't a query expression — belt-and-braces on top of the subquery
          // wrapper, which already can't host a second statement.
          if (!/^(with|select)\b/i.test(inner)) {
            res.status(400).json({ error: "Focus 'sql' must be a SELECT/WITH query." });
            return;
          }
          selectClause =
            `SELECT DISTINCT '${sid}' AS session_id, t.customer_id, current_timestamp() AS created_at, CAST(NULL AS BIGINT) AS premise_id, ${grainSql} AS grain, ${subjectKeySql} AS subject_key\n` +
            `FROM ( ${inner} ) t\nWHERE t.customer_id IS NOT NULL`;
        } else if (b.filters && hasAnyFilter(b.filters)) {
          const pred = buildFilterSql(b.filters); // leading " AND …"
          selectClause =
            `SELECT DISTINCT '${sid}' AS session_id, c.customer_id, current_timestamp() AS created_at, CAST(NULL AS BIGINT) AS premise_id, ${grainSql} AS grain, ${subjectKeySql} AS subject_key\n` +
            `FROM ${catalog}.${schema}.dim_customer c\nWHERE 1=1${pred}`;
        } else if (b.hex && b.hex.cellId) {
          // A clicked choropleth cell → the customers whose current premise falls
          // in that H3 cell, using the precomputed h3_res5..9 columns so this
          // matches the map's cell membership exactly (see exec_map_cell_detail).
          const cellId = String(b.hex.cellId).trim();
          const hexRes = Number(b.hex.resolution);
          if (!H3_CELL_RE.test(cellId) || !Number.isInteger(hexRes) || hexRes < 5 || hexRes > 9) {
            res.status(400).json({ error: "Invalid 'hex' { cellId, resolution }." });
            return;
          }
          // Under Customer grain, premise_id is NULL so the exec_map_cells
          // guard (fs.premise_id IS NULL OR fs.premise_id = p.premise_id) lights
          // every hex holding any premise of the cohort's customers — grain-following
          // spread. Under Premise/Owner grain, keep b.premise_id so only the
          // clicked hex lights. TODO(owner-grain-spread): Owner grain could later
          // expand to all premises of the same owner entity; for now, premise-pinned.
          const premiseExpr = grain === "customer"
            ? "CAST(NULL AS BIGINT)"
            : "b.premise_id";
          selectClause =
            `SELECT DISTINCT '${sid}' AS session_id, b.customer_id, current_timestamp() AS created_at, ${premiseExpr} AS premise_id, ${grainSql} AS grain, ${subjectKeySql} AS subject_key\n` +
            `FROM ${catalog}.${schema}.dim_premise_h3 h3\n` +
            `JOIN ${catalog}.${schema}.bridge_account_premise b ON b.premise_id = h3.premise_id AND b.is_current\n` +
            `WHERE h3.h3_res${hexRes} = h3_stringtoh3('${cellId}')`;
        } else if (Array.isArray(b.hexes) && b.hexes.length > 0 && b.hexRes !== undefined) {
          // A box/lasso drawn over the zoomed-out choropleth → the customers
          // whose current premise falls in ANY of the highlighted cells, same
          // join as the single-`hex` definer above so the outline and the
          // cohort are definitionally identical.
          const hexRes = Number(b.hexRes);
          const cells = b.hexes.map((v) => String(v).trim()).filter((v) => H3_CELL_RE.test(v));
          if (cells.length === 0 || !Number.isInteger(hexRes) || hexRes < 5 || hexRes > 9) {
            res.status(400).json({ error: "Invalid 'hexes' / 'hexRes'." });
            return;
          }
          if (cells.length > HEX_SET_CAP) {
            res.status(400).json({ error: `Too many hexes (>${HEX_SET_CAP}); zoom out or draw smaller.` });
            return;
          }
          const inList = cells.map((c) => `h3_stringtoh3('${c}')`).join(",");
          // Same grain-following logic as the single-hex branch above.
          const premiseExprMulti = grain === "customer"
            ? "CAST(NULL AS BIGINT)"
            : "b.premise_id";
          selectClause =
            `SELECT DISTINCT '${sid}' AS session_id, b.customer_id, current_timestamp() AS created_at, ${premiseExprMulti} AS premise_id, ${grainSql} AS grain, ${subjectKeySql} AS subject_key\n` +
            `FROM ${catalog}.${schema}.dim_premise_h3 h3\n` +
            `JOIN ${catalog}.${schema}.bridge_account_premise b ON b.premise_id = h3.premise_id AND b.is_current\n` +
            `WHERE h3.h3_res${hexRes} IN (${inList})`;
        } else if (Array.isArray(b.premiseNumbers) && b.premiseNumbers.length > 0) {
          // A box/lasso drawn over the dots UNDER Premise grain → the exact
          // premises drawn (WYSIWYG). We resolve premise_number → (customer_id,
          // premise_id) and write a REAL premise_id, so the `in_focus` join
          // (fs.premise_id IS NULL OR fs.premise_id = b.premise_id) lights ONLY
          // the drawn dots — not every other premise of the same customers. The
          // customer-grain box path stays on `accountNumbers` below (premise_id
          // NULL), which SHOULD spread to all of a customer's sites. Same
          // grain-following contract as the hex branches above.
          const prems = b.premiseNumbers
            .map((v) => String(v).trim())
            .filter((v) => /^[A-Za-z0-9_-]+$/.test(v));
          if (prems.length === 0) {
            res.status(400).json({ error: "No valid premiseNumbers." });
            return;
          }
          if (prems.length > EXPLICIT_ID_CAP) {
            res.status(400).json({ error: `Too many premiseNumbers (>${EXPLICIT_ID_CAP}); use a query-defined cohort.` });
            return;
          }
          const inList = prems.map((p) => `'${p}'`).join(",");
          selectClause =
            `SELECT DISTINCT '${sid}' AS session_id, b.customer_id, current_timestamp() AS created_at, b.premise_id AS premise_id, ${grainSql} AS grain, ${subjectKeySql} AS subject_key\n` +
            `FROM ${catalog}.${schema}.bridge_account_premise b\n` +
            `JOIN ${catalog}.${schema}.dim_premise p ON p.premise_id = b.premise_id\n` +
            `WHERE b.is_current AND p.premise_number IN (${inList})`;
        } else if (Array.isArray(b.accountNumbers) && b.accountNumbers.length > 0) {
          const accts = b.accountNumbers
            .map((v) => String(v).trim())
            .filter((v) => /^[A-Za-z0-9_-]+$/.test(v));
          if (accts.length === 0) {
            res.status(400).json({ error: "No valid accountNumbers." });
            return;
          }
          if (accts.length > EXPLICIT_ID_CAP) {
            res.status(400).json({ error: `Too many accountNumbers (>${EXPLICIT_ID_CAP}); use a query-defined cohort.` });
            return;
          }
          const inList = accts.map((a) => `'${a}'`).join(",");
          selectClause =
            `SELECT DISTINCT '${sid}' AS session_id, a.customer_id, current_timestamp() AS created_at, CAST(NULL AS BIGINT) AS premise_id, ${grainSql} AS grain, ${subjectKeySql} AS subject_key\n` +
            `FROM ${catalog}.${schema}.dim_account a\nWHERE a.account_number IN (${inList})`;
        } else {
          const ids = (b.customerIds ?? [])
            .map((v) => String(v).trim())
            .filter((v) => /^-?\d+$/.test(v));
          if (ids.length === 0) {
            res.status(400).json({ error: "Provide 'sql', 'filters', 'premiseNumbers', 'accountNumbers', or a non-empty 'customerIds'." });
            return;
          }
          if (ids.length > EXPLICIT_ID_CAP) {
            res.status(400).json({ error: `Too many explicit ids (>${EXPLICIT_ID_CAP}); use a query-defined cohort.` });
            return;
          }
          const values = ids.map((id) => `('${sid}', ${id}, current_timestamp(), NULL, ${grainSql}, ${subjectKeySql})`).join(",\n");
          selectClause = `VALUES\n${values}`;
        }

        // REPLACE WHERE makes the write atomic per session and isolates
        // concurrent sessions sharing the table. No explicit column list — the
        // clause doesn't parse with one, and Delta's ALTER TABLE ADD COLUMN
        // appends physically at the end — so every selectClause above must
        // project columns in the table's true physical order: session_id,
        // customer_id, created_at, premise_id, grain, subject_key
        // (see 02_focus_set_setup.py and the ALTER TABLE migration in 02_focus_set_setup.py).
        const stmt = `INSERT INTO ${fq} REPLACE WHERE session_id = '${sid}'\n${selectClause}`;
        await runStatement(host, token, warehouseId, stmt);

        // Return a lightweight ack so the client can bump focusVersion and
        // start the map/cells/points refreshes immediately. The summary count
        // is fetched in parallel via GET /api/focus/summary.
        res.json({ active: true });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[focus/set] error:", msg);
        res.status(500).json({ error: msg });
      }
    });

    // Clear this session's cohort.
    router.post("/clear", async (req: Request, res: Response) => {
      try {
        const sid = (req.body ?? {}).sessionId as string | undefined;
        if (!sid || !SESSION_RE.test(sid)) {
          res.status(400).json({ error: "Missing or invalid 'sessionId'." });
          return;
        }
        const ctx = await resolveCtx(req, res);
        if (!ctx) return;
        const { host, token, warehouseId, catalog } = ctx;
        const fq = `${catalog}.${schema}.app_${FOCUS_TABLE}`;
        await runStatement(host, token, warehouseId, `DELETE FROM ${fq} WHERE session_id = '${sid}'`);
        res.json({ active: false, cohortLocations: 0, cohortCustomers: 0 });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[focus/clear] error:", msg);
        res.status(500).json({ error: msg });
      }
    });

    // Cohort size + territory size + spatial extent (for "X of N" and frame-to-fit).
    router.get("/summary", async (req: Request, res: Response) => {
      try {
        const sid = (req.query.sessionId as string | undefined) ?? "";
        if (!sid || !SESSION_RE.test(sid)) {
          res.status(400).json({ error: "Missing or invalid 'sessionId'." });
          return;
        }
        const ctx = await resolveCtx(req, res);
        if (!ctx) return;
        const { host, token, warehouseId, catalog } = ctx;
        res.json(await computeSummary(host, token, warehouseId, catalog, sid));
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[focus/summary] error:", msg);
        res.status(500).json({ error: msg });
      }
    });
  }

  getEndpoints() {
    return {
      set: "/api/focus/set",
      clear: "/api/focus/clear",
      summary: "/api/focus/summary",
    };
  }
}

interface FocusCtx {
  host: string;
  token: string;
  warehouseId: string;
  catalog: string;
}

// Resolve host/token/warehouse/catalog or write the error response and return
// null (so each route can `if (!ctx) return;`).
async function resolveCtx(req: Request, res: Response): Promise<FocusCtx | null> {
  const host = resolveHost();
  const token = await resolveToken(req, host);
  if (!host || !token) {
    res.status(500).json({ error: "Workspace auth unavailable. In local dev set DATABRICKS_HOST and DATABRICKS_TOKEN." });
    return null;
  }
  const warehouseId = process.env.DATABRICKS_WAREHOUSE_ID;
  if (!warehouseId) {
    res.status(500).json({ error: "DATABRICKS_WAREHOUSE_ID is not configured." });
    return null;
  }
  const catalog = resolveCatalog();
  return { host, token, warehouseId, catalog };
}

// Reinterpret the current cohort's customer set at a new grain. Returns a new
// selectClause. Exported as a named insertion point for the grain-change route
// (not yet called by any route — next deliverable adds the UI trigger).
// eslint-disable-next-line @typescript-eslint/no-unused-vars
export function reinterpretCohortAtGrain(
  _existingCustomerIds: string[],
  _newGrain: string,
  _catalog: string,
  _schema: string,
  _sid: string,
): string {
  // "account" expands to one row per account under those customer_ids;
  // "premise" expands to one row per current premise.
  throw new Error("reinterpretCohortAtGrain not yet implemented");
}

// Cohort/territory counts at both service-location and customer grain, the
// cohort's lat/lon bounding box, and the grain/subject_key stored with the
// most recent focus-set write — in one cross-joined single-row query.
async function computeSummary(
  host: string,
  token: string,
  warehouseId: string,
  catalog: string,
  sid: string,
): Promise<GrainedFocusSummary> {
  const c = `${catalog}.${schema}`;
  const fq = `${catalog}.${schema}.app_${FOCUS_TABLE}`;
  const sql = `
    SELECT
      coh.cohort_locations, coh.cohort_customers,
      terr.territory_locations, terr.territory_customers,
      ext.min_lat, ext.max_lat, ext.min_lon, ext.max_lon,
      meta.grain, meta.subject_key
    FROM
      -- Count the cohort over the SAME universe as the territory denominator and
      -- the rail/map: current premises (is_current), not raw focus_set rows —
      -- a raw COUNT(*) would include customers that exist in dim_customer but
      -- have no current premise (never mapped or counted elsewhere), which let
      -- the numerator exceed the territory total (e.g. "55,028 of 50,393").
      -- cohort_locations is the PRIMARY count (service-location grain, matches
      -- the rail's headline count exactly); cohort_customers is the same
      -- cohort collapsed to distinct parties.
      (SELECT COUNT(DISTINCT b.premise_id)  AS cohort_locations,
              COUNT(DISTINCT fs.customer_id) AS cohort_customers
         FROM ${fq} fs
         JOIN ${c}.bridge_account_premise b
           ON b.customer_id = fs.customer_id AND b.is_current
           AND (fs.premise_id IS NULL OR fs.premise_id = b.premise_id)
         WHERE fs.session_id = '${sid}') coh,
      (SELECT COUNT(DISTINCT premise_id)  AS territory_locations,
              COUNT(DISTINCT customer_id) AS territory_customers
         FROM ${c}.bridge_account_premise WHERE is_current) terr,
      -- Percentile (not MIN/MAX) bounds so a few scattered outliers don't blow
      -- the frame up to the whole territory. This frames the dense bulk of the
      -- cohort — "zoom into the group", not "zoom out to everywhere".
      (SELECT percentile_approx(h3.latitude, 0.05)  AS min_lat,
              percentile_approx(h3.latitude, 0.95)  AS max_lat,
              percentile_approx(h3.longitude, 0.05) AS min_lon,
              percentile_approx(h3.longitude, 0.95) AS max_lon
         FROM ${fq} f
         JOIN ${c}.bridge_account_premise b ON b.customer_id = f.customer_id AND b.is_current
           AND (f.premise_id IS NULL OR f.premise_id = b.premise_id)
         JOIN ${c}.dim_premise_h3 h3 ON h3.premise_id = b.premise_id
         WHERE f.session_id = '${sid}') ext,
      -- Most recent grain/subject_key written for this session (null for legacy rows).
      (SELECT grain, subject_key
         FROM ${fq}
         WHERE session_id = '${sid}'
         ORDER BY created_at DESC
         LIMIT 1) meta`;
  const rows = await runStatement(host, token, warehouseId, sql);
  const r = rows[0] ?? {};
  const cohortLocations = Number(r.cohort_locations) || 0;
  const toNum = (v: unknown) => (v == null || !Number.isFinite(Number(v)) ? null : Number(v));
  const s = toNum(r.min_lat), n = toNum(r.max_lat), w = toNum(r.min_lon), e = toNum(r.max_lon);
  const extent = s != null && n != null && w != null && e != null
    ? { south: s, north: n, west: w, east: e }
    : null;
  const grainVal = isValidGrain(r.grain) ? r.grain : null;
  return {
    active: cohortLocations > 0,
    cohortLocations,
    territoryLocations: Number(r.territory_locations) || 0,
    cohortCustomers: Number(r.cohort_customers) || 0,
    territoryCustomers: Number(r.territory_customers) || 0,
    extent,
    grain: grainVal,
    subjectKey: (typeof r.subject_key === "string" && r.subject_key) ? r.subject_key : null,
  };
}

export const focusPlugin = toPlugin(FocusPlugin, "focus");
