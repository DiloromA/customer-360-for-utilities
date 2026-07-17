#!/usr/bin/env bash
set -euo pipefail

# Stage a ready-to-deploy directory at app/deploy/. The DAB uploads this
# directory only (via `source_code_path: app/deploy/`) so the Apps runtime
# never sees package.json and skips its auto `npm install` entirely.
#
# See docs/conventions.md § "Apps deployment pattern".

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

rm -rf deploy
mkdir -p deploy

cp app.yaml deploy/
cp -R build dist deploy/
[ -d config ] && cp -R config deploy/

# tsdown bundled everything possible into build/*.mjs (see
# app/tsdown.config.ts). The bundled output still calls __require() on a
# small set of packages it couldn't safely inline — install just those
# into a minimal deploy/node_modules/ so we don't have to ship the full
# 9k-file transitive tree.
#
# @grpc/grpc-js — used by AppKit's OpenTelemetry exporter (native addons
#   inside, can't bundle). The rest of its workspace's __require() calls
#   (@opentelemetry/winston-transport, pg-native, bufferutil,
#   utf-8-validate) are optional with pure-JS fallbacks; if they're
#   absent the require() throws and the code's try/catch falls through.
node -e '
const slim = {
  name: "app-c360-server",
  private: true,
  version: "0.0.0",
  type: "module",
  dependencies: { "@grpc/grpc-js": "^1.10.0" }
};
require("fs").writeFileSync("deploy/package.json", JSON.stringify(slim, null, 2));
'
(
  cd deploy
  # --prefer-offline: serve these (already-resolved) runtime deps from the npm
  # cache when present, so a flaky registry/proxy tarball 404 doesn't break the
  # deploy stage (the full app/node_modules install already cached them).
  npm install \
    --omit=dev \
    --os=linux --cpu=x64 --libc=glibc \
    --ignore-scripts \
    --no-audit --no-fund \
    --package-lock=false \
    --prefer-offline
)
rm deploy/package.json

# Strip declarations + source maps to keep file count down further.
find deploy/node_modules \
  \( -name "*.d.ts" -o -name "*.map" -o -name "*.md" -o -name "README*" \
     -o -name "CHANGELOG*" -o -name "LICENSE*" -o -name "*.markdown" \) \
  -type f -delete 2>/dev/null || true

echo "Staged deploy/ ($(du -sh deploy | cut -f1), $(find deploy -type f | wc -l | tr -d ' ') files) — ready for \`databricks bundle deploy\`."
