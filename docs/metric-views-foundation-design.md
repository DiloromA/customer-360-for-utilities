# UC Metric Views as the Governed KPI Foundation — Implementation Design

Status: **Phase 1 (governance) SHIPPED 2026-07-10** — comments/tags on all 9
views, `metric_reliability` IEEE 1366 redesign + `v_reliability_base`,
`metric_relationships` + `metric_customer_base` added, `metric_csat`
County/Account Tenure Band dims added, `metric_tenure_at_premise` retired.
Verified live against `timstanton_stable.customer_360`: zero empty comments
on `metric_%` columns, all §4.5 SAIDI/SAIFI/CAIDI invariants hold exactly,
customer-base/relationship counts match known live totals (2,731 current
customers, 2,985 links / 254 move-outs). One correction to §5.1's nested-join
assumption: this warehouse's metric-view join resolver does **not** support a
join `on` clause referencing another join's alias — neither nested
(snowflake) nor sibling-chained — despite DBR 17.1+ docs; `metric_csat`'s
County dimension uses a `MAX()`-wrapped correlated scalar subquery against
`dim_premise` instead (§3). Phase 2 (Genie wiring) SHIPPED 2026-07-10.
**Phase 3 wave A SHIPPED 2026-07-10** (`csat_trend.sql`, `csat_by_channel.sql`,
`csat_by_journey.sql` → `metric_csat`; `mkt_enrollment_monthly.sql` →
`metric_dsm_uptake`) — each verified live against its pre-migration SQL
(identical row counts and values). `exec_complaint_themes.sql` (also listed
under wave A) turned out to be dead code — never called from any React
component — and was left on the star schema rather than migrated for no
consumer; migrating it would also require adding a new raw-date dimension to
`metric_complaints` since its 90-day trailing window isn't month-aligned like
`metric_complaints`' existing `Complaint Month` dimension. **Phase 3 wave B
SHIPPED 2026-07-10** (`csat_by_segment.sql`, `csat_kpis.sql` → `metric_csat` +
`metric_nps` + `metric_fcr`; `mkt_program_kpis.sql` → `metric_customer_base` +
`metric_dsm_uptake`) — each verified live against its pre-migration SQL.
`csat_kpis.sql` was added to wave B per the consolidated-execution-plan audit
(wave A had left the CSAT surface half-migrated). `metric_dsm_uptake` gained
`Active Count`/`Dropped Count` measures for this migration. `csat_by_segment`
migration surfaced a real pre-migration bug: the old SQL required an INNER
JOIN to `dim_premise` (needed only for the county breakdown) across all three
breakdowns, silently dropping 374 corporate_parent commercial interactions
from the customer_class/tenure_band breakdowns too — fixed by construction
(metric_csat resolves county as a non-filtering subquery). `exec_kpis.sql`
turned out to be dead code too (same as `exec_complaint_themes.sql` in wave
A) — zero callers in `app/client/src` — and was left unmigrated;
`exec_kpis_scoped.sql` (already out of scope — map-viewport bbox query) is
also currently dead code, noted here for completeness but out of scope either
way. **All of Phase 3 is now shipped.** The in-app "Documentation → metrics
page" item was also found already shipped, under a different name than this
doc expected: `MetricsCatalogView.tsx` (nav id `metrics-catalog`) queries
`GET /api/metrics/catalog`, which introspects `information_schema.tables` +
`SHOW CREATE TABLE` live — it already reflects all 9 views and picks up new
dims/measures automatically, no code change needed per migration. Only a
stale "7 governed views" comment/count (predating `metric_relationships` +
`metric_customer_base`) needed fixing.

Goal: make the 8 existing UC Metric Views the **single source of truth for
every aggregate/KPI** in the project — aligned with the KPIs utilities
actually govern (IEEE 1366 reliability, contact-center CX, EM&V program
metrics), fully commented and tagged in Unity Catalog, consumed by Genie and
the app's KPI/chart surfaces — while the map, drawer, and cohort machinery
deliberately stay on the star schema.

---

## 1. Context & findings (do not relitigate)

### 1.1 The metric views exist but are 100% orphaned

`src/30_curated/metric_views.py` creates 8 real UC metric views
(`CREATE OR REPLACE VIEW … WITH METRICS LANGUAGE YAML`, v1.1):
`metric_usage`, `metric_complaints`, `metric_reliability`, `metric_nps`,
`metric_csat`, `metric_fcr`, `metric_dsm_uptake`, `metric_tenure_at_premise`.
They run green in the pipeline and are live in UC. **Nothing consumes them:**

- All 40 queries in `app/config/queries/*.sql` hit `dim_*`/`fact_*`/`bridge_*`
  directly; zero reference `metric_*`.
- The Genie space (`app/setup/01_create_genie_space.py`) lists 14 base tables,
  no metric views.
- `ARCHITECTURE.md` §5's claim that they "power Genie spaces, Lakeview
  dashboards, and the AppKit analytics plugin" is aspirational, not true.

### 1.2 Why the UC UI shows no comments — verified, pure authoring gap

YAML `comment:` on a dimension/measure **does propagate** to the UC column
comment. Verified live: exactly two measures in the whole file have YAML
comments (`metric_csat` "Top2Box Rate", `metric_usage` "Avg kWh per Sqft"),
and exactly those two show comments in
`information_schema.columns`; all other 39 columns across the three views
checked are empty. There is **no platform limitation** — the comments were
never written. Fix = author a `comment:` on **every** dimension and measure.

### 1.3 Column-level UC tags on metric views — verified working, with syntax gotcha

Tested live on `metric_reliability`:

```sql
-- ✗ PARSE_SYNTAX_ERROR — ALTER VIEW does not take column clauses
ALTER VIEW cat.sch.metric_reliability ALTER COLUMN `Customer Minutes Out` SET TAGS (...);

-- ✓ works (yes, ALTER TABLE on a metric view)
ALTER TABLE cat.sch.metric_reliability
  ALTER COLUMN `Customer Minutes Out` SET TAGS ('standard' = 'IEEE 1366-2022', 'kpi' = 'CMI');
```

Tags land in `information_schema.column_tags` (verified, then test tags
removed with `UNSET TAGS`). **Caveat:** the pipeline re-creates views with
`CREATE OR REPLACE`, which resets column metadata — so tag application must
run *after* view creation on every pipeline run. `metric_views.py` already
has a post-create view-level tag loop; extend it (see §6).

### 1.4 The aggregate-only constraint (governs what can move to metric views)

A metric view is queried only as
`SELECT <dims>, MEASURE(<m>) … GROUP BY … WHERE <dim predicate>`. Therefore:

- ✅ Grouped business metrics (trend lines, breakdowns, KPI tiles).
- ❌ Row-level entity retrieval (`SELECT customer_id, lat, lon` — impossible).
- ❌ Query-time cross-fact semi-joins (`WHERE EXISTS (complaint …)`,
  `app_focus_set` cohort scoping) — joins are fixed in the YAML.
- ❌ Multi-fact assembly per row (`exec_map_cells` unions customer attrs +
  dominant complaint theme + enrollment per H3 cell in one payload).

So: **map cells/dots, customer drawer, search, and cohort building stay on
the star schema — by design, not as a compromise.** The migration target is
Genie + the app's aggregate KPI/chart queries (§7, §8).

### 1.5 Live data grounding (timstanton_stable.customer_360, sample deploy)

| Fact | Count |
|---|---|
| Current occupancy links (`bridge_account_premise.is_current`) = served customers | 2,731 |
| Total bridge links / ended links (move-outs) | 2,985 / 254 |
| `fact_outage_customer_impact` rows / distinct customers ever affected | 43,154 / 2,577 |
| `fact_outage_events` rows / major-event-day events | 14,000 / 149 |
| `dim_service_agreement` rows / rate-switch agreements (`agreement_seq > 1`) | 3,114 / 129 |

Every proposed measure below has non-trivial data behind it at this sample
size (deploys scale with `customer_sample_size`).

### 1.6 Mechanics recap

- `metric_views.py` is a **Job notebook** (runs after the `curated` SDP task);
  changes ship via `databricks bundle deploy` + re-running that Job task —
  no SDP pipeline edit. Helper plain views (§4) can be created in the same
  notebook immediately before the metric views.
- YAML v1.1 supports: `comment:` at view/dimension/measure level, `filter:`
  (global WHERE), joins incl. **nested (snowflake) joins** (DBR 17.1+), and
  `FILTER (WHERE …)` conditional aggregation in measures. `source:` may be a
  table, view, or SQL query.
- Genie supports metric views natively as data sources.

---

## 2. KPI alignment research — what utilities actually govern

### 2.1 Reliability — IEEE 1366-2022 (the standard; drives §4)

| Index | Definition | Formula on our model |
|---|---|---|
| **SAIDI** | System Avg Interruption Duration Index — minutes of sustained interruption per served customer per period | Σ `minutes_out` / N_served |
| **SAIFI** | System Avg Interruption Frequency Index — sustained interruptions per served customer | Σ customer-interruptions / N_served |
| **CAIDI** | Customer Avg Interruption Duration = SAIDI/SAIFI — avg restoration time per interruption | AVG(`minutes_out`) — *already present as "Avg Restoration Minutes", just misnamed* |
| **CMI / CI** | Customer Minutes Interrupted / Customer Interruptions — the raw building blocks | Σ `minutes_out` / COUNT(impact rows) — *present, named "Customer Minutes Out" / "Customer Events"* |
| **MED exclusion** | IEEE 1366 2.5-beta method excludes Major Event Days for "blue-sky" reporting | `fact_outage_events.is_major_event_day` already modeled → FILTER variants |
| **MAIFI** | Momentary (<5 min) interruption frequency | expressible as FILTER (`minutes_out` < 5); synthetic data may have none — optional |
| **ASAI** | Service availability % = 1 − SAIDI/525,600 (annual) | period-dependent → downstream calc, not a measure (document in view comment) |
| **CEMI-n** | % customers with > n sustained interruptions | needs per-customer pre-aggregation → phase 2 (§4.4) |

The key structural gap: the current view exposes only numerators. The
**served-customer denominator** (N_served) is "applied at consumption time"
per the view comment — i.e., nobody can compute SAIDI/SAIFI from the view
alone. §4 fixes this.

### 2.2 Contact-center / CX — industry conventions

FCR benchmark for utilities ≈ 70–85%; AHT 4–7 min voice; CSAT top-2-box
target ≥ 80–90% on resolved contacts. Our `metric_csat` (Top-2-Box, mean) and
`metric_fcr` (FCR rate, AHT, abandon rate) are **already the right KPIs** —
they need comments/tags, not redefinition. `ref_cx_targets` already carries
J.D. Power / ACSI benchmark values (different grain — targets stay an
app-side join, see §8). NPS formula in `metric_nps` is the standard
Bain/Satmetrix definition. Optional adds: "Pct Answered ≤ 30s" service-level
measure on `metric_fcr` (`wait_time_seconds` exists).

### 2.3 DSM / EE programs — EM&V terminology

Standard EM&V KPIs: **participation rate** (enrolled ÷ eligible), completion
rate, cost per kWh saved (levelized ≈ $0.025/kWh national average),
realization rate (measured ÷ claimed savings). `metric_dsm_uptake` has
completion rate, rebates, kWh saved. Participation rate needs the eligible
denominator = customer base by class → a **cross-metric-view calculation**
(`metric_dsm_uptake` ÷ `metric_customer_base`, §5) — document it in the view
comment; realization rate is not modeled (only `kwh_saved_estimate` exists) —
name the measure comment "estimate (claimed), not EM&V-verified".

### 2.4 Usage — `Avg kWh per Sqft` is EUI (Energy Use Intensity), the
ENERGY STAR / benchmarking convention. Rename comment accordingly; view is
otherwise sound.

Sources: [IEEE 1366 indices overview](https://site.ieee.org/boston-pes/files/2019/03/IEEE-1366-Reliability-Indices-2-2019.pdf),
[IEEE 1366 / MED 2.5-beta summary](https://www.linkedin.com/pulse/ieee-reliability-indices-standard-1366-member-ieee-member-cigre-),
[APPA reliability benchmarking report](https://www.publicpower.org/system/files/documents/Test%20Utility%20-%202023%20Annual%20Reliability%20Benchmarking%20Report.pdf),
[call-center KPI benchmarks by industry](https://www.amplifai.com/blog/call-center-kpi-benchmarks-by-industry),
[2026 call-center benchmarks](https://www.nextiva.com/blog/call-center-benchmarks.html),
[J.D. Power electric utility CSAT study](https://www.jdpower.com/business/us-electric-utility-business-customer-satisfaction-study),
[LBNL cost of saving electricity](https://www.energy.gov/sites/prod/files/2017/01/f34/The%20Total%20Cost%20of%20Saving%20Electricity%20through%20Utility%20Customer-Funded%20Energy%20Efficiency%20Programs%20Estimates%20at%20the%20National,%20State,%20Sector%20and%20Program%20Level.pdf),
[ACEEE cost of saving electricity](https://www.aceee.org/sites/default/files/pdfs/cost_of_saving_electricity_final_6-22-21.pdf),
[ACEEE EM&V](https://www.aceee.org/topic/emv).

---

## 3. Target portfolio — 9 views (8 → rename 1, redesign 1, add 2, retire 1)

| View | Action | Why |
|---|---|---|
| `metric_usage` | Keep; add comments/tags; comment `Avg kWh per Sqft` as EUI | Sound |
| `metric_complaints` | Keep; add comments/tags | Sound |
| `metric_reliability` | **Redesign** — IEEE 1366 measures + denominator (§4) | Headline ask |
| `metric_nps` | Keep; add comments/tags (`standard='NPS (Bain)'`) | Sound |
| `metric_csat` | Keep; add comments/tags; **add County + Account Tenure Band dims** (nested join `dim_account`→`dim_premise`) so `csat_by_segment.sql` can migrate | Sound + small gap |
| `metric_fcr` | Keep; add comments/tags; optional "Pct Answered ≤ 30s" | Sound |
| `metric_dsm_uptake` | Keep; add comments/tags; comment the participation-rate recipe | Sound + doc gap |
| `metric_tenure_at_premise` | **Retire** → replaced by `metric_relationships` (§5.1) | Too narrow |
| `metric_relationships` | **New** (§5.1) — the customer↔account↔premise temporal web | User ask |
| `metric_customer_base` | **New** (§5.2) — the keystone denominator view | Closes `exec_kpis` gap |

Optional (phase 3): `metric_rate_switching` on `dim_service_agreement` (129
switch agreements live) — dims Rate Schedule / Effective Year / Termination
Reason; measures Agreement Count, Rate Switches (`agreement_seq >= 2`),
Switch Rate, Avg Agreement Duration Days, Current Agreements.

**Global rule for all views:** every dimension and every measure gets a
`comment:`; every measure that maps to a named industry KPI gets column tags
`('standard' = <standard>, 'kpi' = <canonical abbreviation>)`.

---

## 4. `metric_reliability` redesign — IEEE 1366 as governed measures

### 4.1 The denominator problem and its solution

SAIDI/SAIFI divide by **customers served**, who mostly don't appear in the
impact fact (only affected customers do). Metric views can't reach a second
fact at query time. Solution: bake the denominator into the source as
constant columns via a helper plain view, created in `metric_views.py` just
before the metric views:

```sql
CREATE OR REPLACE VIEW {catalog}.{schema}.v_reliability_base AS
SELECT
  i.*,
  t.territory_customer_count,
  cc.county_customer_count
FROM {catalog}.{schema}.fact_outage_customer_impact i
CROSS JOIN (
  SELECT COUNT(*) AS territory_customer_count
  FROM {catalog}.{schema}.bridge_account_premise WHERE is_current
) t
LEFT JOIN (
  SELECT p.county, COUNT(*) AS county_customer_count
  FROM {catalog}.{schema}.bridge_account_premise b
  JOIN {catalog}.{schema}.dim_premise p ON p.premise_id = b.premise_id
  WHERE b.is_current
  GROUP BY p.county
) cc ON cc.county = (SELECT county FROM {catalog}.{schema}.dim_premise dp
                     WHERE dp.premise_id = i.premise_id)
```

(Implementation note: the county subquery-per-row form above is illustrative —
join `dim_premise` once for the county and then the county-count derived
table on it. Keep it a plain view so it tracks the current customer base with
zero refresh choreography.)

Then `MAX(territory_customer_count)` inside a measure is a safe constant —
it re-aggregates correctly under any slice.

### 4.2 Semantics: "contribution" measures are valid under ANY slice

`SUM(minutes_out) / MAX(territory_customer_count)` is **SAIDI contribution**:
unsliced it *is* system SAIDI; sliced by cause/weather/circuit/month it is
that slice's contribution to system SAIDI (numerator decomposition over the
fixed system denominator — exactly how utilities report "SAIDI by cause").
This sidesteps the classic trap where slicing would wrongly shrink the
denominator. County SAIDI is the one place a sliced denominator is wanted →
separate measure on `county_customer_count`, comment-flagged as valid **only
when grouped by County**.

### 4.3 Target measure set (replaces the current five)

| Measure (name in view) | expr sketch | comment / tag |
|---|---|---|
| `Customer Interruptions (CI)` | `COUNT(1)` | rename of "Customer Events"; tag `kpi='CI'`, `standard='IEEE 1366-2022'` |
| `Customer Minutes Interrupted (CMI)` | `SUM(minutes_out)` | rename of "Customer Minutes Out"; tag `kpi='CMI'` |
| `SAIDI` | `SUM(minutes_out) / MAX(territory_customer_count)` | "System SAIDI when unsliced; slice = contribution to system SAIDI"; tag `kpi='SAIDI'` |
| `SAIDI (excl MED)` | same + `FILTER (WHERE NOT outage.is_major_event_day)` | IEEE 2.5-beta blue-sky variant; tag `kpi='SAIDI'` |
| `SAIFI` | `COUNT(1) / MAX(territory_customer_count)` | tag `kpi='SAIFI'` |
| `SAIFI (excl MED)` | + FILTER as above | tag `kpi='SAIFI'` |
| `CAIDI (Avg Restoration Minutes)` | `AVG(minutes_out)` | rename; = SAIDI/SAIFI by construction; tag `kpi='CAIDI'` |
| `County SAIDI` | `SUM(minutes_out) / MAX(county_customer_count)` | "VALID ONLY grouped by County" in comment; tag `kpi='SAIDI'` |
| `Distinct Outages` / `Distinct Customers Affected` | keep | building blocks; comment |

Keep all existing dimensions (Circuit, County, Cause Code, Weather Category,
Is Major Event Day, Duration Bucket, Outage Month, Priority Restoration);
`source:` becomes `v_reliability_base`; existing joins unchanged. View
comment: name IEEE 1366-2022 explicitly, state ASAI = `1 − SAIDI/525600` for
an annual slice (downstream calc), and note MAIFI omitted (no momentary data
in the synthetic generator; measure sketch included in a YAML comment for BYO
data).

### 4.4 Phase-2 (optional): `metric_reliability_customer` for CEMI

CEMI-n needs per-customer interruption counts → a small helper view at
(customer × year) grain (`COUNT(*) events`, `SUM(minutes_out)`, county/class
dims), then measures `CEMI-3` = share of served customers with ≥ 3
interruptions, `Avg Interruptions per Customer`. Defer unless reliability
becomes a demo focal point.

### 4.5 Validation queries (run after implementing)

```sql
-- System SAIDI, 2018, blue-sky vs all-in (expect excl-MED < all-in)
SELECT MEASURE(`SAIDI`), MEASURE(`SAIDI (excl MED)`), MEASURE(`SAIFI`), MEASURE(`CAIDI (Avg Restoration Minutes)`)
FROM cat.sch.metric_reliability WHERE YEAR(`Outage Month`) = 2018;
-- Invariant: CAIDI ≈ SAIDI/SAIFI. Cross-check numerators against the raw fact:
SELECT SUM(minutes_out), COUNT(*) FROM cat.sch.fact_outage_customer_impact
WHERE YEAR(affected_start) = 2018;
-- Contribution property: SUM of SAIDI over cause codes = system SAIDI.
```

---

## 5. The relationship & customer-base views

### 5.1 `metric_tenure_at_premise` → `metric_relationships`

The old view proves one narrow thing (tenure math on the bridge, no joins —
can't even slice by county or class). The *actual* asset is the temporal
relationship web: `bridge_account_premise` (who occupied where, when —
move-in/out, turnover) resting on `dim_customer` / `dim_account` /
`dim_premise`, with `dim_service_agreement` carrying the contract/rate
history. New view:

```yaml
version: 1.1
source: {catalog}.{schema}.bridge_account_premise
comment: "Customer↔account↔premise relationship lifecycle metrics off the
  effective-dated occupancy bridge: move-ins, move-outs (turnover), tenure,
  and current occupancy, sliceable by geography, building type, customer
  class, and occupancy type. Tenure = days link_start_date→link_end_date
  (open links measured to the 2018-12-31 as-of date). Rate-switch history
  lives in dim_service_agreement (see metric_rate_switching, optional)."
joins:
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
  - name: dim_premise
    source: {catalog}.{schema}.dim_premise
    on: source.premise_id = dim_premise.premise_id
dimensions:   # every one WITH a comment (elided here for brevity in this doc)
  Occupancy Type, Link Status, Is Current, Move In Year (YEAR(link_start_date)),
  Move Out Year (YEAR(link_end_date)), Termination Reason (link_termination_reason),
  County (dim_premise.county), Building Subtype (dim_premise.building_subtype),
  Customer Class (dim_customer.customer_class)
measures:     # every one WITH a comment
  Relationship Count            COUNT(1)
  Distinct Customers            COUNT(DISTINCT source.customer_id)
  Distinct Premises             COUNT(DISTINCT source.premise_id)
  Distinct Accounts             COUNT(DISTINCT source.account_id)
  Move Outs (Turnover)          SUM(CASE WHEN link_end_date IS NOT NULL THEN 1 ELSE 0 END)
  Turnover Rate                 <move outs> / NULLIF(COUNT(1), 0)
  Current Occupancy Count       SUM(CASE WHEN is_current THEN 1 ELSE 0 END)
  Avg Tenure Days               AVG(DATEDIFF(COALESCE(link_end_date, DATE'2018-12-31'), link_start_date))
  Median Tenure Days            MEDIAN(DATEDIFF(...))
```

This directly answers "which counties/building types churn occupants
fastest", "commercial vs residential tenure", "move-ins by year by county" —
the questions the temporal model exists to demo. (Note: "multi-premise
customer count" needs per-customer pre-aggregation — same pattern as CEMI,
defer.) Drop `metric_tenure_at_premise` in the same notebook run (`DROP VIEW
IF EXISTS`), and remove its entry from the `METRIC_VIEWS` dict.

### 5.2 `metric_customer_base` — the keystone (new)

Every headline denominator in the app ("total customers", "% payment
stressed", "eligible for program X") aggregates dim_customer attributes at
**current-occupant grain** — and no metric view covers it. This is also the
DSM participation-rate denominator (§2.3) and the complaints-per-1k
denominator.

```yaml
version: 1.1
source: {catalog}.{schema}.bridge_account_premise
filter: source.is_current
comment: "The CURRENT customer base at service-location grain (one row per
  occupied premise — matches the exec map counting grain). Denominators for
  penetration/percentage KPIs live here."
joins: dim_customer (customer_id), dim_premise (premise_id)
dimensions (all commented):
  Customer Class, County, Usage Band, Engagement Tier, Income Band,
  Churn Risk Band, Building Subtype, Payment Stressed Flag,
  Critical Care Flag, LIHEAP Eligible, High User Flag
measures (all commented):
  Customer Count                 COUNT(1)          -- service-location grain
  Distinct Customers             COUNT(DISTINCT source.customer_id)  -- entity grain (multi-site collapses)
  Payment Stressed Count / Rate  SUM(CASE…) / …/NULLIF(COUNT(1),0)
  Churn High Count / Rate        …
  Critical Care Count            …
  LIHEAP Eligible Count          …
  High Engagement Rate           …
  Avg Digital Adoption           AVG(dim_customer.digital_adoption_score)
  Total Outage Minutes (90d)     SUM(dim_customer.recent_outage_minutes_90d)
  Total Complaints (90d)         SUM(dim_customer.recent_complaint_count_90d)
```

Grain note (important, learned previously): **service-location grain, not
distinct customer** — same convention as the exec map. `Customer Count` vs
`Distinct Customers` makes the two grains explicit and commented, which is
itself a governance win.

---

## 6. Comments + tags implementation in `metric_views.py`

1. **Comments:** add `comment:` to every dimension/measure in every YAML body
   (the two existing commented measures prove propagation, §1.2). Write them
   as a business user would read them in Catalog Explorer — definition first,
   then formula/units, then caveats ("valid only grouped by County").
2. **Tags:** extend the existing post-create tag loop with a per-view
   `COLUMN_TAGS: dict[view][column] -> dict[tag,value]` structure and emit:
   `ALTER TABLE `{cat}`.`{sch}`.`{view}` ALTER COLUMN `{col}` SET TAGS (…)`
   — **must be `ALTER TABLE`** (§1.3), and must run every pipeline run since
   `CREATE OR REPLACE` resets it. Suggested tag vocabulary:
   - `standard`: `IEEE 1366-2022` | `NPS (Bain)` | `ACSI / J.D. Power benchmark`
     | `EM&V (DOE/ACEEE)` | `ENERGY STAR EUI` | `contact-center convention`
   - `kpi`: `SAIDI` `SAIFI` `CAIDI` `CMI` `CI` `NPS` `CSAT` `CSAT-T2B` `FCR`
     `AHT` `ABN` `EUI` `PARTICIPATION`
3. **Object-level tag is `demo = customer-360-for-utilities` — already done
   (2026-07-10):** the legacy `managed_by`/`area`/`dir_name` tags were repo
   artifacts and have been removed both in code (`metric_views.py`,
   `30_curated/table_comments.py`, `40_ml/*/table_comments.py`,
   `resources/*.yml` bundle tags — the `area`/`dir_name` widgets and job
   params are gone too) and live (all 103 objects in
   `timstanton_stable.customer_360` retagged; verified only `demo` remains in
   `information_schema.table_tags`). The notebooks now UNSET the legacy tags
   on every run, so BYO deployments self-clean. Do not reintroduce them.
   Additionally add `('standard' = 'IEEE 1366-2022')` at view level on
   `metric_reliability`.
4. `v_reliability_base` (and any future helper view) is created in the same
   notebook, before the metric views; tag it `demo` like the rest.

---

## 7. Genie wiring (highest-leverage consumer, lowest risk)

In `app/setup/01_create_genie_space.py`:

1. Append all 9 metric views to `TABLES` (keep every base table — Genie still
   needs them to return `customer_id`/lat/lon row sets for map dots).
2. Add an instructions section:
   > For aggregate/KPI questions (counts, rates, trends, breakdowns — "what is
   > our SAIDI", "CSAT by county", "NPS trend"), PREFER the `metric_*` views:
   > query them with `SELECT <dims>, MEASURE(<measure>) … GROUP BY …`. Use
   > base tables only when the answer is a set of individual customers.
3. Re-run the `app_genie_space` setup job (it PATCHes the existing space;
   SP grant logic is already idempotent — see genie-space-sp-grant memory).

---

## 8. App query migration (phase-gated; move a surface wholesale or not at all)

Half-migrated surfaces create two sources of truth — worse than either pure
state. Migrate per-surface:

| Wave | Query | Target view | Notes |
|---|---|---|---|
| A | ~~`exec_complaint_themes.sql`~~ | ~~`metric_complaints`~~ | **Skipped — dead code**, never called from the app; would also need a new raw-date dim (its 90d window isn't month-aligned) |
| A | `csat_trend.sql` | `metric_csat` | **SHIPPED 2026-07-10.** Interaction Month dim; verified identical 24-row output |
| A | `csat_by_channel.sql`, `csat_by_journey.sql` | `metric_csat` | **SHIPPED 2026-07-10.** Media Type / Queue dims; verified identical output |
| A | `mkt_enrollment_monthly.sql` | `metric_dsm_uptake` | **SHIPPED 2026-07-10.** Program × Enrollment Month; verified identical 223-row output |
| B | `csat_by_segment.sql` | `metric_csat` | **SHIPPED 2026-07-10.** Used the County + Account Tenure Band dims added in wave A; verified live — surfaced a real pre-migration bug (374-row undercount in customer_class/tenure_band from an unrelated dim_premise INNER JOIN), fixed by construction |
| B | `csat_kpis.sql` | `metric_csat` + `metric_nps` + `metric_fcr` | **SHIPPED 2026-07-10.** Added to wave B per the consolidated-execution-plan audit (wave A left this half-migrated); verified live across 9 date-range × segment combos; `ref_cx_targets` stays app-side |
| B | ~~`exec_kpis.sql`~~ | ~~`metric_customer_base` + `metric_complaints`~~ | **Skipped — dead code**, zero callers in `app/client/src` (same situation as `exec_complaint_themes.sql` in wave A) |
| B | `mkt_program_kpis.sql` (eligible denominator) | `metric_customer_base` | **SHIPPED 2026-07-10.** enrollment half → `metric_dsm_uptake` (gained `Active Count`/`Dropped Count` measures); verified live for all 15 programs |
| — | `exec_map_*`, `customer_*` drawer, search, cohort, `exec_kpis_scoped` bbox | **stay on star schema** | §1.4 constraints; scoped KPIs need bbox + cross-fact EXISTS. `exec_kpis_scoped.sql` is also currently dead code (zero callers) but stays out of scope either way |

Mechanics: app queries carry `{{catalog}}`/`{{schema}}` tokens and named
`:params` — metric-view queries work identically through the SQL warehouse
(`SELECT \`Category\`, MEASURE(\`Complaint Count\`) FROM {{catalog}}.{{schema}}.metric_complaints …`).
Backtick-quote spaced names. The app SP needs `SELECT` on the new views —
covered by the existing schema-level grant in
`app/scripts/grant-permissions.sh` if it grants at schema scope (verify; else
add the views).

Each migrated query must be **verified against the old SQL's output** before
the old text is deleted (same numbers, same shape) — run both against
`timstanton_stable.customer_360` and diff.

---

## 9. Implementation phases & verification

- **Phase 1 — governance in place (no consumer changes):** comments on all
  ~90 dims/measures; column tags; `v_reliability_base` + `metric_reliability`
  redesign; `metric_relationships` replaces `metric_tenure_at_premise`;
  `metric_customer_base` created; `metric_csat` dims added. Re-run the
  metric-views Job task; validate with §4.5 queries + a
  `information_schema.columns` / `column_tags` sweep asserting zero empty
  comments on `metric_%`.
- **Phase 2 — Genie:** §7. Smoke-test: ask "what is our SAIDI excluding major
  event days by county" and confirm it queries `metric_reliability` with
  MEASURE().
- **Phase 3 — app waves A then B (§8), each wave verified query-by-query:**
  wave A SHIPPED 2026-07-10 (4 of 5 queries — see §8 table); wave B SHIPPED
  2026-07-10 (3 of 4 queries; `exec_kpis.sql` skipped as dead code).
  `ARCHITECTURE.md` §5 updated to reflect real Genie/app consumption. The
  in-app metrics page (`MetricsCatalogView.tsx`) was found already shipped
  and needed no code change — it introspects `information_schema` live.
  **Nothing remains open in this doc.**
- **Out of scope, deliberately:** map/drawer/search/cohort migration;
  materialization (experimental — revisit if warehouse latency on KPI tiles
  ever matters); CEMI / MAIFI / `metric_rate_switching` (documented above as
  optional follow-ups).
