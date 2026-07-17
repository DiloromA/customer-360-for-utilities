# Complaints Predictor — Scoping

Status: **Phases A+B shipped 2026-07-07** (features MV + all 5 heads +
scores table, deployed and run green end-to-end against
`timstanton_stable.customer_360`). **Phase C re-scoped at the user's
direction (2026-07-07): the scores surface in the EXPLORER, not a CSAT
view** (CSAT stays a nav placeholder for now) — shipped as (1) a
"Complaint risk (predicted)" map lens (`exec_map_cells.sql` +
`geniePlugin.ts` points path aggregate/join `ml_complaint_risk_scores`;
one `LAYERS` entry in `mapConstants.ts`), (2) a risk chip + tooltip tag
on the customer dots/drill panel, and (3) a "High/Elevated complaint
risk (predicted)" alert with drivers + playbook in the full profile
drawer (`customer_header.sql` + `AlertsBanner`). The original Phase C
ideas (CSAT view risk panel, per-team outreach list export) remain
future work behind the CSAT placeholder. This doc defines the second
model in the `40_ml` tier: a
per-customer complaint-risk score, split by complaint category so each
business function can run targeted outreach from its own slice (billing
team calls bill-shock customers, outage comms follows up restoration
delays, collections offers payment plans).

Implementation notes (2026-07-07):

- Lives at `src/40_ml/complaint_predictor/`, wired into the
  `ml_features` pipeline + three chained job tasks exactly per §5.
- §7's "one UC model vs five" question resolved: **one pyfunc model**
  (`ml_complaint_predictor@champion`) wrapping the five boosters;
  `predict()` returns all five `p_*` columns in one call, which kept
  `score.py` simplest. Metrics land in one MLflow run, prefixed per head
  (`any_test_auc`, …), with per-head calibration + feature-importance
  JSON artifacts.
- Held-out (post `2018-06-30`) results: `any` AUC 0.807 / capture@5%
  33% (6.6× lift); `billing` AUC 0.996; `outage` AUC 0.970 / capture@5%
  69.5%; `payment` AUC 0.920; `service` AUC 0.733 — the residual head is
  weak as §7 predicted, keep an eye on whether it earns its UI slot.
- Scoring is as-of each customer's **latest** cycle (Dec 2018), where
  **no one crosses the 30% bill-shock threshold** (max 26.5%; July has
  125 customers over 30%) — so `p_billing` ≈ 0 across the board and
  `top_category` is mostly outage/payment/service. That's the model
  being right (bill shock is seasonal), and it's a good demo beat, but
  don't mistake it for a broken billing head.
- The high tier skews multi-site commercial (balances summed across
  accounts) — §7's residential-filter question for the CSAT view is
  still open and now demonstrably matters.
- Gotcha for future scorers: MLflow pyfunc enforces the model signature
  (all-double, all-required) *before* the wrapper's own alignment runs,
  and `pd.get_dummies` emits int64/bool — `score.py` must reindex to
  the signature's columns and cast float64 before `predict()`.

It follows the `ev_detector` mold exactly: a `features.sql` materialized
view inside the SDP pipeline, plus `train.py` / `score.py` /
`table_comments.py` notebooks chained in the training job.

---

## 1. Problem statement

For every active customer, predict the probability that they file a
complaint **in the next 30 days**, overall and by category, and attach
the top contributing drivers so the score is actionable, not just a
ranking.

Target consumers in the app:

- **CSAT view** (new nav item, Overview group): complaint-risk
  distribution, top-risk cohorts by category, trend vs. actual complaint
  volume.
- **Customer Service view**: per-customer risk + drivers on the CSR
  profile ("this customer is 12× baseline for a billing complaint —
  their last bill was +62% vs. trailing average").
- **Revenue & Collections view**: the `payment` slice doubles as a
  payment-plan / LIHEAP outreach list (joins
  `fact_assistance_enrollment` to exclude already-enrolled).

## 2. What the synthetic data guarantees (and what scoring mechanically needs)

`raw_customer_complaint_event` generates complaints from a known causal
model — monthly propensity = archetype base rate (0.3%–4.0%) ×
bill-shock multiplier (up to 5×) × outage multiplier (up to 5×) ×
arrears multiplier (1.8× over $300). Category is deterministic from the
dominant driver. That's by design: the generator was built precisely so
this model has a real signal to find. Two consequences:

1. **A well-featured model will look great — that's the point.** The
   signal was deliberately planted in the observable data (bills,
   outages, balances), and recovering it *is* the demo. Sanity check
   after training: feature importances dominated by bill-shock, outage
   minutes, and previous balance — if they aren't, the features are
   wrong, not the data. It's fine (encouraged, even) to reuse the
   generator's own recipes when building features — the trailing-12
   bill-shock window, the 30-day outage lookback, the $300 arrears
   threshold — since we own the generator and those are also the
   thresholds a real utility CX team would reach for.
2. **Feature-sourcing constraints are mechanics, not purity.**
   - `fact_customer_complaints` carries the generator's
     diagnostic fields (`bill_shock_pct`, `outages_count_30d`, …), but
     only *on complaint rows* — they don't exist for the ~99% of
     customer-months with no complaint, which are exactly the rows the
     scorer has to score. So features get recomputed from
     `fact_customer_billing` /
     `fact_outage_customer_impact` for every customer as-of the
     observation date; the complaint fact contributes *history* features
     only (prior counts, recency, categories).
   - `dim_customer` doesn't expose the latent `archetype` (a
     separate, earlier persona-layer decision), so the model recovers
     archetype-like risk from behavior instead — which happens to make
     the better demo story anyway. If it's ever useful to show "the
     model rediscovered the planted structure," joining archetype from
     raw for *evaluation/stratification* is fair game.

## 3. Modeling design

### Grain and label

**Customer × billing cycle** (one row per customer per bill, as-of
`bill_period_end`), not one row per customer. The generator rolls the
dice per bill, this grain matches it, and it turns ~2 years of history
into a large training set with natural time-based splits.

- Label window: complaint filed in the **30 days after** the as-of date
  (mirrors the generator: complaints land 2–27 days after period end).
- Labels: `label_any` plus one label per category group (below).
- Split: **time-based** — train on 2017 through ~2018-06, evaluate on
  the remaining months. No random splits; billing/outage conditions are
  strongly autocorrelated within a customer.

### Category groups (4 heads)

The 6 raw categories collapse to 4 scoring targets with distinct
outreach playbooks:

| Head | Raw categories | Dominant driver | Outreach playbook |
|---|---|---|---|
| `billing` | billing | bill shock > 30% | Proactive high-bill alert, rate review, EE audit offer |
| `outage` | outage | ≥240 min or ≥3 outages/30d | Restoration follow-up, reliability credit, critical-care check |
| `payment` | billing_process | previous balance > $300 | Payment plan, LIHEAP/assistance enrollment |
| `service` | customer_service, service_quality, program | residual/random | CSR callback queue, channel-preference fix |

### Architecture: one-vs-rest binaries, not multiclass

**Five XGBoost binary classifiers** (`any` + the 4 heads), same
hyperparameter recipe as `ev_detector/train.py` including the
`sqrt(imbalance_ratio)` `scale_pos_weight` — monthly complaint rates run
~0.3%–4%, so every head is heavily imbalanced.

Why not alternatives:

- *Multiclass with a "no complaint" class*: softmax forces the rare
  classes to compete; calibration on 0.1%-rate classes gets ugly, and a
  customer genuinely can be high-risk for both `billing` and `outage`
  simultaneously (independent heads express that; multiclass can't).
- *Two-stage P(complaint) × P(category | complaint)*: cleaner
  factorization but two models per category path and harder reason
  codes. Not worth it at demo scale; revisit if head count grows.

All five heads share one feature table and one training notebook (loop
over heads, one MLflow run each, registered as a single UC model
`ml_complaint_predictor` with the head as a signature column — or five
aliased models if that proves awkward; decide at implementation).

### Features (`ml_complaint_risk_features`)

One SDP materialized view, `src/40_ml/complaint_predictor/features.sql`,
computed per (customer_id, bill_period_end) exclusively from curated
tables:

- **Billing** (`fact_customer_billing`): current charges,
  trailing-12-month average (same window-function recipe as the
  generator, but from observable bills), bill-shock %, YoY same-month
  delta, rate schedule / budget-billing flags from
  `dim_rate_schedule` / `dim_service_agreement`.
- **Outage exposure** (`fact_outage_customer_impact`): count and
  total/max minutes in trailing 30d and 90d, days since last outage.
- **Arrears & payments** (`fact_payment_history` + billing
  `previous_balance`): balance carried, late-payment count 90d,
  days-late trend, assistance enrollment flag
  (`fact_assistance_enrollment`).
- **Contact & sentiment history**: prior complaints by category group
  (count 90d/365d, days since last) from
  `fact_customer_complaints`; CSR contact count and repeat-call
  flag from `fact_csr_interactions`; latest NPS/CSAT from
  `fact_survey_responses`; portal activity from
  `fact_digital_engagement` (low engagement + mail preference
  correlates with phone complaints).
- **Profile** (`dim_customer` / `dim_account`):
  customer_class, income_band, household_size, tenure,
  critical_care_flag, language_preference, preferred_channel (also the
  outreach-channel output), premise geography for cohort views.

Labels are appended in the same view (join complaints within
`(bill_period_end, bill_period_end + 30d]`), used by train only — same
"label lives in the feature table but scoring never reads it" contract
as `ml_ev_detection_features`.

### Scoring output (`ml_complaint_risk_scores`)

`score.py` scores the **latest** cycle per customer and writes one row
per customer:

```
customer_id, as_of_date,
p_complaint_30d,                       -- 'any' head
p_billing, p_outage, p_payment, p_service,
top_category,                          -- argmax of the 4 heads
risk_tier,                             -- high / elevated / baseline (calibrated cutoffs)
top_drivers,                           -- array<string>, top-3 reason codes
recommended_action,                    -- playbook keyed by top_category
outreach_channel                       -- from preferred_channel
```

Reason codes: start with a deterministic mapping from the customer's
own feature values crossing the known thresholds (bill_shock > 30% →
`"bill +X% vs 12-mo avg"`), which is honest here because the generator
is threshold-based; add SHAP later only if we want the generic story.

## 4. Evaluation

- **Per head**: AUC + average precision (PR matters far more than
  accuracy at these base rates), on the held-out time slice.
- **Calibration**: reliability curve per head — the app surfaces
  probabilities and tiers, so calibrated output matters more than rank.
- **The demo metric — lift**: "the top 5% of customers by
  `p_complaint_30d` capture N% of next month's actual complaints."
  That's the sentence a CX exec buys; compute it per category too, since
  targeted outreach is capacity-constrained per team.
- **Sanity vs. generator**: feature importance concentrated on
  bill-shock / outage-minutes / previous-balance features; per-category
  heads should each be dominated by their own driver family.

## 5. Wiring (mirrors ev_detector exactly)

1. `src/40_ml/complaint_predictor/` — `feature_spec.py`, `features.sql`,
   `train.py`, `score.py`, `table_comments.py`.
2. `resources/pipelines.yml` — add the explicit
   `../src/40_ml/complaint_predictor/features.sql` line (the 40_ml tier
   is deliberately not globbed).
3. `resources/jobs.yml` — three chained tasks
   (`complaint_predictor_train` → `_score` → `_table_comments`) after
   the pipeline task, parallel to the ev_detector chain.
4. UC artifacts: model `ml_complaint_predictor` (@champion), tables
   `ml_complaint_risk_features`, `ml_complaint_training_data`,
   `ml_complaint_risk_scores`.
5. App: grant the app service principal SELECT on the scores table
   (`app/scripts/grant-permissions.sh` — it does not inherit deployer
   grants), then surface in the CSAT placeholder view first.

## 6. Phasing

- **Phase A** — features MV + `any` head + scores table with
  `p_complaint_30d` and threshold-based reason codes. Proves the
  pipeline end-to-end.
- **Phase B** — the 4 category heads, `top_category`,
  `recommended_action`, calibration + lift report logged to MLflow.
- **Phase C** — app surfacing: CSAT view risk panel + CSR profile
  badge + per-team outreach list export (category filter × channel).

## 7. Open questions

- Commercial/industrial customers: the propensity generator runs on all
  archetypes, but outreach playbooks above are residential-flavored.
  Score everyone, but decide whether the CSAT view defaults to a
  residential filter (consistent with the Explorer's
  service-location-grain counting decisions).
- One UC model with a head parameter vs. five registered models — pick
  whichever keeps `score.py` simplest at implementation time.
- Whether `service` (the low-signal residual head) earns its keep in the
  UI, or collapses into `any` until there's a real driver for it.
