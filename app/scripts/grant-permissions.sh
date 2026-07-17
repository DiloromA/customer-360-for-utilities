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
# Note: the "Ask the map" (Genie) route runs as the app's SERVICE PRINCIPAL
# (it mints an SP `all-apis` token; see geniePlugin.ts resolveToken). So the SP
# must be able to read the curated tables AND read/write the focus_set cohort
# table it populates — hence the app schema + app_focus_set grants below.
#
# Usage:
#   bash scripts/grant-permissions.sh
#   APP_NAME=other-app SCHEMAS="curated_x" bash scripts/grant-permissions.sh

APP_NAME="${APP_NAME:-customer-360-for-utilities}"
CATALOG="${CATALOG:-timstanton_stable}"
# Single schema holding all raw_/curated_/ml_/app_ tables.
SCHEMA="${SCHEMA:-customer_360}"
WAREHOUSE_ID="${WAREHOUSE_ID:-8c35ef80cbacd670}"
PROFILE="${DATABRICKS_PROFILE:-DEFAULT}"

echo "App:       $APP_NAME"
echo "Catalog:   $CATALOG"
echo "Schema:    $SCHEMA"
echo "Warehouse: $WAREHOUSE_ID"
echo "Profile:   $PROFILE"
echo

# Look up the App's service principal client id from the apps API.
sp_id="$(
  databricks apps get "$APP_NAME" --profile "$PROFILE" --output json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["service_principal_client_id"])'
)"
echo "Service principal: $sp_id"
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

run_grant "GRANT USE CATALOG ON CATALOG $CATALOG TO \`$sp_id\`"
run_grant "GRANT USE SCHEMA  ON SCHEMA  $CATALOG.$SCHEMA TO \`$sp_id\`"
run_grant "GRANT SELECT      ON SCHEMA  $CATALOG.$SCHEMA TO \`$sp_id\`"

# app_focus_set is read + written per session by the app SP. MODIFY (not just
# SELECT) is required so the app can INSERT/REPLACE/DELETE the session's rows.
run_grant "GRANT MODIFY ON TABLE $CATALOG.$SCHEMA.app_focus_set TO \`$sp_id\`"

echo
echo "Done. Reload the App in your browser."
