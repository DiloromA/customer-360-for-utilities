# Drill-down polish, PV/DER consistency, Genie space configuration, Ask-the-Map empty state

Design + implementation doc for a four-part polish pass. All root causes below were
verified against the code and the live deployed schema
(`timstanton_stable.customer_360`) on 2026-07-13 — the "Evidence" subsections are
facts, not hypotheses. None of the fixes require re-running the pipeline job; parts
1–3 are app-query/UI changes (app rebuild + redeploy), part 4 is the Genie setup
script plus one job-task run of that notebook (or a direct notebook run).

---

## 1. Pivot chips: stop rendering raw 32-hex IDs

### Problem
The three pivot chips under the premise header (`PivotChips` in
`app/client/src/PremiseInspector.tsx:154`) label the Occupant and Owner chips with
the full natural key — e.g. `👤 Account 43782fd0c001dbf797abfe3f7e37e2c3`. The keys
are md5 strings (32 hex chars), so the chips overflow the ~340px right rail. Same
component is rendered in four places: `PremiseDrillCard`, `PremiseDetail`,
`CustomerDrillPanel` (ExplorerMap.tsx:3224), and `OwnerInspector`.

### Evidence
- There is **no name column to use instead**. `dim_customer` and `dim_account`
  carry no person/org name (synthetic data was generated without names);
  the only display names in the model are `bridge_premise_owner.display_name`
  (deliberately sparse — landlord heroes only, most NULL, see
  `src/30_curated/transformations/bridge_premise_owner.sql:21`) and
  `rate_display_name`. So "use the account name" is off the table without a
  data-gen change + full job rerun — out of scope.
- CSS (`App.css:1944` `.pivot-chips` / `.pivot-chip`) has no `flex-wrap`,
  `max-width`, `overflow`, or `text-overflow` — nothing stops a long label from
  running off the rail.
- Precedent already exists for truncation: the cell customer list renders
  `Account {c.account_number.slice(0, 10)}…` (ExplorerMap.tsx:2899).

### Design
Chips are **pivot affordances, not identifiers** — their job is to say "there is an
occupant / an owner, click to switch subject". Lead with the role, keep a short id
suffix for scanability, put the full id in the `title` tooltip:

- Occupant chip: `👤 Occupant · 4378…e2c3` (role + first-4/last-4 short form).
  When vacant: `👤 Vacant` (unchanged). When the subject IS the customer, the
  active chip reads the same (`👤 Occupant · 4378…e2c3`) — "Account" as a word
  disappears from the chips entirely.
- Owner chip: keep preferring `display_name` (e.g. "Maple Court Properties"); when
  NULL fall back to `🏢 Owner · ab12…9f0e` instead of the full hex. "No owner on
  file" state unchanged.
- Premise chip: unchanged (address is already a good label), but give it the same
  ellipsis treatment for very long addresses.

Implementation:
1. Add one shared helper in PremiseInspector.tsx (next to `fmtDate` etc.):
   `shortId(s: string): string` → `s.length > 12 ? s.slice(0,4) + "…" + s.slice(-4) : s`.
2. Use it in the three chip labels; set `title={...full id...}` on the occupant
   chip (premise + owner chips already have `title`).
3. CSS defense in `.pivot-chip`: `max-width: 160px; overflow: hidden;
   text-overflow: ellipsis; white-space: nowrap;` and `flex-wrap: wrap` on
   `.pivot-chips` — so no future label can overflow the rail regardless of content.
4. Sweep other decorative raw-id renders with the same helper:
   - ExplorerMap.tsx:2899 (`slice(0, 10)…` → `shortId`, consistency),
   - App.tsx:1015 profile-change rows (`— {account_number}`),
   - OwnerInspector.tsx:108/177 `Owner ${owner_number}` fallbacks.
   Leave **tables** whose content IS account numbers alone (e.g. the Accounts &
   Premises agreement table App.tsx:987, owner portfolio tenant column) — there
   the id is data, not decoration; a `title` tooltip + `font-variant-numeric`
   styling is enough if they ever look cramped.

## 2. "Occupant since … Account <hex>" noise lines

### Problem
The account id is repeated as body text right under the header where it adds
nothing (it's already one chip away, and now also in the chip tooltip).

### Locations to change
- `PremiseInspector.tsx:344` (rail card "Occupant since" delta-row): the
  `delta-comp` cell renders `Account ${p.occupant_account_number}`. Replace with
  the occupant's `customer_class` (already selected as
  `occupant_customer_class` in premise_header.sql — currently unused by the UI) —
  e.g. `residential occupant` — or keep `vacant` for the vacant state.
- `PremiseInspector.tsx:443` (full drawer header strip): `Occupant since {date} •
  Account {id}` → `Occupant since {date}` (+ optionally `• residential`).
- `App.tsx:1043` (customer drawer header): `Customer since {date} • Account
  {32-hex}` → drop the account fragment. The account number remains available in
  the URL (`/csr/:account_number` deep link) and the Accounts & Premises tab.
  Optional nice-to-have (not required): a small "copy account #" icon-button in
  the header for CSR workflows.
- `App.tsx:912` (`· parent {parent_account_number}`): truncate with `shortId` +
  tooltip; the parent link concept matters, the full hex doesn't.

## 3. "Detected PV (confirmed)" badge with an empty "DER Installed" card

### Root cause (verified, data is fine — no job rerun needed)
The two widgets are computed at different grains:

- The badge comes from `premise_header.sql:83-85`: `pv_on_record :=
  ml_pv_detection_predictions.has_pv_label`, joined on the **current occupant's
  customer_id**. `has_pv_label` is built in
  `src/40_ml/pv_detector/features.sql:144-154` as `MAX(has_pv)` over
  `raw_der_customer` — explicitly customer-grain ("a customer 'has PV' if ANY of
  their premises does — multi-site chains").
- The "DER Installed" card (`premise_der.sql`) lists `fact_der_adoption` rows
  **for this premise_id only**.

Live quantification (2026-07-13, timstanton_stable.customer_360):
- 2,374 premises currently show the "Detected PV (confirmed)" badge
  (`pv_likely_flag = 1 AND has_pv_label = 1` for the current occupant).
- **256** of them have no PV row at that premise; **169** have no DER rows at all
  → badge says confirmed PV, card says "No detected devices on file".
- All 256 are the same story: the occupant has a registered PV row in
  `fact_der_adoption` **at a different premise they hold** (0 cases of a label
  with no PV row anywhere). `fact_der_adoption.premise_id` is never NULL and
  `device_type` values are exactly `PV | EV | HEAT_PUMP | SMART_TSTAT | BESS`.

So the data is internally consistent; the premise view is just reading a
customer-grain flag as if it were premise-grain.

### Design
Make `pv_on_record` premise-scoped in `premise_header.sql`, and add a
customer-scoped companion so the "unregistered" warning doesn't fire for someone
whose PV is registered at their other site:

```sql
pv_at_premise AS (   -- registered PV bolted to THIS roof
  SELECT 1 AS x FROM {{catalog}}.{{schema}}.fact_der_adoption d
  JOIN prem ON prem.premise_id = d.premise_id
  WHERE d.device_type = 'PV' LIMIT 1
),
-- customer-scoped: any registered PV for the occupant (joins cur_link.customer_id)
pv_anywhere AS ( ... same, keyed by d.customer_id = cl.customer_id ... )
```
Expose both: `pv_on_record` (now := premise-scoped EXISTS) and a new
`pv_on_record_elsewhere` BOOLEAN.

Badge logic in `premiseAlerts()` (PremiseInspector.tsx:238):
- `pv_likely && pv_on_record` → **"Detected PV (confirmed)"** (unchanged text).
  Now guaranteed consistent: the DER card will always show the PV row.
- `pv_likely && !pv_on_record && !pv_on_record_elsewhere` → **"Likely
  unregistered PV"** (unchanged — genuinely nothing on the register).
- `pv_likely && !pv_on_record && pv_on_record_elsewhere` → **no badge** (the
  detection signal is customer-level — features sum ALL the customer's service
  points, so the midday-dip may belong to their other site; asserting anything
  about THIS roof would be a guess). This silently absorbs the 256 inconsistent
  cases. If a badge is wanted later, a neutral "Occupant has registered PV at
  another site" info badge is the honest version — but default to nothing.

Also update the model interface (`PremiseHeaderRow`) and the
`PremiseAlertsBanner` "No active issues" detail text if needed. Remember the
BOOLEAN-as-string gotcha: run the new column through `bool()` like the others.

Check while in there: the customer drawer no longer renders a PV badge (it moved
premise-side per the note in premise_header.sql) — verify `customer_header.sql`
consumers don't have the same customer-vs-premise mismatch anywhere else. The DER
opportunity cards were already premise-scoped in the der-opps-premise-grain fix.

### Deploy
App-only: `premise_header.sql` + PremiseInspector.tsx → rebuild + redeploy the app
(remember `app/deploy/config/queries/` is the deploy copy — follow whatever the
existing build script does to sync it; don't hand-edit both). No pipeline run.

---

## 4. Genie space: use the actual configuration features

### Problem (verified by exporting the live space)
`app/setup/01_create_genie_space.py` concatenates ~180 lines of instructions onto
the `description` field and ships a `serialized_space` containing **only**
`config.sample_questions` + `data_sources.tables`. Export of live space
`01f15b1323df18a0a4af1340c92ccef0` confirms: no `instructions` key at all. The
join guidance, key definitions, metric-view rules, and preamble contracts all sit
in the description — the field meant for humans browsing the space list (and for
supervisor-agent routing), not the primary channel Genie is designed to read.

The in-code comment ("the serialized_space `instructions` schema rejects
`general_instructions` on create") almost certainly records a wrong-field-name
attempt: the field is `text_instructions`, not `general_instructions`.

### Best practices (docs.databricks.com/aws/en/genie/best-practices)
Hierarchy of instruction channels, in priority order:
1. **SQL expressions** (`sql_snippets`: measures / filters / expressions with
   synonyms) — business semantics: "payment stressed", "high usage", …
2. **Example SQL queries** (`example_question_sqls`) — teach complex/ambiguous
   patterns: point-in-time joins, the map-dot output contract, MEASURE() syntax.
3. **Text instructions** — last resort, concise (~20 lines), for behavior that SQL
   can't express.
Plus: `join_specs` for table relationships, keep table count small (we're at 24 of
a 30 limit — fine), column synonyms, and `benchmarks` for regression-testing the
space.

### serialized_space v2 target shape
(Field names cross-checked against the API docs summary + the
databricks-solutions vibe-coding-workshop genie-space-patterns skill; the
**first implementation step is an empirical round-trip** — add one join + one
text instruction in the Genie UI, `export` the space, and confirm the exact key
shapes before generating the full payload. Do not trust this doc over the
round-trip.)

```jsonc
{
  "version": 2,
  "config": { "sample_questions": [ { "id": "<32-hex>", "question": ["…"] } ] },
  "data_sources": { "tables": [ { "identifier": "cat.sch.t",
                                   "column_configs": [ /* synonyms, entity matching */ ] } ] },
  "instructions": {
    "text_instructions": /* general instructions — string or [{id, content}]; confirm via round-trip */,
    "example_question_sqls": [ { "question": "…", "sql": "…" /*, usage_guidance */ } ],
    "join_specs": [ { "left_table": "…", "right_table": "…",
                       "join_condition": "…", "relationship_type": "FROM_RELATIONSHIP_TYPE_MANY_TO_ONE" } ],
    "sql_snippets": { "measures": [...], "filters": [...], "expressions": [...] }
  },
  "benchmarks": [ { "question": "…", "answer": [{ "format": "SQL", "content": ["…"] }] } ]
}
```

### Content redistribution plan
Split the current INSTRUCTIONS blob by destination:

| Current block | Destination |
|---|---|
| Short purpose paragraph (`DESCRIPTION` constant) | `description` — and ONLY this |
| "What this data is" table-by-table narrative | Mostly already in UC table COMMENTs (they're good); keep a 3–5 line schema-shape summary in `text_instructions` (customer↔account↔premise hierarchy + "keys are BIGINT `*_id`, human ids are `*_number`") |
| "How to join" | `join_specs`: dim_account→dim_customer (M:1), dim_account→dim_premise (M:1), dim_premise_h3→dim_premise (1:1), dim_service_point→dim_premise (M:1), bridge_account_premise→dim_account/dim_premise, facts→their dims, app_focus_set→dim_customer. Note: the schema already declares 79 real UC FK constraints (RELY) which Genie can read — join_specs still worth adding for the bridge/effective-dating semantics and because the metric views + app_focus_set have no FKs. The **point-in-time half-open-window pattern** can't be a join_spec — make it an `example_question_sqls` entry ("Who was the billing-responsible account at premise X in 2017?") |
| "Key definitions" bullet list | `sql_snippets.filters` with synonyms: payment stressed, high usage/top quartile (`high_user_flag`), dissatisfied/churn (`churn_risk_band='high'`), critical care, LIHEAP, complains-about-high-bills (the category/sub_category IN predicate), not-enrolled (EXISTS pattern may need an example SQL instead — filters must be boolean row-level predicates, and NOT EXISTS against fact_program_enrollment is fine as a filter snippet) |
| "CRITICAL — this powers a map" + "Returning customers at customer grain" | `text_instructions` (behavioral contract — the app parses `customer_id`/lat/lon) **plus** one `example_question_sqls` entry showing the canonical dot-query shape (customer set + latitude/longitude via is_current join) — an example teaches the shape better than prose |
| MAP CONTEXT + FOCUS COHORT preamble contracts | `text_instructions` — genuinely behavioral, keep, but tighten. These are load-bearing: `app/server/geniePlugin.ts` prefixes questions with those blocks |
| Multi-turn note | `text_instructions` (one line) |
| Metric-views section | Split: the MEASURE()/backtick/no-SELECT-* syntax rules + "prefer metric views for aggregates" → `text_instructions` (short); the 9 per-view descriptions → those views' UC COMMENTs if not already there, plus 1–2 `example_question_sqls` (e.g. the SAIDI-by-county query with correct MEASURE syntax); consider moving the 9 metric views from `data_sources.tables` to `data_sources.metric_views` if the round-trip export shows that key |
| `SAMPLE_QUESTIONS` | unchanged (`config.sample_questions`) |
| new | `benchmarks`: seed with 5–8 of the sample questions paired with certified SQL (fixed date literals, no CURRENT_DATE — the data is frozen at `as_of_date` anyway) so future space edits can be regression-checked in the Genie UI's benchmark runner |

Target: `text_instructions` ≤ ~40 lines (map contract, preambles, multi-turn,
metric-view syntax, BIGINT/`*_number` key convention). Everything definitional
moves to structured channels.

### Script changes (`app/setup/01_create_genie_space.py`)
1. Build the full `serialized_space` dict (instructions + join_specs +
   sql_snippets + benchmarks), templated on catalog/schema exactly like TABLES.
2. `description` goes back to the short `DESCRIPTION` constant alone.
3. Keep the existing list→PATCH-or-POST flow and the app-SP CAN_RUN grant block
   unchanged. PATCH with the new payload updates the existing space in place
   (same space_id `01f15b13…` — the app's DATABRICKS_GENIE_SPACE_ID does not
   change, no app redeploy needed for this part).
4. After PATCH, GET/export the space back and **assert** the instructions
   round-tripped (this is the guard against the old `general_instructions`
   silent-rejection problem — fail loudly, don't fall back to description).
5. Delete the stale "instructions schema rejects general_instructions" comment.
6. Verify: open the space UI → Instructions pane should show General
   Instructions + example SQLs + joins populated; then run 2–3 sample questions
   through the app's Ask-the-Map (it exercises the Conversation API + preambles)
   and one MEASURE() metric-view question. Run the benchmark suite in the UI.

Run via: the existing job task that executes this notebook (or a one-off
notebook run with the same widget params — catalog/curated_schema/app_schema/
warehouse_id/app_name as used at deploy; see memory `deploy-target-and-clobber`
for the exact --var discipline if going through the bundle).

---

## 5. Ask-the-Map empty state

### Problem
`ExplorerMap.tsx:2172-2175`: expanding the chat with no turns shows a dead
`"Ask a question to get started."` line. The panel is open by default
(`chatOpen = useState(true)`), so this is literally the first thing the empty
panel says on load.

### Decision (user delegated the call)
Make the empty state useful rather than locking the expand/collapse (blocking
interaction until a question exists is hostile, and the collapsed→expanded→empty
path would still exist on first load). Replace the dead line with a compact
starter block — muted one-liner + 3 tappable example-question chips:

- Guidance line adapts to existing state (the scope hint row at
  `map-chat-scope` already tracks `focusActive`):
  - no focus group: "Ask about everything on screen or the whole territory — or
    build a focus group (hex, draw, filters) and ask about just them."
  - focus group active: "Your focus group is the default scope — ask about them,
    or say 'vs the whole territory' to compare."
- 3 example chips, clicking one submits it immediately (fills `askInput` state →
  `submitAsk()`; check `submitAsk` reads the freshest value — it's a
  `useCallback` over `askInput`, so either pass the question as an arg or set
  state and call submit with the explicit string). Reuse questions from the Genie
  space's SAMPLE_QUESTIONS so the two surfaces stay consistent, e.g.:
  1. "Show me the customers who complain about high bills"
  2. "Which customers are payment-stressed with 2+ complaints in 90 days?"
  3. "How many critical-care customers had 4+ hours of outages recently?"
- Style: reuse the existing chip/badge look (`.badge neutral`-ish, or a new
  `.chat-suggestion` class) — small, wrap in a column, no paragraphs. The box
  must stay visually quiet; total empty-state height ≈ what 2 chat turns take.
- Keep the collapse toggle exactly as is.

---

## Suggested execution order
1. Part 3 (PV/DER query + badge logic) — it's the only correctness bug.
2. Parts 1+2 together (same files, one visual pass) + part 5 (small, same file
   family). One app rebuild/redeploy covers 1/2/3/5. `npm run build` + tsc must
   pass; then live-browser check the rail card, full drawer, customer drawer,
   and empty chat (per repo history, this class of UI change has only ever
   broken in ways tsc can't see — check in a real browser, e.g. a premise with
   confirmed PV: badge + DER card now agree; a premise whose occupant has PV
   elsewhere: no badge).
3. Part 4 (Genie) — independent; starts with the UI-configure→export round-trip
   to pin the schema, then script rewrite, PATCH, verify in UI + app.

For finding test premises for part 3's browser check (all three badge states):

```sql
-- state A: confirmed here / state B: unregistered / state C: PV elsewhere (no badge)
WITH cur AS (SELECT premise_id, customer_id FROM ...bridge_account_premise WHERE is_current),
pv  AS (SELECT customer_id FROM ...ml_pv_detection_predictions WHERE pv_likely_flag=1 AND has_pv_label=1),
here AS (SELECT DISTINCT premise_id FROM ...fact_der_adoption WHERE device_type='PV')
SELECT dp.premise_number, (h.premise_id IS NOT NULL) AS pv_here
FROM cur JOIN pv USING (customer_id)
JOIN ...dim_premise dp ON dp.premise_id = cur.premise_id
LEFT JOIN here h ON h.premise_id = cur.premise_id
ORDER BY pv_here LIMIT 20
```
