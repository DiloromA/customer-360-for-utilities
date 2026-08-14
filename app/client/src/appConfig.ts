// Runtime app config resolved once at boot from GET /api/config/client (see
// main.tsx). Held in a module-level singleton so hooks can read it synchronously
// on their first render — main.tsx awaits loadAppConfig() BEFORE mounting <App/>,
// so isObo() is already correct the first time any analytics query fires (no
// wrong-identity first fetch, no refetch flip).
//
// The default is "sp" — today's behavior and the safe fallback if the config
// fetch ever fails. Only a successful fetch of an "obo" workspace flips it.

export type AuthMode = "sp" | "obo";

let authMode: AuthMode = "sp";

// Fetch the client config and cache the auth mode. Never throws — on any
// failure it leaves the safe "sp" default in place. Call once, before render.
export async function loadAppConfig(): Promise<void> {
  try {
    const r = await fetch("/api/config/client", { headers: { Accept: "application/json" } });
    if (!r.ok) return;
    const j = (await r.json()) as { authMode?: unknown };
    if (j.authMode === "obo" || j.authMode === "sp") authMode = j.authMode;
  } catch {
    // Keep the "sp" default; the app still functions (SP read path).
  }
}

export function getAuthMode(): AuthMode {
  return authMode;
}

// True when the app runs on-behalf-of the viewer — analytics reads must hit the
// `/users/me/...` (OBO) endpoint. Read by useC360Query.
export function isObo(): boolean {
  return authMode === "obo";
}
