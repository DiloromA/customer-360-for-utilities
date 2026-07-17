# Databricks notebook source
# MAGIC %md
# MAGIC # List FEMA USA Structures state deliverables → task value
# MAGIC
# MAGIC Lists the public S3 bucket
# MAGIC `s3://fema-femadata/Partners/ORNL/USA_Structures/` and emits
# MAGIC `[{"state": ..., "s3_key": ...}]` for the downstream `for_each_task`.
# MAGIC The S3 listing is anonymous (no AWS creds needed).
# MAGIC
# MAGIC Set `states_filter` (comma-separated state names) to restrict the run for
# MAGIC quick iteration; leave empty to download every state/territory.

# COMMAND ----------

dbutils.widgets.text("states_filter", "")

filter_raw = dbutils.widgets.get("states_filter").strip()
states_filter: set[str] = {s.strip() for s in filter_raw.split(",") if s.strip()}

# COMMAND ----------

from xml.etree import ElementTree

import requests

S3_BASE = "https://fema-femadata.s3.amazonaws.com"
USA_STRUCTURES_PREFIX = "Partners/ORNL/USA_Structures/"
S3_NS = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}


def list_state_folders() -> list[str]:
    """One folder per state/territory under the USA Structures root."""
    resp = requests.get(
        S3_BASE,
        params={"list-type": "2", "prefix": USA_STRUCTURES_PREFIX, "delimiter": "/"},
        timeout=30,
    )
    resp.raise_for_status()
    root = ElementTree.fromstring(resp.text)
    return [
        cp.find("s3:Prefix", S3_NS).text
        for cp in root.findall("s3:CommonPrefixes", S3_NS)
        if cp.find("s3:Prefix", S3_NS) is not None
    ]


def list_prefix_keys(prefix: str) -> list[str]:
    """All keys under a prefix, paging through continuation tokens."""
    keys: list[str] = []
    continuation_token: str | None = None
    while True:
        params = {"list-type": "2", "prefix": prefix}
        if continuation_token:
            params["continuation-token"] = continuation_token
        resp = requests.get(S3_BASE, params=params, timeout=30)
        resp.raise_for_status()
        root = ElementTree.fromstring(resp.text)
        for contents in root.findall("s3:Contents", S3_NS):
            key_el = contents.find("s3:Key", S3_NS)
            if key_el is not None and key_el.text:
                keys.append(key_el.text)
        truncated = root.find("s3:IsTruncated", S3_NS)
        if truncated is not None and truncated.text == "true":
            token_el = root.find("s3:NextContinuationToken", S3_NS)
            continuation_token = token_el.text if token_el is not None else None
        else:
            break
    return keys


# COMMAND ----------

folders = list_state_folders()
print(f"Discovered {len(folders)} state/territory folders.")

deliverables: list[dict] = []
for folder in sorted(folders):
    state = folder.rstrip("/").split("/")[-1]
    if states_filter and state not in states_filter:
        continue
    keys = list_prefix_keys(folder)
    # Each folder publishes versioned "Deliverable" zips; take the latest.
    zips = sorted(k for k in keys if "Deliverable" in k and k.endswith(".zip"))
    if not zips:
        print(f"  {state}: no deliverable zip found, skipping")
        continue
    deliverables.append({"state": state, "s3_key": zips[-1]})

if states_filter:
    missing = states_filter - {d["state"] for d in deliverables}
    if missing:
        raise ValueError(
            f"states_filter requested unknown states: {sorted(missing)}. "
            f"Discovered: {sorted({f.rstrip('/').split('/')[-1] for f in folders})}"
        )

if not deliverables:
    raise RuntimeError("No deliverables to download — check states_filter / S3 listing.")

print(f"\nEmitting {len(deliverables)} state deliverable(s):")
for d in deliverables:
    print(f"  - {d['state']}")

# COMMAND ----------

dbutils.jobs.taskValues.set(key="states", value=deliverables)
