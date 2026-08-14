import { useRef, useEffect, type DependencyList } from "react";

// ────────────────────────────────────────────────────────────────────
// Dev instrumentation helpers
// ────────────────────────────────────────────────────────────────────

const DEV = import.meta.env.DEV;

export function perfMark(name: string) {
  if (DEV && typeof performance !== "undefined") {
    try { performance.mark(name); } catch { /* ignore */ }
  }
}

export function perfMeasure(name: string, from?: string) {
  if (!DEV || typeof performance === "undefined") return;
  try { performance.measure(name, from); } catch { /* ignore */ }
}

// ────────────────────────────────────────────────────────────────────
// useViewportFetch
// ────────────────────────────────────────────────────────────────────
//
// Drives every map/rail data fetch. On each deps change it cancels the prior
// in-flight fetch when a newer request supersedes it, so the warehouse
// statement is cancelled too (dbx.ts propagates the signal).
//
// `body`, `onData`, and `onMeta` are captured at dispatch time (intentionally
// NOT in the dep array), so any closure value they read — e.g. the H3
// `resolution` stored alongside rows — is snapshotted at DISPATCH time, not
// response time.

// Maximum jittered wait between retries (ms).
const MAX_RETRY_DELAY_MS = 4000;

// Track which tags have fired their first-request and first-data marks so they
// only appear once per page load in the Performance panel (not on every pan).
const _firstRequestMarked = new Set<string>();
const _firstDataMarked = new Set<string>();

export function useViewportFetch<T>(config: {
  route: string;
  tag: string;
  active: boolean;
  responseKey: string;
  body: () => Record<string, unknown>;
  onData: (rows: T[]) => void;
  onMeta?: (data: Record<string, unknown>) => void;
  setLoading?: (loading: boolean) => void;
  // Called with an error message on terminal failure; null to clear.
  setError?: (error: string | null) => void;
  deps: DependencyList;
}) {
  const reqSeq = useRef(0);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    if (!config.active) return;

    // Cancel any in-flight request for the previous deps set.
    abortRef.current?.abort();
    const abort = new AbortController();
    abortRef.current = abort;
    const seq = ++reqSeq.current;

    const run = async () => {
      config.setLoading?.(true);
      config.setError?.(null);

      if (!_firstRequestMarked.has(config.tag)) {
        _firstRequestMarked.add(config.tag);
        perfMark(`c360:${config.tag}:first-request-dispatched`);
        perfMeasure(`c360:${config.tag}:first-request-dispatched`, "c360:app-shell-interactive");
      }

      const MAX_ATTEMPTS = 2;
      for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
        if (abort.signal.aborted || seq !== reqSeq.current) return;
        try {
          const r = await fetch(config.route, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(config.body()),
            signal: abort.signal,
          });
          if (seq !== reqSeq.current) return; // superseded
          if (!r.ok) {
            // 4xx = validation failure, don't retry.
            if (r.status >= 400 && r.status < 500) {
              const msg = `[${config.tag}] ${r.status} error`;
              console.error(msg);
              config.setError?.(msg);
              return;
            }
            // 5xx — fall through to retry.
            if (attempt === MAX_ATTEMPTS) {
              const msg = `[${config.tag}] server error ${r.status}`;
              console.error(msg);
              config.setError?.(msg);
              return;
            }
          } else {
            const data = await r.json();
            if (seq !== reqSeq.current) return; // superseded
            if (Array.isArray(data[config.responseKey])) {
              config.onData(data[config.responseKey] as T[]);
              config.onMeta?.(data);
              config.setError?.(null);
              if (!_firstDataMarked.has(config.tag)) {
                _firstDataMarked.add(config.tag);
                perfMark(`c360:${config.tag}:first-data`);
                perfMeasure(`c360:${config.tag}:warehouse-response`, `c360:${config.tag}:first-request-dispatched`);
              }
              return; // success
            } else if (data.error) {
              const msg = `[${config.tag}] ${data.error}`;
              console.error(msg);
              config.setError?.(msg);
              return;
            }
            return; // unexpected shape, treat as empty success
          }
        } catch (e) {
          if (seq !== reqSeq.current || abort.signal.aborted) return; // superseded or cancelled
          if (attempt === MAX_ATTEMPTS) {
            const msg = `[${config.tag}] ${e instanceof Error ? e.message : String(e)}`;
            console.error(msg);
            config.setError?.(msg);
            return;
          }
        }
        // Backoff before retry: 1–4s with jitter.
        const delay = 1000 + Math.random() * Math.min(1000 * attempt, MAX_RETRY_DELAY_MS - 1000);
        await new Promise<void>((res) => setTimeout(res, delay));
        if (abort.signal.aborted || seq !== reqSeq.current) return;
      }
    };

    run().finally(() => {
      if (seq === reqSeq.current) config.setLoading?.(false);
    });

    return () => { abort.abort(); };
  }, config.deps); // eslint-disable-line react-hooks/exhaustive-deps
}
