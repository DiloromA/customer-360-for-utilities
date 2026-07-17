# Databricks notebook source
# MAGIC %md
# MAGIC # focus_set TTL sweep — `app_focus_set`
# MAGIC
# MAGIC Deletes focus-cohort rows older than the retention window. The focus set is
# MAGIC ephemeral per-session state (see `02_focus_set_setup.py`); without a sweep
# MAGIC it would accumulate one cohort per browser session forever. Scheduled daily
# MAGIC by the `app_focus_set_ttl` job (resources/app.yml).

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("app_schema", "customer_360")
dbutils.widgets.text("retention_hours", "24")

import re

_SAFE = re.compile(r"^[a-zA-Z0-9_]+$")


def _check(value: str, label: str) -> str:
    if not _SAFE.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check(dbutils.widgets.get("catalog").strip(), "catalog")
app_schema = _check(dbutils.widgets.get("app_schema").strip(), "app_schema")
retention_hours = int(dbutils.widgets.get("retention_hours").strip())
if retention_hours <= 0:
    raise ValueError(f"retention_hours must be positive: {retention_hours}")
fq = f"{catalog}.{app_schema}.app_focus_set"

# COMMAND ----------

before = spark.table(fq).count()
spark.sql(
    f"DELETE FROM {fq} WHERE created_at < current_timestamp() - INTERVAL {retention_hours} HOURS"
)
after = spark.table(fq).count()
print(f"{fq}: swept {before - after} rows (>{retention_hours}h old); {after} remain.")
