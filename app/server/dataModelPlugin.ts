// Data Model — a dynamic ERD generated live from Unity Catalog metadata via
// information_schema, scoped to a layer: the curated star (selected by its
// dim_/fact_/bridge_ role prefixes) or a single naming-convention prefix
// (raw_/ml_/app_). Declaring FOREIGN KEY constraints across the core star
// (design doc §8) is rolling out table by table — those declared edges are
// read straight from information_schema.referential_constraints and rendered
// solid/authoritative. Everywhere else (not yet hardened), a non-PK column
// whose name matches a known single-column PK's name is drawn as an INFERRED
// edge to that PK's table (dashed) — convention, not a declared constraint.
//
// Auth + SQL execution reuse the shared helpers in ./dbx, same as focus/genie.

import { Plugin, toPlugin, type IAppRouter } from "@databricks/appkit";
import type { Request, Response } from "express";
import { resolveHost, resolveToken, runStatement, resolveCatalog, resolveSchema } from "./dbx";

const LAYERS = ["curated", "raw", "ml", "app"] as const;
type Layer = (typeof LAYERS)[number];
const DEFAULT_LAYER: Layer = "curated";
const CACHE_TTL_MS = 5 * 60 * 1000;

// Documented exceptions where a non-PK column's name doesn't literally match
// its referenced table's PK column, so convention-based inference alone
// would miss the edge. Keep this list small and explicit — see design doc §8.
const COLUMN_ALIAS: Record<string, string> = {
  // fact_customer_billing.rate_schedule → dim_rate_schedule(rate_schedule_id)
  rate_schedule: "rate_schedule_id",
};

type TableKind = "dim" | "fact" | "bridge" | "history" | "other";

interface ErdColumn {
  name: string;
  type: string;
  nullable: boolean;
  comment: string | null;
  isPk: boolean;
  isFk: boolean;
  refTable: string | null;
  refColumn: string | null;
}

interface ErdTable {
  name: string;
  kind: TableKind;
  comment: string | null;
  ucUrl: string;
  columns: ErdColumn[];
}

interface ErdEdge {
  fromTable: string;
  fromColumn: string;
  toTable: string;
  toColumn: string;
  inferred: boolean;
}

interface ErdResponse {
  catalog: string;
  schema: string;
  layer: Layer;
  generatedAt: string;
  edgesAreInferred: boolean;
  tables: ErdTable[];
  edges: ErdEdge[];
}

// Metadata is slow-changing and warehouse spin-up has latency — cache the
// assembled response in-process, bypassed by ?refresh=1.
const cache = new Map<string, { expires: number; data: ErdResponse }>();

function tableKind(name: string): TableKind {
  if (/^dim_.+_history$/.test(name)) return "history";
  if (name.startsWith("dim_")) return "dim";
  if (name.startsWith("fact_")) return "fact";
  if (name.startsWith("bridge_")) return "bridge";
  return "other";
}

// The curated star has no single naming prefix (it's selected by the three
// role prefixes together); raw_/ml_/app_ each use a single prefix LIKE.
function tableFilterSql(layer: Layer, alias = ""): string {
  const col = alias ? `${alias}.table_name` : "table_name";
  if (layer === "curated") {
    return `(${col} LIKE 'dim_%' OR ${col} LIKE 'fact_%' OR ${col} LIKE 'bridge_%')`;
  }
  return `${col} LIKE '${layer}_%'`;
}

class DataModelPlugin extends Plugin {
  protected envVars: string[] = [];
  name = "data-model";

  injectRoutes(router: IAppRouter): void {
    router.get("/erd", async (req: Request, res: Response) => {
      try {
        const layerParam = String(req.query.layer ?? DEFAULT_LAYER);
        if (!(LAYERS as readonly string[]).includes(layerParam)) {
          res.status(400).json({ error: `Invalid 'layer'. Expected one of: ${LAYERS.join(", ")}.` });
          return;
        }
        const layer = layerParam as Layer;
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

        const cacheKey = `${catalog}.${schema}.${layer}`;
        const cached = cache.get(cacheKey);
        if (req.query.refresh !== "1" && cached && cached.expires > Date.now()) {
          res.json(cached.data);
          return;
        }

        const data = await buildErd(host, token, warehouseId, catalog, schema, layer);
        cache.set(cacheKey, { expires: Date.now() + CACHE_TTL_MS, data });
        res.json(data);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[data-model/erd] error:", msg);
        res.status(500).json({ error: msg });
      }
    });
  }

  getEndpoints() {
    return { erd: "/api/data-model/erd" };
  }
}

async function buildErd(
  host: string, token: string, warehouseId: string, catalog: string, schema: string, layer: Layer,
): Promise<ErdResponse> {
  const filter = tableFilterSql(layer);
  const tcFilter = tableFilterSql(layer, "tc");

  const [tableRows, columnRows, pkRows, fkRows] = await Promise.all([
    runStatement(host, token, warehouseId, `
      SELECT table_name, comment
      FROM ${catalog}.information_schema.tables
      WHERE table_schema = '${schema}' AND ${filter}
    `),
    runStatement(host, token, warehouseId, `
      SELECT table_name, column_name, ordinal_position, full_data_type, is_nullable, comment
      FROM ${catalog}.information_schema.columns
      WHERE table_schema = '${schema}' AND ${filter}
      ORDER BY table_name, ordinal_position
    `),
    runStatement(host, token, warehouseId, `
      SELECT tc.table_name, kcu.column_name
      FROM ${catalog}.information_schema.table_constraints tc
      JOIN ${catalog}.information_schema.key_column_usage kcu
        ON tc.constraint_catalog = kcu.constraint_catalog
        AND tc.constraint_schema = kcu.constraint_schema
        AND tc.constraint_name = kcu.constraint_name
      WHERE tc.table_schema = '${schema}' AND tc.constraint_type = 'PRIMARY KEY'
        AND ${tcFilter}
    `),
    // Declared FKs (design doc §8 hardening, rolled out table by table). Join
    // key_column_usage twice — once for the child (FK) columns, once for the
    // parent (referenced PK/unique) columns — matching each child column to
    // its parent by position within the key, so composite keys line up.
    runStatement(host, token, warehouseId, `
      SELECT fk_kcu.table_name AS from_table, fk_kcu.column_name AS from_column,
             pk_kcu.table_name AS to_table, pk_kcu.column_name AS to_column
      FROM ${catalog}.information_schema.table_constraints tc
      JOIN ${catalog}.information_schema.referential_constraints rc
        ON tc.constraint_catalog = rc.constraint_catalog
        AND tc.constraint_schema = rc.constraint_schema
        AND tc.constraint_name = rc.constraint_name
      JOIN ${catalog}.information_schema.key_column_usage fk_kcu
        ON fk_kcu.constraint_catalog = tc.constraint_catalog
        AND fk_kcu.constraint_schema = tc.constraint_schema
        AND fk_kcu.constraint_name = tc.constraint_name
      JOIN ${catalog}.information_schema.key_column_usage pk_kcu
        ON pk_kcu.constraint_catalog = rc.unique_constraint_catalog
        AND pk_kcu.constraint_schema = rc.unique_constraint_schema
        AND pk_kcu.constraint_name = rc.unique_constraint_name
        AND pk_kcu.ordinal_position = fk_kcu.position_in_unique_constraint
      WHERE tc.table_schema = '${schema}' AND tc.constraint_type = 'FOREIGN KEY'
        AND ${tcFilter}
    `),
  ]);

  // Single-column PKs only — every curated PK today is one surrogate
  // <entity>_id column (design doc §7.1). A composite PK is excluded from
  // the inference map outright rather than guessed at.
  const pkCountByTable = new Map<string, number>();
  for (const r of pkRows) {
    const t = String(r.table_name);
    pkCountByTable.set(t, (pkCountByTable.get(t) ?? 0) + 1);
  }
  const pkColumnByTable = new Map<string, string>();
  const pkColumnToTable = new Map<string, string>();
  for (const r of pkRows) {
    const t = String(r.table_name);
    if (pkCountByTable.get(t) !== 1) continue;
    const col = String(r.column_name);
    pkColumnByTable.set(t, col);
    pkColumnToTable.set(col, t);
  }

  const declaredFkByColumn = new Map<string, { refTable: string; refColumn: string }>();
  for (const r of fkRows) {
    declaredFkByColumn.set(`${r.from_table}.${r.from_column}`, {
      refTable: String(r.to_table),
      refColumn: String(r.to_column),
    });
  }

  const tables = new Map<string, ErdTable>();
  for (const r of tableRows) {
    const name = String(r.table_name);
    tables.set(name, {
      name,
      kind: tableKind(name),
      comment: (r.comment as string | null) ?? null,
      ucUrl: `${host}/explore/data/${catalog}/${schema}/${name}`,
      columns: [],
    });
  }

  const edges: ErdEdge[] = [];
  for (const r of columnRows) {
    const tableName = String(r.table_name);
    const table = tables.get(tableName);
    if (!table) continue;
    const columnName = String(r.column_name);
    const isPk = pkColumnByTable.get(tableName) === columnName;

    const column: ErdColumn = {
      name: columnName,
      type: String(r.full_data_type ?? ""),
      nullable: r.is_nullable !== "NO",
      comment: (r.comment as string | null) ?? null,
      isPk,
      isFk: false,
      refTable: null,
      refColumn: null,
    };

    if (!isPk) {
      const declared = declaredFkByColumn.get(`${tableName}.${columnName}`);
      if (declared) {
        column.isFk = true;
        column.refTable = declared.refTable;
        column.refColumn = declared.refColumn;
        edges.push({ fromTable: tableName, fromColumn: columnName, toTable: declared.refTable, toColumn: declared.refColumn, inferred: false });
      } else {
        const candidate = COLUMN_ALIAS[columnName] ?? columnName;
        const refTable = pkColumnToTable.get(candidate);
        if (refTable && refTable !== tableName) {
          column.isFk = true;
          column.refTable = refTable;
          column.refColumn = candidate;
          edges.push({ fromTable: tableName, fromColumn: columnName, toTable: refTable, toColumn: candidate, inferred: true });
        }
      }
    }
    table.columns.push(column);
  }

  return {
    catalog, schema, layer,
    generatedAt: new Date().toISOString(),
    // True while any edge in this response is still convention-inferred
    // (design doc §8 hardening is rolling out table by table, not all at once).
    edgesAreInferred: edges.some((e) => e.inferred),
    tables: Array.from(tables.values()),
    edges,
  };
}

export const dataModelPlugin = toPlugin(DataModelPlugin, "data-model");
