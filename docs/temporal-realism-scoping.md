# Temporal Realism — Time, Weather & Entity History Scoping

Status: **ALL PHASES SHIPPED.** Phase 1 shipped 2026-07-09 (see
`docs/solar-injection-pv-detector-design.md` for the executed design);
Phase 3 shipped 2026-07-07 as the "Accounts & Premises" drawer tab +
show-all-locations map action; Phase 2 shipped 2026-07-12 as W9 (PR #14,
`weather_calendar_map` + `curated_demo_config`); Phase 4 shipped
2026-07-13 as W10, three PRs — #16 (relocations), #17 (generalized
in-window turnover), #18 (sub-metered commercial). The §6 follow-up
(document the curated layer as the drop-in contract) is done — see
`curated-layer-contract.md`. This doc is retained as the design record.
It resolved three
intertwined problems in one design: (1) the demo calendar is welded to
2017–2018 because load shapes align to real weather years; (2) the NREL
solar pull required an API key and had been unreliable enough that
solar was optional — **retired in Phase 1**, replaced by keyless EULP
weather + PV shape injection; (3) the customer/premise/meter/account
model is temporally rich in schema but only partially exercised by the
generator and consumed as pure current-snapshot by the app.

Everything here was verified against the working tree at `9954b16`
(entity + app audits, live anonymous S3 fetches against the OEDI
bucket). Numbers and file:line refs below are from that audit — trust
them, but re-check line numbers after any rebase.

Phase order (dependencies flow downward; Phase 3 is independent and can
be pulled forward any time):

| Phase | What | Why first-to-last |
|---|---|---|
| 1 | Keyless weather + PV generation source swap — **SHIPPED 2026-07-09** | Removes API key + secret scope from deploy; prerequisite for Phase 2's single weather library |
| 2 | `weather_calendar_map` + as-of parameterization (single source year, YoY scale — amended 2026-07-09, see §3) — **SHIPPED 2026-07-12 (W9, PR #14)** | Unlocks arbitrary demo anchor dates; kills all hardcoded 2018 literals AND `target_years`; halves AMI volume |
| 3 | Relationships tab + customer-premises map highlight — **SHIPPED 2026-07-07 ("Accounts & Premises" tab)** | Pure app work; demoable today with chain customers, no data changes |
| 4 | Synthetic data v2: relocations, in-window turnover, multi-meter — **SHIPPED 2026-07-13 (W10, PRs #16–#18)** | The realism payload; depends on Phase 2's date machinery |

Non-goals (decided, don't relitigate): no time-travel slider on the
map; no switch to TMY shapes; no full-attribute SCD2; no
presentation-layer date shifting in `curated`.

---

## 1. Findings the design rests on (audit summary, 2026-07-07)

### 1.1 What the synthetic data models today

The spine is generated deterministically (`xxhash64(id, purpose,
${random_seed})`) from `raw_premises` through
`raw_premise_customer_map` ("the SINGLE source of the Option-A
decoupling rules"), anchored to `as_of_date` (default `2018-12-31`),
facts spanning 2017–2018. Default scale `customer_sample_size=1000`
premises (`databricks.yml:65-67`) — the "~50K/58K rows" comments in
curated headers describe a full-territory override, not the default.

Genuinely temporal today:

- **Occupant turnover** — ~15% of residential premises have a prior
  occupant: a *different* customer with a closed account and a closed
  `bridge_account_premise` link (`link_start_date`/`link_end_date`/
  `is_current`/`link_termination_reason`)
  (`raw_premise_customer_map.sql:40-41`,
  `raw_account_premise_link.sql:64-78`).
- **Commercial chains** — ~20% of commercial premises collapse into
  chain customers (≤30/county): one customer, N site accounts + 1
  `corporate_parent` account (`raw_premise_customer_map.sql:33-39`,
  `raw_customer_account.sql:109-127`). The only genuine
  multi-premise/multi-account customers.
- **Meter swaps** — ~7% of pre-2017 smart meters get a replacement
  (`meter_seq=2`), windowed into `meter_installation` via
  `LEAD(install_date)` with `removal_reason_code='meter_exchange'`
  (`raw_end_device_asset.sql:64-75`, `raw_meter_installation.sql:30-61`).
- **Rate-switch history** — EV-TOU accounts and ~50% of res_d3 carry a
  terminated prior `res_d1` service agreement
  (`raw_service_agreement.sql:38-90`). `dim_service_agreement` is
  documented as the as-of resolution source (half-open
  `[effective_date, termination_date)`).
- **SCD2** — real AUTO CDC on `dim_customer_history`
  (`critical_care_flag` only) and `dim_account_history`
  (`current_status` only), fed by `change_feeds.py`.

Deliberately NOT modeled (the gaps Phase 4 closes):

- **Customers never relocate.** Turnover = a new customer identity per
  premise; the same `customer_id` is never linked to two premises.
  "Customer A lived at 5 premises" has no representation.
- **All turnover is pre-2017** so no fact is ever split across
  occupants (`raw_account_premise_link.sql:10-12`). Convenient; hides
  exactly the mess real CIS extracts have.
- **Premise→service_location→usage_point→meter is hard 1:1:1:1**; no
  concurrent multi-meter premises ("v2 extension when the demo needs
  sub-metered tenants", `raw_usage_point.sql:1-3`).
- Residential customers never hold >1 account.

### 1.2 What the app consumes

Every population query (map cells, dots, KPIs, marketing, search) joins
`dim_premise_h3 → bridge_account_premise WHERE is_current →
dim_customer`. The ONLY history surfaced anywhere: the profile header's
"previous occupant until … (N prior tenancies)" (`customer_header.sql`
`prior_occ` CTE) and the Service Timeline's prior-occupant badge
(`customer_timeline.sql` filters `fact_service_event` by *premise*,
flags `is_current_account`). `dim_*_history` tables are never queried.
No as-of controls exist. The Genie space instructions already teach the
half-open-window point-in-time pattern
(`app/setup/01_create_genie_space.py:109-131`) — the NL path can answer
"who lived here in 2017"; the structured app cannot.

Hardcoded date literals (the full list Phase 2 must sweep):
`DATE'2018-10-02'..'2018-12-31'` in `exec_kpis.sql:729`,
`exec_map_cells.sql:1149`, `exec_complaint_themes.sql:594`,
`exec_kpis_scoped.sql:663`, `exec_map_cell_themes.sql:1041`, and the
points builder in `geniePlugin.ts:535`; `DATE'2017-01-01'..'2018-12-31'`
in `mkt_enrollment_monthly.sql` and `mkt_complaint_themes.sql`.

### 1.3 Where the weather-year coupling actually lives

- **ResStock/ComStock shapes are AMY2018** (simulated against actual
  2018 weather) — but `raw_meter_readings.sql` already *re-stamps* them
  onto each target year via `MAKE_TIMESTAMP(y.year, MONTH(amy), …,
  'UTC')` (`ami/raw_meter_readings.sql:175-181`). Base load is already
  decoupled from the real calendar; it just happens to be projected
  onto 2017/2018. Precedent established.
- **NSRDB PSM3** pulls real per-year weather (2017 AND 2018) via an
  API-key endpoint (`nsrdb_solar/01_download_psm3.py`; key from secret
  scope `c360/nrel_api_key` + `nrel_email` widget). PV/HP adders join
  it on `(county_fips, timestamp_utc)`.
- **Latent inconsistency:** displayed-2017 base load reflects 2018
  weather while displayed-2017 PV/HP reflect real 2017 weather.
- **Latent clock bug (check during Phase 1):** EULP timestamps are
  local standard time, but the code labels AMY hours `'UTC'` and joins
  real-UTC NSRDB against them — solar noon may be misaligned vs. load
  noon by ~5h today. Phase 1 makes both series share one clock; pick
  one convention and verify solar peaks at displayed midday.
- Re-stamping today has two silent defects Phase 2's map fixes:
  day-of-week drift (Jan 1 2018 = Monday re-stamped onto 2017 =
  Sunday, misaligning ResStock occupancy schedules) and leap-day gaps
  (AMY2018 has no Feb 29 → projecting onto 2020/2024 leaves a 24h
  hole).

---

## 2. Phase 1 — Keyless weather + PV generation (retire the NREL API)

**Decision:** replace the PSM3 API with data already inside the
ResStock release, from the same anonymous OEDI bucket the load-shapes
download uses (unsigned boto3, no key, no email).

### 2.1 Weather (verified by anonymous fetch 2026-07-07)

```
s3://oedi-data-lake/nrel-pds-building-stock/end-use-load-profiles-for-us-building-stock/
  2024/resstock_amy2018_release_2/weather/state=MI/G2600010_2018.csv
```

One CSV per county for AMY2018, ~200 KB, ~85 files for MI. Columns:
`date_time, Dry Bulb Temperature [°C], Relative Humidity [%], Wind
Speed [m/s], Wind Direction [Deg], Global Horizontal Radiation [W/m2],
Direct Normal Radiation [W/m2], Diffuse Horizontal Radiation [W/m2]`
— a superset of the `${nsrdb_table}` contract
(`geoid, timestamp_utc, ghi_w_m2, temperature_c`) that
`raw_meter_readings.sql`'s `nsrdb` CTE consumes. GISJOIN filename
encoding: `G` + state fips + `0` + county fips + `0` (geoid `26163` →
`G2601630`).

### 2.2 Solar generation (verified 2026-07-07)

The by_state aggregates **already downloaded** carry
`out.electricity.pv.energy_consumption.kwh` — real EnergyPlus-simulated
rooftop-PV generation. MI single-family-detached: 35,040 rows (15-min),
−32.4 GWh/yr total, peak −5,931.9 kWh at 2018-04-19 12:45 (negative =
generation). The AMI SQL currently discards it via the exclusion list
at `raw_meter_readings.sql:57-61` (the tidy layer normalizes dots to
underscores: `out_electricity_pv_energy_consumption_kwh`).

**Decision — Option A now:** flip sign, aggregate to hourly, normalize
the year to sum-to-one, then per adopter
`kwh_pv = shape[hour] × pv_system_kw_dc × annual_yield` (MI fleet
≈ 1,100–1,200 kWh/kW-DC-yr; pick 1,150, comment it). This replaces the
flat `GHI × kW × 0.77` model (`raw_meter_readings.sql:226-230`). The
generation shape is weather-consistent with base load *by construction*
(same simulation). Known weakness, accepted: one state-level
fleet-average shape → no county cloud decorrelation, all adopters
perfectly correlated.

**Option B, deferred** (do NOT build now): offline pvlib transposition
(PVWatts physics, no API) from the weather CSVs' DNI/DHI → per-county,
per-orientation profiles. Build it when a use case needs house-to-house
PV diversity (EV-detector realism, net-metering fidelity). ComStock
baseline has ~no PV; commercial adopters ride the residential shape
until Option B.

### 2.3 Work items

1. Extend `src/10_ingest/load_shapes/01_download.py` (or sibling
   notebook) to pull `weather/state={XX}/` with the same STATE_FILTER +
   unsigned-boto3 pattern. Land under
   `{volume}/load_profiles_weather/state=XX/` so the SDP glob picks up
   path metadata.
2. New SDP raw table (in `10_ingest`, under a `transformations/` folder
   — pipeline globs only take folders, see repo memory) parsing geoid
   from the GISJOIN filename, landing the existing `${nsrdb_table}`
   contract. Keep humidity/wind/DNI/DHI as extra columns (future
   storm-outage realism + Option B).
3. Resolve the timestamp convention once (LST vs the fake-'UTC' AMY
   stamps) — both series now share a source clock, so this is a
   deliberate choice + comment, not archaeology. **Acceptance: PV
   generation peaks 12:00–14:00 displayed local time on a July day.**
4. Un-exclude the PV channel in the tidy/aggregate path; build the
   normalized shape CTE; replace the GHI model in the PV adder.
5. Retire `nsrdb_solar/01_download_psm3.py`, the `nrel_email` widget,
   the secret-scope lookup, and the "solar optional" carve-outs in the
   job/pipeline config. Delete `${nsrdb_table}`'s PSM3 provenance
   comments.
6. Re-run pipeline; re-verify FK constraints via `information_schema`
   (SDP FK-attach race — see repo memory), and confirm
   `kwh_delivered`/`kwh_received` distributions look sane vs. current
   (spot-check a PV adopter's July day and January day).

---

## 3. Phase 2 — `weather_calendar_map` + as-of parameterization

**AMENDED 2026-07-09** (user-approved, prompted by the Phase 1 design
work in `docs/solar-injection-pv-detector-design.md`): the original
framing was "map one weather year onto N display years". The new
framing is stronger — **generate ONE source year; manufacture ALL
display history through the map; `target_years` dies as a concept.**
Rationale: after Phase 1 removes NSRDB, real 2017-vs-2018 weather was
the *only* remaining year-over-year variation — displayed 2017 and
2018 become hour-for-hour identical copies, so any YoY benchmark
("high bill vs last year") computes ~0% everywhere, and the AMI table
doubles in volume to store a photocopy. One source year + map-projected
history halves AMI volume and makes YoY non-degenerate via the scale
column below.

**Decision:** separate the *source library* (fixed: AMY2018 shapes +
AMY2018 weather + AMY2018 PV, one canonical year after Phase 1) from
the *display calendar* (parameterized). One mapping table, consulted by
every weather-dependent CTE:

```
weather_calendar_map(
  display_date DATE PK,
  source_date  DATE,     -- analog day in the AMY2018 library
  kwh_scale    DOUBLE    -- YoY realism factor, see below
)
```

Built from two params: `as_of_date` (the demo "today"; may be set to a
real current date) and `history_months` (display window length, default
24). For each display_date: pick the source_date in the library with
the **same month and nearest day-of-week** (the TMY/load-forecasting
"weather analog" method — defensible to utility audiences, not a hack).
Leap days borrow Feb 28 explicitly. This fixes the DOW drift and
leap-day gaps re-stamping has today.

**`kwh_scale` — deterministic YoY variation (the 2026-07-09 addition):**
a gentle per-display-date factor, seeded like everything else
(`xxhash64(display_date, 'yoy_scale', ${random_seed})`): a small
year-trend (~±2–4% between display years) plus month-level noise,
centered on 1.0. Applied ONCE, at the AMI projection step
(`kwh_* × m.kwh_scale`), so it flows upward through billing,
peer benchmarks, and ML features automatically — "last year" differs
plausibly at every grain while hourly AMI, daily rollups, and bills
all stay mutually reconciled (the reason we do NOT spoof YoY at the
billing grain only: a high-bill alert must still reconcile when a demo
audience drills into the hourly usage beneath it). Real-utility onramp
unchanged: real multi-year AMI drops into curated, bypasses the map,
and every YoY computation is genuine — the map and scale live in
`20_synthetic` only.

- `base` CTE joins the map instead of `MAKE_TIMESTAMP(y.year, …)`;
  the `years` EXPLODE and the `target_years` bundle var are DELETED,
  not internalized.
- The `weather` CTE (renamed from `nsrdb` in Phase 1) and `pv_shape`
  already join on the source clock after Phase 1, so they are
  untouched — only the display projection changes to a map join.
- All other generators (billing cycles, complaint dates,
  `link_start_date`s, outages, DER adoption) were never physically
  coupled — they key off `as_of_date` relative offsets directly.

**App-side anchor: a 1-row `curated_demo_config(as_of_date, …)` table
written by the pipeline.** App queries CROSS JOIN it and express
windows as `DATE_SUB(cfg.as_of_date, 90)` etc., replacing every literal
in the §1.2 sweep list (including the two built in `geniePlugin.ts`).
Rejected alternatives: a `{{as_of_date}}` sed token (frozen at
container start; config table needs no redeploy and Genie can read it
too); shifting dates in curated views (contaminates the exact layer a
real utility replaces with real-timestamped AMI — parameterization
belongs in `20_synthetic` only).

Accepted cost, state it in the table comment: within a displayed month,
days are real weather days slightly reshuffled, so a displayed date
won't match the historical weather record for that date. Nobody demoing
synthetic data will feel this; utilities wiring real AMI bypass the map
entirely.

**Acceptance:** set `as_of_date` to (a) 2018-12-31 → output ≈ today's
at the monthly grain (regression guard; exact hourly equality no longer
expected once `kwh_scale` applies); (b) a 2026 date → pipeline green,
app renders with no 2018 literals anywhere, complaint window = trailing
90 days of the new anchor, Feb 29 2024 exists if in window. Plus YoY
non-degeneracy: same-month-last-year kWh differs by a plausible few
percent (not 0.0%), and a drilled bill still reconciles with the daily
AMI beneath it.

---

## 4. Phase 3 — Relationships tab + customer-premises map highlight

**Decision:** snapshot stays the app-wide default (matches how real
CIS/CSR/exec screens work). The temporal/relationship depth gets an
**entity-centric tab in the existing full-profile drawer** — NOT a new
nav page, NOT a map time slider. Rationale: relationship churn doesn't
read visually on a choropleth (premises don't move; ~15% pre-2017
turnover changes no pixels), and the drawer is where a utility
architect will judge whether the model maps to their CC&B/IS-U.

Content (new tab "Accounts & Premises" alongside the existing profile
tabs; new queries follow the `customer_*.sql` pattern, keyed by
`account_number` → resolved ids):

1. **Customer→accounts→tenancies tree/timeline**: every account for
   this `customer_id` (chains: N site accounts + corporate parent;
   residential: usually one), each with its `bridge_account_premise`
   links as date-ranged tenancy rows (address, move-in/out,
   `occupancy_type`, termination reason). Uses the bridge WITHOUT
   `is_current` — the first UI consumer of the full history.
2. **Service point → meter install history** per tenancy:
   `meter_installation` rows incl. removed originals with swap dates
   (~7% have two rows today).
3. **Rate history**: `dim_service_agreement` windows (rate switchers
   show the terminated res_d1 → current row).
4. **Map highlight**: "Show all locations" action → highlights every
   premise of this customer on the map. Cheap: one query for the
   customer's premise lat/lons through the bridge; reuse the existing
   `MapFocusRequest` fly-to plumbing (`App.tsx:316-327`). **Chain
   customers make this demoable immediately** — corporate parent with N
   sites is the showcase; after Phase 4, residential movers light it up
   too.

SCD2 garnish (cheap, do last): a "profile changes" line in the tab
reading `dim_customer_history`/`dim_account_history` — first consumer
of the SCD2 tables, e.g. "Critical care registered 2017-08-14",
"Account suspended 2018-03-02".

Gotchas: new tables touched by the app need SP grants (repo memory:
`app/scripts/grant-permissions.sh`); local dev needs the
`{{catalog}}/{{schema}}` sed applied/reverted (repo memory).

---

## 5. Phase 4 — Synthetic data v2: make the M:N real

Three generators, in payoff order. All build on Phase 2's date
machinery (relocation dates must be display-calendar-relative).

### 5.1 Intra-territory relocations (same customer moves)

~5% of residential customers relocate once **inside the fact window**:
close the bridge link at premise A (`move_out`), open at premise B
(`move_in`), SAME `customer_id`. **Structural blocker to design
around:** today `account_id = md5(premise_id + '_acct')` — account
identity is derived from the premise, so a mover forces a decision.
**Decision: the account moves with the customer** (one account, two
sequential premise links) — it's the common CC&B pattern, exercises the
bridge exactly as intended, and avoids inventing a second
account-creation path. Premise B comes from the turnover pool (its
"prior customer" is the mover's old identity at A — i.e., implement
relocation as a *re-labeling* of a slice of the existing turnover
pairs: instead of generating an unrelated prior customer for premise B,
make the prior-at-B / current-at-A identities collapse into one
customer). That keeps every downstream invariant (one current occupant
per premise) intact by construction.

### 5.2 In-window turnover (facts split across occupants)

Let a fraction of turnover `move_in_date`s land inside the display
window instead of all-pre-window (`raw_account_premise_link.sql:35-36`
currently forces pre-2017). Consequences to handle deliberately —
this IS the feature, it's the mess real utilities have day one:

- `fact_customer_billing` (account grain): bills at one premise split
  across two accounts mid-window. Billing generator must key bills off
  the link window, not the premise.
- Load/AMI is usage_point-keyed → unaffected; but any query attributing
  usage to a customer must resolve through the as-of join
  (`dim_service_agreement` / bridge half-open window) instead of
  assuming one occupant. Audit `peer_monthly_usage_benchmark` and the
  ML feature MVs (`40_ml/*/features.sql`) for hidden
  one-occupant-per-window assumptions — the complaint predictor's
  billing features are the likely casualty.
- The profile timeline already handles prior-occupant events; verify
  the "previous occupant" badge logic against in-window dates.

### 5.3 Sub-metered commercial (concurrent multi-meter premises)

The deferred v2 from `raw_usage_point.sql:1-3`: for large commercial
premises (say sqft ≥ 25K, ~N per county), generate 2–5 usage_points per
service_location, each with its own meter and service agreement to the
same account. Ripples: every "one usage_point per premise" join in
`raw_meter_readings.sql`'s `customer_full` CTE, the EV/PV adder
attribution (DER adoption is usage_point-keyed — fine), and premise-
grain rollups in the app (dots = premise, unchanged; but per-customer
kWh sums must aggregate usage_points).

**Acceptance for Phase 4 overall:** the Relationships tab shows a
residential mover with two tenancies; a mid-window mover's bills split
correctly across accounts; map highlight shows both premises;
`exec_kpis` totals unchanged in premise grain (occupancy invariant
holds); complaint-predictor training still runs green.

---

## 6. Real-utility drop-in posture (cuts across all phases)

The integration contract is the **curated schema shape**, and the
phases sharpen it: Phase 1 removes the only credentialed external
dependency from deploy; Phase 2 keeps all demo-date math out of
`curated` so real-timestamped data drops in with the map bypassed;
Phases 3–4 prove the app against CIS-realistic mess *before* a utility
brings their own. Follow-up worth doing after Phase 3: document the
curated layer explicitly as "map your CIS/MDM into these tables and the
app lights up" (table-by-table contract: `dim_*`,
`bridge_account_premise.is_current` + half-open windows,
`dim_premise_h3.h3_res5..9`, `account_number` as deep-link identity).
**Done 2026-07-13 — see `curated-layer-contract.md`.**
