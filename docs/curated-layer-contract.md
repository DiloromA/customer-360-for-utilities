# The Curated Layer as a Drop-In Contract

**Map your CIS/MDM/AMI into these tables and the app lights up.**

This is an explicit, table-by-table statement of the curated star schema as
the integration contract for a real utility. Everything downstream of the
curated layer — the map app, Genie, the metric views, the ML models — reads
only these tables (plus the derived `metric_*`/`ml_*`/`app_*` objects the
pipeline itself produces). A utility that lands its own data in this shape
gets the whole demo stack against real data, with the synthetic generators
and the demo-date machinery bypassed entirely.

There are two seams, at different depths:

1. **The raw seam** (`ARCHITECTURE.md` §6) — replace the synthetic `raw_*`
   tables source-by-source via the `*_schema` SDP config keys, and keep the
   curated transformations. Right choice when your extracts resemble the
   raw shapes (CIS event dumps, AMI interval files) and you want the
   curated logic (surrogate keying, deduplication, window computation) done
   for you.
2. **The curated seam** (this doc) — populate the `dim_*` / `fact_*` /
   `bridge_*` tables directly from your own pipelines and drop
   `20_synthetic/` + `30_curated/transformations/` altogether. Right choice
   when you already have a governed dimensional layer and only want the
   app/Genie/metrics/ML stack.

Full column lists are deliberately not duplicated here — they live in the
DDL (`src/30_curated/transformations/*.sql`, one file per table, each with
a header comment stating grain and keys), in UC comments
(`information_schema.columns`), and interactively in the in-app
**Documentation → The Curated Star Schema** and **Data Model** pages. This
doc states the contract: identity, grain, temporal semantics, and what
each table feeds.

---

## 1. Conventions (the grammar of the contract)

- **Dual keys.** Every entity carries a durable BIGINT surrogate `*_id`
  (in the demo, `abs(xxhash64(natural_string))` — any stable BIGINT works)
  **and** a STRING natural key `*_number` (your CIS identifier). Facts and
  bridges join on the BIGINT `*_id`; people-facing surfaces and URLs use
  `*_number`.
- **`account_number` is the deep-link identity.** The app's customer
  profile routes are `/csr/:account_number`; Genie answers cite it; the
  focus-set job keys on it. It must be stable and unique per account.
- **Client-side premise identity is `premise_number` (STRING), never
  `premise_id` (BIGINT).** BIGINT surrogates exceed JS safe-integer range
  and get silently corrupted in the browser; the app never ships
  `premise_id` to the client. The same rule holds for any new BIGINT key
  you surface.
- **Effective dating is half-open.** Date-ranged relationships cover
  `[start_date, end_date)`; the live row has `end_date IS NULL` and
  `is_current = true`. Point-in-time resolution is
  `start_date <= d AND (end_date IS NULL OR d < end_date)`. `is_current`
  is a convenience denormalization of the same fact — keep them
  consistent.
- **`date_key` INT (`yyyymmdd`)** on facts, joining `dim_date.date_key`.
- **FKs are genuine UC constraints** (`FOREIGN KEY ... NOT ENFORCED RELY`).
  They are not decoration: the in-app ERD renders from
  `information_schema` constraints, and RELY feeds the optimizer. Declare
  them on your tables (constraint names are schema-scoped; on
  materialized views they can only be managed in the `CREATE OR REFRESH`
  DDL).
- **`_ingested_at TIMESTAMP`** audit column on every table.
- **"Now" is data, not code.** `curated_demo_config` is a 1-row table
  (`as_of_date`, `history_months`, `complaint_window_days`,
  `billing_lookback_months`); every app query `CROSS JOIN`s it instead of
  hardcoding dates. For real, current data: set `as_of_date` to today (or
  your snapshot date) and the whole app re-anchors. No other date literals
  exist in the query layer.

## 2. The spine (required — this is the model)

The model separates the **party/commercial overlay** (who is billed) from
the **physical spine** (where energy flows), joined by effective-dated
relationship tables. This is the CIM-ish core a CC&B / SAP IS-U / Oracle
CIS maps onto:

| Table | Grain / role | Keys & contract notes |
|---|---|---|
| `dim_customer` | One row per **party** (person/org), profile only | `customer_id` / `customer_number`. Carries no `account_id`/`premise_id` — reach the spine through `dim_account` and `dim_service_agreement`. Includes prior occupants (profile, no in-window facts). The disclosed behavioural signals (churn band, usage band, 90-day outage/complaint counts, peer benchmarks) are demo conveniences derived from the facts — populate or drop; the map's cohort lenses read them. |
| `dim_account` | One row per **billing account** | `account_id` / `account_number` (the deep-link identity), `customer_id` FK. customer→account is 1:many (chains hold N site accounts under a corporate parent; `account_group='consolidated_billing'` marks the parent). |
| `dim_premise` | One row per **premise** (the place) | `premise_id` / `premise_number`. Building characteristics incl. `building_subtype` (peer grouping) and native GEOMETRY columns. |
| `dim_service_point` | One row per **point of delivery** (CIM UsagePoint) | `service_point_id` / `service_point_number`, `premise_id` FK. premise→service_point is 1:many (sub-metered commercial premises carry 2–5). The meter asset does *not* live here. |
| `dim_meter` | One row per **physical meter asset** (CIM EndDeviceAsset) | `meter_id` / `meter_number`. Includes removed/swapped-out meters so historical readings resolve to the meter of record. |
| `dim_service_agreement` | One row per (account × service_point × rate × validity window) — **the contract** | `service_agreement_id`; FKs to account, customer, premise, service_point; `effective_date`/`termination_date`/`is_current`/`agreement_seq`. The pivot binding the commercial overlay to the physical spine over time, and the carrier of rate-switch history. |
| `bridge_account_premise` | Effective-dated account↔premise occupancy link | Which account was billing-responsible for a premise during which `[link_start_date, link_end_date)` window — move-in/move-out and tenant turnover. One open link per premise; closed links are prior occupants. `occupancy_type`, `link_termination_reason`. The occupant-timeline UI reads the **full history**, not just `is_current`. |
| `meter_installation` | Effective-dated meter↔service_point placement | The meter-swap mechanism: `[installation_date, removal_date)`, `to_meter_id` chains original→replacement. How a reading resolves to the meter actually installed on its date. |
| `bridge_premise_owner` | Sparse, dated, account-backed owner→premise edge | `party_id` FK **into `dim_customer`** (an owner is always a party — no separate owner dimension), `basis` (owner_pays / owner_occupied / landlord_agreement), `owns_from`/`owns_to`/`is_current`. Only ownership a utility can actually observe; most premises legitimately have no row. Feeds the Owners lens and Owner inspector. |

Geography / lookup dims:

| Table | Grain / role |
|---|---|
| `dim_premise_h3` | One row per premise: `latitude`/`longitude` + **`h3_res5`…`h3_res9`** (BIGINT H3 cells). The map's entire spatial contract — dots, hex aggregation at every zoom band, and hex-click focus all read this. Compute the five resolutions from each premise centroid (`h3_longlatash3`). |
| `dim_geography` | One row per (county_fips, census_tract); county attrs + service-territory constants. |
| `dim_date` | Standard date dimension spanning your data window; `date_key` INT PK. |
| `dim_rate_schedule` | Static rate-code catalog (natural STRING key). |
| `dim_program` | DSM/marketing program catalog (natural STRING key). |
| `dim_agent` | CSR agent roster + engagement rollup; only needed with the CSR-interaction source. |

## 3. Facts (bring what you have — one file, one source)

Facts are one-file-per-source; the source capability matrix in
`ARCHITECTURE.md` §7 says what degrades when a source is absent. Grain and
key columns per table:

| Table | Grain | Notes |
|---|---|---|
| `fact_meter_readings_daily` | (service_point, date) | **Physical grain only — deliberately no `account_id`/`customer_id`.** Occupants change mid-window; stamping a "current occupant" on physical rows is wrong by construction. |
| `fact_customer_hourly_load_profile` | (service_point, year_month, day_type, hour_of_day) | Pre-aggregated hourly shape; same physical-grain discipline. |
| `fact_meter_readings_monthly` | (account, year, month) | **The one place account/customer attribution happens**: each reading resolves to the service agreement whose half-open window covers its date. Carries `customer_id`, `service_point_id`, `premise_id`. |
| `fact_customer_billing` | (account, bill) | Computed YoY / bill-shock columns are derived over a deduplicated (account, calendar-month) grain. |
| `fact_payment_history` | (payment) | `account_id`, `customer_id`, lateness bucketing. |
| `fact_customer_complaints` | (complaint) | Event + verbatim text 1:1. |
| `fact_csr_interactions` | (contact-center session) | Session level; event-level transitions stay raw. |
| `fact_outage_events` / `fact_outage_customer_impact` | (outage) / (outage × customer) | Impact rows carry `customer_id`/`service_point_id`/`premise_id` so reliability joins geography directly. |
| `fact_active_outage_event` / `fact_active_outage_customer_impact` | current OMS snapshot | The "live" map layer + CSR without-power banner. |
| `fact_program_enrollment` | (enrollment) | DSM enrollments; feeds `metric_dsm_uptake`. |
| `fact_assistance_enrollment` | (enrollment) | LIHEAP + payment plans + critical care, `program_type` discriminator. |
| `fact_der_adoption` | (premise, device_type) | **DER is a physical install** — keyed to premise, `customer_id` is the current occupant. Multi-site customers get independent DER per site. |
| `fact_survey_responses` / `fact_survey_invitations` | (response) / (survey, period, segment) | CSAT/NPS + the response-rate denominator; `comment_sentiment`/`comment_theme` feed the verbatim feed. |
| `fact_digital_engagement` | (event) | Portal sessions + digital events unioned. |
| `fact_social_mentions` | (mention) | With match-confidence band. |
| `fact_service_event` | (event_type, source relationship row) | The occurrence log for move-in/move-out, rate switch, meter swap — keys populated per event type. Powers the CSR journey timeline; the visible proof of the temporal model. |
| `fact_legacy_cx_snapshot` | (customer, snapshot_date) | Optional legacy-history garnish. |

SCD2 history (optional, showcased in the Accounts & Premises tab):
`dim_customer_history`, `dim_account_history` — AUTO CDC `STORED AS SCD
TYPE 2` targets keyed on `customer_id`/`account_id` with
`__START_AT`/`__END_AT`. Bring change feeds if you have them; the tab's
"profile changes" line is their only consumer.

Reference seeds (static VALUES lists — edit, don't generate):
`ref_cx_targets` (CX targets/benchmarks per metric × year × segment),
`dim_rate_schedule`. Derived aggregate: `peer_monthly_usage_benchmark`
(peer group = building_subtype × sqft_band, resolved from each account's
**own** premise) — recompute from your readings or keep the SQL.

## 4. Derived layers — regenerate, don't map

- **`metric_*` views** (usage, complaints, reliability, NPS, CSAT, FCR,
  DSM uptake, relationships, customer base) are defined in
  `src/30_curated/metric_views.py` (`METRIC_VIEWS` dict) and read only the
  star. Rerun that task and they materialize over your data. Genie and the
  CSAT/marketing app queries read them directly.
- **`ml_*` tables** come from `40_ml/` (features → train → score). The
  models (EV/PV detection from AMI shape, complaint risk) retrain on your
  readings; nothing to map.
- **`app_focus_set`** is written by the app's setup job, not by you.

## 5. Minimum viable "lights up" checklist

The app queries reference (by count, descending): `dim_account`,
`bridge_account_premise`, `dim_customer`, `dim_premise`,
`curated_demo_config`, `dim_service_point`, `dim_premise_h3`, then the
facts and metric views per view. In practice:

1. **Spine + geography** (§2, all of it) + `curated_demo_config` — the
   map, search, premise/owner inspectors, and profile drawer work.
2. **Each fact you bring** switches on its surface (billing → bill chart,
   outages → reliability, surveys → CSAT view, …); each you omit degrades
   that panel only.
3. **Grants:** the app runs as a service principal that inherits nothing —
   grant `USE SCHEMA`/`SELECT` on the schema (+ `MODIFY` on
   `app_focus_set`) via `app/scripts/grant-permissions.sh`, and `CAN_RUN`
   on the Genie space (auto-granted by `app/setup/01_create_genie_space.py`).
4. **Catalog/schema are injected at container start** — app queries carry
   `{{catalog}}`/`{{schema}}` tokens; point the app at any schema that
   honors this contract.
