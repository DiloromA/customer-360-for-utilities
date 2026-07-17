import { defineConfig } from "tsdown";

// Bundle the AppKit server into a single .mjs so Apps source-staging
// doesn't have to upload ~9k node_modules files. The Apps runtime never
// sees package.json (the stage script removes it), so this won't trigger
// the runtime npm install that the conventions doc warns about.
//
// Externals: keep packages out of the bundle when (a) they ship native
// .node binaries, (b) they're CommonJS with side effects bundlers can't
// safely flatten, or (c) we just don't need them at runtime (dev-only).
// The stage script ships only these externals in deploy/node_modules/.
export default defineConfig({
  entry: ["server/server.ts"],
  outDir: "build",
  format: "esm",
  target: "node22",
  platform: "node",
  outExtensions: () => ({ js: ".mjs" }),
  noExternal: [/.*/],  // bundle everything by default
  external: [
    // Native bindings — must stay in node_modules at runtime.
    /^@grpc\/.*/,            // grpc has native addons
    "protobufjs",            // depends on grpc
    // Build-time only (never imported at runtime, here just to stop tsdown
    // from chasing them):
    "vite",
    /^@vitejs\/.*/,
    /^@rolldown\/.*/,
    "rolldown-vite",
    "lightningcss",
    /^lightningcss-.*/,
  ],
});
