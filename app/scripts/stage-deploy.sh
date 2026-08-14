#!/usr/bin/env bash
set -euo pipefail

# Stage a ready-to-deploy directory at app/deploy/. The DAB uploads this
# directory only (via `source_code_path: app/deploy/`) so the Apps runtime
# never sees package.json and skips its auto `npm install` entirely.
#

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

# Load local, gitignored dev values (catalog/schema/genie/auth mode) when present
# so a maintainer's build stages their real environment. Public defaults live in
# app.yaml as neutral placeholders; this file overrides them without editing it.
[ -f scripts/dev-env.sh ] && . scripts/dev-env.sh

rm -rf deploy
mkdir -p deploy

cp app.yaml deploy/

# Per-environment app.yaml env values. Each is overridden from the matching env
# var when set (so deploying to another workspace needs no edit to app.yaml —
# just export the var before `npm run build`); when unset, app.yaml's own value
# is kept as the default. A value that ends up EMPTY aborts the stage: an empty
# DATABRICKS_GENIE_SPACE_ID is the exact shape the Apps runtime rejects at deploy
# ("Must specify environment variable source using either value or valueFrom"),
# and a wrong-empty catalog/schema silently points the app at the wrong data.
python3 - "$here/deploy/app.yaml" <<'PY'
import os, re, sys

path = sys.argv[1]
text = open(path).read()
# Only override a var when its env value is explicitly set; otherwise keep the
# app.yaml default already present in the file.
overrides = {
    name: os.environ[name]
    for name in ("DATABRICKS_CATALOG", "DATABRICKS_SCHEMA",
                 "DATABRICKS_GENIE_SPACE_ID", "DATABRICKS_AUTH_MODE")
    if name in os.environ
}

def replace_value(text, name, value):
    # Rewrite the `value:` line that immediately follows `- name: <NAME>`.
    pat = re.compile(r"(- name:\s*" + re.escape(name) + r"\s*\n\s*value:\s*).*")
    new, n = pat.subn(lambda m: m.group(1) + value, text, count=1)
    if n != 1:
        sys.exit(f"stage-deploy: could not find env entry {name!r} in app.yaml to override")
    return new

for name, value in overrides.items():
    text = replace_value(text, name, value)

open(path, "w").write(text)

# Fail loudly on any empty resolved value among the four managed env entries.
for name in ("DATABRICKS_CATALOG", "DATABRICKS_SCHEMA",
             "DATABRICKS_GENIE_SPACE_ID", "DATABRICKS_AUTH_MODE"):
    m = re.search(r"- name:\s*" + re.escape(name) + r"\s*\n\s*value:\s*(.*)", text)
    if not m or not m.group(1).strip():
        sys.exit(f"stage-deploy: {name} resolved to an empty value — refusing to "
                 f"stage a deploy the Apps runtime would reject. Set env {name} or "
                 f"restore its value in app/app.yaml.")
print("  app.yaml env: " + (", ".join(f"{k}={v}" for k, v in overrides.items())
                             if overrides else "kept app.yaml defaults (no env overrides)"))
PY

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
