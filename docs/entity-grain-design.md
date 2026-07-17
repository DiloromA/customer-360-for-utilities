# Entity Grain, Ownership & the Entity-Aware Right Rail — Design

Status: **ALL PHASES SHIPPED — fully merged to `main` 2026-07-12.**
Executed as **W2–W5 in `consolidated-execution-plan.md`**: W2 = Phase A
(counting-unit model, `8270e14`), W3 = Phase B (premise inspector + pivot
chips, PR #10 `11dbd63`), W4 = Phase C (ownership edge + landlord hero +
Owner inspector) and W5 = Phase D (unit/lens control) merged together via
PR #11 (`ba100ef`), including "owner" wired into the lens toggle
(`c508ffb`). This doc is now the *as-designed* reference; §6.3's locked
decisions held as built. File:line refs date from 2026-07-11
(`entity-grain-rail-design` tip `45b7c63`) — re-verify before relying on
them.

## 0. What this doc owns (and what it does not)

This is the third leg of a trio; read the siblings first and do **not**
duplicate them:

- **`temporal-realism-scoping.md`** owns *generator depth* — intra-territory
  relocations, in-window turnover, sub-metered commercial (its Phase 4) —
  and the *snapshot-vs-history* posture (its Phase 3 shipped the
  **"Accounts & Premises" drawer tab**; decided: **no map time-slider**,
  snapshot stays the app default). Everything about *how movers/turnover
  get generated* lives there.
- **This doc** owns the three things that one does **not**:
  1. **The grain/counting-unit model** — the fix for the "708 vs 849"
     *class* of mismatch (customer-grain vs location-grain surfacing the
     same cohort with different numbers).
  2. **The ownership / landlord edge** — a genuinely new relationship
     (property owner ≠ account holder ≠ occupant), absent from both sibling
     docs.
  3. **The entity-aware right rail** — a rail *typed by its subject*
     (premise vs customer vs owner), a deeper move than adding one tab.

Ground rule inherited and reaffirmed: **the map atom is always the premise
/ service location** (dots have geography; customers and owners are
groupings of premises). Snapshot stays the default. No time-slider.

---

## 1. The problem this fixes

The app chooses grain **ad-hoc per panel**, and the same root cause keeps
resurfacing as separate bugs (repo memories: `map-counting-grain`,
`csr-header-site-grain`, `der-opps-premise-grain`, and this session's
ask-bubble fix). Concretely, the trigger this session:

> "Ask the map" bubble reported **708** ("customers"), the right rail
> reported **849** ("customers"). Both are correct at *their* grain —
> 708 distinct customers occupy 849 current service locations — but nothing
> declared which grain it was speaking, so they read as a bug.

The one-line fix already shipped (`ChatAnswer` now counts the dots it
describes — `ExecMap.tsx:2914-2926`). But that is a spot-fix. The
**systemic** fix is to make *counting unit* an explicit, shared concept so
every number declares its grain. That is §5.

Why it *felt* systemic but isn't: 97.5% of records are 1:1:1 (see §2).
The mismatch only ever bites the commercial/multi-site minority. This is a
**bounded feature**, not a rewrite.

---

## 2. Data findings the design rests on (profiled 2026-07-10)

Current-state (`is_current`) fan-out:

| Grain | Distinct (current) |
|---|---|
| Service locations (premises) | 2,731 |
| Accounts | 2,731 |
| Customers | 2,570 |

- **Account : premise is exactly 1:1 today** (2,731 = 2,731; zero accounts
  span premises). In the *current snapshot* an account *is* a location — so
  "Account view" as a distinct **map** view earns nothing. It becomes
  distinct only over **time** (an account is a tenancy with a lifespan) and
  under **hierarchy** (`parent_account_id`), never as a spatial pivot.
- **63 customers are multi-location, all Commercial** (2.5%), holding 224
  locations (avg 3.6, max 9). The other 2,507 are 1 customer : 1 account :
  1 premise. The entire 849−708 gap is these 63.

The CIM-style model **already carries the richness** (it is mostly
flattened away in curated):

| Concept | Already in schema | Evidence (2026-07-10) |
|---|---|---|
| Move-in/out timeline | `dim_service_agreement` (`effective_date`, `termination_date`, `agreement_seq`, `is_current`); `bridge_account_premise` (`link_start_date`/`link_end_date`, `link_status`) | 3,114 agreements, 383 terminated |
| Master/corporate accounts | `dim_account.parent_account_id` + `account_group` | 85 `corporate_parent`, 247 `consolidated_billing` children |
| Owner vs tenant occupancy | `bridge_account_premise.occupancy_type`, `billing_responsibility_flag`; `raw_customer_changes.n_premises_owned` | 947 owner_occupied, 840 tenant, 1,198 commercial; owns up to 9 |
| Prior-occupant load already attributed | readings carry moved-out customers | 5,110 daily readings stamped to 253 moved-out customers |

**AMI is already compact and premise-anchored** (this is the answer to
"how do we do journeys without a crazy amount of AMI"):

| Table | Rows | Grain | Span |
|---|---|---|---|
| `fact_customer_hourly_load_profile` | 3.16M | service_point × month × day_type × hour (a *typical-shape* profile, not raw intervals) | 2017-01 → 2018-12 |
| `fact_meter_readings_daily` | 2.0M | service_point × day | 2017 → 2018 |

There is **no raw interval AMI**. Load is a property of the physical
service point and persists across occupants. Therefore a customer's
multi-house **journey load is a query, not new data**: slice the existing
service-point series by the customer's agreement windows. Adding movers,
chains, or landlords adds *relational rows only* — AMI volume does not move.
(Generation of the movers themselves = temporal-realism Phase 4.)

---

## 3. Real-world entity semantics (the model to be faithful to)

A utility is **not** a property-ownership registry. It knows an owner only
when that owner has a *billing relationship* with it. So "owns" is really
**three distinct relationships**, and the schema must keep them separate:

| Relationship | Meaning | Utility knows it? | Home in the model |
|---|---|---|---|
| **Account holder** | who is responsible for the bill | **Always** | `dim_account.customer_id` |
| **Occupant** | who physically lives/operates there | When they hold the account | `dim_service_agreement` / bridge, `occupancy_type` |
| **Property owner** | who holds the deed | **Only when account-backed** — owner-pays / master-metered, or the named reversion party in a landlord agreement | **new** owner edge (§4.2) |

Key consequence that decides the owner model: **every owner the utility can
represent is itself a party that bills somewhere** (they either hold the
accounts, or are the owner-of-record who catches service at vacancy). There
is no owner who is *never* a party — so there is no separate "owner master"
to build. Ownership is a **sparse, account-backed edge on the shared party
node**, not a second node type.

---

## 4. Data-model design

### 4.1 One party node; account = tenancy; premise = physical (unchanged)

Keep `dim_customer` as the **party** table (person or org). `dim_account`
stays the billing relationship; `dim_service_agreement` is the dated tenancy
(occupant party ↔ premise ↔ service_point). Surface — do not flatten —
`parent_account_id`/`account_group` so the app can traverse the
corporate/consolidated hierarchy. Curated must expose the **full temporal
bridge**, not just `is_current` (the shipped Accounts & Premises tab is the
first consumer; keep `is_current` as a convenience flag).

### 4.2 The ownership edge (the one genuinely new structure)

**Decision (resolved 2026-07-10):** one party node + a **new, deliberately
sparse, dated, account-backed** owner→premise edge. Not a separate owner
dimension (would model owners the utility structurally can't know, and
duplicate identity the moment an owner also bills).

```
bridge_premise_owner (
  premise_owner_link_id   BIGINT,
  party_id                BIGINT,     -- FK dim_customer (the owner, a party)
  premise_id              BIGINT,     -- FK dim_premise
  owns_from               DATE,
  owns_to                 DATE,       -- NULL = current
  basis                   STRING,     -- 'owner_pays' | 'landlord_agreement' | 'owner_occupied'
  is_current              BOOLEAN
)
```

Populated **only where account-backed** — so it is sparse by construction,
matching what a real utility has:

- **owner-pays / master-metered & corporate** → owner holds the child
  accounts (already via `parent_account_id`); add owner edges to each held
  premise. `basis='owner_pays'`.
- **landlord agreement (tenant pays, owner on file for reversion)** → the
  one case where the owner is *not* the current account holder; the owner
  edge is what makes the landlord traversable. `basis='landlord_agreement'`.
- **owner-occupant** → account holder = occupant = owner; edge optional,
  `basis='owner_occupied'` (can be derived from `occupancy_type`, not
  mandatory to materialize).

Requires: a `raw_*` generator row source, a curated transform, a real UC FK
(repo memory `feedback-fk-constraints-must-be-real` — no dashed-line ERD
fallback), and SP grants on the new table
(`app/scripts/grant-permissions.sh`, memory `app-sp-grants`).

### 4.3 Load attribution: service-point anchored, temporally resolved

**Correction (audit 2026-07-10):** the curated load facts are actually
**account-grain**, not service-point-grain —
`fact_customer_hourly_load_profile` = (account_id, year_month, day_type,
hour), `fact_meter_readings_daily` = (account_id, date_key) — with
`customer_id`/`service_point_id` stamped as non-key columns. Equivalent
today (1:1), but the in-window-turnover implication is resolved in
`consolidated-execution-plan.md` §2.3 item 1; decide re-keying there (W10),
not here.

Load/readings stay keyed to the physical service point conceptually. Make
customer/account
**derivable temporally** — resolve occupant by joining `reading_date` to the
active agreement window (`dim_service_agreement` half-open window / bridge),
rather than trusting only the baked `customer_id` stamp. The stamp is mostly
right today (prior occupants already appear — §2), but the temporal join is
the source of truth once in-window turnover lands (temporal-realism §5.2).
No volume change.

### 4.4 The counting-unit concept (the systemic anti-mismatch)

Every headline/cohort count declares a **unit** ∈ `{service_location,
customer, owner}` (account is a tenancy, not a spatial count — omit it as a
top-level unit). Both counts already derive from one cohort: `app_focus_set`
carries `customer_id` (+ nullable `premise_id`) and the bridge expands to
locations. So this is **presentation, not pipeline** — a shared count/format
helper carrying a `unit` in context. Default unit = **service_location**
(matches the dots).

Cohort-definition grain rule (correctness edge for the 63 multi-site):
**signal/behavior filters** (churn, payment, complaints — the signal lives
on the customer) → customer cohort, expand to all their premises;
**location/property filters** (built pre-1950, envelope quality — the
predicate is about the place) → premise cohort, store `premise_id`, **do not
NULL-expand** (else one qualifying store lights up a chain's other 8).

---

## 5. Synthetic data — the landlord hero (new here)

Chains and residential movers are **temporal-realism Phase 4's** job — do
not re-spec them. This doc adds only what that doc lacks: an **ownership /
landlord showcase**, cheap because it reuses existing premises' existing
load.

- **1 named landlord/portfolio party** owning ~10 premises
  (`occupancy_type='tenant'` on the occupants; owner edges via §4.2),
  including ≥1 **vacancy gap** where billing reverts to the landlord
  (`billing_responsibility_flag`, `link_status='ended'`). This is the case
  the owner edge exists for.
- Reuse the existing `corporate_parent` chain as the *owner-pays* example
  (already generated); just add its owner edges + a readable label.

**Open (light): naming.** Recommend **fictional-but-evocative** ("Summit
Residential Holdings" → 10 units; the existing chain gets a "Sunbelt Burger
Co."-style label) over real brands — safe in a shipped dataset, still reads
instantly. Chains are unnamed today, so this is additive.

---

## 6. App design — the entity-aware right rail

### 6.1 The rail is a *subject inspector*

Today the rail has two states — cohort (`FocusPanel`, `ExecMap.tsx:2587`)
and a customer drill (a dot-click sets `drillCustomerId`). Premise data has
nowhere to live because **a dot-click jumps straight to the customer** —
fine when premise≡customer, wrong once they diverge. Make the rail
explicitly **typed by its subject**; the subject's type drives its sections.

Two independent axes (keeping them separate is the whole trick):

- **Relationship pivots** (breadcrumb chips) = *which entity* — walk premise
  ⇄ occupant ⇄ owner ⇄ owner's other premises. This is the ego-network
  drill in the rail; never a global graph.
- **Tabs** = *which facet* of the current entity (the existing Overview /
  Accounts & Premises pattern).

```
[ 📍 Location ▸ 👤 Occupant ▸ 🏢 Owner ]   ← pivots (which entity)
<subject header for the active type>
┌ tabs (facets of THIS entity) ┐
```

### 6.2 The subjects and their grain-appropriate sections

| Subject | Sections that matter |
|---|---|
| **📍 Premise** (dot-click default) | building (subtype, sqft, vintage, envelope) · **load over time** (service-point profile + monthly trend, spans occupants) · **occupant timeline** (tenant A → vacancy → tenant B) · outages/service events *at this address* · DER physically installed here (solar stays with the house) · owner |
| **👤 Customer** (party) | **experience across all their premises** (complaints, CSR, surveys aggregated over locations) · **journey/footprint** (premises over time; "show on map") · payment/assistance · DER they own (EV moves *with* them) · Accounts & Premises roster |
| **🏢 Owner / portfolio** | portfolio roster (premise · occupancy status · tenant · load) · vacancy rate · aggregate consumption · issues across portfolio · "light up portfolio" map action |
| **▦ Cohort / territory** | today's `FocusPanel`, made unit-aware (§4.4) |

Principle the split encodes: **load & building live on the premise**
(physical, persist across occupants — also *why* AMI isn't regenerated per
customer); **experience follows the party** (aggregates across their
locations).

### 6.3 Interaction decisions (agreed 2026-07-10 — do not relitigate)

1. **Dot-click lands on the Premise inspector**, with the occupant as a
   one-tap pivot chip in the header. For the 97.5% residential 1:1 case it
   reads as "premise with its occupant inline"; it visibly diverges only for
   the commercial/landlord minority — exactly where divergence is wanted.
2. **Experience follows the party**; the Premise inspector shows only
   **location-bound events** (outages, service visits, DER installs — all
   already premise-keyed). Ideal end-state tags complaints by scope
   (customer vs location); **start with the fallback** (complaints on the
   Customer inspector only, premise shows outages/service events) to avoid
   touching the complaint model now. Complaint-scope tagging = a later,
   optional refinement.

### 6.4 A unit/lens control at cohort level

A "count by {service locations · customers · owners}" control on the cohort
inspector sets the default subject when you drill (locations→premise,
customers→customer). Default = service locations. Backed by §4.4.

### 6.5 Map to what exists

- `FocusPanel` → **Cohort inspector** (add unit-awareness).
- The **shipped Accounts & Premises tab** + `HeaderStrip` + "Show all
  locations" (handler `App.tsx:429-441`, button `App.tsx:811-819`, and the
  `MapFocusRequest` focus state at `App.tsx:348`) is already ~60% of the
  **Customer inspector**.
- **Net-new: the Premise inspector**, and routing a dot-click to it.

---

## 7. Existing custom logic to rework (explicit ask)

The grain hacks are local patches an explicit unit model subsumes. Re-express
each against §4.4, don't keep patching:

**Curated / pipeline** (`src/30_curated/transformations/`):
- `bridge_account_premise.sql`, `dim_service_agreement.sql`, `dim_account.sql`
  — stop collapsing to current-only / 1:1; expose full temporal history +
  the `parent_account_id`/`account_group` hierarchy.
- `fact_customer_hourly_load_profile.sql`, `fact_meter_readings_*.sql` —
  confirm/adopt the temporal-attribution join (§4.3).
- **new**: `bridge_premise_owner` raw source + curated transform + FK (§4.2).

**App server**:
- `geniePlugin.ts` — the premise-grain headline + `is_current` joins +
  `enrichCustomers` premise expansion (`geniePlugin.ts:746-753`, `942-948`);
  the ask cohort-grain rule (§4.4).
- `focusPlugin.ts` — the `premise_id IS NULL` NULL-expansion and
  `COUNT(DISTINCT customer)` (`focusPlugin.ts:118-119`, `318-322`): make the
  cohort carry an explicit unit + store `premise_id` for location-defined
  cohorts.

**App client**:
- `ExecMap.tsx` — `FocusPanel` headline (`:2654`), the unit/lens control,
  routing dot-click to a Premise inspector.
- `App.tsx` — the profile drawer becomes the Customer inspector; add the
  Premise + Owner inspectors and the pivot chips.

The three memories (`map-counting-grain`, `csr-header-site-grain`,
`der-opps-premise-grain`) are all this one root cause and should collapse
into the unit model rather than remain separate special-cases.

---

## 8. Phasing (dependencies flow downward)

| Phase | What | Depends on |
|---|---|---|
| A (= W2) | **Counting-unit model** (§4.4) — shared unit-aware count/format helper; make every existing headline declare its unit; ask cohort-grain rule. *App/curated only, no new data.* Kills the mismatch class. | — |
| B (= W3) | **Premise inspector + pivots** (§6) — new premise-subject rail, dot-click routes to it, occupant/owner pivot chips. | A |
| C (= W4) | **Ownership edge + landlord hero** (§4.2, §5) — new table/FK/grants + generator + Owner inspector. | A |
| D (= W5) | **Unit/lens control** (§6.4) surfaced to the user. | A, B |

Phase A is the highest-value, lowest-risk slice (it's what this session's
bug was a symptom of) and unblocks the rest. B and C are independent after A.
Movers/turnover generation (temporal-realism Phase 4) can land in parallel;
the Premise inspector's occupant-timeline gets richer once it does.

## 9. Open decisions

- **Hero naming** (§5): fictional-but-evocative (recommended) vs real brands.
- **Complaint scope tagging** (§6.3): ship the fallback now; decide later
  whether to add a customer-vs-location scope flag to the complaint model.

## 10. Gotchas (repo memories)

- New app-read tables need SP grants — `app/scripts/grant-permissions.sh`
  (`app-sp-grants`); the app SP does **not** inherit deployer grants.
- Local dev against real data needs the `{{catalog}}/{{schema}}` query-token
  sed applied then **reverted before commit** (`app-local-dev-boot`).
- New FKs must be genuine UC constraints, verified via
  `information_schema` — no dashed-line ERD fallback
  (`feedback-fk-constraints-must-be-real`, `fk-constraint-dag-race`).
- `tsc` has a standing App.tsx baseline from generated `appKitTypes.d.ts` —
  don't chase those errors (`deferred-app-layer-refactor`).
