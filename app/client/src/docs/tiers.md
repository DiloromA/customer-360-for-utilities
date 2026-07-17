## From raw signals to a working app

Everything you're looking at in this demo — the map, the customer profiles, the
cohorts — is built up through four layers, or **tiers**. Each tier has one job,
and every table's tier is visible right in its name (`raw_…`, `dim_/fact_/bridge_/metric_…`,
`ml_…`, `app_…`), so you can always tell what you're looking at at a glance.

### `raw` — the inputs

Building footprints, county boundaries, solar potential, load profiles — real
public data, pulled in as-is. On top of that sit 13 synthetic generators that
fill in what no public dataset provides: meters, billing history, outages,
complaints, digital engagement. Real geography and climate, synthetic customer
behavior — that's what makes ~1,000 believable customers out of open data
alone.

### `curated` — the star schema

The raw inputs get reshaped into a proper dimensional model: customers,
accounts, premises, meters — related through clean, durable keys. This is the
layer everything else builds on, and it's detailed enough to get its own page —
see **The Curated Star Schema**, and the live **Data Model** view for the
interactive diagram.

### `ml` — predictions

Machine-learned features and predictions sit in their own tier, read-only from
`curated` and written back as their own tables. Today that's EV detection from
AMI load patterns; the pattern is designed to add more models without
disturbing anything upstream.

### `app` — what the app remembers

A small amount of session state the app itself owns, like saved focus sets —
distinct from the analytical data above it, and small by design.

### Why it matters

One Job runs the whole chain end to end — ingest, synthesize, curate, model —
into a **single catalog and schema**. Nothing is hidden behind a dozen
schemas or a tangle of pipelines: it's a straight, inspectable line from a
public building footprint to a targeted marketing cohort.
