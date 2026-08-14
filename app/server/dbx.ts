// Shared Databricks workspace helpers for the app's server plugins (genie, focus).
//
// Both plugins talk to the same workspace the same way: resolve the host, mint a
// token (prefer the app's service principal, fall back to the forwarded user
// token, then DATABRICKS_TOKEN in dev), and run SQL via the Statement Execution
// API — deliberately bypassing AppKit's analytics SSE transport (and its ~1 MB
// event cap) so queries can return tens of thousands of rows.

import type { Request } from "express";

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ── M2M token cache ──────────────────────────────────────────────────────────
// Mints one service-principal OAuth token and reuses it until ~60s before
// expiry. A single-flight promise prevents concurrent startup requests from
// each minting their own token simultaneously.
interface CachedToken { value: string; expiresAt: number; }
let cachedToken: CachedToken | null = null;
let tokenFlight: Promise<string | undefined> | null = null;

async function mintSPToken(host: string, clientId: string, clientSecret: string): Promise<string | undefined> {
  const now = Date.now();
  if (cachedToken && now < cachedToken.expiresAt) return cachedToken.value;
  // If a refresh is already in flight, wait for it rather than issuing another mint.
  if (tokenFlight) return tokenFlight;
  tokenFlight = (async () => {
    try {
      const basic = Buffer.from(`${clientId}:${clientSecret}`).toString("base64");
      const r = await fetch(`${host}/oidc/v1/token`, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Authorization: `Basic ${basic}`,
        },
        body: new URLSearchParams({ grant_type: "client_credentials", scope: "all-apis" }),
      });
      if (r.ok) {
        const j: any = await r.json();
        if (j.access_token) {
          const ttlMs = ((j.expires_in as number) || 3600) * 1000;
          // Cache until 60s before expiry so callers never receive an about-to-expire token.
          cachedToken = { value: j.access_token as string, expiresAt: Date.now() + ttlMs - 60_000 };
          return cachedToken.value;
        }
      } else {
        console.warn(`[dbx] SP token mint failed ${r.status}: ${await r.text()}`);
      }
    } catch (e) {
      console.warn("[dbx] SP token mint error:", e instanceof Error ? e.message : e);
    }
    return undefined;
  })().finally(() => { tokenFlight = null; });
  return tokenFlight;
}

// The Unity Catalog the app reads/writes. Supplied via the DATABRICKS_CATALOG
// app env (see databricks.yml). No hardcoded fallback — a personal catalog must
// never bake into this extraction-eligible code; fail loudly if it's unset.
export function resolveCatalog(): string {
  const c = process.env.DATABRICKS_CATALOG;
  if (!c) throw new Error("DATABRICKS_CATALOG is not set.");
  return c;
}

// The single schema the app reads/writes (all dim_/fact_/bridge_/metric_/app_
// tables live here). Supplied via DATABRICKS_SCHEMA (see databricks.yml). No
// fallback — fail loudly if unset, same rationale as resolveCatalog.
export function resolveSchema(): string {
  const s = process.env.DATABRICKS_SCHEMA;
  if (!s) throw new Error("DATABRICKS_SCHEMA is not set.");
  return s;
}

export function resolveHost(): string | undefined {
  let h = process.env.DATABRICKS_HOST;
  if (!h) return undefined;
  if (!/^https?:\/\//.test(h)) h = `https://${h}`;
  return h.replace(/\/+$/, "");
}

// Auth strategy depends on DATABRICKS_AUTH_MODE, which is the
// same per-target flag that drives the OBO/SP grants and the analytics read
// path. This function serves all four custom plugins (genie/focus/dataModel/
// metrics); the AppKit analytics plugin's own read path is switched separately
// by the useC360Query wrapper (R6).
//
//   sp  (default) — prefer the app's own service principal (OAuth M2M via the
//     DATABRICKS_CLIENT_ID/SECRET that Databricks Apps inject). An SP token gets
//     the `all-apis` scope, which the Genie API requires. Falls back to the
//     forwarded user token, then DATABRICKS_TOKEN (dev). This is today's behavior.
//
//   obo — every read runs AS THE VIEWER, so prefer the forwarded end-user token.
//     Under OBO the user token carries the app's declared user scopes (the
//     `internal` target declares [sql, dashboards.genie] — enough for both the
//     Statement Execution API and Genie). If there's no forwarded token (local
//     dev), fall back to DATABRICKS_TOKEN (the developer's own identity), then
//     the SP as a last resort. The SP is a deliberate fail-closed fallback: in a
//     deployed OBO workspace the SP holds NO data grants (grant-permissions.sh
//     obo mode grants the viewer, not the SP), so an SP token here cannot read
//     the viewer's data — it errors rather than serving another identity's rows.
export async function resolveToken(req: Request, host?: string): Promise<string | undefined> {
  const clientId = process.env.DATABRICKS_CLIENT_ID;
  const clientSecret = process.env.DATABRICKS_CLIENT_SECRET;
  const fwd = req.headers["x-forwarded-access-token"];
  const fwdToken = typeof fwd === "string" && fwd.length > 0 ? fwd : undefined;
  const oboFirst = (process.env.DATABRICKS_AUTH_MODE ?? "sp").toLowerCase() === "obo";

  if (oboFirst) {
    if (fwdToken) return fwdToken;
    if (process.env.DATABRICKS_TOKEN) return process.env.DATABRICKS_TOKEN;
    if (host && clientId && clientSecret) return await mintSPToken(host, clientId, clientSecret);
    return undefined;
  }

  if (host && clientId && clientSecret) {
    const token = await mintSPToken(host, clientId, clientSecret);
    if (token) return token;
  }
  if (fwdToken) return fwdToken;
  return process.env.DATABRICKS_TOKEN || undefined;
}

// Run a SQL statement via the Statement Execution API and return typed rows.
// Non-SELECT statements (INSERT/DELETE) return an empty array.
//
// Overall deadline: 30s synchronous wait (on_wait_timeout: CONTINUE) then up
// to 60s of polling = 90s total for cold warehouse warm-up. Callers may supply
// an AbortSignal to cancel mid-flight (issues DELETE /sql/statements/{id}).
export async function runStatement(
  host: string,
  token: string,
  warehouseId: string,
  statement: string,
  signal?: AbortSignal,
): Promise<Record<string, unknown>[]> {
  const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  const r = await fetch(`${host}/api/2.0/sql/statements`, {
    method: "POST",
    headers,
    signal,
    body: JSON.stringify({
      statement,
      warehouse_id: warehouseId,
      wait_timeout: "30s",
      on_wait_timeout: "CONTINUE",
      format: "JSON_ARRAY",
      disposition: "INLINE",
    }),
  });
  if (!r.ok) throw new Error(`statement submit ${r.status}: ${await r.text()}`);
  let j: any = await r.json();
  const sid: string = j.statement_id;

  // Cancel the warehouse statement when the caller aborts, so we don't leave
  // RUNNING statements consuming warehouse resources for superseded requests.
  const cancelStatement = async () => {
    try {
      await fetch(`${host}/api/2.0/sql/statements/${sid}/cancel`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
      });
    } catch {
      // Best-effort; ignore cancellation errors.
    }
  };

  const deadline = Date.now() + 60_000;
  while (["PENDING", "RUNNING"].includes(j.status?.state) && Date.now() < deadline) {
    if (signal?.aborted) {
      await cancelStatement();
      throw new Error("statement cancelled");
    }
    await sleep(1000);
    if (signal?.aborted) {
      await cancelStatement();
      throw new Error("statement cancelled");
    }
    const p = await fetch(`${host}/api/2.0/sql/statements/${sid}`, { headers, signal });
    if (!p.ok) throw new Error(`statement poll ${p.status}: ${await p.text()}`);
    j = await p.json();
  }
  if (["PENDING", "RUNNING"].includes(j.status?.state)) {
    await cancelStatement();
    throw new Error("statement timeout: warehouse did not respond within the deadline");
  }
  if (j.status?.state === "CANCELLED") throw new Error("statement cancelled");
  if (j.status?.state !== "SUCCEEDED") {
    const err = j.status?.error;
    const detail = err?.message || JSON.stringify(err ?? {});
    throw new Error(`statement ${j.status?.state}: ${detail}`);
  }
  const colmeta: { name: string; type_name?: string }[] = j.manifest?.schema?.columns ?? [];
  const rows: unknown[][] = j.result?.data_array ?? [];
  // INLINE disposition splits large results across multiple fixed-size chunks
  // (empirically ~28.7k rows / ~16.8 MB per chunk for this app's ~15-column
  // point rows — well under the ~25 MiB the Statement Execution API allows
  // for the whole INLINE result). The first response only ever carries chunk
  // 0; a result with >1 chunk silently dropped everything past it until this
  // loop was added — caught only by directly probing the manifest during the
  // full-density-dots work, not by any error the API surfaces. Fetch the rest
  // by chunk_index; each chunk response has the same `result.data_array` shape.
  const totalChunks: number = j.manifest?.total_chunk_count ?? 1;
  for (let i = 1; i < totalChunks; i++) {
    const c = await fetch(`${host}/api/2.0/sql/statements/${sid}/result/chunks/${i}`, { headers });
    if (!c.ok) throw new Error(`statement chunk ${i} fetch ${c.status}: ${await c.text()}`);
    const cj: any = await c.json();
    rows.push(...(cj.data_array ?? []));
  }
  const numeric = new Set(["INT", "LONG", "DOUBLE", "FLOAT", "DECIMAL", "SHORT", "BYTE"]);
  return rows.map((row) => {
    const o: Record<string, unknown> = {};
    colmeta.forEach((c, i) => {
      let v: unknown = row[i];
      if (v != null && typeof v === "string") {
        const t = c.type_name ?? "";
        if (t === "BOOLEAN") v = v === "true";
        else if (numeric.has(t)) v = Number(v);
      }
      o[c.name] = v;
    });
    return o;
  });
}
