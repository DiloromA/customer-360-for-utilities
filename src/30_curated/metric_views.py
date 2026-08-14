# Databricks notebook source
# MAGIC %md
# MAGIC # Stage C — UC Metric Views
# MAGIC
# MAGIC Creates the governed metric views on top of the curated facts. These
# MAGIC are first-class Unity Catalog Metric Views (CREATE VIEW ... WITH
# MAGIC METRICS LANGUAGE YAML), distinct from SDP materialized views. Every
# MAGIC dimension and measure carries a `comment:` (propagates to the UC
# MAGIC column comment) and named-KPI measures carry `standard`/`kpi` column
# MAGIC tags (applied below, since CREATE OR REPLACE resets column metadata
# MAGIC on every run).

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
dbutils.widgets.text("as_of_date", "2018-12-31")
# "false" on a governed workspace whose UC tag policy rejects our tag values
#. When false, the metric views are still created with all
# column `comment:`s; only the `demo`/`standard`/`kpi` UC tags below are skipped.
dbutils.widgets.text("apply_data_asset_tags", "true")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")
_SAFE_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _check_id(value, label):
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


def _check_date(value, label):
    if not _SAFE_DATE.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")
as_of_date = _check_date(dbutils.widgets.get("as_of_date").strip(), "as_of_date")
APPLY_TAGS = dbutils.widgets.get("apply_data_asset_tags").strip().lower() == "true"

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")

print(f"Creating metric views in {catalog}.{schema}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Helper views
# MAGIC
# MAGIC `v_reliability_base` bakes the served-customer denominator (territory
# MAGIC and county customer counts, off the current-tenancy bridge) onto
# MAGIC the outage-impact fact as constant columns, so SAIDI/SAIFI can be
# MAGIC computed as `SUM(...) / MAX(...)` inside a metric view — which cannot
# MAGIC otherwise reach a second fact at query time. It tracks the current
# MAGIC customer base with zero refresh choreography (plain view, not
# MAGIC materialized).

# COMMAND ----------

print("\nCreating helper views...")

spark.sql(f"""
CREATE OR REPLACE VIEW `{catalog}`.`{schema}`.`v_reliability_base`
COMMENT 'Helper view for metric_reliability. fact_outage_customer_impact plus the served-customer denominators (territory_customer_count = current occupied premises, county_customer_count = current occupied premises per county) needed for SAIDI/SAIFI, which a metric view cannot compute directly since it cannot join a second fact at query time.'
AS
SELECT
  i.*,
  p.county,
  t.territory_customer_count,
  cc.county_customer_count
FROM `{catalog}`.`{schema}`.fact_outage_customer_impact i
LEFT JOIN `{catalog}`.`{schema}`.dim_premise p
  ON p.premise_id = i.premise_id
CROSS JOIN (
  SELECT COUNT(*) AS territory_customer_count
  FROM `{catalog}`.`{schema}`.bridge_account_premise
  WHERE is_current
) t
LEFT JOIN (
  SELECT p2.county, COUNT(*) AS county_customer_count
  FROM `{catalog}`.`{schema}`.bridge_account_premise b
  JOIN `{catalog}`.`{schema}`.dim_premise p2 ON p2.premise_id = b.premise_id
  WHERE b.is_current
  GROUP BY p2.county
) cc
  ON cc.county = p.county
""")
print("  ✓ v_reliability_base")

# COMMAND ----------

# All metric views use YAML v1.1 (DBR 17.2+ / serverless current channel).

METRIC_VIEWS: dict[str, str] = {
    # ────────────────────────────────────────────────────────────────
    "metric_usage": f"""
version: 1.1
source: {catalog}.{schema}.fact_meter_readings_monthly
comment: "Customer usage metrics. Monthly kWh, peer-group benchmarks (kWh/sqft via join to dim_premise), and DER component breakdown. Drives EE marketing segment targeting and the CSR view usage chart."
joins:
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
  - name: dim_premise
    source: {catalog}.{schema}.dim_premise
    on: source.premise_id = dim_premise.premise_id
dimensions:
  - name: Customer Class
    expr: dim_customer.customer_class
    comment: "Residential vs Commercial vs Industrial."
  - name: Building Subtype
    expr: dim_premise.building_subtype
    comment: "ResStock-aligned building type (e.g. Single-Family Detached, Multi-Family, SmallOffice)."
  - name: Sqft Band
    expr: dim_premise.sqft_band
    comment: "Premise square-footage band; the peer-group benchmark grouping."
  - name: Income Band
    expr: dim_customer.income_band
    comment: "Household income band (disclosed signal)."
  - name: Engagement Tier
    expr: dim_customer.engagement_tier
    comment: "Digital engagement tier: high | medium | low."
  - name: High User Flag
    expr: dim_customer.high_user_flag
    comment: "Customer flagged as a high energy user relative to peers."
  - name: Payment Stressed Flag
    expr: dim_customer.payment_stressed_flag
    comment: "Customer flagged as payment-stressed from trailing 12mo billing history."
  - name: County
    expr: dim_premise.county
    comment: "Service county."
  - name: Year
    expr: source.year
    comment: "Calendar year of the meter reading."
  - name: Month
    expr: source.month
    comment: "Calendar month (1-12) of the meter reading."
measures:
  - name: Customer Count
    expr: COUNT(DISTINCT source.customer_id)
    comment: "Distinct customers with a meter reading in the sliced period."
  - name: Total kWh Delivered
    expr: SUM(source.kwh_delivered)
    comment: "Sum of grid-delivered kWh (consumption)."
  - name: Total kWh Received
    expr: SUM(source.kwh_received)
    comment: "Sum of kWh received back to the grid (export, e.g. from PV)."
  - name: Avg Monthly kWh
    expr: AVG(source.kwh_delivered)
    comment: "Average monthly kWh delivered per reading."
  - name: Avg kWh per Sqft
    expr: SUM(source.kwh_delivered) / NULLIF(SUM(dim_premise.sqft), 0)
    comment: "Energy Use Intensity (EUI) — the ENERGY STAR / building-benchmarking convention for kWh delivered per square foot. Useful for peer comparisons."
  - name: Total kWh EV
    expr: SUM(source.kwh_ev)
    comment: "Sum of kWh attributable to EV charging load (DER component breakdown)."
  - name: Total kWh PV
    expr: SUM(source.kwh_pv)
    comment: "Sum of kWh attributable to on-site solar PV production/offset (DER component breakdown)."
  - name: Total kWh HP
    expr: SUM(source.kwh_hp)
    comment: "Sum of kWh attributable to heat-pump load (DER component breakdown)."
""",
    # ────────────────────────────────────────────────────────────────
    "metric_complaints": f"""
version: 1.1
source: {catalog}.{schema}.fact_customer_complaints
comment: "Complaint metrics. Counts, resolution rates, sentiment mix, and complaint drivers (bill shock vs outage vs service). Filterable by archetype-disclosed flags via dim_customer join."
joins:
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
dimensions:
  - name: Category
    expr: source.category
    comment: "Top-level complaint category (e.g. billing, outage, service)."
  - name: Sub Category
    expr: source.sub_category
    comment: "Complaint sub-category, one level of detail below Category."
  - name: Channel
    expr: source.channel
    comment: "Channel the complaint was filed through (phone, web, email, etc.)."
  - name: Severity
    expr: source.severity
    comment: "Complaint severity as logged at intake."
  - name: Sentiment
    expr: source.sentiment_label
    comment: "NLP-derived sentiment label of the complaint verbatim."
  - name: Resolution Status
    expr: source.resolution_status
    comment: "Current resolution status: open | resolved | escalated."
  - name: Verbatim Language
    expr: source.verbatim_language
    comment: "Language the complaint verbatim was written/spoken in."
  - name: Complaint Month
    expr: DATE_TRUNC('MONTH', source.complaint_date)
    comment: "Calendar month the complaint was filed."
  - name: Customer Class
    expr: dim_customer.customer_class
    comment: "Residential vs Commercial vs Industrial."
  - name: Engagement Tier
    expr: dim_customer.engagement_tier
    comment: "Digital engagement tier: high | medium | low."
  - name: Payment Stressed Flag
    expr: dim_customer.payment_stressed_flag
    comment: "Customer flagged as payment-stressed from trailing 12mo billing history."
  - name: High User Flag
    expr: dim_customer.high_user_flag
    comment: "Customer flagged as a high energy user relative to peers."
  - name: Language Preference
    expr: dim_customer.language_preference
    comment: "Customer's preferred language on file, for comparison against Verbatim Language."
measures:
  - name: Complaint Count
    expr: COUNT(1)
    comment: "Total complaints filed."
  - name: Distinct Customers Complaining
    expr: COUNT(DISTINCT source.customer_id)
    comment: "Distinct customers with at least one complaint in the sliced period."
  - name: Resolved Count
    expr: SUM(CASE WHEN source.resolution_status = 'resolved' THEN 1 ELSE 0 END)
    comment: "Complaints currently in resolved status."
  - name: Escalated Count
    expr: SUM(CASE WHEN source.resolution_status = 'escalated' THEN 1 ELSE 0 END)
    comment: "Complaints currently in escalated status."
  - name: Open Count
    expr: SUM(CASE WHEN source.resolution_status = 'open' THEN 1 ELSE 0 END)
    comment: "Complaints currently in open status."
  - name: Avg Resolution Minutes
    expr: AVG(source.resolution_minutes)
    comment: "Average minutes from complaint intake to resolution."
  - name: Resolution Rate
    expr: SUM(CASE WHEN source.resolution_status = 'resolved' THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Share of complaints resolved."
  - name: Very Negative Share
    expr: SUM(CASE WHEN source.sentiment_label = 'very_negative' THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Share of complaints with a very-negative sentiment label."
""",
    # ────────────────────────────────────────────────────────────────
    # IEEE 1366-2022 reliability measures with a real served-customer
    # denominator (v_reliability_base). County comes baked onto
    # v_reliability_base, which needs it for the county denominator anyway.
    "metric_reliability": f"""
version: 1.1
source: {catalog}.{schema}.v_reliability_base
comment: "Reliability metrics per IEEE 1366-2022. SAIDI/SAIFI/CAIDI are computed against the real served-customer population (v_reliability_base), not left as an unsliceable numerator. SAIDI/SAIFI are CONTRIBUTION measures: unsliced they equal system-wide SAIDI/SAIFI; sliced (by cause, weather, month, circuit) each row is that slice's contribution to the system total — the standard 'SAIDI by cause' decomposition. County SAIDI is the one measure meant to be re-sliced by a shrinking denominator, and is valid ONLY when grouped by County. ASAI (service availability) = 1 - SAIDI/525600 for an annual slice — a downstream calc, not modeled as a measure. MAIFI (momentary interruption frequency) is not modeled: the synthetic generator has no sub-5-minute interruption data."
joins:
  - name: outage
    source: {catalog}.{schema}.fact_outage_events
    on: source.outage_id = outage.outage_id
dimensions:
  - name: Circuit
    expr: source.circuit_id
    comment: "Distribution circuit identifier."
  - name: County
    expr: source.county
    comment: "Service county of the affected premise."
  - name: Cause Code
    expr: outage.cause_code
    comment: "Root cause of the outage event (e.g. weather, equipment failure, vegetation)."
  - name: Weather Category
    expr: outage.weather_category
    comment: "Weather condition at the time of the outage event."
  - name: Is Major Event Day
    expr: outage.is_major_event_day
    comment: "IEEE 1366 Major Event Day flag — excluded from the blue-sky (excl MED) variants below per the 2.5-beta method."
  - name: Duration Bucket
    expr: outage.duration_bucket
    comment: "Bucketed outage duration (event-level, from fact_outage_events)."
  - name: Outage Month
    expr: DATE_TRUNC('MONTH', source.affected_start)
    comment: "Calendar month the customer impact began."
  - name: Priority Restoration
    expr: source.priority_restoration_flag
    comment: "Customer flagged for priority restoration (e.g. critical care, medical baseline)."
measures:
  - name: Customer Interruptions (CI)
    expr: COUNT(1)
    comment: "IEEE 1366 CI — count of sustained customer interruptions (impact rows)."
  - name: Customer Minutes Interrupted (CMI)
    expr: SUM(source.minutes_out)
    comment: "IEEE 1366 CMI — total customer-minutes of sustained interruption."
  - name: SAIDI
    expr: SUM(source.minutes_out) / MAX(source.territory_customer_count)
    comment: "System Average Interruption Duration Index (IEEE 1366). Unsliced = system SAIDI (minutes per served customer); sliced = that slice's contribution to system SAIDI."
  - name: SAIDI (excl MED)
    expr: SUM(source.minutes_out) FILTER (WHERE NOT outage.is_major_event_day) / MAX(source.territory_customer_count)
    comment: "SAIDI excluding IEEE 1366 Major Event Days — the 2.5-beta 'blue-sky' reporting variant."
  - name: SAIFI
    expr: COUNT(1) / MAX(source.territory_customer_count)
    comment: "System Average Interruption Frequency Index (IEEE 1366). Unsliced = system SAIFI (interruptions per served customer); sliced = contribution to system SAIFI."
  - name: SAIFI (excl MED)
    expr: COUNT(1) FILTER (WHERE NOT outage.is_major_event_day) / MAX(source.territory_customer_count)
    comment: "SAIFI excluding IEEE 1366 Major Event Days."
  - name: CAIDI (Avg Restoration Minutes)
    expr: AVG(source.minutes_out)
    comment: "Customer Average Interruption Duration Index (IEEE 1366) = SAIDI/SAIFI by construction — the average restoration time per interruption."
  - name: County SAIDI
    expr: SUM(source.minutes_out) / MAX(source.county_customer_count)
    comment: "SAIDI using the per-county served-customer count as denominator. VALID ONLY when grouped by County — an unsliced or non-county grouping produces a meaningless number."
  - name: Distinct Outages
    expr: COUNT(DISTINCT source.outage_id)
    comment: "Distinct outage events contributing to the sliced impact rows."
  - name: Distinct Customers Affected
    expr: COUNT(DISTINCT source.customer_id)
    comment: "Distinct customers with at least one sustained interruption in the sliced period."
""",
    # ────────────────────────────────────────────────────────────────
    "metric_nps": f"""
version: 1.1
source: {catalog}.{schema}.fact_survey_responses
comment: "NPS metrics. Promoter / passive / detractor counts and the computed NPS score. Filterable by source_system (Qualtrics NPS vs CSAT vs SQM) and customer attrs."
joins:
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
dimensions:
  - name: Source System
    expr: source.source_system
    comment: "Survey platform of record (e.g. Qualtrics NPS, CSAT, SQM)."
  - name: Survey Type
    expr: source.survey_type
    comment: "Survey instrument type."
  - name: NPS Bucket
    expr: source.nps_bucket
    comment: "Respondent bucket: promoter | passive | detractor."
  - name: Response Month
    expr: DATE_TRUNC('MONTH', source.response_date)
    comment: "Calendar month the survey was completed."
  - name: Customer Class
    expr: dim_customer.customer_class
    comment: "Residential vs Commercial vs Industrial."
  - name: Engagement Tier
    expr: dim_customer.engagement_tier
    comment: "Digital engagement tier: high | medium | low."
  - name: Payment Stressed Flag
    expr: dim_customer.payment_stressed_flag
    comment: "Customer flagged as payment-stressed from trailing 12mo billing history."
  - name: Churn Risk Band
    expr: dim_customer.churn_risk_band
    comment: "Modeled churn risk: high | medium | low."
measures:
  - name: Response Count
    expr: COUNT(1)
    comment: "Total survey responses."
  - name: Promoter Count
    expr: SUM(CASE WHEN source.nps_bucket = 'promoter' THEN 1 ELSE 0 END)
    comment: "Respondents scoring 9-10 (promoters)."
  - name: Detractor Count
    expr: SUM(CASE WHEN source.nps_bucket = 'detractor' THEN 1 ELSE 0 END)
    comment: "Respondents scoring 0-6 (detractors)."
  - name: Passive Count
    expr: SUM(CASE WHEN source.nps_bucket = 'passive' THEN 1 ELSE 0 END)
    comment: "Respondents scoring 7-8 (passives)."
  - name: NPS Score
    expr: 100.0 * (SUM(CASE WHEN source.nps_bucket = 'promoter' THEN 1 ELSE 0 END)
                  - SUM(CASE WHEN source.nps_bucket = 'detractor' THEN 1 ELSE 0 END))
          / NULLIF(COUNT(1), 0)
    comment: "Standard Bain/Satmetrix NPS formula: 100 * (promoters - detractors) / total responses."
  - name: Avg Score
    expr: AVG(source.score_0_10)
    comment: "Average 0-10 recommend-likelihood score."
""",
    # ────────────────────────────────────────────────────────────────
    # County and Account Tenure Band are included so csat_by_segment.sql
    # can read them from this view. County can't be a nested/snowflake
    # join (dim_account -> dim_premise): the metric-view join resolver
    # only lets a join's `on` reference `source`, not another join's
    # alias, whether declared nested or as two sibling joins — so it's a
    # MAX()-wrapped correlated scalar subquery instead
    # (dim_premise.premise_id is a PK, so MAX() over the single matching
    # row is exact, not an approximation).
    "metric_csat": f"""
version: 1.1
source: {catalog}.{schema}.fact_csr_interactions
comment: "Contact-center CSAT metrics. csat_score_1_5 is populated on every interaction (not just the ~10% independently surveyed via fact_survey_responses), so this is the complete, unsampled CSAT series — the headline for the CSAT / Service & Experience view. Top-2-box = score of 4 or 5."
joins:
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
  - name: dim_account
    source: {catalog}.{schema}.dim_account
    on: source.account_id = dim_account.account_id
dimensions:
  - name: Media Type
    expr: source.media_type
    comment: "Interaction media: phone | chat | email."
  - name: Queue
    expr: source.queue
    comment: "Contact-center queue the interaction was routed to."
  - name: Disposition Code
    expr: source.disposition_code
    comment: "Agent-logged outcome code for the interaction."
  - name: Interaction Month
    expr: DATE_TRUNC('MONTH', source.started_at)
    comment: "Calendar month the interaction started."
  - name: Customer Class
    expr: dim_customer.customer_class
    comment: "Residential vs Commercial vs Industrial."
  - name: Rate Category
    expr: dim_account.rate_category
    comment: "Residential vs Commercial rate category (dim_account.rate_category)."
  - name: County
    expr: (SELECT MAX(p.county) FROM {catalog}.{schema}.account_current_premise acp JOIN {catalog}.{schema}.dim_premise p ON p.premise_id = acp.premise_id WHERE acp.account_id = dim_account.account_id)
    comment: "Service county of the account's current premise (via account_current_premise seam)."
  - name: Account Tenure Band
    expr: dim_account.account_tenure_band
    comment: "Account age band as of {as_of_date}: new_<1yr | 1-3yr | 3-10yr | 10+yr."
measures:
  - name: Response Count
    expr: COUNT(1)
    comment: "Total interactions with a CSAT score."
  - name: Avg CSAT 1-5
    expr: AVG(source.csat_score_1_5)
    comment: "Average CSAT score on a 1-5 scale."
  - name: Top2Box Count
    expr: SUM(CASE WHEN source.csat_score_1_5 >= 4 THEN 1 ELSE 0 END)
    comment: "Interactions scoring 4 or 5 of 5."
  - name: Top2Box Rate
    expr: SUM(CASE WHEN source.csat_score_1_5 >= 4 THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Headline CSAT metric: share of interactions scoring 4 or 5 of 5 (Top-2-Box, the ACSI / J.D. Power convention)."
""",
    # ────────────────────────────────────────────────────────────────
    "metric_fcr": f"""
version: 1.1
source: {catalog}.{schema}.fact_csr_interactions
comment: "First Call Resolution metrics. Genesys interaction outcomes joined with agent + customer context. The headline KPI for the CCO scorecard."
joins:
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
  - name: dim_agent
    source: {catalog}.{schema}.dim_agent
    on: source.agent_id = dim_agent.agent_id
dimensions:
  - name: Queue
    expr: source.queue
    comment: "Contact-center queue the interaction was routed to."
  - name: Media Type
    expr: source.media_type
    comment: "Interaction media: phone | chat | email."
  - name: Disposition Code
    expr: source.disposition_code
    comment: "Agent-logged outcome code for the interaction."
  - name: Interaction Source
    expr: source.interaction_source
    comment: "Originating system for the interaction record."
  - name: Interaction Month
    expr: DATE_TRUNC('MONTH', source.started_at)
    comment: "Calendar month the interaction started."
  - name: Agent
    expr: source.agent_id
    comment: "Handling agent's natural key."
  - name: Team
    expr: dim_agent.team_id
    comment: "Handling agent's team."
  - name: Customer Class
    expr: dim_customer.customer_class
    comment: "Residential vs Commercial vs Industrial."
measures:
  - name: Interaction Count
    expr: COUNT(1)
    comment: "Total contact-center interactions."
  - name: FCR Count
    expr: SUM(CASE WHEN source.first_call_resolution_flag THEN 1 ELSE 0 END)
    comment: "Interactions resolved on first contact (no transfer, resolved disposition)."
  - name: FCR Rate
    expr: SUM(CASE WHEN source.first_call_resolution_flag THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "First Call Resolution rate — the contact-center convention benchmark (~70-85% for utilities)."
  - name: Avg Handle Time Seconds
    expr: AVG(source.handle_time_seconds)
    comment: "Average Handle Time (AHT), seconds — the standard contact-center throughput measure."
  - name: Avg Wait Time Seconds
    expr: AVG(source.wait_time_seconds)
    comment: "Average time a customer waited before being handled."
  - name: Abandon Rate
    expr: SUM(CASE WHEN source.abandoned_flag THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Share of interactions abandoned before being handled."
  - name: Avg CSAT
    expr: AVG(source.csat_score_1_5)
    comment: "Average CSAT score (1-5) on FCR-scoped interactions."
""",
    # ────────────────────────────────────────────────────────────────
    "metric_dsm_uptake": f"""
version: 1.1
source: {catalog}.{schema}.fact_program_enrollment
comment: "DSM/EE program uptake metrics. Enrollment counts, completion rates, rebates paid, and kWh savings realized. Drives the EE marketing portfolio view and CCO EE penetration tile. GRAIN: fact_program_enrollment is one row per (customer, program, premise) — every program is a physical install/service, so the per-record measures (Enrollment Count, Total Rebates Paid, kWh saved) count actual installs; a multi-site customer contributes one per site. EM&V participation rate (enrolled / eligible) is a cross-metric-view calculation: divide either Distinct Premises Enrolled by metric_customer_base's Service Locations Served (premise-over-premise, matching grains) or Distinct Customers Enrolled by its customer count — the eligible denominator lives on the customer base, not the enrollment fact."
joins:
  - name: dim_program
    source: {catalog}.{schema}.dim_program
    on: source.program_id = dim_program.program_id
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
dimensions:
  - name: Program ID
    expr: source.program_id
    comment: "Program natural key."
  - name: Program Name
    expr: dim_program.program_name
    comment: "Program display name."
  - name: Program Type
    expr: dim_program.program_type
    comment: "DSM/EE program category (e.g. rebate, time-of-use, weatherization)."
  - name: Customer Segment
    expr: dim_program.customer_segment
    comment: "Program's target customer segment."
  - name: Enrollment Status
    expr: source.enrollment_status
    comment: "Current enrollment status: enrolled | completed | cancelled, etc."
  - name: Enrollment Month
    expr: DATE_TRUNC('MONTH', source.enrollment_date)
    comment: "Calendar month of enrollment."
  - name: Customer Class
    expr: dim_customer.customer_class
    comment: "Residential vs Commercial vs Industrial."
  - name: Engagement Tier
    expr: dim_customer.engagement_tier
    comment: "Digital engagement tier: high | medium | low."
  - name: Income Band
    expr: dim_customer.income_band
    comment: "Household income band (disclosed signal)."
measures:
  - name: Enrollment Count
    expr: COUNT(1)
    comment: "Total enrollment records."
  - name: Distinct Customers Enrolled
    expr: COUNT(DISTINCT source.customer_id)
    comment: "Distinct customers enrolled — the customer-grain numerator of EM&V participation rate."
  - name: Distinct Premises Enrolled
    expr: COUNT(DISTINCT source.premise_id)
    comment: "Distinct premises enrolled — the premise-grain numerator of EM&V participation rate (matches metric_customer_base's Service Locations Served denominator)."
  - name: Active Count
    expr: SUM(CASE WHEN source.enrollment_status = 'active' THEN 1 ELSE 0 END)
    comment: "Enrollments currently in active status."
  - name: Completion Count
    expr: SUM(CASE WHEN source.enrollment_status = 'completed' THEN 1 ELSE 0 END)
    comment: "Enrollments that reached completed status."
  - name: Dropped Count
    expr: SUM(CASE WHEN source.enrollment_status = 'dropped' THEN 1 ELSE 0 END)
    comment: "Enrollments that were dropped/cancelled before completion."
  - name: Completion Rate
    expr: SUM(CASE WHEN source.enrollment_status = 'completed' THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Share of enrollments that reached completed status — the EM&V completion-rate KPI."
  - name: Total Rebates Paid
    expr: SUM(source.rebate_paid_usd)
    comment: "Total program rebates paid, USD."
  - name: Total kWh Saved Estimate
    expr: SUM(source.kwh_saved_estimate)
    comment: "Program-estimated (claimed) kWh savings — NOT an EM&V-verified realization rate; no measured-savings data is modeled, so realization rate (measured / claimed) cannot be computed."
""",
    # ────────────────────────────────────────────────────────────────
    # New. Replaces metric_tenure_at_premise — the actual asset is the full
    # temporal relationship web (bridge + customer + premise attrs), not
    # bare bridge math with no slicing dimensions.
    "metric_relationships": f"""
version: 1.1
source: {catalog}.{schema}.bridge_account_premise
comment: "Customer<->account<->premise relationship lifecycle metrics off the effective-dated tenancy bridge: move-ins, move-outs (turnover), tenure, and current tenancy, sliceable by geography, building type, and customer class. Tenure = days link_start_date -> link_end_date (open links measured to the {as_of_date} as-of date). Rate-switch history lives in dim_service_agreement (not modeled here)."
joins:
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
  - name: dim_premise
    source: {catalog}.{schema}.dim_premise
    on: source.premise_id = dim_premise.premise_id
dimensions:
  - name: Tenancy Type
    expr: source.tenancy_type
    comment: "How the account occupies the premise (e.g. owner, tenant)."
  - name: Link Status
    expr: source.link_status
    comment: "Current status of the tenancy link."
  - name: Is Current
    expr: source.is_current
    comment: "True for the live tenancy link; false for a closed prior-customer link."
  - name: Move In Year
    expr: YEAR(source.link_start_date)
    comment: "Calendar year the tenancy link began."
  - name: Move Out Year
    expr: YEAR(source.link_end_date)
    comment: "Calendar year the tenancy link ended (NULL for open/current links)."
  - name: Termination Reason
    expr: source.link_termination_reason
    comment: "Why the tenancy link ended, when it has."
  - name: County
    expr: dim_premise.county
    comment: "Service county of the premise."
  - name: Building Subtype
    expr: dim_premise.building_subtype
    comment: "ResStock-aligned building type."
  - name: Customer Class
    expr: dim_customer.customer_class
    comment: "Residential vs Commercial vs Industrial."
measures:
  - name: Relationship Count
    expr: COUNT(1)
    comment: "Total tenancy-link rows (both current and historical)."
  - name: Distinct Customers
    expr: COUNT(DISTINCT source.customer_id)
    comment: "Distinct customers appearing in the sliced links."
  - name: Distinct Premises
    expr: COUNT(DISTINCT source.premise_id)
    comment: "Distinct premises appearing in the sliced links."
  - name: Distinct Accounts
    expr: COUNT(DISTINCT source.account_id)
    comment: "Distinct billing accounts appearing in the sliced links."
  - name: Move Outs (Turnover)
    expr: SUM(CASE WHEN source.link_end_date IS NOT NULL THEN 1 ELSE 0 END)
    comment: "Ended links — move-outs / tenant turnover."
  - name: Turnover Rate
    expr: SUM(CASE WHEN source.link_end_date IS NOT NULL THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Share of tenancy links that have ended (turned over)."
  - name: Current Customer Count
    expr: SUM(CASE WHEN source.is_current THEN 1 ELSE 0 END)
    comment: "Links representing the live, current customer."
  - name: Avg Tenure Days
    expr: AVG(DATEDIFF(COALESCE(source.link_end_date, DATE'{as_of_date}'), source.link_start_date))
    comment: "Average tenancy tenure in days; open links measured to the {as_of_date} as-of date."
  - name: Median Tenure Days
    expr: MEDIAN(DATEDIFF(COALESCE(source.link_end_date, DATE'{as_of_date}'), source.link_start_date))
    comment: "Median tenancy tenure in days — robust to the long tail of very-long-tenure links that skews the average."
""",
    # ────────────────────────────────────────────────────────────────
    # New. The keystone denominator view: every "% of customers" KPI in the
    # app (payment-stressed rate, EM&V participation rate, complaints per
    # 1k) needs this current-customer-base grain and nothing else exposes
    # it as a metric view.
    "metric_customer_base": f"""
version: 1.1
source: {catalog}.{schema}.bridge_account_premise
filter: source.is_current
comment: "The CURRENT customer base at service-location grain (one row per occupied premise — matches the exec map counting grain, NOT distinct customers; a multi-site customer has one row per site). Denominators for penetration/percentage KPIs (payment-stressed rate, EM&V participation rate, complaints per 1k) live here."
joins:
  - name: dim_customer
    source: {catalog}.{schema}.dim_customer
    on: source.customer_id = dim_customer.customer_id
  - name: dim_premise
    source: {catalog}.{schema}.dim_premise
    on: source.premise_id = dim_premise.premise_id
dimensions:
  - name: Customer Class
    expr: dim_customer.customer_class
    comment: "Residential vs Commercial vs Industrial."
  - name: County
    expr: dim_premise.county
    comment: "Service county of the premise."
  - name: Usage Band
    expr: dim_customer.usage_band
    comment: "Trailing-12mo usage band relative to peers: high | medium | low."
  - name: Engagement Tier
    expr: dim_customer.engagement_tier
    comment: "Digital engagement tier: high | medium | low."
  - name: Income Band
    expr: dim_customer.income_band
    comment: "Household income band (disclosed signal)."
  - name: Churn Risk Band
    expr: dim_customer.churn_risk_band
    comment: "Modeled churn risk: high | medium | low."
  - name: Building Subtype
    expr: dim_premise.building_subtype
    comment: "ResStock-aligned building type."
  - name: Payment Stressed Flag
    expr: dim_customer.payment_stressed_flag
    comment: "Customer flagged as payment-stressed from trailing 12mo billing history."
  - name: Critical Care Flag
    expr: dim_customer.critical_care_flag
    comment: "Customer registered for critical-care / priority-restoration status."
  - name: LIHEAP Eligible
    expr: dim_customer.liheap_eligible
    comment: "Customer eligible for the Low Income Home Energy Assistance Program."
  - name: High User Flag
    expr: dim_customer.high_user_flag
    comment: "Customer flagged as a high energy user relative to peers."
measures:
  - name: Service Locations Served
    expr: COUNT(1)
    comment: "Current customer base at service-location grain — one row per occupied premise. The exec map counting convention."
  - name: Distinct Customers
    expr: COUNT(DISTINCT source.customer_id)
    comment: "Current customer base at entity grain — multi-site customers collapse to one. Differs from Service Locations Served when a customer occupies multiple premises."
  - name: Payment Stressed Count
    expr: SUM(CASE WHEN dim_customer.payment_stressed_flag THEN 1 ELSE 0 END)
    comment: "Service locations with a payment-stressed customer."
  - name: Payment Stressed Rate
    expr: SUM(CASE WHEN dim_customer.payment_stressed_flag THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Share of the current customer base flagged payment-stressed."
  - name: Churn High Count
    expr: SUM(CASE WHEN dim_customer.churn_risk_band = 'high' THEN 1 ELSE 0 END)
    comment: "Service locations with a high modeled churn-risk customer."
  - name: Churn High Rate
    expr: SUM(CASE WHEN dim_customer.churn_risk_band = 'high' THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Share of the current customer base flagged high churn risk."
  - name: Critical Care Count
    expr: SUM(CASE WHEN dim_customer.critical_care_flag THEN 1 ELSE 0 END)
    comment: "Service locations with a critical-care registered customer."
  - name: LIHEAP Eligible Count
    expr: SUM(CASE WHEN dim_customer.liheap_eligible THEN 1 ELSE 0 END)
    comment: "Service locations with a LIHEAP-eligible customer."
  - name: High Engagement Rate
    expr: SUM(CASE WHEN dim_customer.engagement_tier = 'high' THEN 1.0 ELSE 0.0 END) / NULLIF(COUNT(1), 0)
    comment: "Share of the current customer base in the high digital-engagement tier."
  - name: Avg Digital Adoption
    expr: AVG(dim_customer.digital_adoption_score)
    comment: "Average digital-adoption score (0-100) across the current customer base."
  - name: Total Outage Minutes (90d)
    expr: SUM(dim_customer.recent_outage_minutes_90d)
    comment: "Sum of each customer's trailing-90-day outage-minute exposure."
  - name: Total Complaints (90d)
    expr: SUM(dim_customer.recent_complaint_count_90d)
    comment: "Sum of each customer's trailing-90-day complaint count."
""",
}

# COMMAND ----------

# Create each metric view.
results: dict[str, str] = {}
for view_name, yaml_body in METRIC_VIEWS.items():
    full_name = f"`{catalog}`.`{schema}`.`{view_name}`"
    try:
        spark.sql(
            f"CREATE OR REPLACE VIEW {full_name}\n"
            f"WITH METRICS\n"
            f"LANGUAGE YAML\n"
            f"AS $${yaml_body}$$"
        )
        results[view_name] = "ok"
        print(f"  ✓ {view_name}")
    except Exception as e:
        results[view_name] = str(e)
        print(f"  ✗ {view_name}: {e}")

ok = sum(1 for v in results.values() if v == "ok")
print(f"\nMetric views created: {ok} / {len(METRIC_VIEWS)}")

failures = {k: v for k, v in results.items() if v != "ok"}
if failures:
    raise RuntimeError(
        f"{len(failures)} metric view(s) failed to (re)create, leaving a stale "
        f"prior version live in UC: {failures}"
    )

# COMMAND ----------

# MAGIC %md
# MAGIC ## UC tags
# MAGIC
# MAGIC Object-level `demo` tag on every view/helper view. Column-level
# MAGIC `standard`/`kpi` tags on measures that map to a named industry KPI —
# MAGIC must be `ALTER TABLE ... ALTER COLUMN ... SET TAGS` (a metric view is
# MAGIC a VIEW object, but `ALTER VIEW` does not accept column clauses).
# MAGIC Column tags are reset by `CREATE OR REPLACE`, so this reapplies on
# MAGIC every pipeline run.

# COMMAND ----------

# Views to apply the demo tag to (metric views + helper views).
ALL_VIEWS = list(METRIC_VIEWS.keys()) + ["v_reliability_base"]

# View-level tags beyond `demo`, e.g. naming the governing standard.
VIEW_TAGS: dict[str, dict[str, str]] = {
    "metric_reliability": {"standard": "IEEE 1366-2022"},
}

# Column-level tags: view -> column -> {tag: value}. Only measures that map
# to a named, external industry KPI get tagged; every dimension/measure gets
# a `comment:` above regardless.
COLUMN_TAGS: dict[str, dict[str, dict[str, str]]] = {
    "metric_usage": {
        "Avg kWh per Sqft": {"standard": "ENERGY STAR EUI", "kpi": "EUI"},
    },
    "metric_reliability": {
        "Customer Interruptions (CI)": {"standard": "IEEE 1366-2022", "kpi": "CI"},
        "Customer Minutes Interrupted (CMI)": {"standard": "IEEE 1366-2022", "kpi": "CMI"},
        "SAIDI": {"standard": "IEEE 1366-2022", "kpi": "SAIDI"},
        "SAIDI (excl MED)": {"standard": "IEEE 1366-2022", "kpi": "SAIDI"},
        "SAIFI": {"standard": "IEEE 1366-2022", "kpi": "SAIFI"},
        "SAIFI (excl MED)": {"standard": "IEEE 1366-2022", "kpi": "SAIFI"},
        "CAIDI (Avg Restoration Minutes)": {"standard": "IEEE 1366-2022", "kpi": "CAIDI"},
        "County SAIDI": {"standard": "IEEE 1366-2022", "kpi": "SAIDI"},
    },
    "metric_nps": {
        "NPS Score": {"standard": "NPS (Bain)", "kpi": "NPS"},
    },
    "metric_csat": {
        "Top2Box Rate": {"standard": "ACSI / J.D. Power benchmark", "kpi": "CSAT-T2B"},
        "Avg CSAT 1-5": {"standard": "ACSI / J.D. Power benchmark", "kpi": "CSAT"},
    },
    "metric_fcr": {
        "FCR Rate": {"standard": "contact-center convention", "kpi": "FCR"},
        "Avg Handle Time Seconds": {"standard": "contact-center convention", "kpi": "AHT"},
        "Abandon Rate": {"standard": "contact-center convention", "kpi": "ABN"},
    },
    "metric_dsm_uptake": {
        "Completion Rate": {"standard": "EM&V (DOE/ACEEE)", "kpi": "COMPLETION"},
    },
}

if not APPLY_TAGS:
    print(
        "\napply_data_asset_tags=false — skipping metric-view object + column "
        "UC tags (governed workspace tag policy). All column comments already applied."
    )
else:
    print("\nApplying UC tags to metric views...")
    for view_name in ALL_VIEWS:
        full_name = f"`{catalog}`.`{schema}`.`{view_name}`"
        try:
            spark.sql(f"ALTER VIEW {full_name} UNSET TAGS ('managed_by', 'area', 'dir_name')")
            tags = {"demo": "customer-360-for-utilities", **VIEW_TAGS.get(view_name, {})}
            tag_clause = ", ".join(f"'{k}' = '{v}'" for k, v in tags.items())
            spark.sql(f"ALTER VIEW {full_name} SET TAGS ({tag_clause})")
            print(f"  ✓ {view_name} (object tags)")
        except Exception as e:
            print(f"  ✗ {view_name} (object tags): {e}")

    print("\nApplying UC column tags to named-KPI measures...")
    for view_name, columns in COLUMN_TAGS.items():
        full_name = f"`{catalog}`.`{schema}`.`{view_name}`"
        for column_name, tags in columns.items():
            tag_clause = ", ".join(f"'{k}' = '{v}'" for k, v in tags.items())
            try:
                spark.sql(
                    f"ALTER TABLE {full_name} ALTER COLUMN `{column_name}` SET TAGS ({tag_clause})"
                )
                print(f"  ✓ {view_name}.`{column_name}`")
            except Exception as e:
                print(f"  ✗ {view_name}.`{column_name}`: {e}")
