# Databricks notebook source
# MAGIC %md
# MAGIC # focus_set setup — `app_focus_set`
# MAGIC
# MAGIC Creates the **focus set** carrier table that backs the executive map's
# MAGIC cohort scoping ("Ask the map", filter/lasso selections). One row per
# MAGIC (session, customer); the table is discriminated by `session_id` (a
# MAGIC per-load client session key, NOT the Genie conversationId) so every browser
# MAGIC session has its own isolated cohort in a single shared table.
# MAGIC
# MAGIC Intentional convention divergences:
# MAGIC - Hard rule #12 ("runtime state not in UC"): this is session/runtime-ish
# MAGIC   state, but Genie can only reach a UC table (it runs on the SQL warehouse
# MAGIC   over UC, not Lakebase). Mitigated by short TTL (`03_focus_set_ttl.py`).
# MAGIC - Hard rule #14 ("SDP for all data processing"): `focus_set` is written
# MAGIC   transactionally per session by the app, not by a pipeline — SDP cannot
# MAGIC   express per-session upserts. Legitimate operational exception.
# MAGIC
# MAGIC Idempotent (`CREATE TABLE IF NOT EXISTS`). Run once after `bundle deploy`.

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("app_schema", "customer_360")

import re

_SAFE = re.compile(r"^[a-zA-Z0-9_]+$")


def _check(value: str, label: str) -> str:
    if not _SAFE.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check(dbutils.widgets.get("catalog").strip(), "catalog")
app_schema = _check(dbutils.widgets.get("app_schema").strip(), "app_schema")
fq = f"{catalog}.{app_schema}.app_focus_set"
print(f"Target table: {fq}")

# COMMAND ----------

spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS {fq} (
      session_id  STRING    NOT NULL COMMENT 'Per-load client session key (NOT the Genie conversationId). Isolates one cohort per session.',
      customer_id BIGINT    NOT NULL COMMENT 'dim_customer.customer_id in this session''s focus cohort.',
      created_at  TIMESTAMP          COMMENT 'When this cohort row was written; drives TTL sweep.',
      premise_id  BIGINT             COMMENT 'When set, this cohort row is scoped to ONE premise (spatial hex/box selection). NULL = the whole customer, all premises (query/attribute/account cohorts).'
    )
    USING DELTA
    CLUSTER BY (session_id)
    COMMENT 'Per-session focus cohort (focus set) backing the executive map. One row per (session, customer) or, for spatial selections, (session, customer, premise). Ephemeral; swept by the app_focus_set_ttl job.'
    """
)
print(f"Ensured {fq}")

# COMMAND ----------

# Table already deployed before premise_id existed — idempotent add for
# upgrade-in-place. Existing rows are ephemeral/TTL-swept, so no back-fill.
# `ADD COLUMN IF NOT EXISTS` isn't supported on all SQL warehouse versions, so
# the idempotency check happens here in Python instead.
existing_cols = {row.col_name for row in spark.sql(f"DESCRIBE TABLE {fq}").collect()}
if "premise_id" not in existing_cols:
    spark.sql(
        f"""
        ALTER TABLE {fq} ADD COLUMN
        premise_id BIGINT COMMENT 'When set, this cohort row is scoped to ONE premise (spatial hex/box selection). NULL = the whole customer, all premises (query/attribute/account cohorts).'
        """
    )
    print("Added premise_id column.")
else:
    print("premise_id column already present.")

# Grain-aware focus contract: grain and subject_key identify which
# viewing grain and natural-key entity defined this cohort. Both nullable so
# legacy rows (written before this migration) remain valid.
if "grain" not in existing_cols:
    spark.sql(
        f"""
        ALTER TABLE {fq} ADD COLUMN
        grain STRING COMMENT 'Grain that defined this cohort row: customer | account | premise. NULL for legacy rows written before the grain contract.'
        """
    )
    print("Added grain column.")
else:
    print("grain column already present.")

if "subject_key" not in existing_cols:
    spark.sql(
        f"""
        ALTER TABLE {fq} ADD COLUMN
        subject_key STRING COMMENT 'Opaque subject key "<grain>:<naturalKey>" identifying the entity that defined this cohort. NULL for legacy rows.'
        """
    )
    print("Added subject_key column.")
else:
    print("subject_key column already present.")

# COMMAND ----------

# Resource tags (hard rule #13). Schemas use properties (DAB), tables use TAGS.
for key, value in (
    ("managed_by", "databricks-demos"),
    ("area", "demos"),
    ("dir_name", "customer_360"),
):
    spark.sql(f"ALTER TABLE {fq} SET TAGS ('{key}' = '{value}')")
print("Tags applied.")
