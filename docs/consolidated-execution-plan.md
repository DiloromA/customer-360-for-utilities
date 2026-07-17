# Consolidated Execution Plan — All Outstanding Work

Status: **PLAN COMPLETE 2026-07-13 — W1–W10 all merged to `main`.** W10
(temporal realism Phase 4) shipped as three PRs, all merged 2026-07-13:
PR #16 (relocations + shared in-window infra, `0e560f7`), PR #17
(generalized in-window turnover, `45d552c`), PR #18 (sub-metered
commercial premises, `f52f507`). The pre-W10 ETL efficiency pass merged as
PR #15 (`4ed4c19`, 2026-07-13). Nothing on this plan remains open; the doc
is retained as the historical record and index into the sibling design
docs. The curated-layer drop-in contract (the one deferred follow-up, from
`temporal-realism-scoping.md` §6) now lives in
`curated-layer-contract.md`.

Prior status: **Written 2026-07-10 after a full ground-truth audit**; **re-audited
2026-07-12 after W1–W7 all merged to `main`** (PRs #8–#12) — ground truth
below reflects the re-audit, including a live check of FKs (83 live, none
dropped), the new W4/W7 tables, and an independent code review of the W4/W5
and W7 merges (§1.1). **W8 (CSAT Phase 3) shipped later the same day** —
see §3.5 — as two additive nullable columns on `fact_survey_responses` (no
new FKs; re-verified the existing 3 still intact post-run) plus two new
queries and a `CsatView` prop (committed same day). **W9 (temporal realism
Phase 2) shipped 2026-07-12, merged to `main` via PR #14** (`3f4e09b`) —
see §3.7 — `weather_calendar_map` + `curated_demo_config`, `target_years`
fully retired, and two ML time-window bugs found only by running the
pipeline at a shifted `as_of_date`. **A pre-W10 ETL efficiency pass shipped
2026-07-12** (trim over-ingestion + job-run inefficiencies, on branch
`w10-pre-etl-efficiency` — see `etl-efficiency-pass-design.md`): county-scoped
weather/buildings ingest (727K→26K weather rows, 4.9M→1.55M buildings rows),
pruned `raw_load_profiles` 106→47 columns, skip-if-exists on all 4 downloads
(confirmed working, though gains are capped by serverless cold-start —
see the doc's §6), `curated_table_comments` 440s→~120s via parallelization,
deleted an orphaned test notebook, and renamed the confusingly-named Job
resource `customer_360_pipeline` → `customer_360_job`. This is the **master index**: it
says what is actually done, what remains, in what order to do it, and every
correction discovered during the audit. The sibling docs stay the
deep reference for mechanics — this doc does not duplicate them, it
sequences and corrects them:

- `metric-views-foundation-design.md` — wave B mechanics (§8 there)
- `entity-grain-design.md` — grain/ownership/right-rail mechanics
- `csat-experience-view-design.md` — CSAT Phases 2–3 mechanics (§4–5 there)
- `temporal-realism-scoping.md` — calendar-map + synthetic-v2 mechanics (§3, §5 there)
- `etl-efficiency-pass-design.md` — pre-W10 ETL efficiency pass mechanics

A fresh session should read **this doc first**, then only the sibling
section(s) for the workstream it is executing.

---

## 1. Ground truth (final: 2026-07-13 — trust this over stale status lines)

**Everything W1–W10 is merged to `main`.** W9 merged via PR #14, `3f4e09b`,
merge commit `c13b31d` — see §3.7. The pre-W10 ETL efficiency pass merged
via PR #15 (`4ed4c19`). W10 merged as PRs #16–#18 (`0e560f7`, `45d552c`,
`f52f507`), all 2026-07-13. No open work remains on this plan.

### Shipped and committed (do not redo)

| Work | Where | Note |
|---|---|---|
| Metric views Phase 1 (9 governed views, comments/tags, IEEE 1366 redesign, `metric_relationships`/`metric_customer_base`) + Phase 2 (Genie wiring) | `main` (`e0da13f`, `1f50c1f`) | verified live |
| Metric views Phase 3 **wave A** (`csat_trend`, `csat_by_channel`, `csat_by_journey` → `metric_csat`; `mkt_enrollment_monthly` → `metric_dsm_uptake`) | `main` (`292916b`, PR #8) | each verified identical vs pre-migration SQL; `exec_complaint_themes.sql` skipped as dead code |
| Metric views Phase 3 **wave B** (`csat_by_segment`, `csat_kpis` → `metric_csat`+`metric_nps`+`metric_fcr`; `mkt_program_kpis` → `metric_customer_base`+`metric_dsm_uptake`) — **W1 done** | `main` (`45b7c63`, PR #8) | each verified live (csat_kpis: 9 date-range×segment combos; mkt_program_kpis: all 15 programs); `exec_kpis.sql` skipped as dead code (zero callers, same as `exec_complaint_themes.sql`); `metric_dsm_uptake` gained Active/Dropped Count measures; `csat_by_segment` migration fixed a real 374-row undercount bug (unrelated dim_premise INNER JOIN dropped corporate_parent rows from all three breakdowns); in-app "Documentation → metrics page" found already shipped as `MetricsCatalogView.tsx` (live information_schema introspection, no code change needed) |
| **CSAT view Phase 1 — fully shipped** (nav renamed "Service & Experience", `csat` ready, `ref_cx_targets` seed, all 5 Row-1..4a panels in `CsatView.tsx`) | `main` (`bf79ff5`) | the design doc's "nothing implemented" status line was stale; fixed |
| EULP keyless weather + PV shape injection, `pv_detector` model, NREL/PSM3 fully retired | `main` | temporal-realism Phase 1 |
| Relationships / "Accounts & Premises" drawer tab, hex-click focus, CSR site-grain, DER premise-grain, complaints predictor incl. Explorer surfacing, UC rename + 79 FKs | `main` | |
| Ask-the-map count-grain spot-fix + profile-tab restyle; entity-grain design doc | `main` (`7fa4f55`, `41aad50`, PR #8) | |
| Entity grain **Phase A** (counting-unit model) — **W2** + AppKit BOOLEAN-as-string fix | `main` (`8270e14`, `bb5bea6`) | |
| Entity grain **Phase B** (premise inspector + pivot chips) — **W3** | `main` (`2db4532`, PR #10) | |
| Entity grain **Phase C** (ownership edge + landlord hero + Owner inspector) — **W4** | `main` (PR #11, `ba100ef`) | FKs + landlord data verified live |
| Entity grain **Phase D** (unit/lens control) + "owner" wired into the toggle — **W5** | `main` (`4f851db`, `c508ffb`, PR #11) | closes the entity-grain design entirely |
| PV + EV detection surfacing (drawer badges, confirmed + unregistered variants) — **W6** | `main` (`08e1160`, PR #9) | |
| CSAT **Phase 2** (drivers, ops correlation, survey health + response rate) — **W7** | `main` (`24123e9`, PR #12) | `fact_survey_invitations` verified live (16 rows: 8 NPS quarters × 2 segments, response rates 27–33%) |
| CSAT **Phase 3** (Voice-of-Customer verbatim feed + theme tagging, closed-loop detractor follow-up queue) — **W8** | `main` (PR #13, `732f1f2`) | `comment_sentiment`/`comment_theme` added to `fact_survey_responses`; curated pipeline redeployed + rerun green, FKs re-verified live; `CsatView` now threads `onJumpToSubject`; live-verified in a local dev browser session |
| Temporal realism **Phase 2** (`weather_calendar_map`, `curated_demo_config`, `target_years` retired) — **W9** | `main` (PR #14, `3f4e09b`, merge `c13b31d`) | see §3.7 for the full account, incl. two ML time-window bugs found only by running the pipeline at a shifted `as_of_date` |
| Pre-W10 ETL efficiency pass (county-scoped weather/buildings ingest, load-shape column pruning, skip-if-exists downloads, parallelized `curated_table_comments`, orphaned test-notebook cleanup, `customer_360_pipeline`→`customer_360_job` rename) | `main` (PR #15, `4ed4c19`) | see `etl-efficiency-pass-design.md` §6 for full verification results; two full end-to-end job runs, all row counts + 83 FKs verified unchanged, app smoke-tested |
| Temporal realism **Phase 4** (relocations, generalized in-window turnover ~40%, sub-metered commercial 2–5 usage points per large premise) — **W10** | `main` (PRs #16 `0e560f7`, #17 `45d552c`, #18 `f52f507`) | each PR live-verified against a `customer_sample_size=150` run; found 7 real bugs along the way (duplicate customer row, phantom orphan account, billing YoY window-fn desync, complaint-predictor `n_accounts_billed` miscount, DER host-cloning, billing-arrears cross-meter contamination, complaint-event trailing-avg desync) plus app-query dedup/aggregation fixes |

### Outstanding (the whole remaining backlog — nothing else is open)

| # | Workstream | Size | Deep doc |
|---|---|---|---|
| ~~W1~~ | ~~Metric views wave B + finish the CSAT surface migration~~ — **SHIPPED 2026-07-10** | S | metric-views §8 |
| ~~W2~~ | ~~Entity grain Phase A — counting-unit model~~ — **SHIPPED 2026-07-11** | M | entity-grain §4.4, §7 |
| ~~W3~~ | ~~Entity grain Phase B — premise inspector + pivot chips~~ — **SHIPPED 2026-07-12** | L | entity-grain §6 |
| ~~W4~~ | ~~Entity grain Phase C — ownership edge + landlord hero~~ — **SHIPPED 2026-07-12** | M | entity-grain §4.2, §5 |
| ~~W5~~ | ~~Entity grain Phase D — unit/lens control~~ — **SHIPPED 2026-07-12** | S | entity-grain §6.4 |
| ~~W6~~ | ~~PV + EV detection surfacing~~ — **SHIPPED 2026-07-11** | M | §3.6 below (no sibling doc) |
| ~~W7~~ | ~~CSAT **Phase 2** (drivers, ops correlation, survey health + invitations)~~ — **SHIPPED 2026-07-12** | M | csat doc §4.2, §5 rows 4b–6 |
| ~~W8~~ | ~~CSAT **Phase 3** (verbatims, closed-loop follow-up queue)~~ — **SHIPPED 2026-07-12** | M | csat doc §5 rows 7–8 |
| ~~W9~~ | ~~Temporal realism **Phase 2** — `weather_calendar_map` + as-of parameterization~~ — **SHIPPED 2026-07-12** | L | §3.7 below |
| ~~W10-prep~~ | ~~Pre-W10 ETL efficiency pass~~ — **SHIPPED, merged 2026-07-13 (PR #15)** | M | etl-efficiency-pass-design.md §6 |
| ~~W10~~ | ~~Temporal realism **Phase 4** — relocations, in-window turnover, sub-metering~~ — **SHIPPED 2026-07-13 (PRs #16–#18)** | L | temporal §5 |

Explicitly *not* open: map/drawer/search/cohort metric-view migration
(excluded by design), map time-slider, TMY shapes, full SCD2, CEMI/MAIFI/
`metric_rate_switching` (optional follow-ups only if a demo needs them).

### 1.1 Re-audit findings (2026-07-12 — independent review of the W4/W5 and W7 merges)

Both merges were independently code-reviewed post-merge, with live data
checks. **The work is in good shape overall** — grains, FK derivations,
STRING-identity and `{{catalog}}/{{schema}}` rules all held. One confirmed
UI bug and one confirmed process deviation to act on; the rest are
non-blocking nits.

**Fixed (confirmed bug — FIXED 2026-07-12, same session as this re-audit):**

- **W4 / `OwnerInspector.tsx:195`** — the alerts banner compared
  `o.n_currently_vacant === 0 && o.n_historical_vacancies === 0`, but
  AppKit returns COUNT columns as *strings*, so `"0" === 0` was false: the
  "Fully occupied" badge never rendered and every no-vacancy owner (all
  owner-occupied parties + the Sunbelt hero chain) got an **empty**
  "Next actions & insights" banner. Only the landlord hero (which has a
  historical vacancy) rendered a populated banner, which is why live
  verification missed it. **Fixed** by coercing both counts through the
  file's own `num()` helper at the top of `OwnerAlertsBanner`; tsc
  confirmed no new errors vs the pre-edit baseline (same 92, the known
  generated-types noise).

**Decide (confirmed rule deviation, likely accept):**

- **W4 / `raw_customer.sql:233-243, 272-273`** — beyond the additive
  landlord UNION branch, the final SELECT gained a `LEFT JOIN
  raw_landlord_portfolio` + first-position `WHEN … THEN 'rent'` in the
  tenure CASE, flipping `tenure` for the ≤ ~12 existing occupants of the 10
  landlord premises. This violates the "additive UNION branches only" rule
  as stated — but it is load-bearing: forcing those occupants to `tenant`
  occupancy is what prevents a spurious `owner_occupied` edge from
  coexisting with the `landlord_agreement` edge in `bridge_premise_owner`
  (which would fan out). Recommendation: accept and re-state the rule as
  "no changes that alter *pre-existing entity counts or IDs*"; the tenure
  flip is semantically required, not accidental.

**Nits (fix opportunistically, all bounded to the one showcase premise or
hardening):**

- W4 vacancy episode `[move_in − 200, move_in]` can overlap a prior
  occupant's tenancy when the showcase premise has one
  (`raw_account_premise_link.sql:93-97`) — contradictory timeline in the
  Premise inspector; end the prior link at `move_in − 200` instead.
- W4 vacancy account's `account_opened_date` (random 2015) can postdate or
  long-predate its own link window (`raw_customer_account.sql:171-172`).
- ~~`premise_header.sql:28-35` counts the vacancy link as a "previous
  occupant"; consider excluding `occupancy_type='vacant'`.~~ **FIXED
  2026-07-12** (W8 session, opportunistic).
- Single-current-owner-edge assumption unguarded in `geniePlugin.ts`
  (cohort headline join) and `premise_header.sql` (`owner` CTE has no
  `LIMIT 1`) — safe with today's data by construction, add
  `LIMIT 1`/`MIN_BY` when next touched.
- `raw_account_premise_link.sql:21` table COMMENT missing 'vacant' in the
  occupancy_type enum; `OwnerInspector.tsx` drill card renders query errors
  as "Owner not found"; `tenant_customer_number` fetched but unused.
- ~~**W7 / `CsatView.tsx`**: the new Phase-2 correlation/volume charts bind
  possibly-string DECIMAL columns (`nps_score`, `top2box_pct`, `n`)
  directly to Recharts instead of mapping through the established `num()`
  helper (Phase 1's `trendData` does).~~ **FIXED 2026-07-12** (W8 session,
  opportunistic).
- ~~**W7 / `csat_operational_correlation.sql:52-59`**: `nearest_bill`'s
  `ROW_NUMBER()` has no tiebreaker, so a multi-site commercial customer's
  attributed bill (and its `bill_shock_pct`) is arbitrary among same-day
  `bill_period_end` bills~~ **FIXED 2026-07-12** (W8 session, opportunistic
  — added a `bill_id` tiebreaker). The separate "first-year customers with a
  real bill but NULL `bill_shock_pct` land in 'No bill history'" cosmetic
  note still stands (rates are not wrong).
- **Metric views**: one count measure missed correction #3's naming sweep —
  the energy view's `Customer Count` (`metric_views.py:139`). It genuinely
  is `COUNT(DISTINCT customer_id)` (comment says so), so no grain ambiguity;
  rename to `Distinct Customers` for vocabulary consistency when next
  touching the file.

Verified clean in the same review — W7: top-2-box `>= 8` (and its `>= 4`
1–5-scale equivalent) consistent across every query and `metric_views.py`;
star-schema-by-design headers present on all three Phase-2 queries;
survey-health rate cannot fan out or exceed 100% (invitations and responses
share the identical seeded population by construction; `NULLIF` guards);
`fact_survey_responses` change additive/backward-compatible; all driver
buckets exhaustive and non-overlapping with correct units. W4/W5: the other
two synthetic files are genuinely additive-only with collision-free ID
salts; STRING identity (`premise_number`/`customer_number`) holds
everywhere client-side; boolean flags go through the server's `boolOf()`;
`bridge_premise_owner` PK/FKs are genuine UC constraints with key
derivations matching `dim_customer`/`dim_premise` exactly; lens grains are
correct (locations `COUNT(*)`, customers/owners `COUNT(DISTINCT …)`) with
matching drill routing. Both merges: `{{catalog}}/{{schema}}` tokens intact
(no leaked sed); SP access covered by the existing schema-level
`GRANT SELECT` (no script change needed).

---

## 2. Sanity-check verdict (the "is this a good plan" answer)

**The plan is sound.** The domain modeling was checked against how real
utility systems (CC&B / SAP IS-U / MDM, CIM) actually behave; the synthetic
generator against what is defensible to a utility audience. Confirmations
first, then the four real corrections the audit found.

### 2.1 Data-model choices — confirmed

- **Party / account / premise / service-point separation** is the correct
  CIM-style decomposition: `dim_customer` = party, `dim_account` = billing
  relationship (a *tenancy*, not a person), `dim_premise` = physical,
  meters/usage on the service point. This is exactly how CC&B and IS-U
  factor the world; the "account moves with the customer on relocation"
  decision (temporal §5.1) is the common CC&B pattern.
- **Ownership as a sparse, account-backed edge** (entity-grain §4.2) is the
  genuinely correct nuance: a utility is not a deed registry; it knows an
  owner only through owner-pays/master-meter accounts or a landlord
  reversion agreement — both real CC&B constructs. Not building a separate
  owner dimension is right.
- **Load anchored to the meter/premise, occupant resolved temporally** —
  correct; MDM data is never customer-keyed at source. It's also why the
  multi-premise "journey" is a query, not new AMI volume.
- **Counting-unit default = service location** matches how utilities
  themselves count "customers" (metered services), and matches the map dots.
- **IEEE 1366 treatment** (SAIDI/SAIFI/CAIDI, MED 2.5-beta exclusion,
  fixed-system-denominator "contribution" semantics for sliced SAIDI) is
  textbook-correct, including the county-denominator carve-out.
- **CX/EM&V KPI choices** (CSAT top-2-box headline, Bain NPS, FCR/AHT,
  participation = enrolled ÷ eligible) are the standard industry definitions;
  `csat_kpis.sql` sourcing CSAT from `fact_csr_interactions` (complete
  series) and NPS from the survey fact is the honest split.

### 2.2 Synthetic data generation — confirmed

- Deterministic `xxhash64(id, purpose, ${random_seed})` everywhere: right
  for a reproducible demo, and the EULP AMY2018 shapes give physically real
  load (weather-consistent PV by construction after Phase 1).
- The **weather-analog calendar map** (same month, nearest day-of-week) is a
  real load-forecasting technique — defensible on stage, and it fixes the
  existing DOW-drift and leap-day defects rather than adding hacks.
- **`kwh_scale` applied once at AMI projection** so YoY variation flows
  upward and every drill-down still reconciles — the reconciliation argument
  is the important one; keep it.
- The 97.5% / 2.5% split (1:1:1 residential vs multi-site commercial) is
  realistic in shape, and correctly framed as making the grain work a
  **bounded feature, not a rewrite**.
- Landlord-hero naming: fictional-but-evocative (recommended in entity-grain
  §9) is the right call for a shipped dataset — adopt it, close the question.

### 2.3 Corrections found by the audit (bake these into execution)

1. **Entity-grain §4.3 mis-states the curated load grain.** The curated
   facts are **account-grain**, not service-point-grain:
   `fact_customer_hourly_load_profile` = (account_id, year_month, day_type,
   hour); `fact_meter_readings_daily` = (account_id, date_key); `customer_id`
   and `service_point_id` are stamped non-key columns. Equivalent today
   (account:premise:service-point is 1:1) but **not** once W10's in-window
   turnover lands: an account change mid-window means AMI rows must be
   attributed across two accounts at *generation* time. The temporal
   attribution join (entity-grain §4.3) must therefore be planned against
   account grain — either re-key these facts to usage_point, or make the
   generator stamp account_id from the link window. Decide in W10, not W2.
   (The doc's own §4.3 line has been corrected to point here.)
2. **Wave A left the CSAT surface half-migrated**, violating the metric-views
   doc's own "migrate a surface wholesale or not at all" rule (§8): trend/
   channel/journey now read `metric_csat` while `csat_kpis.sql` and
   `csat_by_segment.sql` still read the star schema — and `csat_kpis.sql`
   was never assigned to any wave. **W1 must close this**: migrate both (see
   §3.1), restoring one source of truth for the CSAT page.
3. **`metric_customer_base` naming collides with the unit model.** Its
   `Customer Count` measure is `COUNT(1)` at *service-location* grain — the
   exact ambiguity entity-grain §4.4 exists to kill. When W2 lands the unit
   vocabulary, rename/re-comment the measures to match it (e.g. `Service
   Locations Served` + `Distinct Customers`), and sweep the other views'
   count measures for the same ambiguity. Cheap, high governance value.
4. **The hardcoded-date sweep list is stale.** Since temporal §1.2 was
   written, new literals were born: `CsatView.tsx` `RANGE_BOUNDS`
   (client-side 2017/2018 bounds), the five `csat_*.sql` params fed from it,
   `mkt_enrollment_monthly.sql`'s `DATE'2017-01-01'..'2018-12-31'` (survived
   its metric-view migration), and `metric_relationships`' tenure anchor
   `DATE'2018-12-31'` inside `metric_views.py`. W9's sweep must re-grep
   rather than trust the doc's list: `grep -rn "2017-\|2018-" app/config
   app/client/src src/30_curated/metric_views.py`.

---

## 3. Workstream specs (what "done" means for each)

### 3.1 W1 — Metric views wave B (finish the migration story) — SHIPPED 2026-07-10

Per metric-views §8, plus the correction above. Three of the four queries
migrated and verified live against their pre-migration output on
`timstanton_stable.customer_360` (the wave-A discipline); the fourth turned
out to be dead code:

- `csat_by_segment.sql` → `metric_csat` — **done.** Surfaced a real bug in
  the pre-migration SQL (374-row undercount in the customer_class/tenure_band
  breakdowns from an INNER JOIN to `dim_premise` needed only for county),
  fixed by construction in the migrated version.
- `csat_kpis.sql` → **done** (correction #2): CSAT half from `metric_csat`,
  NPS from `metric_nps` (via `MEASURE(\`NPS Score\`)` directly — the
  original account_group anti-fanout guard turned out unnecessary since
  `metric_nps` already joins 1:1 `dim_customer`; verified live it drops zero
  rows), FCR/AHT from `metric_fcr`; `ref_cx_targets` join stays app-side.
- `exec_kpis.sql` → **skipped, dead code** (zero callers in
  `app/client/src` — same situation as `exec_complaint_themes.sql` in wave
  A). Was expected to migrate to `metric_customer_base` + `metric_complaints`;
  turned out unnecessary.
- `mkt_program_kpis.sql` → **done.** Eligible denominator from
  `metric_customer_base` (correlated scalar subquery against `dim_program`
  for the segment filter — metric views don't support JOINs to other
  relations), enrollment half from `metric_dsm_uptake` (gained `Active Count`
  / `Dropped Count` measures for full column parity). Verified live for all
  15 programs.
- The in-app **Documentation → metrics** page was found already shipped as
  `MetricsCatalogView.tsx` (nav id `metrics-catalog`) — it introspects
  `information_schema` live via `GET /api/metrics/catalog`, so it already
  reflects all 9 views and picked up the new measures automatically; only a
  stale "7 governed views" comment/count needed fixing. `ARCHITECTURE.md` §5
  updated.
- Carried the month-truncation caveat forward: `metric_csat`/`metric_nps`/
  `metric_fcr` filter on month-truncated date dims; safe only because the
  app's ranges are year-aligned (`RANGE_BOUNDS`). Any free-form date picker
  needs a raw-date dim first.

### 3.2 W2 — Entity grain Phase A (counting-unit model)

Entity-grain §4.4 + §7, unchanged, plus correction #3 (align
`metric_customer_base` measure names with the unit vocabulary in the same
pass). App/curated only, no new data. Kills the 708-vs-849 mismatch class;
unblocks W3–W5.

### 3.3 W3/W5 — Premise inspector + pivots; unit/lens control — **SHIPPED 2026-07-12**

Entity-grain §6, unchanged. W3 (branch `w3-premise-inspector`, PR #10,
merge `11dbd63`): new premise-subject rail (`PremiseInspector.tsx`, pivot
chips), dot-click routes to it by default, occupant pivot chip (owner pivot
chip added by W4). W5 (commit `4f851db`, merged to `main` with W4 via
PR #11): "Count by Locations/Customers/Owners" toggle on the cohort
inspector (`FocusPanel`) — sets the headline unit and drives which
inspector a rail-list row drills into; "owner" was wired into the toggle
in `c508ffb` (same PR), all three modes live-verified. Decisions locked in
§6.3 held as built:
dot-click lands on the Premise inspector; experience follows the party;
complaints stay on the Customer inspector for now.

### 3.4 W4 — Ownership edge + landlord hero — **SHIPPED 2026-07-12**

Entity-grain §4.2 + §5, done as scoped: new `bridge_premise_owner` (real UC
FKs into `dim_customer`/`dim_premise`, verified live via
`information_schema`); `owner_pays`/`owner_occupied` derived entirely from
already-curated tables (no new raw data); `landlord_agreement` backed by one
new raw table, `raw_landlord_portfolio` — a single hero party ("Summit
Residential Holdings") owning 10 existing residential premises, additively
threaded through `raw_customer`/`raw_customer_account`/
`raw_account_premise_link` (new UNION branches only, no existing row
changed). The vacancy reversion **is a real bridge link** as planned — a
landlord-held, closed `bridge_account_premise` row
(`occupancy_type='vacant'`, `billing_responsibility_flag=true`) ending when
the current tenant's link starts, which threads through
`fact_service_event`'s existing (unmodified) logic and the Accounts &
Premises tab for free. Naming: "Summit Residential Holdings" (landlord) +
"Sunbelt Burger Co." (the largest existing chain, labeled via
`bridge_premise_owner.display_name`, NULL elsewhere).

New app-side: `OwnerInspector.tsx` (rail card + full drawer, portfolio
roster, "light up portfolio" map action), wired as the third pivot chip
(Premise ⇄ Occupant ⇄ Owner) alongside Premise/Customer. Live-verified in a
local dev browser session: search → Customer → pivot to Premise → pivot to
Owner → portfolio roster (10 premises, 1 historical vacancy, 0 current
vacancy) → light up portfolio → pivot a roster row back to Premise. Console
clean. W4+W5 merged to `main` together via PR #11 (`ba100ef`), including
the owner-toggle wiring (`c508ffb`) — no loose ends remain; the
entity-grain design is fully executed. Post-merge live check (2026-07-12):
`bridge_premise_owner` populated (1,195 rows) with its PK + both FKs
(`fk_bpo_party`, `fk_bpo_premise`) present in `information_schema`.

### 3.5 W7 — CSAT Phase 2 / W8 — CSAT Phase 3 — both **SHIPPED 2026-07-12**

**W7 shipped as scoped** (PR #12, `24123e9`; build notes in the csat doc's
status header). As-built notes:

- The three new queries (`csat_drivers.sql`, `csat_operational_correlation.sql`,
  `csat_survey_health.sql`) **stay on the star schema deliberately** — they
  bucket row-level driver fields, outside the aggregate-only metric-view
  constraint — and each query header says so, per plan.
- `fact_survey_invitations` landed at `(survey_id, period_date_key, segment)`
  grain, quarterly-NPS only (transactional CSAT has no invitation concept —
  volume stays the honest label there). Verified live post-merge: 16 rows
  (8 quarters × 2 segments), response rates 27–33%, always < 100%.
- W7 also fixed a real off-by-one in the csat design doc: top-2-box is
  `score_0_10 >= 8`, not `>= 9`. All shipped SQL uses `>= 8`.

**W8 (Phase 3 — verbatims, closed-loop follow-up queue) shipped the same
session as this plan update.** csat doc §5 rows 7–8, done as scoped, plus a
build-time discovery that simplified it:

- The "decide the verbatim synthetic-text mechanism" open question (seeded
  template bank vs. `ai_gen`) turned out to be already answered by existing
  code: `fact_survey_responses.comment_text` is already LLM-generated via
  `ai_query` at build time in `raw_qualtrics_response.sql` (~5% of NPS
  responses) — the same precedent `raw_customer_complaint_text.sql` set for
  complaints. No new generator was needed; W8 only added two curated
  columns, `comment_sentiment` (cheap `score_0_10` bucket) and
  `comment_theme` (`ai_classify` reusing the complaint category taxonomy),
  both gated on `comment_text IS NOT NULL` so the AI cost stays bounded to
  the same small NPS-comment slice.
- The follow-up queue is the piece that finally threads a drawer callback
  into `CsatView` — done as `onJumpToSubject` (matching `ExplorerMap`'s
  existing prop name/shape over the `InspectorSubject` union, not the
  stale `setFullProfile`/`onJumpToCustomer` naming this doc previously
  guessed at), wired in `App.tsx` to the existing `setFullSubject`.
- Full pipeline redeploy + curated-pipeline rerun done live against
  `timstanton_stable.customer_360`; FKs on `fact_survey_responses`
  re-verified via `information_schema` post-run (all 3 intact). Live-verified
  in a local dev browser session: theme frequency + verbatim feed with
  sentiment/theme badges, follow-up queue table with real detractor rows,
  "Open profile" opens the existing customer drawer from both panels.
- Picked up three of §1.1's residual nits opportunistically while in the
  area: `num()`-wrapped the Phase-2 correlation/volume chart bindings in
  `CsatView.tsx`, added a `bill_id` tiebreaker to `csat_operational_correlation.sql`'s
  `nearest_bill`, and excluded `occupancy_type = 'vacant'` from
  `premise_header.sql`'s prior-occupant count.

### 3.6 W6 — PV + EV detection surfacing (no sibling doc; spec is here)

Current state (verified): `ml_pv_detection_predictions` and
`ml_ev_detection_predictions` are populated, correct, and referenced by
**zero** app code. The one shipped ML-surfacing precedent is the complaints
predictor (commit `debb8b3`): score join in `exec_map_cells.sql` +
`POINT_COLS`/`POINT_RISK_JOIN` in `geniePlugin.ts` + drill-panel chip +
drawer AlertsBanner item.

Decisions (recommended; the three open questions from the
`app-surface-pv-predictions` memory, resolved):

1. **Do both EV and PV in one pass** — same pattern, same joins, neither has
   an existing surface; doing one leaves the other as an identical TODO.
2. **Drawer-first, map-lens second**: a "Detected DER" block on the customer
   drawer (chip + probability + drivers), reusing the AlertsBanner shape;
   add an Explorer map lens only if the demo narrative wants territory-level
   DER heat (cheap to add later via the `exec_map_cells.sql` pattern).
3. **The disagreement case is the story**: `pv_likely_flag = 1` while
   `raw_der_customer.has_pv = 0` is "likely unregistered self-install —
   not on the interconnection register", a real utility compliance/safety
   use case. Give it a distinct badge, not just a probability. (Same logic
   for EV vs the EV-program flag.)

Placement: customer drawer + (optionally) the `ee-der-programs` placeholder
view when it becomes real. Respect the entity grain: PV attaches to the
**premise** (it's on the roof), EV to the **customer** (it moves with them)
— after W3 exists, PV belongs on the Premise inspector, EV on the Customer
inspector; before W3, both live on the drawer with a one-line note.

### 3.7 W9 — Temporal realism Phase 2 — **SHIPPED 2026-07-12**

Built as scoped (temporal §3), plus correction #4 (re-grepped fresh rather
than trusting the doc's stale literal-sweep list, and it did turn up more
than expected — see below). PR #14 (`3f4e09b`), branch
`w9-temporal-realism-phase2`.

- `weather_calendar_map` (new, `src/20_synthetic/transformations/ami/`):
  maps each display date (the `as_of_date`-minus-`history_months` trailing
  window) onto a day-of-week analog in the fixed 2018 AMY source library
  (same month, nearest day-of-month; Feb 29 explicitly borrows Feb 28),
  plus a deterministic `kwh_scale` (seeded `xxhash64`, ~±2%/yr trend + ±3.5%
  month noise). `raw_meter_readings.sql`'s `base` CTE now joins this map
  instead of `EXPLODE(SPLIT('${target_years}', ','))`; `kwh_scale` applies
  once, to `kwh_base`.
- `target_years` **fully retired** — killed as a bundle var and re-derived
  from `as_of_date`/`history_months` in situ (a `SEQUENCE(...) INTERVAL 1
  MONTH` + `YEAR()` CTE) in all 5 places that consumed it:
  `raw_meter_readings`, `raw_outage_event`, `raw_digital_event` (also fixed
  two literal-`2017-01-01`-anchored one-time-event CTEs,
  `app_installs`/`outage_alert_optins`, to float with the window),
  `raw_portal_session`, `cx_genesys/raw_interaction`.
- `curated_demo_config` (new, `src/30_curated/transformations/`): 1-row
  table (`as_of_date`, `history_months`, `complaint_window_days`,
  `billing_lookback_months`) — the app's single non-literal anchor,
  following the `ref_cx_targets` static-table precedent. New `curated`
  pipeline config keys: `as_of_date`, `history_months`.
- **App-side literal sweep — re-grepped fresh, found beyond the doc's
  list**: `exec_kpis`, `exec_map_cells` (×2), `exec_complaint_themes`,
  `exec_kpis_scoped`, `exec_map_cell_themes` (all the 90-day complaint
  window) — plus **`owner_portfolio`/`customer_header`/`owner_header`**
  (12-month billing window, not in the doc's original list — same bug
  pattern, caught only by the re-grep), `mkt_enrollment_monthly`/
  `mkt_complaint_themes`, `geniePlugin.ts`'s two inline SQL-template
  windows, `CsatView.tsx`'s `RANGE_BOUNDS` (now computed from a new
  `demo_config` query — the period picker shows real date ranges, not
  literal "2017"/"2018"), and `metric_relationships`' tenure anchor in
  `metric_views.py` (now an `as_of_date` widget).
- **Found and fixed during live verification (not in any doc's scope) —
  two ML time-window bugs that only surface once the window moves off
  2018**: `ev_detector`/`pv_detector` `features.sql` had a hardcoded
  `reading_date BETWEEN DATE'2017-12-31' AND DATE'2018-12-31'` — with
  `as_of_date=2026-03-15` this returned zero rows, crashing both trainers
  (`CANNOT_INFER_EMPTY_SCHEMA`); fixed via `CROSS JOIN curated_demo_config`.
  `complaint_predictor`'s `SPLIT_DATE = "2018-06-30"` (a train/test time
  split) is worse — the empty-train-set case didn't crash, it silently
  **trained a model on 0 rows** (100% test split) and reported job
  SUCCESS; only caught by explicitly querying `ml_complaint_training_data`'s
  split-column distribution post-run. Fixed by deriving `SPLIT_DATE` in
  `train.py` from a new `as_of_date` widget (trailing-6-months-held-out)
  instead of a `feature_spec.py` constant.
- Explicitly **out of scope, left alone**: the large set of internal
  generator literals anchored to "before 2017-01-01" (turnover history in
  `raw_customer`/`raw_account_premise_link`/`raw_customer_account`/
  `raw_end_device_asset`/`raw_premise_customer_map`, static survey-campaign
  seed dates in `raw_qualtrics_survey`/`raw_emplify_*`) — these are fixed
  points that stay semantically valid ("before the display window") for
  any realistic `as_of_date`, and rewriting the turnover model itself is
  W10's job (temporal §1.1's "all turnover is pre-2017" gap), not W9's.
- **Verified live**: regression guard at `as_of_date=2018-12-31` (default)
  — pipeline green, FK count unchanged (83), 2017-vs-2018 AMI totals now
  differ ~1.9% (was ~0% pre-Phase-2). Then a full run at
  `as_of_date=2026-03-15` — pipeline green end-to-end including ML
  train/score, FKs still 83, `curated_demo_config`/complaint window/
  weather-calendar-map all reflect the new anchor correctly, leap-day
  borrow logic verified correct in isolation, and a drilled bill still
  reconciles with its underlying daily AMI. App rebuilt + redeployed;
  browser-level visual verification was attempted (deployed app blocked by
  Databricks SSO on automated browser tools; local dev fell back to a
  code-level review after the same tooling issue) but not completed — the
  data/query-layer verification above is thorough, but the CSAT period
  picker's live rendering has not been eyeballed in a browser.

---

## 4. Recommended order (historical — the sequence is complete)

```
W10 (relocations / turnover / sub-metering) — SHIPPED 2026-07-13 as three
                       PRs (#16 relocations + shared in-window infra,
                       #17 generalized in-window turnover, #18 sub-metered
                       commercial); the heavy data work, last; enriches the
                       (already-shipped) premise inspector's occupant
                       timeline, and owned the account-grain attribution
                       decision (correction #1). It inherited W9's
                       curated_demo_config anchor and weather_calendar_map,
                       so in-window turnover generates against a
                       physically consistent calendar.
```

(W1–W9 all shipped as of 2026-07-12, W10 as of 2026-07-13 — see §1 and
§3.1–§3.7. Nothing remains in the active sequence.)

Rationale: W8 was the only remaining pure-app workstream and completes the
user-visible narrative arc (CSAT overview → drivers → verbatims/follow-up).
W9 closed the temporal-realism half of the plan (calendar map + as-of
parameterization, including two ML time-window bugs found only by running
the pipeline at a shifted `as_of_date`). W10 is the heavy generator work,
last; all the surfaces that will *show* their output (premise inspector, occupant
timeline, Accounts & Premises tab) already exist, and W9's calendar map is
the prerequisite for W10's in-window turnover to produce physically
consistent load.

Session-sizing guidance: W10 ≈ a full session or more.

---

## 5. Standing gotchas (from repo memories — apply to every workstream)

- New app-read tables need SP grants (`app/scripts/grant-permissions.sh`);
  the app SP does **not** inherit deployer grants. Genie-space access for
  the app SP is a separate CAN_RUN grant (auto-granted by
  `01_create_genie_space.py`).
- Local dev: `{{catalog}}/{{schema}}` sed must be applied then **reverted
  before commit**.
- FKs must be genuine UC constraints, re-verified via `information_schema`
  after pipeline runs (SDP orders by data lineage, not declared FKs — a
  fact/dim refresh race can silently drop a constraint; re-run fixes it).
- Constraint names are schema-scoped; MV constraints only manageable via the
  `CREATE OR REFRESH` DDL.
- `CREATE OR REPLACE` on metric views resets column tags — the tag loop must
  run every pipeline run (already wired; don't remove it).
- `tsc` has a standing `App.tsx` baseline from generated `appKitTypes.d.ts`
  — don't chase those errors.
- Pipeline SQL lives under `transformations/` folders (globs only take
  folders); job notebooks sit at the tier root.
- Deploy target: `timstanton_stable.customer_360`, DEFAULT profile,
  warehouse `8c35ef80cbacd670`.
- Verify migrated/changed queries **live against real output** before
  deleting old SQL — tsc and unit reasoning have both missed real bugs here;
  browser-level checks caught what synthetic events couldn't.
