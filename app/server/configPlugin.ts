// Client-visible app config — a single tiny GET the browser fetches once at boot
// (see client/src/main.tsx + appConfig.ts) before it renders, so the client can
// pick the correct analytics read path without baking anything in at build time.
//
// Why not import.meta.env / a build-time constant: the app is built ONCE and the
// same artifact is deployed to multiple workspaces, which may run
// in different auth modes. The mode is a runtime env value on the server
// (DATABRICKS_AUTH_MODE, injected via app.yaml), so it must be delivered to the
// browser at runtime, not compiled in.
//
// This intentionally exposes ONLY non-secret, client-relevant config. Today
// that's just the auth mode, which decides whether useC360Query hits the
// service-principal or the "as the viewer" (OBO) analytics endpoint.

import { Plugin, toPlugin, type IAppRouter } from "@databricks/appkit";
import type { Request, Response } from "express";

export type AuthMode = "sp" | "obo";

class ConfigPlugin extends Plugin {
  protected envVars: string[] = [];
  name = "config";

  injectRoutes(router: IAppRouter): void {
    router.get("/client", (_req: Request, res: Response) => {
      const authMode: AuthMode =
        (process.env.DATABRICKS_AUTH_MODE ?? "sp").toLowerCase() === "obo" ? "obo" : "sp";
      // No caching — this is a tiny per-boot fetch and the value is fixed for
      // the life of the process, but a stale CDN/proxy copy across a redeploy
      // that flips modes would be a correctness bug, so mark it uncacheable.
      res.setHeader("Cache-Control", "no-store");
      res.json({ authMode });
    });
  }

  getEndpoints() {
    return { client: "/api/config/client" };
  }
}

export const configPlugin = toPlugin(ConfigPlugin, "config");
