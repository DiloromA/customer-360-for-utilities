# Databricks notebook source
# MAGIC %md
# MAGIC # Curated Layer Contract Assertions — customer_360
# MAGIC
# MAGIC Set-level quality gate for the curated integration contract: the
# MAGIC key, referential, temporal, and grain invariants that `EXPECT`
# MAGIC constraints cannot express because they span rows or tables.
# MAGIC
# MAGIC Each check returns **one row, one integer column** = the violation count.
# MAGIC Severity is `error` (fails the job run) or `warn` (logs only).
# MAGIC
# MAGIC All checks run before any exception is raised, so one run reports
# MAGIC every violation rather than stopping at the first.
# MAGIC
# MAGIC **Self-test:** run with `seed_violation=true` (set the widget below)
# MAGIC to confirm the harness raises `AssertionError` on a known bad query.
# MAGIC Run with `seed_violation=false` to confirm all `error`-severity checks
# MAGIC pass on clean current data.

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
# Set to "true" to seed one intentional violation and confirm the harness
# fails.  Never set to "true" in production job runs.
dbutils.widgets.text("seed_violation", "false")
# Release-config values, threaded from ${var.*} / ${bundle.target}
# in resources/jobs.yml. These drive the config-consistency checks near the end.
# Only scalars are threadable — the scopes *list* checks (#1/#3) live in
# app/scripts/check-release-config.py, which reads the rendered bundle JSON.
dbutils.widgets.text("app_auth_mode", "sp")
dbutils.widgets.text("viewer_grantee", "")
dbutils.widgets.text("bundle_target", "")

import re
from dataclasses import dataclass, field
from typing import List

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value, label):
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema  = _check_id(dbutils.widgets.get("schema").strip(),  "schema")
seed_violation = dbutils.widgets.get("seed_violation").strip().lower() == "true"

app_auth_mode  = dbutils.widgets.get("app_auth_mode").strip().lower()
viewer_grantee = dbutils.widgets.get("viewer_grantee").strip()
bundle_target  = dbutils.widgets.get("bundle_target").strip().lower()

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Check definitions

# COMMAND ----------


@dataclass
class Check:
    name: str
    sql: str
    severity: str  # "error" | "warn"
    description: str = ""


CHECKS: List[Check] = []

# ── Helper — every check SQL must return exactly one row with one integer ──────

def _pk_dupes(table: str, key_cols: str) -> str:
    return f"""
        SELECT COUNT(*) AS violations FROM (
            SELECT {key_cols}, COUNT(*) AS n
            FROM {table}
            GROUP BY {key_cols}
            HAVING n > 1
        )
    """

def _fk_orphans(fact: str, fk_col: str, dim: str, pk_col: str) -> str:
    return f"""
        SELECT COUNT(*) AS violations
        FROM {fact} f
        LEFT JOIN {dim} d ON f.{fk_col} = d.{pk_col}
        WHERE f.{fk_col} IS NOT NULL AND d.{pk_col} IS NULL
    """

def _at_most_one_current(table: str, grain_cols: str) -> str:
    """At most one is_current=true row per grain."""
    return f"""
        SELECT COUNT(*) AS violations FROM (
            SELECT {grain_cols}, COUNT(*) AS n
            FROM {table}
            WHERE is_current = true
            GROUP BY {grain_cols}
            HAVING n > 1
        )
    """

def _is_current_vs_open_end(table: str, end_col: str) -> str:
    """is_current must agree with open-ended (NULL) date interval."""
    return f"""
        SELECT COUNT(*) AS violations FROM (
            SELECT *
            FROM {table}
            WHERE (is_current = true  AND {end_col} IS NOT NULL)
               OR (is_current = false AND {end_col} IS NULL)
        )
    """


# ── 1. Primary-key uniqueness for dims and bridges ─────────────────────────────

for table, key in [
    ("dim_customer",              "customer_id"),
    ("dim_account",               "account_id"),
    ("dim_premise",               "premise_id"),
    ("dim_service_point",         "service_point_id"),
    ("dim_meter",                 "meter_id"),
    ("dim_service_agreement",     "service_agreement_id"),
    ("dim_rate_schedule",         "rate_schedule_id"),
    ("dim_date",                  "date_key"),
    ("dim_agent",                 "agent_id"),
    ("bridge_account_premise",    "account_premise_link_id"),
    ("bridge_premise_owner",      "premise_owner_link_id"),
    ("bridge_customer_hierarchy", "hierarchy_link_id"),
    ("bridge_customer_account",   "customer_account_link_id"),
    ("hierarchy_version",         "hierarchy_version_id"),
    ("meter_installation",        "meter_installation_id"),
]:
    CHECKS.append(Check(
        name=f"pk_unique_{table}",
        sql=_pk_dupes(table, key),
        severity="error",
        description=f"No duplicate {key} values in {table}",
    ))

# ── 2. Orphan FKs for RELY relationships ──────────────────────────────────────

RELY_FKS = [
    # (fact/bridge table, FK column, referenced dim, PK column)
    ("bridge_customer_hierarchy",      "parent_customer_id",     "dim_customer",        "customer_id"),
    ("bridge_customer_hierarchy",      "child_customer_id",      "dim_customer",        "customer_id"),
    ("dim_service_agreement",          "account_id",             "dim_account",         "account_id"),
    ("dim_service_agreement",          "customer_id",            "dim_customer",        "customer_id"),
    ("dim_service_agreement",          "service_point_id",       "dim_service_point",   "service_point_id"),
    ("bridge_account_premise",         "account_id",             "dim_account",         "account_id"),
    ("bridge_account_premise",         "customer_id",            "dim_customer",        "customer_id"),
    ("bridge_account_premise",         "premise_id",             "dim_premise",         "premise_id"),
    ("bridge_premise_owner",           "party_id",               "dim_customer",        "customer_id"),
    ("bridge_premise_owner",           "premise_id",             "dim_premise",         "premise_id"),
    ("meter_installation",             "meter_id",               "dim_meter",           "meter_id"),
    ("meter_installation",             "service_point_id",       "dim_service_point",   "service_point_id"),
    ("meter_installation",             "premise_id",             "dim_premise",         "premise_id"),
    ("fact_meter_readings_monthly",    "account_id",             "dim_account",         "account_id"),
    ("fact_meter_readings_monthly",    "customer_id",            "dim_customer",        "customer_id"),
    ("fact_meter_readings_monthly",    "service_point_id",       "dim_service_point",   "service_point_id"),
    ("fact_meter_readings_monthly",    "premise_id",             "dim_premise",         "premise_id"),
    ("fact_meter_readings_monthly",    "month_end_date_key",     "dim_date",            "date_key"),
    ("fact_customer_billing",          "account_id",             "dim_account",         "account_id"),
    ("fact_customer_billing",          "customer_id",            "dim_customer",        "customer_id"),
    ("fact_customer_billing",          "service_agreement_id",   "dim_service_agreement","service_agreement_id"),
    ("fact_customer_billing",          "service_point_id",       "dim_service_point",   "service_point_id"),
    ("fact_customer_billing",          "date_key",               "dim_date",            "date_key"),
    ("fact_der_adoption",              "customer_id",            "dim_customer",        "customer_id"),
    ("fact_der_adoption",              "premise_id",             "dim_premise",         "premise_id"),
    ("fact_payment_history",           "account_id",             "dim_account",         "account_id"),
    ("fact_payment_history",           "customer_id",            "dim_customer",        "customer_id"),
    ("fact_payment_history",           "payment_date_key",       "dim_date",            "date_key"),
    ("fact_assistance_enrollment",     "customer_id",            "dim_customer",        "customer_id"),
    ("fact_assistance_enrollment",     "enrollment_date_key",    "dim_date",            "date_key"),
    ("fact_active_outage_customer_impact", "customer_id",        "dim_customer",        "customer_id"),
    ("fact_active_outage_customer_impact", "service_point_id",   "dim_service_point",   "service_point_id"),
    ("fact_active_outage_customer_impact", "premise_id",         "dim_premise",         "premise_id"),
    ("fact_legacy_cx_snapshot",        "customer_id",            "dim_customer",        "customer_id"),
    ("fact_legacy_cx_snapshot",        "snapshot_date_key",      "dim_date",            "date_key"),
    ("bridge_customer_account",        "customer_id",            "dim_customer",        "customer_id"),
    ("bridge_customer_account",        "account_id",             "dim_account",         "account_id"),
    ("hierarchy_version",              "root_customer_id",       "dim_customer",        "customer_id"),
    ("hierarchy_version",              "customer_id",            "dim_customer",        "customer_id"),
    ("hierarchy_version",              "account_id",             "dim_account",         "account_id"),
    ("hierarchy_version",              "premise_id",             "dim_premise",         "premise_id"),
    ("hierarchy_version",              "service_point_id",       "dim_service_point",   "service_point_id"),
]

for fact, fk_col, dim, pk_col in RELY_FKS:
    CHECKS.append(Check(
        name=f"fk_{fact}_{fk_col}",
        sql=_fk_orphans(fact, fk_col, dim, pk_col),
        severity="error",
        description=f"No orphan {fact}.{fk_col} -> {dim}.{pk_col}",
    ))

# ── 3. Effective-date non-overlap for temporal bridges ────────────────────────
#
# "No two rows for the same grain grain-key have overlapping validity windows."
# A window [A, B) overlaps [C, D) iff A < D AND C < B.  With NULL end = open.

CHECKS.append(Check(
    name="no_overlap_bridge_account_premise_per_premise",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT a.account_premise_link_id AS id_a, b.account_premise_link_id AS id_b
            FROM bridge_account_premise a
            JOIN bridge_account_premise b
              ON a.premise_id = b.premise_id
             AND a.account_premise_link_id < b.account_premise_link_id
            WHERE a.link_start_date < COALESCE(b.link_end_date, '9999-12-31')
              AND b.link_start_date < COALESCE(a.link_end_date, '9999-12-31')
        )
    """,
    severity="error",
    description="No overlapping account-premise windows for the same premise",
))

CHECKS.append(Check(
    name="bap_closed_rows_have_valid_interval",
    sql="""
        SELECT COUNT(*) AS violations
        FROM bridge_account_premise
        WHERE link_end_date IS NOT NULL AND link_start_date >= link_end_date
    """,
    severity="error",
    description=(
        "bridge_account_premise: every closed link has link_start_date < "
        "link_end_date. An inverted window empties the hierarchy_version "
        "intersection and strands the customer's outage/timeline views."
    ),
))

CHECKS.append(Check(
    name="no_overlap_dim_service_agreement_per_acct_sp",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT a.service_agreement_id AS id_a, b.service_agreement_id AS id_b
            FROM dim_service_agreement a
            JOIN dim_service_agreement b
              ON a.account_id     = b.account_id
             AND a.service_point_id = b.service_point_id
             AND a.service_agreement_id < b.service_agreement_id
            WHERE a.effective_date    < COALESCE(b.termination_date, '9999-12-31')
              AND b.effective_date    < COALESCE(a.termination_date, '9999-12-31')
        )
    """,
    severity="error",
    description="No overlapping service-agreement windows for the same account+service_point",
))

CHECKS.append(Check(
    name="no_overlap_meter_installation_per_sp",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT a.meter_installation_id AS id_a, b.meter_installation_id AS id_b
            FROM meter_installation a
            JOIN meter_installation b
              ON a.service_point_id = b.service_point_id
             AND a.meter_installation_id < b.meter_installation_id
            WHERE a.installation_date < COALESCE(b.removal_date, '9999-12-31')
              AND b.installation_date < COALESCE(a.removal_date, '9999-12-31')
        )
    """,
    severity="error",
    description="No overlapping meter-installation windows for the same service point",
))

# ── 4. is_current consistency for temporal bridges ────────────────────────────

CHECKS.append(Check(
    name="is_current_singular_bridge_account_premise",
    sql=_at_most_one_current("bridge_account_premise", "premise_id"),
    severity="error",
    description="At most one is_current=true link per premise in bridge_account_premise",
))

CHECKS.append(Check(
    name="is_current_singular_dim_service_agreement",
    sql=_at_most_one_current("dim_service_agreement", "account_id, service_point_id"),
    severity="error",
    description="At most one is_current=true agreement per account+service_point",
))

CHECKS.append(Check(
    name="is_current_singular_meter_installation",
    sql=_at_most_one_current("meter_installation", "service_point_id"),
    severity="error",
    description="At most one is_current=true installation per service point",
))

CHECKS.append(Check(
    name="is_current_vs_open_end_bridge_account_premise",
    sql=_is_current_vs_open_end("bridge_account_premise", "link_end_date"),
    severity="error",
    description="bridge_account_premise: is_current agrees with NULL link_end_date",
))

CHECKS.append(Check(
    name="is_current_vs_open_end_meter_installation",
    sql=_is_current_vs_open_end("meter_installation", "removal_date"),
    severity="error",
    description="meter_installation: is_current agrees with NULL removal_date",
))

CHECKS.append(Check(
    name="is_current_vs_open_end_dim_service_agreement",
    sql=_is_current_vs_open_end("dim_service_agreement", "termination_date"),
    severity="error",
    description="dim_service_agreement: is_current agrees with NULL termination_date",
))

CHECKS.append(Check(
    name="is_current_vs_open_end_bridge_premise_owner",
    sql=_is_current_vs_open_end("bridge_premise_owner", "owns_to"),
    severity="error",
    description="bridge_premise_owner: is_current agrees with NULL owns_to",
))

# ── 5. Customer-hierarchy integrity — bridge_customer_hierarchy ───────────────
#
# No cycles, no self-links, no overlapping parent windows for one child,
# is_current agrees with valid_to IS NULL, and depth stays ≤ 1.

CHECKS.append(Check(
    name="bch_no_self_links",
    sql="""
        SELECT COUNT(*) AS violations
        FROM bridge_customer_hierarchy
        WHERE parent_customer_id = child_customer_id
    """,
    severity="error",
    description="bridge_customer_hierarchy: no row where parent_customer_id = child_customer_id",
))

CHECKS.append(Check(
    name="bch_is_current_vs_open_end",
    sql=_is_current_vs_open_end("bridge_customer_hierarchy", "valid_to"),
    severity="error",
    description="bridge_customer_hierarchy: is_current agrees with NULL valid_to",
))

CHECKS.append(Check(
    name="bch_at_most_one_current_parent_per_child",
    sql=_at_most_one_current("bridge_customer_hierarchy", "child_customer_id"),
    severity="error",
    description="bridge_customer_hierarchy: at most one is_current=true parent per child",
))

CHECKS.append(Check(
    name="bch_no_overlapping_parent_windows_per_child",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT a.hierarchy_link_id AS id_a, b.hierarchy_link_id AS id_b
            FROM bridge_customer_hierarchy a
            JOIN bridge_customer_hierarchy b
              ON a.child_customer_id = b.child_customer_id
             AND a.hierarchy_link_id < b.hierarchy_link_id
            WHERE a.valid_from < COALESCE(b.valid_to, DATE'9999-12-31')
              AND b.valid_from < COALESCE(a.valid_to, DATE'9999-12-31')
        )
    """,
    severity="error",
    description="bridge_customer_hierarchy: no overlapping parent windows for the same child",
))

CHECKS.append(Check(
    name="bch_depth_at_most_1",
    sql="""
        SELECT COUNT(*) AS violations
        FROM bridge_customer_hierarchy bch
        -- A cycle or depth > 1 would mean a parent in the bridge is itself a
        -- child somewhere else in the bridge. The model is two tiers, so no
        -- parent_customer_id may appear as a child_customer_id.
        WHERE bch.parent_customer_id IN (
            SELECT child_customer_id FROM bridge_customer_hierarchy
        )
    """,
    severity="error",
    description="bridge_customer_hierarchy: no parent_customer_id is itself a child (depth > 1 / cycle guard)",
))

CHECKS.append(Check(
    name="bch_commercial_parent_rows_are_premise_less",
    sql="""
        SELECT COUNT(*) AS violations
        FROM bridge_customer_hierarchy bch
        JOIN dim_customer dc ON dc.customer_id = bch.parent_customer_id
        -- All commercial_parent rows must carry customer_type='commercial_parent'
        -- in dim_customer (not some other type).
        WHERE dc.customer_type <> 'commercial_parent'
    """,
    severity="error",
    description="bridge_customer_hierarchy: all parent_customer_id rows are commercial_parent in dim_customer",
))

CHECKS.append(Check(
    name="bch_hero_fixtures_exist",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM bridge_customer_hierarchy
    """,
    severity="error",
    description=(
        "bridge_customer_hierarchy: at least one hero-chain row exists. "
        "Chains are now guaranteed by explicit seed mechanism."
    ),
))

# ── Simultaneous multi-site customers ─

CHECKS.append(Check(
    name="multi_site_commercial_customer_exists",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM (
            SELECT customer_id
            FROM bridge_account_premise
            WHERE is_current = true
            GROUP BY customer_id
            HAVING COUNT(DISTINCT premise_id) > 1
        ) m
        JOIN dim_customer c USING (customer_id)
        WHERE c.customer_class = 'Commercial'
    """,
    severity="error",
    description=(
        "At least one is_current Commercial customer occupies >1 premise (Case A chain fixture). "
        "A failure means the guaranteed-chain mechanism collapsed — check n_guaranteed_chains_floor and chain_fraction."
    ),
))

CHECKS.append(Check(
    name="multi_site_residential_customer_exists",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM (
            SELECT customer_id
            FROM bridge_account_premise
            WHERE is_current = true
            GROUP BY customer_id
            HAVING COUNT(DISTINCT premise_id) > 1
        ) m
        JOIN dim_customer c USING (customer_id)
        WHERE c.customer_class = 'Residential'
    """,
    severity="error",
    description=(
        "At least one is_current Residential customer occupies >1 premise (Case B second-home fixture). "
        "A failure means the guaranteed-floor mechanism collapsed — check n_second_homes_floor and second_home_fraction."
    ),
))

# ── 6. Declared fact grain — fact_meter_readings_monthly ──────────────────────
#
# Grain is (account_id, service_point_id, month_end_date_key).  customer_id and
# premise_id are month-end attributions, not GROUP BY keys, so a mid-month
# customer reassignment must produce exactly ONE row per
# (account_id, service_point_id, month) with customer_changed_mid_month=true.

CHECKS.append(Check(
    name="grain_fact_meter_readings_monthly",
    sql=_pk_dupes("fact_meter_readings_monthly",
                  "account_id, service_point_id, month_end_date_key"),
    severity="error",
    description=(
        "No duplicate (account_id, service_point_id, month_end_date_key) rows in "
        "fact_meter_readings_monthly — its declared grain."
    ),
))

# ── 6b. Mid-month reassignment fixture ────────────────────────────────────────
#
# Confirms the synthetic layer actually generates at least one mid-month customer
# reassignment, so the flag above is exercised rather than dead.

CHECKS.append(Check(
    name="mid_month_reassignment_fixture",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM fact_meter_readings_monthly
        WHERE customer_changed_mid_month = true
    """,
    severity="error",
    description=(
        "At least one fact_meter_readings_monthly row has "
        "customer_changed_mid_month=true (account reassignment fixture is "
        "present in the synthetic data)."
    ),
))

# ── 6b-ii. Episode WINDOW PLACEMENT ───────────────────────────────────────────
#
# Structural checks (non-overlap, at-most-one-current, valid intervals) all pass
# on a perfectly well-formed episode that sits entirely OUTSIDE the display
# window — where it is invisible to every fact and to the demo.  A hardcoded
# year in a synthetic date expression fails exactly this way: it drifts out of
# the window as soon as as_of_date moves, while every structural check stays
# green.  These checks assert PLACEMENT, not just structure, and read the window
# from curated_demo_config so they follow as_of_date.

CHECKS.append(Check(
    name="reassignment_episode_inside_window",
    sql="""
        SELECT COUNT(*) AS violations
        FROM bridge_customer_account bca
        CROSS JOIN curated_demo_config cfg
        WHERE bca.valid_to IS NOT NULL
          AND (
                bca.valid_to >= cfg.as_of_date
             OR bca.valid_to <  DATE_ADD(ADD_MONTHS(cfg.as_of_date, -cfg.history_months), 1)
          )
    """,
    severity="error",
    description=(
        "Every closed bridge_customer_account window ends INSIDE the display "
        "window — an ownership transfer dated outside it is invisible to the "
        "AMI facts and cannot drive customer_changed_mid_month."
    ),
))

CHECKS.append(Check(
    name="divestiture_episode_inside_window",
    sql="""
        SELECT COUNT(*) AS violations
        FROM bridge_premise_owner bpo
        CROSS JOIN curated_demo_config cfg
        WHERE bpo.owns_to IS NOT NULL
          AND (
                bpo.owns_to >= cfg.as_of_date
             OR bpo.owns_to <  DATE_ADD(ADD_MONTHS(cfg.as_of_date, -cfg.history_months), 1)
          )
    """,
    severity="error",
    description=(
        "Every closed bridge_premise_owner window ends INSIDE the display "
        "window — a property sale dated after as_of_date would show the demo "
        "a transaction in its own future."
    ),
))

CHECKS.append(Check(
    name="no_fact_dates_after_as_of",
    sql="""
        SELECT COUNT(*) AS violations
        FROM fact_meter_readings_monthly f
        CROSS JOIN curated_demo_config cfg
        WHERE f.month_end_date > LAST_DAY(cfg.as_of_date)
    """,
    severity="error",
    description=(
        "No fact_meter_readings_monthly row is dated past as_of_date — guards "
        "the whole class of hardcoded-year drift when as_of_date moves."
    ),
))

# ── 6c. bridge_customer_account temporal integrity ────────────────────────────

CHECKS.append(Check(
    name="bca_natural_key_unique",
    sql=_pk_dupes("bridge_customer_account", "account_id, valid_from"),
    severity="error",
    description="No duplicate (account_id, valid_from) in bridge_customer_account — its declared grain",
))
CHECKS.append(Check(
    name="bca_no_overlap_per_account",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT a.customer_account_link_id AS id_a, b.customer_account_link_id AS id_b
            FROM bridge_customer_account a
            JOIN bridge_customer_account b
              ON a.account_id = b.account_id
             AND a.customer_account_link_id < b.customer_account_link_id
            WHERE a.valid_from < COALESCE(b.valid_to, DATE'9999-12-31')
              AND b.valid_from < COALESCE(a.valid_to, DATE'9999-12-31')
        )
    """,
    severity="error",
    description="No overlapping customer-account windows for the same account",
))
CHECKS.append(Check(
    name="bca_at_most_one_current_per_account",
    sql=_at_most_one_current("bridge_customer_account", "account_id"),
    severity="error",
    description="At most one is_current=true row per account in bridge_customer_account",
))
CHECKS.append(Check(
    name="bca_is_current_vs_open_end",
    sql=_is_current_vs_open_end("bridge_customer_account", "valid_to"),
    severity="error",
    description="bridge_customer_account: is_current agrees with NULL valid_to",
))
CHECKS.append(Check(
    name="bca_current_customer_agrees_with_dim_account",
    sql="""
        SELECT COUNT(*) AS violations
        FROM bridge_customer_account bca
        JOIN dim_account da ON da.account_id = bca.account_id
        WHERE bca.is_current = true
          AND bca.customer_id <> da.customer_id
    """,
    severity="error",
    description="bridge_customer_account: current row's customer_id agrees with dim_account.customer_id",
))
CHECKS.append(Check(
    name="bca_reassignment_mirrored_in_service_agreement",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            -- Every account whose ownership edge is split must also have its
            -- service agreement split at the SAME date.  The two are independent
            -- edges of the hierarchy_version intersection (edge 2 and edge 4);
            -- splitting only one makes them disagree about who held the account,
            -- and leaves customer_changed_mid_month dead because that flag is
            -- computed from dim_service_agreement, not from this bridge.
            SELECT bca.account_id
            FROM bridge_customer_account bca
            LEFT JOIN dim_service_agreement sa
              ON sa.account_id       = bca.account_id
             AND sa.termination_date = bca.valid_to
            WHERE bca.valid_to IS NOT NULL
              AND sa.service_agreement_id IS NULL
        )
    """,
    severity="error",
    description=(
        "Every closed bridge_customer_account window has a matching "
        "dim_service_agreement termination at the same date (ownership and "
        "agreement edges tell the same story)."
    ),
))

# ── 6d. hierarchy_version integrity ──────────────────────────────────────────

CHECKS.append(Check(
    name="hv_natural_key_unique",
    sql=_pk_dupes("hierarchy_version",
                  "root_customer_id, customer_id, account_id, premise_id, service_point_id, COALESCE(meter_id, -1), valid_from"),
    severity="error",
    description="No duplicate natural key in hierarchy_version",
))
CHECKS.append(Check(
    name="hv_is_current_vs_open_end",
    sql=_is_current_vs_open_end("hierarchy_version", "valid_to"),
    severity="error",
    description="hierarchy_version: is_current agrees with NULL valid_to",
))
CHECKS.append(Check(
    name="hv_at_most_one_root_per_customer_date",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT customer_id, valid_from, COUNT(DISTINCT root_customer_id) AS n
            FROM hierarchy_version
            GROUP BY customer_id, valid_from
            HAVING n > 1
        )
    """,
    severity="error",
    description="hierarchy_version: at most one root_customer_id per customer/valid_from",
))
CHECKS.append(Check(
    name="hv_coverage_per_required_edges",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            -- Only check accounts that have at least one valid downstream path:
            -- a BCA window that overlaps with both a service agreement window
            -- (bca.valid_from < sa.termination_date OR sa.termination_date IS NULL)
            -- and a bridge_account_premise window.
            -- Accounts where no such overlap exists are correctly absent from
            -- hierarchy_version (prior-customer synthetic accounts whose SA
            -- terminated before the BCA opened have no valid path to intersect).
            SELECT bca.account_id
            FROM bridge_customer_account bca
            JOIN dim_service_agreement sa
              ON sa.account_id   = bca.account_id
             AND bca.valid_from  < COALESCE(sa.termination_date, DATE'9999-12-31')
             AND sa.effective_date < COALESCE(bca.valid_to, DATE'9999-12-31')
            JOIN bridge_account_premise bap
              ON bap.account_id  = bca.account_id
             AND bca.valid_from  < COALESCE(bap.link_end_date, DATE'9999-12-31')
             AND bap.link_start_date < COALESCE(bca.valid_to, DATE'9999-12-31')
            GROUP BY bca.account_id
        ) reachable
        LEFT JOIN (
            SELECT account_id FROM hierarchy_version GROUP BY account_id
        ) hv ON hv.account_id = reachable.account_id
        WHERE hv.account_id IS NULL
    """,
    severity="error",
    description=(
        "hierarchy_version: every bridge_customer_account window that has an "
        "overlapping SA + BAP path is represented (trap-4 coverage). Accounts "
        "with zero valid downstream edges are correctly absent."
    ),
))

# ── 6e. bridge_premise_owner temporal integrity ───────────────────────────────

CHECKS.append(Check(
    name="bpo_no_overlap_per_premise_basis",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT a.premise_owner_link_id AS id_a, b.premise_owner_link_id AS id_b
            FROM bridge_premise_owner a
            JOIN bridge_premise_owner b
              ON a.premise_id = b.premise_id
             AND a.basis      = b.basis
             AND a.premise_owner_link_id < b.premise_owner_link_id
            WHERE a.owns_from < COALESCE(b.owns_to, DATE'9999-12-31')
              AND b.owns_from < COALESCE(a.owns_to, DATE'9999-12-31')
        )
    """,
    severity="error",
    description="bridge_premise_owner: no overlapping ownership windows for the same (premise, basis)",
))
CHECKS.append(Check(
    name="bpo_closed_rows_have_valid_interval",
    sql="""
        SELECT COUNT(*) AS violations
        FROM bridge_premise_owner
        WHERE owns_to IS NOT NULL AND owns_from >= owns_to
    """,
    severity="error",
    description="bridge_premise_owner: every closed row has owns_from < owns_to",
))
CHECKS.append(Check(
    name="bpo_divestiture_fixture_exists",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM bridge_premise_owner
        WHERE basis = 'landlord_agreement' AND is_current = false AND owns_to IS NOT NULL
    """,
    severity="error",
    description="bridge_premise_owner: at least one closed landlord_agreement row exists (divestiture fixture)",
))
CHECKS.append(Check(
    name="bpo_divestiture_has_successor",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT closed.premise_id
            FROM bridge_premise_owner closed
            LEFT JOIN bridge_premise_owner successor
              ON successor.premise_id = closed.premise_id
             AND successor.basis = 'landlord_agreement'
             AND successor.owns_from = closed.owns_to
            WHERE closed.basis = 'landlord_agreement' AND closed.is_current = false
              AND successor.premise_owner_link_id IS NULL
        )
    """,
    severity="error",
    description="bridge_premise_owner: every closed landlord_agreement row has a successor edge starting at owns_to",
))

# ── 7. dim_premise_history ─────────────────────────────────────────────────
#
# dim_premise_history must:
#   a. Have a unique (premise_id, valid_from) key.
#   b. Have no overlapping intervals per premise.
#   c. Have exactly one is_current=true row per premise.
#   d. Agree with dim_premise: every premise has at least one history row.
#   e. NOT multiply hierarchy_version's rows (this table must not join into
#      hierarchy_version). There is deliberately no absolute row-count check —
#      a hardcoded count is a scale artifact. See the NOTE below: the isolation
#      is enforced at any scale by the hierarchy_version uniqueness checks.

CHECKS.append(Check(
    name="dph_pk_unique",
    sql=_pk_dupes("dim_premise_history", "premise_id, valid_from"),
    severity="error",
    description="No duplicate (premise_id, valid_from) in dim_premise_history",
))
CHECKS.append(Check(
    name="dph_no_overlapping_intervals",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT a.premise_history_id
            FROM dim_premise_history a
            JOIN dim_premise_history b
              ON  b.premise_id = a.premise_id
             AND  b.premise_history_id < a.premise_history_id
            WHERE a.valid_from      < COALESCE(b.valid_to, '9999-12-31')
              AND b.valid_from      < COALESCE(a.valid_to, '9999-12-31')
        )
    """,
    severity="error",
    description="dim_premise_history: no overlapping intervals per premise",
))
CHECKS.append(Check(
    name="dph_at_most_one_current",
    sql=_at_most_one_current("dim_premise_history", "premise_id"),
    severity="error",
    description="At most one is_current=true row per premise in dim_premise_history",
))
CHECKS.append(Check(
    name="dph_is_current_vs_open_end",
    sql=_is_current_vs_open_end("dim_premise_history", "valid_to"),
    severity="error",
    description="dim_premise_history: is_current agrees with NULL valid_to",
))
CHECKS.append(Check(
    name="dph_every_premise_has_history",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT dp.premise_id
            FROM dim_premise dp
            LEFT JOIN dim_premise_history dph ON dph.premise_id = dp.premise_id
            WHERE dph.premise_id IS NULL
        )
    """,
    severity="error",
    description="dim_premise_history: every dim_premise row has at least one history row",
))
CHECKS.append(Check(
    name="dph_current_matches_dim_premise",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT dph.premise_id
            FROM dim_premise_history dph
            LEFT JOIN dim_premise dp ON dp.premise_id = dph.premise_id
            WHERE dph.is_current = true
              AND dp.premise_id IS NULL
        )
    """,
    severity="error",
    description="dim_premise_history: every current history row has a matching dim_premise row",
))
CHECKS.append(Check(
    name="dph_status_change_fixture_exists",
    sql="""
        SELECT CASE WHEN COUNT(*) < 1 THEN 1 ELSE 0 END AS violations FROM (
            SELECT premise_id, COUNT(*) AS n
            FROM dim_premise_history
            WHERE service_status IN ('active', 'inactive')
            GROUP BY premise_id
            HAVING COUNT(*) >= 3
        )
    """,
    severity="error",
    description="dim_premise_history: at least one premise has 3+ history rows (status change fixture)",
))
CHECKS.append(Check(
    name="dph_classification_change_fixture_exists",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations FROM (
            SELECT premise_id
            FROM dim_premise_history
            GROUP BY premise_id
            HAVING COUNT(DISTINCT service_class) > 1
        )
    """,
    severity="error",
    description="dim_premise_history: at least one premise has a service_class change (classification fixture)",
))
# NOTE: dim_premise_history must not fan out hierarchy_version's rows. There is
# no absolute-count check for this — a hardcoded row count is a scale artifact
# that fails as customer_sample_size grows. The isolation is instead guaranteed
# at any scale by two structural checks above: pk_unique_hierarchy_version (the
# xxhash64 surrogate) and hv_natural_key_unique (the full natural key). If a
# future edit joined dim_premise_history into hierarchy_version, the per-premise
# history versions would multiply that spine's rows into duplicate natural keys,
# which both uniqueness checks would catch regardless of scale.

# ── 7b. fact_work_order ───────────────────────────────────────────────────────

CHECKS.append(Check(
    name="fwo_pk_unique",
    sql=_pk_dupes("fact_work_order", "work_order_id"),
    severity="error",
    description="No duplicate work_order_id in fact_work_order",
))
CHECKS.append(Check(
    name="fwo_premise_fk",
    sql=_fk_orphans("fact_work_order", "premise_id", "dim_premise", "premise_id"),
    severity="error",
    description="fact_work_order: every premise_id FK resolves to dim_premise",
))
CHECKS.append(Check(
    name="fwo_customer_fk",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT wo.work_order_id
            FROM fact_work_order wo
            LEFT JOIN dim_customer dc ON dc.customer_id = wo.customer_id
            WHERE wo.customer_id IS NOT NULL AND dc.customer_id IS NULL
        )
    """,
    severity="error",
    description="fact_work_order: every non-NULL customer_id resolves to dim_customer",
))
CHECKS.append(Check(
    name="fwo_completed_has_date",
    sql="""
        SELECT COUNT(*) AS violations
        FROM fact_work_order
        WHERE status = 'completed' AND completed_at IS NULL
    """,
    severity="error",
    description="fact_work_order: every completed row has a non-NULL completed_at",
))
CHECKS.append(Check(
    name="fwo_open_orders_exist",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM fact_work_order
        WHERE status = 'open'
    """,
    severity="error",
    description="fact_work_order: at least one open order exists (fixture)",
))
CHECKS.append(Check(
    name="fwo_meter_related_orders_exist",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM fact_work_order
        WHERE work_type IN ('meter_exchange', 'meter_investigation')
          AND service_point_id IS NOT NULL
    """,
    severity="error",
    description="fact_work_order: at least one meter-related order with service_point_id exists (fixture)",
))
CHECKS.append(Check(
    name="fwo_premise_only_orders_exist",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM fact_work_order
        WHERE service_point_id IS NULL
    """,
    severity="error",
    description="fact_work_order: at least one premise-only order (service_point_id NULL) exists (fixture)",
))

# ── 7c. complaint premise attribution ─────────────────────────────────────────

CHECKS.append(Check(
    name="fcc_attribution_method_coverage",
    sql="""
        SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS violations
        FROM fact_customer_complaints
        WHERE premise_attribution_method IN (
            'driver_outage', 'driver_bill', 'unique_account_link'
        )
    """,
    severity="error",
    description="fact_customer_complaints: at least one complaint has a resolved premise attribution",
))
CHECKS.append(Check(
    name="fcc_unresolved_complaints_have_null_premise",
    sql="""
        SELECT COUNT(*) AS violations
        FROM fact_customer_complaints
        WHERE premise_attribution_method = 'unresolved'
          AND premise_id IS NOT NULL
    """,
    severity="error",
    description="fact_customer_complaints: unresolved complaints must have NULL premise_id",
))
CHECKS.append(Check(
    name="fcc_resolved_complaints_have_premise",
    sql="""
        SELECT COUNT(*) AS violations
        FROM fact_customer_complaints
        WHERE premise_attribution_method != 'unresolved'
          AND premise_id IS NULL
    """,
    severity="error",
    description="fact_customer_complaints: resolved complaints must have non-NULL premise_id",
))
CHECKS.append(Check(
    name="fcc_premise_fk",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT fcc.complaint_id
            FROM fact_customer_complaints fcc
            LEFT JOIN dim_premise dp ON dp.premise_id = fcc.premise_id
            WHERE fcc.premise_id IS NOT NULL AND dp.premise_id IS NULL
        )
    """,
    severity="error",
    description="fact_customer_complaints: every non-NULL premise_id resolves to dim_premise",
))
CHECKS.append(Check(
    name="fcc_driver_outage_attribution_uses_customer",
    sql="""
        SELECT COUNT(*) AS violations FROM (
            SELECT fcc.complaint_id
            FROM fact_customer_complaints fcc
            WHERE fcc.premise_attribution_method = 'driver_outage'
              AND fcc.driver_outage_id IS NULL
        )
    """,
    severity="error",
    description="fact_customer_complaints: driver_outage attribution requires a non-NULL driver_outage_id",
))

# ── Resolver coverage — every account-bearing customer resolves to a premise ───
#
# customer_outages.sql / customer_active_outage.sql / customer_timeline.sql
# resolve an account_number to its customer, then to premises via
# hierarchy_version keyed on hv.customer_id (direct scope — the customer's own
# service paths, not the parent portfolio roll-up). If a customer with a real
# account has no hierarchy_version row under its own customer_id, all three
# queries return zero rows for that account. Premise-less parties are the only
# legitimate absences: a commercial_parent holds no account (never reached by
# these queries) and a landlord_portfolio party owns premises through
# bridge_premise_owner, not through a service path.

CHECKS.append(Check(
    name="hv_account_customer_has_premise_coverage",
    sql="""
        SELECT COUNT(*) AS violations
        FROM dim_account a
        JOIN dim_customer dc ON dc.customer_id = a.customer_id
        WHERE dc.customer_type NOT IN ('commercial_parent', 'landlord_portfolio')
          AND NOT EXISTS (
            SELECT 1 FROM hierarchy_version hv
            WHERE hv.customer_id = a.customer_id
          )
    """,
    severity="error",
    description=(
        "hierarchy_version: every account-bearing customer (except premise-less "
        "commercial_parent / landlord_portfolio parties) resolves to at least one "
        "row under hv.customer_id — the direct-scope resolver the customer "
        "outage/active-outage/timeline queries join on. A violation here means "
        "those account-keyed queries return zero rows for the affected accounts."
    ),
))

# ── Release-config consistency ─────────────────────────────────
#
# These are *config* checks, not data checks: they assert the target's auth
# configuration cannot be internally inconsistent. They are expressed as trivial
# `SELECT <n> AS violations` so they flow through the same runner/report/gate as
# the data checks. Only the checks expressible from threadable *scalar* widgets
# live here; the scopes-*list* invariants (#1 mode ⟺ scopes non-empty, #3 sp ⟹
# scopes empty) live in app/scripts/check-release-config.py, which reads the
# rendered bundle JSON — DAB will not serialize a complex var into a string
# base_parameter, so the notebook never receives app_user_api_scopes.

def _config_check(name: str, ok: bool, description: str) -> None:
    CHECKS.append(Check(
        name=name,
        sql=f"SELECT {0 if ok else 1} AS violations",
        severity="error",
        description=description,
    ))

# #2 — OBO mode requires a non-empty viewer_grantee (the principal that gets
# SELECT + Genie CAN_RUN, since reads run as the viewer). An empty grantee in OBO
# mode means nobody is granted and every viewer 403s.
_config_check(
    "release_config_obo_requires_grantee",
    ok=not (app_auth_mode == "obo" and viewer_grantee == ""),
    description=f"OBO mode must set viewer_grantee (mode={app_auth_mode!r}, grantee={viewer_grantee!r})",
)

# #4 — target `internal` must resolve to app_auth_mode == "obo". Internal OBO is
# workspace POLICY, not a preference, so an SP-mode internal deploy must
# fail the suite, not merely look wrong in a diff. Skipped when bundle_target is
# unknown (e.g. a bare notebook run outside the bundle).
if bundle_target == "internal":
    _config_check(
        "release_config_internal_is_obo",
        ok=app_auth_mode == "obo",
        description=f"target 'internal' must be OBO by workspace policy (got mode={app_auth_mode!r})",
    )

# ── Seeded violation (harness self-test) ──────────────────────────────────────
#
# When seed_violation=true, inject one intentionally bad check that returns
# violation count = 1.  Use only to verify that the harness raises AssertionError.
# Never set to true in production job runs.

if seed_violation:
    CHECKS.insert(0, Check(
        name="HARNESS_SELF_TEST_intentional_violation",
        sql="SELECT 1 AS violations",
        severity="error",
        description="Intentional seeded violation — confirms the harness fails correctly",
    ))

# COMMAND ----------

# MAGIC %md
# MAGIC ## Run all checks

# COMMAND ----------

from pyspark.sql import Row

results = []

for check in CHECKS:
    try:
        row = spark.sql(check.sql).collect()[0]
        violations = int(row[0])
    except Exception as exc:
        violations = -1
        print(f"ERROR executing check {check.name!r}: {exc}")

    results.append({
        "check": check.name,
        "severity": check.severity,
        "violations": violations,
        "pass": violations == 0,
        "description": check.description,
    })

# Pretty-print result table
header = f"{'CHECK':<60} {'SEV':<6} {'VIOLATIONS':>10}  {'STATUS'}"
print(header)
print("-" * len(header))
for r in results:
    status = "PASS" if r["pass"] else ("FAIL" if r["severity"] == "error" else "WARN")
    print(f"{r['check']:<60} {r['severity']:<6} {r['violations']:>10}  {status}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Gate — fail on any error-severity violation

# COMMAND ----------

failures = [r for r in results if not r["pass"] and r["severity"] == "error"]

if failures:
    lines = [f"  {f['check']}: {f['violations']} violation(s)" for f in failures]
    raise AssertionError(
        f"Contract assertion failures ({len(failures)}):\n" + "\n".join(lines)
    )

print(f"All {len(CHECKS)} checks passed.")
