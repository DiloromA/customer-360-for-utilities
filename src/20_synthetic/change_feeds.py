# Databricks notebook source
# MAGIC %md
# MAGIC # Change Feeds — customer_changes & account_changes (plain Delta tables)
# MAGIC
# MAGIC These two append-only CDC feeds drive the curated SCD Type 2 streaming
# MAGIC dimensions via Databricks **AUTO CDC ... STORED AS SCD TYPE 2**. AUTO CDC
# MAGIC requires a STREAMING source, and Databricks does not allow streaming from
# MAGIC a materialized view — so (unlike the rest of this SDP-only bundle) the
# MAGIC feeds are written here as plain managed Delta tables, which ARE
# MAGIC streamable. This is a deliberate, documented exception to the otherwise
# MAGIC SDP-only design, to enable the genuine AUTO CDC feature in the curated layer.
# MAGIC
# MAGIC Both feeds are recomputed deterministically (xxhash64) and OVERWRITTEN
# MAGIC each run; the curated SCD2 tables therefore run triggered + full-refresh
# MAGIC (reprocessing the whole feed reconstructs identical history). Runs after
# MAGIC the pipeline builds `customer` / `customer_account`.

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
dbutils.widgets.text("random_seed", "42")
dbutils.widgets.text("as_of_date", "2018-12-31")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")
_SAFE_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _check(value, pattern, label):
    if not pattern.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check(dbutils.widgets.get("catalog").strip(), _SAFE_ID, "catalog")
schema = _check(dbutils.widgets.get("schema").strip(), _SAFE_ID, "schema")
seed = _check(dbutils.widgets.get("random_seed").strip(), re.compile(r"^-?\d+$"), "random_seed")
as_of = _check(dbutils.widgets.get("as_of_date").strip(), _SAFE_DATE, "as_of_date")

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")
print(f"Writing change feeds to {catalog}.{schema} (seed={seed}, as_of={as_of})")

# COMMAND ----------

# customer_changes — SEED row per customer (profile as of customer_since_date)
# + an UPDATE row for the ~50% of critical-care customers who registered
# mid-window (pre-registration version carries critical_care_flag = FALSE).
spark.sql(f"""
CREATE OR REPLACE TABLE raw_customer_changes AS
WITH base AS (
  SELECT
    customer_id, customer_type, n_premises_owned, customer_class, income_band,
    household_size, age_band_hoh, language_preference, tenure, liheap_eligible,
    customer_since_date, critical_care_flag, is_prior_customer,
    (critical_care_flag AND NOT is_prior_customer
       AND abs(xxhash64(customer_id, 'cc_register', {seed})) % 100 < 50) AS cc_registered_midwindow,
    DATE_ADD(DATE'2017-01-01',
             CAST(abs(xxhash64(customer_id, 'cc_date', {seed})) % 700 AS INT)) AS cc_change_date
  FROM raw_customer
),
seed AS (
  SELECT
    customer_id, customer_type, n_premises_owned, customer_class, income_band,
    household_size, age_band_hoh, language_preference, tenure, liheap_eligible,
    customer_since_date,
    CASE WHEN cc_registered_midwindow THEN false ELSE critical_care_flag END AS critical_care_flag,
    is_prior_customer,
    CAST(customer_since_date AS TIMESTAMP) AS change_ts,
    'INSERT' AS operation
  FROM base
),
chg AS (
  SELECT
    customer_id, customer_type, n_premises_owned, customer_class, income_band,
    household_size, age_band_hoh, language_preference, tenure, liheap_eligible,
    customer_since_date,
    true AS critical_care_flag,
    is_prior_customer,
    CAST(cc_change_date AS TIMESTAMP) AS change_ts,
    'UPDATE' AS operation
  FROM base
  WHERE cc_registered_midwindow
)
SELECT customer_id, customer_type, n_premises_owned, customer_class, income_band,
       household_size, age_band_hoh, language_preference, tenure, liheap_eligible,
       customer_since_date, critical_care_flag, is_prior_customer, change_ts, operation,
       current_timestamp() AS _ingested_at
FROM seed
UNION ALL
SELECT customer_id, customer_type, n_premises_owned, customer_class, income_band,
       household_size, age_band_hoh, language_preference, tenure, liheap_eligible,
       customer_since_date, critical_care_flag, is_prior_customer, change_ts, operation,
       current_timestamp() AS _ingested_at
FROM chg
""")
print("  raw_customer_changes:", spark.table("raw_customer_changes").count(), "rows")

# COMMAND ----------

# account_changes — SEED row per account (baseline active at account_opened_date)
# + an UPDATE row for accounts that later suspended/closed (live mid-window;
# prior-customer accounts just before the 2017 fact window).
spark.sql(f"""
CREATE OR REPLACE TABLE raw_account_changes AS
WITH base AS (
  SELECT
    a.account_id, a.customer_id, a.premise_id, a.parent_account_id, a.account_group,
    a.customer_class, a.rate_schedule, a.autopay_enrolled, a.paperless_enrolled,
    a.marketing_consent, a.preferred_channel, a.account_opened_date, a.current_status,
    c.is_prior_customer,
    (a.current_status IN ('suspended','closed') AND NOT c.is_prior_customer) AS status_changed_midwindow,
    LEAST(DATE'{as_of}',
          DATE_ADD(a.account_opened_date,
                   CAST(90 + abs(xxhash64(a.account_id, 'status_date', {seed})) % 400 AS INT))) AS status_change_date
  FROM raw_customer_account a
  JOIN raw_customer c ON a.customer_id = c.customer_id
),
seed AS (
  SELECT
    account_id, customer_id, premise_id, parent_account_id, account_group,
    customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
    marketing_consent, preferred_channel, account_opened_date,
    'active' AS current_status,
    CAST(account_opened_date AS TIMESTAMP) AS change_ts,
    'INSERT' AS operation
  FROM base
),
chg AS (
  SELECT
    account_id, customer_id, premise_id, parent_account_id, account_group,
    customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
    marketing_consent, preferred_channel, account_opened_date,
    current_status,
    CAST(status_change_date AS TIMESTAMP) AS change_ts,
    'UPDATE' AS operation
  FROM base
  WHERE status_changed_midwindow
  UNION ALL
  SELECT
    account_id, customer_id, premise_id, parent_account_id, account_group,
    customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
    marketing_consent, preferred_channel, account_opened_date,
    'closed' AS current_status,
    CAST(DATE'2016-12-15' AS TIMESTAMP) AS change_ts,
    'UPDATE' AS operation
  FROM base
  WHERE is_prior_customer
)
SELECT account_id, customer_id, premise_id, parent_account_id, account_group,
       customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
       marketing_consent, preferred_channel, account_opened_date, current_status,
       change_ts, operation, current_timestamp() AS _ingested_at
FROM seed
UNION ALL
SELECT account_id, customer_id, premise_id, parent_account_id, account_group,
       customer_class, rate_schedule, autopay_enrolled, paperless_enrolled,
       marketing_consent, preferred_channel, account_opened_date, current_status,
       change_ts, operation, current_timestamp() AS _ingested_at
FROM chg
""")
print("  raw_account_changes:", spark.table("raw_account_changes").count(), "rows")
