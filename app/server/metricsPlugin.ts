// Metrics Catalog: surfaces the governed UC
// metric views (metric_*) — name, description, dimensions, measures.
// A metric view's dimensions/measures aren't exposed as structured metadata
// anywhere in information_schema (it only lists them as plain columns, with
// no dimension/measure distinction), so the source of truth is the YAML body
// embedded in `SHOW CREATE TABLE`, parsed with the `yaml` package rather than
// hand-rolled regex (Spark emits folded/quoted scalars for multi-line
// comments that a regex would mangle).
//
// Auth + SQL execution reuse the shared helpers in ./dbx, same as data-model.

import { Plugin, toPlugin, type IAppRouter } from "@databricks/appkit";
import type { Request, Response } from "express";
import { parse as parseYaml } from "yaml";
import { resolveHost, resolveToken, runStatement, resolveCatalog, resolveSchema } from "./dbx";

const METRIC_VIEW_LIKE = "metric_%";
const CACHE_TTL_MS = 5 * 60 * 1000;

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

// Metadata is slow-changing and warehouse spin-up has latency — cache the
// assembled response in-process, bypassed by ?refresh=1 (same pattern as
// data-model's ERD cache).
const cache = new Map<string, { expires: number; data: MetricsCatalogResponse }>();

interface RawField {
  name?: unknown;
  expr?: unknown;
  comment?: unknown;
}

function normalizeFields(fields: unknown): MetricField[] {
  if (!Array.isArray(fields)) return [];
  return (fields as RawField[]).map((f) => ({
    name: String(f.name ?? ""),
    expr: String(f.expr ?? ""),
    comment: f.comment != null ? String(f.comment) : null,
  }));
}

// SHOW CREATE TABLE wraps the metric view's YAML body in a `$$ ... $$`
// dollar-quoted string, following `WITH METRICS LANGUAGE YAML AS`.
function extractYamlBody(createStmt: string): string | null {
  const match = createStmt.match(/LANGUAGE YAML\s*AS\s*\$\$([\s\S]*)\$\$/);
  return match ? match[1] : null;
}

class MetricsCatalogPlugin extends Plugin {
  protected envVars: string[] = [];
  name = "metrics";

  injectRoutes(router: IAppRouter): void {
    router.get("/catalog", async (req: Request, res: Response) => {
      try {
        const host = resolveHost();
        const token = await resolveToken(req, host);
        if (!host || !token) {
          res.status(500).json({ error: "Workspace auth unavailable. In local dev set DATABRICKS_HOST and DATABRICKS_TOKEN." });
          return;
        }
        const warehouseId = process.env.DATABRICKS_WAREHOUSE_ID;
        if (!warehouseId) {
          res.status(500).json({ error: "DATABRICKS_WAREHOUSE_ID is not configured." });
          return;
        }
        const catalog = resolveCatalog();
        const schema = resolveSchema();

        const cacheKey = `${catalog}.${schema}`;
        const cached = cache.get(cacheKey);
        if (req.query.refresh !== "1" && cached && cached.expires > Date.now()) {
          res.json(cached.data);
          return;
        }

        const data = await buildCatalog(host, token, warehouseId, catalog, schema);
        cache.set(cacheKey, { expires: Date.now() + CACHE_TTL_MS, data });
        res.json(data);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[metrics/catalog] error:", msg);
        res.status(500).json({ error: msg });
      }
    });
  }

  getEndpoints() {
    return { catalog: "/api/metrics/catalog" };
  }
}

async function buildCatalog(
  host: string, token: string, warehouseId: string, catalog: string, schema: string,
): Promise<MetricsCatalogResponse> {
  const tableRows = await runStatement(host, token, warehouseId, `
    SELECT table_name, comment
    FROM ${catalog}.information_schema.tables
    WHERE table_schema = '${schema}' AND table_name LIKE '${METRIC_VIEW_LIKE}'
    ORDER BY table_name
  `);

  const views = await Promise.all(tableRows.map(async (r): Promise<MetricView> => {
    const name = String(r.table_name);
    const createRows = await runStatement(
      host, token, warehouseId, `SHOW CREATE TABLE ${catalog}.${schema}.${name}`,
    );
    const stmt = String(createRows[0]?.createtab_stmt ?? "");
    const yamlBody = extractYamlBody(stmt);
    const def = (yamlBody ? parseYaml(yamlBody) : {}) as {
      source?: unknown;
      dimensions?: unknown;
      measures?: unknown;
    };
    return {
      name,
      comment: (r.comment as string | null) ?? null,
      ucUrl: `${host}/explore/data/${catalog}/${schema}/${name}`,
      source: def.source != null ? String(def.source) : null,
      dimensions: normalizeFields(def.dimensions),
      measures: normalizeFields(def.measures),
    };
  }));

  return { catalog, schema, generatedAt: new Date().toISOString(), views };
}

export const metricsPlugin = toPlugin(MetricsCatalogPlugin, "metrics");
