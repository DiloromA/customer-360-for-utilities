#!/usr/bin/env bash
set -euo pipefail

# Grant the App's service principal USE CATALOG + USE SCHEMA + SELECT on
# every UC schema the App reads. Databricks Apps run as a dedicated SP that
# does NOT inherit the deploying user's grants, so without this step every
# query returns
# [INSUFFICIENT_PERMISSIONS] User does not have USE SCHEMA on Schema 'X'.
#
# Run AFTER `databricks bundle deploy` + `bundle run <app>` has created the
# SP, and AFTER the curated bundle has created the schema.
#
# Note: in SP mode the "Ask the map" (Genie) route and every read run as the
# app's SERVICE PRINCIPAL (it mints an SP `all-apis` token; see geniePlugin.ts
# resolveToken). So the SP must be able to read the curated tables AND read/write
# the focus_set cohort table it populates — hence the app schema + app_focus_set
# grants below.
#
# AUTH_MODE selects WHO is granted (keep both paths, do not delete
# the SP path):
#   sp  (default) → grant the app's service principal (today's behavior).
#   obo           → grant $GRANTEE (the signed-in viewer principal), since under
#                   OBO every read runs as the viewer, not the SP.
# Note: in obo mode only $GRANTEE needs data grants (the app reads as the viewer).
# If you also want the app's own SP to read in obo mode as a fallback, the SP must
# ALSO be on the warehouse ACL.
#
# Usage:
#   bash scripts/grant-permissions.sh                                  # sp mode
#   AUTH_MODE=obo GRANTEE='account users' bash scripts/grant-permissions.sh
#   APP_NAME=other-app SCHEMAS="curated_x" bash scripts/grant-permissions.sh

# Load local, gitignored dev values (catalog/schema/warehouse) when present, so a
# maintainer's own environment overrides the neutral defaults below automatically.
_sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_sd/dev-env.sh" ] && . "$_sd/dev-env.sh"

APP_NAME="${APP_NAME:-customer-360-for-utilities}"
CATALOG="${CATALOG:-main}"
# Single schema holding all raw_/curated_/ml_/app_ tables.
SCHEMA="${SCHEMA:-customer_360}"
# Your workspace's SQL warehouse id — required (statements run against it).
WAREHOUSE_ID="${WAREHOUSE_ID:-}"
PROFILE="${DATABRICKS_PROFILE:-DEFAULT}"
AUTH_MODE="${AUTH_MODE:-sp}"
GRANTEE="${GRANTEE:-account users}"

echo "App:       $APP_NAME"
echo "Catalog:   $CATALOG"
echo "Schema:    $SCHEMA"
echo "Warehouse: $WAREHOUSE_ID"
echo "Profile:   $PROFILE"
echo "Auth mode: $AUTH_MODE"
echo

if [ "$AUTH_MODE" = "obo" ]; then
  # OBO: grant the signed-in viewer principal. `GRANT … TO \`$GRANTEE\`` is
  # type-agnostic in SQL, so a group ('account users') or a user email both work
  # without a group_name/user_name distinction (unlike the Genie ACL API — see
  # 01_create_genie_space.py, which needs the user-vs-group heuristic).
  grantee_principal="$GRANTEE"
  echo "Grantee (viewer): $grantee_principal"
elif [ "$AUTH_MODE" = "sp" ]; then
  # SP: look up the App's service principal client id from the apps API.
  grantee_principal="$(
    databricks apps get "$APP_NAME" --profile "$PROFILE" --output json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["service_principal_client_id"])'
  )"
  echo "Grantee (service principal): $grantee_principal"
else
  echo "ERROR: AUTH_MODE must be 'sp' or 'obo' (got '$AUTH_MODE')." >&2
  exit 1
fi
echo

run_grant() {
  local stmt="$1"
  python3 -c "import json; print(json.dumps({'warehouse_id': '$WAREHOUSE_ID', 'statement': '''$stmt''', 'wait_timeout': '15s'}))" > /tmp/_grant.json
  local state
  state="$(
    databricks api post /api/2.0/sql/statements --json @/tmp/_grant.json --profile "$PROFILE" 2>&1 \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",{}).get("state","?"))'
  )"
  echo "  $state  $stmt"
}

run_grant "GRANT USE CATALOG ON CATALOG $CATALOG TO \`$grantee_principal\`"
run_grant "GRANT USE SCHEMA  ON SCHEMA  $CATALOG.$SCHEMA TO \`$grantee_principal\`"
run_grant "GRANT SELECT      ON SCHEMA  $CATALOG.$SCHEMA TO \`$grantee_principal\`"

# app_focus_set is read + written per session by whoever runs the query (the app
# SP in sp mode, the viewer in obo mode). MODIFY (not just SELECT) is required so
# the app can INSERT/REPLACE/DELETE the session's rows. In obo mode this widens
# MODIFY to the viewer principal ($GRANTEE).
# flags; REPLACE WHERE session_id still isolates each session's rows.
run_grant "GRANT MODIFY ON TABLE $CATALOG.$SCHEMA.app_focus_set TO \`$grantee_principal\`"

echo
echo "Done. Reload the App in your browser."
