import { useAnalyticsQuery } from "@databricks/appkit-ui/react";
import { isObo } from "./appConfig";

// Normalize useAnalyticsQuery result to an array.
//
// AppKit's useAnalyticsQuery<T> returns { data: T | null }. Without the
// auto-generated appKitTypes.d.ts (which is produced at dev/build time and
// is not committed), TypeScript infers data as T | null rather than T[] | null.
// At runtime the value is always T[] or null; this helper bridges the gap so
// every callsite gets a T[] without unsafe casts, and tsc stays green without
// the generated registry.
export function rows<T>(data: T | null | undefined): T[] {
  if (data == null) return [];
  return Array.isArray(data) ? data as T[] : [data];
}

// The app's analytics query hook — a thin wrapper over AppKit's
// useAnalyticsQuery that routes the read through the correct identity for the
// deployed auth mode:
//   sp  → POST /api/analytics/query/:key            (runs as the app SP)
//   obo → POST /api/analytics/users/me/query/:key   (runs as the viewer)
// AppKit picks the route from `options.asUser` (default false = SP route), so
// injecting { asUser: isObo() } here flips ALL analytics reads at once. The mode
// is resolved once at boot (appConfig / main.tsx), not baked in at build time,
// so a single build deploys to both sp and obo workspaces.
//
// Every call site in the app imports useC360Query, NEVER useAnalyticsQuery
// directly — that invariant is what makes one flag control the read identity
// app-wide. A caller-supplied `asUser` would defeat this and is overridden.
export function useC360Query<T = unknown>(
  queryKey: Parameters<typeof useAnalyticsQuery>[0],
  parameters?: Parameters<typeof useAnalyticsQuery<T>>[1],
  options?: Parameters<typeof useAnalyticsQuery<T>>[2],
): ReturnType<typeof useAnalyticsQuery<T>> {
  return useAnalyticsQuery<T>(queryKey, parameters, { ...options, asUser: isObo() });
}
