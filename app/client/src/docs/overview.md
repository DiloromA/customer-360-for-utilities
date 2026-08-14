## Overview

Customer 360 for Utilities is a reference solution that assembles a utility's
customer, premise, and operational data into a single governed model and a map-
first application for exploring it. This documentation covers three things: the
**data model**, the **application architecture**, and the **use cases and
business value** it delivers to each part of the utility.

### How it's built

Everything is organized into four tiers, and each table's tier is visible in its
name:

- **`raw_*`** — inputs. Real public data (FEMA/ORNL building footprints, US
  Census county boundaries, NREL weather and building load shapes) plus
  synthetic generators standing in for a utility's private operational systems.
- **`dim_/fact_/bridge_/metric_*`** — the curated star schema and governed
  metric views. → [The data model](doc:data-model)
- **`ml_*`** — machine-learned predictions, written back as their own tables.
- **`app_*`** — a small amount of session state the app owns.

One job runs the whole chain — ingest, synthesize, curate, model — into a
**single catalog and schema**. The demo's clock is frozen at **December 31,
2018**, so every effective-dated result is reproducible from run to run.

### Bring your own data

The synthetic `raw_*` tables are the integration seam: a utility replaces them
with its own billing, AMI, and CRM feeds of the same shape, and the curated
model, metric views, ML, and app run unchanged. The table-by-table contract is
in the repo (`docs/curated-layer-contract.md`).
