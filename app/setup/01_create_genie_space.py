# Databricks notebook source
# MAGIC %md
# MAGIC # Create / Update Genie Space — Customer 360 "Ask the Map"
# MAGIC
# MAGIC Ships a Genie space over the curated schema so the Executive (CCO) map can
# MAGIC answer multi-turn natural-language questions and narrow the customers
# MAGIC shown on the map turn by turn, e.g.:
# MAGIC
# MAGIC > "Show me the customers who complain about high bills"
# MAGIC > → "Of those, which are in the top 25% for annual energy usage?"
# MAGIC
# MAGIC The app's `/api/genie/ask` route calls this space via the Genie
# MAGIC Conversation API and renders the returned `customer_id`s as map dots.
# MAGIC
# MAGIC Managed via REST API — Genie spaces are not yet first-class DAB
# MAGIC resources.
# MAGIC
# MAGIC ## serialized_space v2 — instruction channels
# MAGIC Business semantics live in structured channels Genie is designed to read
# MAGIC (`instructions.sql_snippets.filters`, `instructions.example_question_sqls`,
# MAGIC `benchmarks`), not bolted onto `description`. `description` stays a short
# MAGIC human-facing blurb; `instructions.text_instructions` holds only the
# MAGIC behavioral contract that structured channels can't express (the map's
# MAGIC customer_id/lat-lon output contract, the MAP CONTEXT / FOCUS COHORT preamble
# MAGIC handling, and the metric-view MEASURE() syntax rule).
# MAGIC
# MAGIC Field shapes below were confirmed empirically against a live workspace
# MAGIC (create a throwaway space, PATCH candidate shapes via `manage_genie`, export,
# MAGIC read back what stuck) — the public API docs describe the channels but not
# MAGIC every field name or the "every id-keyed list must be sorted by id" rule.
# MAGIC `join_specs` is deliberately NOT set here: an export of a space over this
# MAGIC schema shows Genie auto-populates join_specs itself (one entry per real UC
# MAGIC FK constraint, `sql: [condition, "--rt=RELATIONSHIP_TYPE--"]`) straight from
# MAGIC this schema's 79 real FK constraints (NOT ENFORCED RELY) — nothing to add by
# MAGIC hand. The one join pattern FKs can't express (point-in-time / half-open
# MAGIC windows) is taught via an example_question_sqls entry instead.

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("curated_schema", "customer_360")
dbutils.widgets.text("app_schema", "customer_360")
dbutils.widgets.text("warehouse_id", "")
dbutils.widgets.text("workspace_folder", "")
# App name — used to look up the app's service principal and grant it CAN_RUN on
# the space (the app runs as a dedicated SP that does not inherit deployer grants).
dbutils.widgets.text("app_name", "")

import hashlib
import json
import re

import requests

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value: str, label: str) -> str:
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
curated_schema = _check_id(dbutils.widgets.get("curated_schema").strip(), "curated_schema")
app_schema = _check_id(dbutils.widgets.get("app_schema").strip(), "app_schema")
warehouse_id = _check_id(dbutils.widgets.get("warehouse_id").strip(), "warehouse_id")

print(f"Catalog:        {catalog}")
print(f"Curated schema: {curated_schema}")
print(f"App schema:     {app_schema}")
print(f"Warehouse ID:   {warehouse_id}")


def q(table: str) -> str:
    """Fully-qualified table name in the curated schema, for use in SQL text."""
    return f"{catalog}.{curated_schema}.{table}"


# COMMAND ----------

DISPLAY_NAME = "Customer 360 — Ask the Map"

# description is a short human-facing blurb ONLY (space-list browsing,
# supervisor-agent routing) — everything Genie itself needs to read lives in
# the structured instruction channels below.
DESCRIPTION = (
    "Natural-language exploration of the utility customer base behind the "
    "Customer 360 executive map. Ask who is struggling, where they are, and "
    "narrow a population down step by step. Powers the map's conversational "
    "'ask the map' bar, which renders the customers in each answer as dots."
)

TABLES = sorted(
    [
        f"{catalog}.{curated_schema}.dim_customer",
        f"{catalog}.{curated_schema}.dim_account",
        f"{catalog}.{curated_schema}.dim_premise",
        f"{catalog}.{curated_schema}.dim_premise_h3",
        f"{catalog}.{curated_schema}.dim_service_point",
        f"{catalog}.{curated_schema}.bridge_account_premise",
        f"{catalog}.{curated_schema}.dim_service_agreement",
        f"{catalog}.{curated_schema}.fact_customer_complaints",
        f"{catalog}.{curated_schema}.fact_customer_billing",
        f"{catalog}.{curated_schema}.fact_outage_customer_impact",
        f"{catalog}.{curated_schema}.fact_outage_events",
        f"{catalog}.{curated_schema}.fact_program_enrollment",
        f"{catalog}.{curated_schema}.dim_program",
        # The per-session focus cohort carrier (see FOCUS COHORT instructions).
        f"{catalog}.{app_schema}.app_focus_set",
        # Governed UC Metric Views — the preferred source for aggregate/KPI
        # questions (see the metric-view rule in TEXT_INSTRUCTIONS below). Base
        # tables above stay for row-level "who/where" questions the metric
        # views can't answer (no customer_id/lat-lon, no per-row EXISTS).
        f"{catalog}.{curated_schema}.metric_usage",
        f"{catalog}.{curated_schema}.metric_complaints",
        f"{catalog}.{curated_schema}.metric_reliability",
        f"{catalog}.{curated_schema}.metric_nps",
        f"{catalog}.{curated_schema}.metric_csat",
        f"{catalog}.{curated_schema}.metric_fcr",
        f"{catalog}.{curated_schema}.metric_dsm_uptake",
        f"{catalog}.{curated_schema}.metric_relationships",
        f"{catalog}.{curated_schema}.metric_customer_base",
    ]
)

SAMPLE_QUESTIONS = [
    "Show me the customers who complain about high bills",
    "Of those customers, which are in the top 25% for annual energy usage?",
    "Which customers are payment-stressed and have filed 2 or more complaints in the last 90 days?",
    "How many critical-care customers had more than 4 hours of outages in the last 90 days?",
    "List residential customers with high dissatisfaction risk, with their service address",
    "Which counties have the most LIHEAP-eligible customers not enrolled in any program?",
    "What are the top complaint sub-categories among high-usage customers?",
    "Show high-usage customers who are NOT enrolled in any demand-side program",
    "Who was the billing-responsible account at premise X in 2017?",
    "Which premises had a meter swap, and how many changed occupants over the period?",
]

# ~40 lines: only what structured channels below can't express — the map's
# output contract, the app's conversational preambles, and the metric-view
# syntax rule. Definitional content (joins, key mappings, worked queries)
# lives in join_specs/FK constraints, sql_snippets, and example_question_sqls.
TEXT_INSTRUCTIONS = f"""\
## Schema shape
A utility customer hierarchy: `dim_customer` (person/org, no premise_id — a
customer can hold multiple accounts/premises) → `dim_account` (billing
account; carries `customer_id` and `premise_id`, the join hub) → `dim_premise`
/ `dim_premise_h3` (the physical location; lat/lon on the `_h3` table).
`bridge_account_premise` is the effective-dated occupancy link
(`link_start_date`/`link_end_date`/`is_current`) — use `is_current = true` for
today, or the half-open window for a point in time. All keys are BIGINT
`*_id`; human-readable ids are the `*_number` columns.

## CRITICAL — this powers a map
Whenever the answer is a **set of customers**, ALWAYS include `customer_id`,
`latitude`, and `longitude` in the SELECT (join `dim_customer` → `dim_account`
on `customer_id` → `dim_premise_h3` on `premise_id`, restricting to the
current account via `bridge_account_premise.is_current = true`). The app reads
`customer_id` to render dots on the map. Prefer the full matching set over a
small TOP-N unless a ranking/limit is explicitly requested.

Analytical/aggregate questions (counts, percentages, breakdowns) are equally
welcome — return the aggregated result WITHOUT a `customer_id` column; do not
force a customer list onto an aggregate question.

## MAP CONTEXT preamble
The app may prefix a question with a `[MAP CONTEXT — …]` block: a lat/lon
bounding box plus active filters describing what the user is currently
viewing. Treat "these customers"/"this area"/"here"/"on screen" as that box —
add a `dim_premise_h3.latitude BETWEEN … AND … longitude BETWEEN …` predicate
(via the current account) plus any listed filters, unless asked to broaden.

## FOCUS COHORT preamble
The app may prefix a question with a `[FOCUS COHORT — …]` block: a saved
cohort in `app_focus_set` for the session (`session_id`), a LABELED SEGMENT,
not a hard filter. Join `app_focus_set.customer_id = dim_customer.customer_id`
AND `app_focus_set.session_id = '<the literal id in the preamble>'` (never
guess it). If `app_focus_set.premise_id` is set, also join it to
`bridge_account_premise.premise_id` so a multi-site customer counts only for
the cohort's premise. "these"/"the cohort"/"them" → restrict to it;
"compare"/"vs territory"/"overall" → return both, labeled. An explicit scope
directive in the preamble overrides inference.

## Multi-turn
"Of those customers, which also …" narrows the population from the previous
answer — keep working with the same customer set.

## "Recent" / "last N days" — the data is frozen, do NOT use CURRENT_DATE
This dataset is a frozen snapshot as of a fixed `as_of_date`, not a live feed.
For "recent complaints/outages" or "in the last 90 days", use the precomputed
`dim_customer.recent_complaint_count_90d` / `recent_outage_minutes_90d` /
`recent_outage_events_90d` columns (already windowed relative to `as_of_date`)
— do NOT build your own `CURRENT_DATE`/`current_date()`-relative filter on
`complaint_date`/`affected_start`; today's real-world date is long after the
snapshot, so that always returns zero rows.

## Metric views — aggregate/KPI syntax
For counts/rates/trends/breakdowns, PREFER the `metric_*` views (governed UC
Metric Views) over hand-rolled aggregation on base tables. Query as
`SELECT <dims>, MEASURE(<measure>) AS alias FROM metric_x GROUP BY ALL`, with
dimension/measure names backtick-quoted (they contain spaces). Never
`SELECT *` a metric view or aggregate its columns with `SUM`/`AVG` outside
`MEASURE()` — both fail. Use base tables instead only for individual customer
rows (map dots) or a cross-fact filter a metric view's fixed joins can't
express (e.g. "complaint AND outage" via EXISTS).
"""

# COMMAND ----------

# sql_snippets.filters: the former "Key definitions" bullet list as boolean
# row-level predicates Genie can splice into a WHERE clause, with synonyms so
# it recognizes the vocabulary regardless of exact table context.
FILTERS = [
    {
        "display_name": "Complains about high bills",
        "sql": [
            "category = 'billing' AND sub_category IN ('high_bill_dispute','unexpected_charges')"
        ],
        "synonyms": ["complains about high bills", "billing complaint", "high bill dispute"],
    },
    {
        "display_name": "High usage / heavy user",
        "sql": ["high_user_flag = true"],
        "synonyms": ["high usage", "heavy user", "top quartile energy usage", "top 25% usage"],
    },
    {
        "display_name": "Payment stressed",
        "sql": ["payment_stressed_flag = true"],
        "synonyms": ["payment stressed", "payment stress", "struggling to pay"],
    },
    {
        "display_name": "Dissatisfied / high churn risk",
        "sql": ["churn_risk_band = 'high'"],
        "synonyms": ["dissatisfied", "high churn risk", "likely to escalate", "high dissatisfaction risk"],
    },
    {
        "display_name": "Critical care",
        "sql": ["critical_care_flag = true"],
        "synonyms": ["critical care", "medical priority"],
    },
    {
        "display_name": "LIHEAP eligible",
        "sql": ["liheap_eligible = true"],
        "synonyms": ["liheap eligible", "low-income assistance eligible"],
    },
    {
        "display_name": "Not enrolled in any program",
        "sql": [
            f"NOT EXISTS (SELECT 1 FROM {q('fact_program_enrollment')} fpe "
            "WHERE fpe.customer_id = dim_customer.customer_id "
            "AND fpe.enrollment_status IN ('active','completed'))"
        ],
        "synonyms": ["not enrolled", "not enrolled in any program", "no active program"],
    },
]

# instructions.example_question_sqls: certified queries teaching patterns
# structured channels can't (the map output shape, and the point-in-time
# half-open-window join that FK constraints alone can't express), plus one
# canonical metric-view MEASURE() example.
EXAMPLE_QUESTION_SQLS = [
    {
        "question": "Show me the customers who are payment-stressed, as dots on the map",
        "sql": (
            "SELECT DISTINCT c.customer_id, p.latitude, p.longitude\n"
            f"FROM {q('dim_customer')} c\n"
            f"JOIN {q('dim_account')} a ON a.customer_id = c.customer_id\n"
            f"JOIN {q('bridge_account_premise')} bap "
            "ON bap.account_id = a.account_id AND bap.premise_id = a.premise_id AND bap.is_current\n"
            f"JOIN {q('dim_premise_h3')} p ON p.premise_id = a.premise_id\n"
            "WHERE c.payment_stressed_flag = true"
        ),
    },
    {
        "question": "Who was the billing-responsible account at premise X in 2017?",
        "sql": (
            "SELECT a.account_number\n"
            f"FROM {q('bridge_account_premise')} bap\n"
            f"JOIN {q('dim_premise')} pr ON pr.premise_id = bap.premise_id\n"
            f"JOIN {q('dim_account')} a ON a.account_id = bap.account_id\n"
            "WHERE pr.premise_number = 'X'\n"
            "  AND bap.billing_responsibility_flag = true\n"
            "  AND bap.link_start_date <= DATE '2017-06-01'\n"
            "  AND (bap.link_end_date IS NULL OR bap.link_end_date > DATE '2017-06-01')"
        ),
    },
    {
        "question": "What is our SAIDI by county?",
        "sql": (
            "SELECT `County`, MEASURE(`SAIDI`) AS saidi\n"
            f"FROM {q('metric_reliability')}\n"
            "GROUP BY ALL"
        ),
    },
]

# benchmarks: certified Q&A pairs for the Genie UI's benchmark runner, so
# future edits to this space can be regression-checked. Fixed literals only
# (no CURRENT_DATE) — the data is frozen at as_of_date.
BENCHMARKS = [
    {
        "question": "Show me the customers who complain about high bills",
        "sql": (
            "SELECT DISTINCT c.customer_id, p.latitude, p.longitude\n"
            f"FROM {q('dim_customer')} c\n"
            f"JOIN {q('fact_customer_complaints')} fc ON fc.customer_id = c.customer_id\n"
            f"JOIN {q('dim_account')} a ON a.customer_id = c.customer_id\n"
            f"JOIN {q('bridge_account_premise')} bap "
            "ON bap.account_id = a.account_id AND bap.premise_id = a.premise_id AND bap.is_current\n"
            f"JOIN {q('dim_premise_h3')} p ON p.premise_id = a.premise_id\n"
            "WHERE fc.category = 'billing' AND fc.sub_category IN ('high_bill_dispute','unexpected_charges')"
        ),
    },
    {
        "question": "Which customers are payment-stressed and have filed 2 or more complaints in the last 90 days?",
        "sql": (
            "SELECT DISTINCT c.customer_id, p.latitude, p.longitude\n"
            f"FROM {q('dim_customer')} c\n"
            f"JOIN {q('dim_account')} a ON a.customer_id = c.customer_id\n"
            f"JOIN {q('bridge_account_premise')} bap "
            "ON bap.account_id = a.account_id AND bap.premise_id = a.premise_id AND bap.is_current\n"
            f"JOIN {q('dim_premise_h3')} p ON p.premise_id = a.premise_id\n"
            "WHERE c.payment_stressed_flag = true AND c.recent_complaint_count_90d >= 2"
        ),
    },
    {
        "question": "How many critical-care customers had more than 4 hours of outages in the last 90 days?",
        "sql": (
            "SELECT COUNT(*) AS n\n"
            f"FROM {q('dim_customer')} c\n"
            "WHERE c.critical_care_flag = true AND c.recent_outage_minutes_90d > 240"
        ),
    },
    {
        "question": "Show high-usage customers who are NOT enrolled in any demand-side program",
        "sql": (
            "SELECT DISTINCT c.customer_id, p.latitude, p.longitude\n"
            f"FROM {q('dim_customer')} c\n"
            f"JOIN {q('dim_account')} a ON a.customer_id = c.customer_id\n"
            f"JOIN {q('bridge_account_premise')} bap "
            "ON bap.account_id = a.account_id AND bap.premise_id = a.premise_id AND bap.is_current\n"
            f"JOIN {q('dim_premise_h3')} p ON p.premise_id = a.premise_id\n"
            "WHERE c.high_user_flag = true\n"
            "  AND NOT EXISTS (\n"
            f"    SELECT 1 FROM {q('fact_program_enrollment')} fpe\n"
            "    WHERE fpe.customer_id = c.customer_id AND fpe.enrollment_status IN ('active','completed')\n"
            "  )"
        ),
    },
    {
        "question": "What are the top complaint sub-categories among high-usage customers?",
        "sql": (
            "SELECT fc.sub_category, COUNT(*) AS n\n"
            f"FROM {q('fact_customer_complaints')} fc\n"
            f"JOIN {q('dim_customer')} c ON c.customer_id = fc.customer_id\n"
            "WHERE c.high_user_flag = true\n"
            "GROUP BY fc.sub_category\n"
            "ORDER BY n DESC"
        ),
    },
]

# COMMAND ----------


def _stable_hex_id(value: str) -> str:
    return hashlib.md5(value.encode("utf-8")).hexdigest()


def _sorted_by_id(items: list) -> list:
    # Every id-keyed list in serialized_space (sample_questions, filters,
    # measures, example_question_sqls, text_instructions, benchmarks.questions)
    # must be sorted by its hex id or the import is rejected — confirmed
    # empirically, not documented in the public API reference.
    return sorted(items, key=lambda item: item["id"])


serialized_space = {
    "version": 2,
    "config": {
        "sample_questions": _sorted_by_id(
            [{"id": _stable_hex_id(q_), "question": [q_]} for q_ in SAMPLE_QUESTIONS]
        ),
    },
    "data_sources": {
        "tables": [{"identifier": tid} for tid in TABLES],
    },
    "instructions": {
        "text_instructions": [
            {"id": _stable_hex_id("text_instructions:v2"), "content": [TEXT_INSTRUCTIONS]},
        ],
        "example_question_sqls": _sorted_by_id(
            [
                {
                    "id": _stable_hex_id(f"eqs:{e['question']}"),
                    "question": [e["question"]],
                    "sql": [e["sql"]],
                }
                for e in EXAMPLE_QUESTION_SQLS
            ]
        ),
        "sql_snippets": {
            "filters": _sorted_by_id(
                [
                    {
                        "id": _stable_hex_id(f"filter:{f['display_name']}"),
                        "display_name": f["display_name"],
                        "sql": f["sql"],
                        "synonyms": f["synonyms"],
                    }
                    for f in FILTERS
                ]
            ),
        },
    },
    "benchmarks": {
        "questions": _sorted_by_id(
            [
                {
                    "id": _stable_hex_id(f"benchmark:{b['question']}"),
                    "question": [b["question"]],
                    "answer": [{"format": "SQL", "content": [b["sql"]]}],
                }
                for b in BENCHMARKS
            ]
        ),
    },
}

# COMMAND ----------

ctx = dbutils.notebook.entry_point.getDbutils().notebook().getContext()
host = ctx.apiUrl().get()
token = ctx.apiToken().get()
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

existing_space_id = None
try:
    resp = requests.get(f"{host}/api/2.0/genie/spaces", headers=headers, timeout=30)
    if resp.ok:
        for s in resp.json().get("spaces", []):
            if s.get("title") == DISPLAY_NAME:
                existing_space_id = s.get("space_id") or s.get("id")
                break
except Exception as e:
    print(f"Warning: could not list Genie spaces: {e}")

payload = {
    "title": DISPLAY_NAME,
    "description": DESCRIPTION,
    "warehouse_id": warehouse_id,
    "serialized_space": json.dumps(serialized_space),
}

if existing_space_id:
    resp = requests.patch(
        f"{host}/api/2.0/genie/spaces/{existing_space_id}",
        headers=headers,
        json=payload,
        timeout=60,
    )
    if not resp.ok:
        print(f"Update failed ({resp.status_code}): {resp.text[:500]}")
    resp.raise_for_status()
    space_id = existing_space_id
    action = "Updated"
else:
    payload["table_identifiers"] = TABLES
    resp = requests.post(
        f"{host}/api/2.0/genie/spaces",
        headers=headers,
        json=payload,
        timeout=60,
    )
    if not resp.ok:
        print(f"Create failed ({resp.status_code}): {resp.text[:500]}")
    resp.raise_for_status()
    result = resp.json()
    space_id = result.get("space_id") or result["id"]
    action = "Created"

    workspace_folder = dbutils.widgets.get("workspace_folder").strip()
    if workspace_folder:
        user_name = ctx.userName().get()
        source_path = f"/Users/{user_name}/{DISPLAY_NAME}"
        dest_path = f"{workspace_folder}/{DISPLAY_NAME}"
        requests.post(
            f"{host}/api/2.0/workspace/mkdirs",
            headers=headers,
            json={"path": workspace_folder},
            timeout=30,
        )
        requests.post(
            f"{host}/api/2.0/workspace/move",
            headers=headers,
            json={"source_path": source_path, "destination_path": dest_path},
            timeout=30,
        )

print(f"{action} Genie space: {space_id}")
print(f"URL: {host}/genie/rooms/{space_id}")
print(f"Tables: {len(TABLES)}")

# COMMAND ----------

# Assert the instructions round-tripped — the guard against a repeat of the
# old general_instructions silent-rejection problem this rewrite fixes. Fail
# loudly rather than falling back to stuffing content into description.
verify_resp = requests.get(
    f"{host}/api/2.0/genie/spaces/{space_id}",
    headers={**headers, "Content-Type": "application/json"},
    params={"include_serialized_space": "true"},
    timeout=30,
)
verify_resp.raise_for_status()
verify_body = verify_resp.json()
raw_serialized = verify_body.get("serialized_space")
if not raw_serialized:
    raise RuntimeError(
        "serialized_space missing from GET response after PATCH/POST — "
        "instructions did not round-trip. Aborting rather than silently "
        "leaving the space under-configured."
    )
round_tripped = json.loads(raw_serialized) if isinstance(raw_serialized, str) else raw_serialized
instr = round_tripped.get("instructions", {})
assert instr.get("text_instructions"), "text_instructions did not round-trip"
assert instr.get("example_question_sqls"), "example_question_sqls did not round-trip"
assert instr.get("sql_snippets", {}).get("filters"), "sql_snippets.filters did not round-trip"
assert round_tripped.get("benchmarks", {}).get("questions"), "benchmarks did not round-trip"
print("Verified: text_instructions, example_question_sqls, sql_snippets.filters, and benchmarks all round-tripped.")

# COMMAND ----------

# Grant the app's service principal CAN_RUN on the space. Databricks Apps run as
# a dedicated SP that does NOT inherit the deploying user's grants, so without
# this the app's /api/genie/ask route hits 403 PERMISSION_DENIED on the space
# (same reason scripts/grant-permissions.sh grants the SP on the UC schema). We
# PATCH (merge) so the owner/admin ACEs are preserved. Idempotent — safe to
# re-run, and it re-grants after the app is renamed/redeployed under a new SP.
app_name = dbutils.widgets.get("app_name").strip()
if app_name:
    _check_id(app_name, "app_name")
    try:
        app_resp = requests.get(f"{host}/api/2.0/apps/{app_name}", headers=headers, timeout=30)
        app_resp.raise_for_status()
        sp_client_id = app_resp.json().get("service_principal_client_id")
        if sp_client_id:
            perm_resp = requests.patch(
                f"{host}/api/2.0/permissions/genie/{space_id}",
                headers=headers,
                json={
                    "access_control_list": [
                        {"service_principal_name": sp_client_id, "permission_level": "CAN_RUN"}
                    ]
                },
                timeout=30,
            )
            if perm_resp.ok:
                print(f"Granted CAN_RUN on space to app SP {sp_client_id}")
            else:
                print(f"Warning: could not grant app SP CAN_RUN "
                      f"({perm_resp.status_code}): {perm_resp.text[:300]}")
        else:
            print(f"Warning: app {app_name!r} has no service_principal_client_id yet; "
                  "skipping space grant (run this job again after the app is created).")
    except Exception as e:
        print(f"Warning: could not grant app SP on space: {e}")
else:
    print("No app_name provided; skipping app-SP space grant "
          "(the app will 403 on 'Ask the Map' until the SP is granted CAN_RUN).")

print()
print("➜ Set DATABRICKS_GENIE_SPACE_ID in the app config to this space_id.")
