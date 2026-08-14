import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { loadAppConfig } from "./appConfig";
import "./App.css";

if (import.meta.env.DEV && typeof performance !== "undefined") {
  try { performance.mark("c360:app-shell-interactive"); } catch { /* ignore */ }
}

// Resolve the runtime auth mode BEFORE first render so every analytics query
// picks the correct (SP vs OBO) endpoint on its first fetch — see appConfig +
// useC360Query. loadAppConfig never throws; it leaves the safe
// "sp" default on any failure. Wrapped in an async fn (not top-level await) so
// the client bundle builds for the baseline browser target.
async function boot() {
  await loadAppConfig();
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}

void boot();
