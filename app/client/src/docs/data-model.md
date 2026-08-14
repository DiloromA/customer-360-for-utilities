## The data model

The curated layer is a conventional dimensional model — a star schema any BI
tool, Genie space, or analyst recognizes immediately. Facts hang off shared
dimensions through durable surrogate keys, so revenue, usage, and reliability
questions all answer consistently regardless of the angle.

### Dimensions, facts, bridges

- **Dimensions** — `dim_customer`, `dim_account`, `dim_premise`, `dim_meter`,
  `dim_rate_schedule`, and more. Each carries a stable surrogate key alongside
  its natural business key, so identity survives a source system's renumbering.
- **Facts** — `fact_customer_billing` (charges, payments) and
  `fact_meter_readings_daily` (usage, consumption). Every fact declares real
  foreign keys back to its dimensions, so the relationships are enforced, not
  implied.
- **Bridges** — `bridge_account_premise` resolves the many-to-many reality of
  service: one account can span premises; one premise passes through several
  accounts over time.
- **History** — SCD2 tables (`dim_customer_history`, `dim_account_history`)
  track how a customer or account changed over time, not just its final state.

### Grain

Identity is layered: **customer → account → premise → meter**, with an owner
bridge over premises. This matters for correct counting — a multi-site
commercial customer is one customer across many premises — and the app lets you
switch the counting grain explicitly.

### Governed metric views

Nine `metric_*` views sit on the facts with the business logic baked in — usage,
revenue, complaints, reliability (defined to **IEEE 1366-2022**), NPS, CSAT,
first-contact resolution, DSM uptake, and the customer base. Computed once and
reused everywhere, so Genie, the app, and any dashboard agree by construction.
See the [Metrics Catalog](app:metrics-catalog) for each definition.

### Machine-learned tables

The `ml_*` tier is read-only from `curated` and writes predictions back as its
own tables: EV detection and rooftop-solar (PV) detection from AMI load
patterns, and per-customer complaint-risk scoring. Adding a model doesn't
disturb anything upstream.

**See it live:** the [Data Model](app:data-model) view renders every table and
relationship straight from Unity Catalog metadata, so it's never out of date.
