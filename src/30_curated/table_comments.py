# Databricks notebook source
# MAGIC %md
# MAGIC # Column Comments & UC Tags — customer_360
# MAGIC
# MAGIC Applies the **UC tag** (`demo = customer-360-for-utilities`) to every curated
# MAGIC table, and **column-level COMMENTs** from the `COLUMN_COMMENTS` dict below.
# MAGIC
# MAGIC TABLE-level comments are owned by the SDP DDL (`src/*.sql`) — this notebook
# MAGIC deliberately does **not** issue `COMMENT ON TABLE`.

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "customer_360")
# "false" on a governed workspace whose UC tag policy rejects our tag values
#. When false, this notebook still
# applies COLUMN COMMENTs but skips the `demo` UC tag. Kept in sync with the
# databricks.yml data_asset_tags var (asserted in check-release-config.py).
dbutils.widgets.text("apply_data_asset_tags", "true")

import re

_SAFE_ID = re.compile(r"^[a-zA-Z0-9_-]+$")


def _check_id(value, label):
    if not _SAFE_ID.match(value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


catalog = _check_id(dbutils.widgets.get("catalog").strip(), "catalog")
schema = _check_id(dbutils.widgets.get("schema").strip(), "schema")
APPLY_TAGS = dbutils.widgets.get("apply_data_asset_tags").strip().lower() == "true"

spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Helpers

# COMMAND ----------


def apply_uc_tags(table_name):
    """Every table carries the demo tag."""
    try:
        spark.sql(
            f"ALTER TABLE `{table_name}` SET TAGS ("
            f"'demo' = 'customer-360-for-utilities')"
        )
        return "ok"
    except Exception as e:
        return str(e)


def apply_column_comments(table_name, column_comments):
    """Apply COMMENT ON COLUMN for each column that actually exists. Skips
    missing columns gracefully. Never issues COMMENT ON TABLE."""
    results = {}
    existing_columns = {c.name for c in spark.table(table_name).schema.fields}
    for col_name, col_comment in column_comments.items():
        if col_name not in existing_columns:
            results[col_name] = "skipped (column not found)"
            continue
        try:
            escaped = col_comment.replace("'", "''")
            spark.sql(
                f"COMMENT ON COLUMN `{table_name}`.`{col_name}` IS '{escaped}'"
            )
            results[col_name] = "ok"
        except Exception as e:
            results[col_name] = str(e)
    return results


# COMMAND ----------

# MAGIC %md
# MAGIC ## Discover tables & apply UC tags
# MAGIC
# MAGIC Tags go on EVERY base table. We exclude SDP internals
# MAGIC (`__materialization*`, `event_log*`) and metric views (`METRIC_VIEW`,
# MAGIC tagged by `metric_views.py`).

# COMMAND ----------

discovered = spark.sql(
    f"""
    SELECT table_name, table_type
    FROM `{catalog}`.information_schema.tables
    WHERE table_schema = '{schema}'
    """
).collect()

taggable_tables = [
    row["table_name"]
    for row in discovered
    if not row["table_name"].startswith("__materialization")
    and not row["table_name"].startswith("event_log")
    and (row["table_type"] or "").upper() != "METRIC_VIEW"
]

print(f"Discovered {len(discovered)} objects; tagging {len(taggable_tables)} tables.")

if not APPLY_TAGS:
    print(
        "apply_data_asset_tags=false — skipping UC tags "
        "(governed workspace tag policy). Column comments still applied below."
    )
else:
    from concurrent.futures import ThreadPoolExecutor, as_completed

    tag_ok = 0
    tag_fail = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(apply_uc_tags, t): t for t in taggable_tables}
        for future in as_completed(futures):
            table_name = futures[future]
            result = future.result()
            if result == "ok":
                tag_ok += 1
            else:
                tag_fail += 1
                print(f"  TAG FAILED: {table_name}: {result}")
    print(f"\nTags: {tag_ok} applied, {tag_fail} failed")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Column comments

# COMMAND ----------

_INGESTED_AT = "Pipeline load timestamp (curation run time)."

COLUMN_COMMENTS = {
    # ── Dimensions ──────────────────────────────────────────────────
    "dim_customer": {
        "customer_id": "Durable BIGINT customer key (xxhash64 of the raw customer string).",
        "customer_number": "Natural customer key (the raw human-readable id).",
        "customer_type": "residential | commercial_standalone | commercial_chain | commercial_subsidiary | commercial_parent | landlord_portfolio.",
        "customer_name": "Fictional org label for commercial_parent rows; NULL for all other customer types (PII-free policy).",
        "n_premises_owned": "Number of premises this customer directly holds across their accounts.",
        "n_premises_portfolio": "For commercial_parent: total premises across all subsidiaries. For all other types: same as n_premises_owned.",
        "is_prior_customer": "True if a former customer who carries profile but no fact activity in the display window.",
        "customer_class": "Residential | Commercial.",
        "income_band": "ACS-derived income band (under_25k .. over_200k).",
        "household_size": "Household size 1-6 (residential only; NULL for commercial).",
        "age_band_hoh": "Age band of head of household (18_34 .. 65_plus).",
        "language_preference": "Preferred language (EN | ES | OTHER).",
        "tenure": "Housing tenure (own | rent).",
        "critical_care_flag": "Medical-equipment-dependent (critical-care) customer.",
        "liheap_eligible": "Income/household-size eligible for LIHEAP assistance.",
        "customer_since_date": "Date the customer relationship started.",
        "payment_stressed_flag": "Disclosed signal: any unpaid/partial bill in trailing 12 months OR previous_balance over $200.",
        "payment_late_flag": "Disclosed signal: any paid-late bill in trailing 12 months.",
        "high_user_flag": "Disclosed signal: avg monthly kWh above peer-group 75th percentile (peer = building_subtype x sqft_band).",
        "usage_band": "Disclosed signal: low | medium | high usage vs peer group (below p25 / between / above p75).",
        "engagement_tier": "Disclosed signal: high | medium | low digital engagement (autopay/paperless/portal frequency).",
        "digital_adoption_score": "Disclosed signal: 0-100 (autopay 25 + paperless 20 + mobile app 20 + portal frequency up to 20 + energy-efficiency/DSM participation 15). EE participation also lifts the upstream portal-session and app-install signals.",
        "churn_risk_band": "Disclosed signal: low | medium | high, derived from the latest SAP legacy churn risk score.",
        "recent_outage_minutes_90d": "Disclosed signal: total minutes out in the 90 days before the demo's as-of date.",
        "recent_outage_events_90d": "Disclosed signal: distinct outages in the trailing-90-day window.",
        "recent_complaint_count_90d": "Disclosed signal: complaints filed in the trailing-90-day window.",
        "avg_monthly_kwh_12mo": "Disclosed signal: avg monthly kWh over trailing 12 months.",
        "peer_p75_avg_monthly_kwh": "Disclosed signal: 75th-percentile avg monthly kWh among this customer's peer group.",
        "peer_building_subtype": "Disclosed signal: peer-group building type used for benchmarking.",
        "peer_sqft_band": "Disclosed signal: peer-group square-footage band.",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_account": {
        "account_id": "Durable BIGINT account key (xxhash64 of the raw account string).",
        "account_number": "Natural account key the app searches and deep-links by.",
        "customer_id": "Durable BIGINT key of the owning customer (joins dim_customer).",
        "customer_number": "Natural key of the owning customer.",
        "parent_account_id": "Durable BIGINT key of the consolidated-billing parent account.",
        "account_group": "standard | consolidated_billing | corporate_parent.",
        "customer_class": "Residential | Commercial.",
        "rate_schedule": "Rate code in effect (res_d1, res_d8_ev, com_d6, ...); joins dim_rate_schedule.",
        "rate_category": "Residential | Commercial | Other.",
        "rate_display_name": "Human-readable rate name (Standard / EV Time-of-Use / Industrial / ...).",
        "autopay_enrolled": "Enrolled in autopay.",
        "paperless_enrolled": "Enrolled in paperless billing.",
        "marketing_consent": "Opted in to marketing communications.",
        "preferred_channel": "Preferred contact channel (email | sms | mail).",
        "account_opened_date": "Date the account was opened.",
        "current_status": "Present account status (active | suspended | closed); history in dim_account_history.",
        "account_tenure_years": "Whole years on the account as of the demo's as-of date.",
        "account_tenure_band": "new_<1yr | 1-3yr | 3-10yr | 10+yr.",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_premise": {
        "premise_id": "Durable BIGINT premise key (xxhash64 of the canonical unbraced UUID).",
        "premise_number": "Natural premise key — canonical unbraced lowercase UUID (e.g. 36635486-93f7-...).",
        "source_building_id": "Raw FEMA source building id (braced UUID, for lineage).",
        "occupancy_class": "Residential | Commercial.",
        "primary_occupancy": "Raw FEMA primary-occupancy subtype.",
        "building_subtype": "ResStock-aligned building type (Single-Family Detached / Multi-Family / Mobile Home / Small/Medium/LargeOffice).",
        "sqft": "Building footprint area in square feet.",
        "year_built": "Synthesized year of construction.",
        "heating_fuel": "natural_gas | electricity | propane | fuel_oil.",
        "envelope_quality": "Building-envelope quality (low | medium | high).",
        "hvac_system_type": "HVAC system (central_ac | window_units | no_cooling | rooftop_unit).",
        "city": "Property city.",
        "zip_code": "Property ZIP code.",
        "county": "County name.",
        "county_fips": "Five-digit state+county FIPS code.",
        "census_tract": "Census tract identifier.",
        "latitude": "Centroid latitude (WGS84).",
        "longitude": "Centroid longitude (WGS84).",
        "centroid_point": "GEOMETRY point of the building centroid.",
        "footprint_polygon": "GEOMETRY polygon of the building footprint.",
        "climate_zone": "Climate zone (constant '5A' for the demo territory).",
        "sqft_band": "Banded square footage for peer-group benchmarks (<1000 .. 15000+).",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_premise_h3": {
        "premise_id": "Durable BIGINT premise key (matches dim_premise).",
        "premise_number": "Natural premise key (FEMA UUID).",
        "latitude": "Centroid latitude (WGS84).",
        "longitude": "Centroid longitude (WGS84).",
        "h3_res5": "H3 cell index at resolution 5 (county-level), BIGINT long form.",
        "h3_res6": "H3 cell index at resolution 6 (neighborhood-cluster), BIGINT long form.",
        "h3_res7": "H3 cell index at resolution 7 (neighborhood), BIGINT long form.",
        "h3_res8": "H3 cell index at resolution 8 (sub-neighborhood), BIGINT long form.",
        "h3_res9": "H3 cell index at resolution 9 (block-level), BIGINT long form.",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_service_point": {
        "service_point_id": "Durable BIGINT service-point key (xxhash64 of the raw service-point string).",
        "service_point_number": "Natural service-point key (raw service_point id).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise).",
        "service_location_number": "Natural key of the originating premise service attrs record.",
        "commodity": "always 'electric'. This model covers electric service only; gas is out of scope.",
        "service_point_type": "residential_single_meter | commercial_small | commercial_large | other.",
        "phase_code": "Electrical phase (single_phase | three_phase).",
        "nominal_service_voltage": "Nominal service voltage in volts.",
        "amperage_service_size": "Service amperage rating.",
        "is_smart_meter": "True if served by an AMI-enabled smart meter.",
        "service_address": "Synthesized service street address.",
        "service_city": "Service city.",
        "service_state": "Service state (always 'MI').",
        "service_zip": "Service ZIP code.",
        "in_service_date": "Date electric service was first energized.",
        "service_status": "active | disconnected.",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_meter": {
        "meter_id": "Durable BIGINT meter key (xxhash64 of the raw meter string).",
        "meter_number": "Natural meter key (raw meter id).",
        "commodity": "always 'electric'. This model covers electric service only; gas is out of scope.",
        "meter_seq": "Sequence number of this meter at the service point (1 = original).",
        "is_replacement": "True if this is a swap-in replacement meter.",
        "serial_number": "Synthesized meter serial number.",
        "manufacturer": "Meter manufacturer (Itron | Landis+Gyr | Honeywell | Sensus | GE).",
        "model_number": "Meter model number.",
        "install_date": "Date the meter was installed.",
        "communication_protocol": "AMI/AMR communication protocol (rf_mesh_* | cellular | none_amr_walk_by).",
        "firmware_version": "Meter firmware version (NULL for AMR meters).",
        "status": "Meter status (active | replaced).",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_service_agreement": {
        "service_agreement_id": "Durable BIGINT agreement key (xxhash64 of the raw agreement string).",
        "service_agreement_number": "Natural agreement key.",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "account_number": "Natural account key.",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise).",
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "rate_schedule": "Rate code for this agreement (joins dim_rate_schedule).",
        "effective_date": "Start of the agreement validity window.",
        "termination_date": "End of the validity window (NULL if open).",
        "status": "Agreement status.",
        "is_current": "True for the live agreement (used in as-of resolution).",
        "agreement_seq": "Per-account agreement sequence (rate switchers have seq 1 terminated + seq 2 current).",
        "termination_reason": "Reason the agreement was terminated (NULL if open).",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_rate_schedule": {
        "rate_schedule_id": "Natural rate-code key (res_d1, res_d8_ev, com_d4, ...).",
        "rate_display_name": "Human-readable rate name.",
        "rate_category": "Residential | Commercial.",
        "is_time_of_use": "True if the rate has TOU peak/off-peak pricing.",
        "is_medical_baseline": "True if reserved for medical-baseline (critical-care) customers.",
        "service_charge_usd": "Fixed monthly customer charge in USD.",
        "energy_charge_per_kwh": "Volumetric energy rate in USD per kWh (peak rate for TOU rates).",
        "demand_charge_per_kw": "Commercial demand charge in USD per kW (0 for residential).",
        "description": "Plain-language description of the rate.",
    },
    "ref_cx_targets": {
        "metric": "csat | nps | fcr | aht.",
        "year": "Calendar year the target/benchmark applies to.",
        "segment": "all | residential | commercial.",
        "target_value": "Internal goal, in the metric's native unit (csat/fcr as a %, nps as -100..100, aht in seconds).",
        "jdpower_value": "External J.D. Power benchmark (csat only; NULL otherwise).",
        "acsi_value": "External ACSI benchmark (csat only; NULL otherwise).",
    },
    "dim_program": {
        "program_id": "Natural program-code key (PRG-XXXX).",
        "program_name": "Customer-facing program name.",
        "program_type": "EE_rebate | DR_enrollment | EE_grant | audit | rate_program | DER_incentive.",
        "customer_segment": "Eligible segment (residential | commercial).",
        "rebate_amount_usd": "Rebate paid per enrollment in USD.",
        "avg_annual_kwh_saved": "Estimated annual kWh saved per participant.",
        "program_status": "Active | Closed.",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_agent": {
        "agent_id": "Natural CSR agent key (AGT-NNNN).",
        "team_id": "Team the agent belongs to (TEAM-NN).",
        "latest_engagement_score": "Most recent Emplify engagement score (0-100).",
        "latest_enps_score": "Most recent eNPS score (-100 to +100).",
        "latest_career_growth": "Most recent self-reported career-growth score (1-5).",
        "latest_manager_relationship": "Most recent self-reported manager-relationship score (1-5).",
        "latest_recognition": "Most recent self-reported recognition score (1-5).",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_date": {
        "date_key": "yyyymmdd integer date key (natural key on all facts).",
        "date_value": "Native DATE value.",
        "year": "Calendar year.",
        "quarter": "Calendar quarter (1-4).",
        "month": "Calendar month (1-12).",
        "day_of_month": "Day of month (1-31).",
        "day_of_week": "Day of week (Spark convention; 1=Sunday .. 7=Saturday).",
        "day_name": "Full weekday name (Monday, Tuesday, ...).",
        "month_name": "Full month name (January, February, ...).",
        "week_of_year": "ISO week of year (1-52).",
        "is_weekend": "True for Saturday/Sunday.",
        "season": "winter | spring | summer | fall (climate-zone 5A buckets).",
        "tou_day_type": "weekday | weekend (drives the EV-TOU rate peak window).",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_geography": {
        "tract_id": "Census tract identifier (natural key).",
        "county_fips": "Five-digit state+county FIPS code.",
        "county_name": "County name.",
        "primary_city": "City the tract is primarily in.",
        "primary_zip": "Primary ZIP code for the tract.",
        "county_name_lsad": "TIGER NAMELSAD county label.",
        "county_land_sqm": "County land area in square meters (TIGER ALAND).",
        "county_water_sqm": "County water area in square meters (TIGER AWATER).",
        "utility_name": "Operating utility display name (neutral placeholder for the demo).",
        "state_code": "State code (constant 'MI').",
        "climate_zone": "Climate zone (constant '5A').",
        "_ingested_at": _INGESTED_AT,
    },
    # ── Bridges & temporal ──────────────────────────────────────────
    "bridge_customer_hierarchy": {
        "hierarchy_link_id": "Deterministic surrogate key (md5 of parent+child customer_id strings).",
        "parent_customer_id": "Durable BIGINT key of the parent-tier customer (joins dim_customer).",
        "child_customer_id": "Durable BIGINT key of the subsidiary customer (joins dim_customer).",
        "relationship_type": "Nature of the relationship — currently 'subsidiary'; extensible for franchise/JV/managed-by.",
        "valid_from": "Start of the relationship window (half-open interval).",
        "valid_to": "End of the relationship window (NULL = currently active).",
        "is_current": "True where valid_to IS NULL.",
        "_ingested_at": _INGESTED_AT,
    },
    "bridge_customer_account": {
        "customer_account_link_id": "Durable BIGINT link key (xxhash64 of customer_id + account_id + valid_from).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "valid_from": "Start of the customer-ownership window (half-open interval).",
        "valid_to": "End of the window (NULL = currently active).",
        "is_current": "True where valid_to IS NULL.",
        "_ingested_at": _INGESTED_AT,
    },
    "hierarchy_version": {
        "hierarchy_version_id": "Durable BIGINT path key (xxhash64 of root+customer+account+premise+sp+meter+valid_from).",
        "root_customer_id": "Portfolio parent valid during this interval; equals customer_id when no parent hierarchy applies.",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise).",
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "meter_id": "Durable BIGINT meter key; NULL when no meter was installed during this interval.",
        "valid_from": "Start of the interval during which the full path was stable (half-open).",
        "valid_to": "End of the interval (NULL = currently active).",
        "is_current": "True where valid_to IS NULL.",
        "_ingested_at": _INGESTED_AT,
    },
    "bridge_account_premise": {
        "account_premise_link_id": "Durable BIGINT link key (xxhash64 of the raw link string).",
        "account_premise_link_number": "Natural link key.",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "account_number": "Natural account key.",
        "premise_id": "Durable BIGINT premise key (joins dim_premise).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "link_start_date": "Start of the tenancy/billing-responsibility window.",
        "link_end_date": "End of the window (NULL while current).",
        "is_current": "True for the live link (current customer).",
        "link_status": "Link status.",
        "billing_responsibility_flag": "True if this account was billing-responsible for the premise.",
        "tenancy_type": "Tenancy type for the link.",
        "link_termination_reason": "Reason the link ended (NULL while current).",
        "_ingested_at": _INGESTED_AT,
    },
    "bridge_premise_owner": {
        "premise_owner_link_id": "Durable BIGINT edge key (xxhash64 of party+premise+basis).",
        "party_id": "Durable BIGINT owner-party key (joins dim_customer).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise).",
        "basis": "owner_pays (chain consolidated billing) | owner_occupied | landlord_agreement.",
        "display_name": "Readable label populated only for a few showcase parties; NULL elsewhere.",
        "owns_from": "Start of the ownership window.",
        "owns_to": "End of the ownership window (NULL for current owners; set when a property is sold or transferred).",
        "is_current": "True for active ownership rows (valid_to IS NULL). False for closed rows where ownership ended.",
        "_ingested_at": _INGESTED_AT,
    },
    "meter_installation": {
        "meter_installation_id": "Durable BIGINT installation key (xxhash64 of the raw installation string).",
        "meter_installation_number": "Natural installation key.",
        "meter_id": "Durable BIGINT meter key (joins dim_meter).",
        "meter_number": "Natural meter key.",
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise).",
        "installation_date": "Date the meter was installed at the service point.",
        "removal_date": "Date the meter was removed (NULL while current).",
        "to_meter_id": "Durable BIGINT key of the swap-in successor meter (NULL for the current install).",
        "removal_reason_code": "Reason code for meter removal (NULL while current).",
        "is_current": "True for the live installation.",
        "installation_status": "Installation status.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_service_event": {
        "service_event_id": "Durable BIGINT event key (xxhash64 of the source row id + event type).",
        "event_type": "move_in | move_out | rate_switch | meter_swap.",
        "event_date": "Date the event occurred.",
        "account_id": "Durable BIGINT account key (NULL for meter-swap events).",
        "customer_id": "Durable BIGINT customer key (NULL for meter-swap events).",
        "premise_id": "Durable BIGINT premise key.",
        "service_point_id": "Durable BIGINT service-point key (NULL for move events).",
        "service_agreement_id": "Durable BIGINT agreement key (populated for rate-switch events).",
        "meter_id": "Durable BIGINT meter key (populated for meter-swap events).",
        "detail": "Event-specific detail string (e.g. to_rate=, tenancy=, to_meter=).",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_customer_history": {
        "customer_sk": "Per-version SCD2 surrogate key (xxhash64 of customer_id + version start).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "customer_number": "Natural customer key.",
        "customer_type": "residential | commercial party type.",
        "n_premises_owned": "Number of premises owned at this version.",
        "customer_class": "Residential | Commercial.",
        "income_band": "ACS-derived income band.",
        "household_size": "Household size (residential only).",
        "age_band_hoh": "Age band of head of household.",
        "language_preference": "Preferred language.",
        "tenure": "Housing tenure (own | rent).",
        "liheap_eligible": "LIHEAP eligibility at this version.",
        "customer_since_date": "Date the customer relationship started.",
        "critical_care_flag": "Critical-care status at this version (the SCD2-tracked attribute).",
        "is_prior_customer": "True if a former customer.",
        "effective_from": "Start of this version's validity window.",
        "effective_to": "End of the validity window (NULL = current version).",
        "is_current": "True for the current version.",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_account_history": {
        "account_sk": "Per-version SCD2 surrogate key (xxhash64 of account_id + version start).",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "account_number": "Natural account key.",
        "customer_id": "Durable BIGINT customer key.",
        "premise_id": "Durable BIGINT premise key as of this version's window (history row = as-of stamp; dim_account no longer carries this column).",
        "parent_account_id": "Durable BIGINT consolidated-billing parent key.",
        "account_group": "standard | consolidated_billing | corporate_parent.",
        "customer_class": "Residential | Commercial.",
        "rate_schedule": "Rate code at this version.",
        "autopay_enrolled": "Autopay enrollment at this version.",
        "paperless_enrolled": "Paperless enrollment at this version.",
        "marketing_consent": "Marketing consent at this version.",
        "preferred_channel": "Preferred contact channel at this version.",
        "account_opened_date": "Date the account was opened.",
        "current_status": "Account status at this version (the SCD2-tracked attribute).",
        "effective_from": "Start of this version's validity window.",
        "effective_to": "End of the validity window (NULL = current version).",
        "is_current": "True for the current version.",
        "_ingested_at": _INGESTED_AT,
    },
    "dim_premise_history": {
        "premise_history_id": "Durable BIGINT version key (xxhash64 of premise_id + valid_from).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise).",
        "valid_from": "Start of the attribute-version window (half-open interval).",
        "valid_to": "End of the window (NULL = currently active).",
        "is_current": "True where valid_to IS NULL.",
        "service_status": "Service status at this version: active | inactive | demolished.",
        "service_class": "Service class at this version: Residential | Commercial.",
        "primary_occupancy": "Primary occupancy type at this version.",
        "building_subtype": "ResStock-aligned building subtype at this version.",
        "_ingested_at": _INGESTED_AT,
    },
    # ── Facts ───────────────────────────────────────────────────────
    "fact_work_order": {
        "work_order_id": "Natural work-order key.",
        "premise_id": "Durable BIGINT premise key (always non-NULL; joins dim_premise).",
        "service_point_id": "Durable BIGINT service-point key (NULL for premise-only orders).",
        "meter_id": "Durable BIGINT meter key (NULL for premise-only orders).",
        "customer_id": "Durable BIGINT customer key resolved as-of the work timestamp via hierarchy_version (nullable).",
        "account_id": "Durable BIGINT account key resolved as-of the work timestamp via hierarchy_version (nullable).",
        "work_type": "meter_exchange | meter_investigation | premise_inspection | service_disconnect | service_reconnect | new_service | DER_inspection.",
        "status": "open | completed | cancelled.",
        "priority": "routine | urgent | emergency.",
        "created_at": "Timestamp the work order was created.",
        "scheduled_at": "Timestamp the work order was scheduled.",
        "completed_at": "Timestamp the work order was completed (NULL for open orders).",
        "created_date_key": "yyyymmdd date key for the creation timestamp (joins dim_date).",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_meter_readings_daily": {
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise). Structural only — a usage point's premise never changes.",
        "date_key": "yyyymmdd date key (joins dim_date).",
        "reading_date": "Reading date (denormalized).",
        "kwh_delivered": "Total kWh delivered for the day (net of DER).",
        "kwh_received": "Total kWh received from PV export for the day.",
        "kwh_base": "Base-load kWh (ResStock-derived, no DER applied).",
        "kwh_ev": "EV-charging kWh contribution.",
        "kwh_pv": "PV-generation kWh.",
        "kwh_hp": "Heat-pump heating kWh contribution.",
        "kwh_tstat_savings": "Demand-response HVAC dampening kWh (negative).",
        "peak_hour_kwh": "Maximum single-hour kWh in the day.",
        "peak_hour_of_day": "Hour 0-23 when the daily peak occurred.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_meter_readings_monthly": {
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise).",
        "year": "Calendar year of the reading month.",
        "month": "Calendar month (1-12).",
        "month_end_date_key": "yyyymmdd date key for the last day of the month (joins dim_date).",
        "month_end_date": "Last day of the month.",
        "kwh_delivered": "Total kWh delivered for the month.",
        "kwh_received": "Total kWh received from PV export for the month.",
        "kwh_base": "Base-load kWh for the month.",
        "kwh_ev": "EV-charging kWh for the month.",
        "kwh_pv": "PV-generation kWh for the month.",
        "kwh_hp": "Heat-pump heating kWh for the month.",
        "kwh_tstat_savings": "Demand-response HVAC dampening kWh for the month (negative).",
        "month_peak_hour_kwh": "Maximum single-hour kWh in the month.",
        "days_in_month_with_data": "Distinct days with readings in the month.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_customer_hourly_load_profile": {
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise). Structural only — a usage point's premise never changes.",
        "year_month": "Aggregation month as yyyy-MM.",
        "day_type": "weekday | weekend.",
        "hour_of_day": "Hour of day (0-23).",
        "avg_kwh": "Average hourly kWh across days in the window.",
        "median_kwh": "Median hourly kWh across days in the window.",
        "p90_kwh": "90th-percentile hourly kWh across days in the window.",
        "max_kwh": "Maximum hourly kWh across days in the window.",
        "n_days_in_window": "Distinct days contributing to this (month, day_type, hour) cell.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_customer_billing": {
        "bill_id": "Natural bill key (one row per bill).",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "service_agreement_id": "Durable BIGINT agreement key (joins dim_service_agreement).",
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "rate_schedule": "Rate code applied to the bill (joins dim_rate_schedule).",
        "bill_period_start": "First day of the billing period.",
        "bill_period_end": "Last day of the billing period.",
        "date_key": "yyyymmdd date key keyed off bill_period_end (joins dim_date).",
        "bill_date": "Bill issuance date.",
        "due_date": "Payment due date.",
        "total_kwh": "Total kWh billed in the period.",
        "peak_kwh": "TOU peak-hour kWh.",
        "offpeak_kwh": "TOU off-peak kWh.",
        "peak_demand_kw": "Peak hourly demand in kW (commercial demand-charge basis).",
        "exported_kwh": "PV export kWh in the period.",
        "service_charge": "Fixed monthly service charge in USD.",
        "energy_charge": "Volumetric energy charge in USD.",
        "demand_charge": "Commercial demand charge in USD.",
        "pscr_adjustment": "Power Supply Cost Recovery adjustment in USD.",
        "net_metering_credit": "Net-metering credit for PV export in USD (negative).",
        "current_charges": "Sum of bill line items in USD.",
        "payment_status": "paid_on_time | paid_late | paid_partial | unpaid.",
        "unpaid_carry": "Portion of this bill carried to the next month in USD.",
        "previous_balance": "Carried arrears from prior bills in USD.",
        "total_amount_due": "current_charges plus previous_balance in USD.",
        "yoy_kwh_change_pct": "Fractional kWh change vs the same month last year (NULL if no prior).",
        "yoy_bill_change_pct": "Fractional charges change vs the same month last year (NULL if no prior).",
        "bill_shock_pct": "Fractional charges change vs the trailing-12-month average (NULL if no trailing).",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_payment_history": {
        "payment_id": "Natural payment key (one row per payment).",
        "bill_id": "Natural key of the bill being paid (joins fact_customer_billing).",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "payment_status": "paid_on_time | paid_late | paid_partial | unpaid.",
        "amount_paid": "Amount paid in USD.",
        "days_late": "Days late (negative = early, 0 = on time, positive = late; NULL if unpaid).",
        "payment_date": "Date paid (NULL if unpaid).",
        "payment_date_key": "yyyymmdd date key for the payment (joins dim_date).",
        "payment_method": "Payment method (autopay | online_portal | mail_check | ...).",
        "lateness_bucket": "unpaid | on_time_or_early | late_1_7 | late_8_30 | late_31_plus.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_customer_complaints": {
        "complaint_id": "Natural complaint key (one row per complaint).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "premise_id": "Durable BIGINT premise key (nullable; resolved via ordered evidence chain — see premise_attribution_method).",
        "premise_attribution_method": "How premise_id was resolved: driver_outage | driver_bill | unique_account_link | unresolved.",
        "complaint_date": "Date the complaint was filed.",
        "date_key": "yyyymmdd date key (joins dim_date).",
        "channel": "phone | online_chat | email | social_media | in_person | mail.",
        "category": "Top-level complaint category.",
        "sub_category": "Specific issue within the category.",
        "severity": "low | medium | high.",
        "sentiment_label": "negative | very_negative | mixed.",
        "driver_bill_id": "Natural key of the triggering bill (NULL if not bill-driven).",
        "driver_outage_id": "Natural key of the triggering outage (NULL if not outage-driven).",
        "assigned_agent_id": "Agent assigned to handle the complaint.",
        "resolution_status": "open | in_progress | resolved | escalated.",
        "resolution_minutes": "Minutes to resolve (NULL if open).",
        "triggering_bill_amount": "Charges on the triggering bill in USD.",
        "trailing_12_avg_bill": "Trailing-12-month average bill in USD for context.",
        "bill_shock_pct": "Fractional bill shock vs trailing average at complaint time.",
        "outages_count_30d": "Outages in the 30 days before the complaint.",
        "outage_minutes_30d": "Total outage minutes in the 30 days before the complaint.",
        "verbatim_language": "Language of the verbatim text (en | es).",
        "verbatim_text": "LLM-generated complaint narrative.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_outage_events": {
        "outage_id": "Natural outage key (one row per outage).",
        "circuit_id": "Synthetic distribution-feeder identifier.",
        "started_at": "Outage start timestamp (UTC).",
        "ended_at": "Outage restoration timestamp (UTC).",
        "started_date_key": "yyyymmdd date key for the outage start (joins dim_date).",
        "duration_minutes": "Minutes from start to restoration.",
        "duration_bucket": "short_<=30m | medium_31_120m | long_2_6h | extended_6_24h | major_24h_plus.",
        "cause_code": "CIM cause (equipment_failure | vegetation | weather | animal | vehicle | planned_maintenance | unknown).",
        "weather_category": "clear | heat_wave | ice_storm | wind_storm | severe_weather.",
        "affected_customer_count": "Number of customers affected.",
        "is_major_event_day": "IEEE 1366 major-event-day approximation.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_outage_customer_impact": {
        "impact_id": "Natural impact key (one row per outage x customer).",
        "outage_id": "Natural key of the parent outage (joins fact_outage_events).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "circuit_id": "Distribution-feeder identifier (denormalized).",
        "affected_start": "When this customer lost service.",
        "affected_end": "When this customer was restored.",
        "affected_date_key": "yyyymmdd date key for the impact start (joins dim_date).",
        "minutes_out": "Customer-experienced outage duration in minutes.",
        "priority_restoration_flag": "True for critical-care priority restoration.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_active_outage_event": {
        "active_outage_id": "Natural active-outage key (one row per currently-open incident).",
        "circuit_id": "Downed distribution-feeder identifier.",
        "snapshot_at": "The demo 'now' — the instant this real-time OMS snapshot represents.",
        "started_at": "When the feeder went down (before snapshot_at).",
        "minutes_out_so_far": "Minutes elapsed from started_at to snapshot_at.",
        "estimated_restoration_at": "Projected restoration timestamp (after snapshot_at).",
        "eta_minutes": "Estimated minutes from now to restoration.",
        "cause_code": "Storm-dominated cause (weather | vegetation | equipment_failure | animal | unknown).",
        "weather_category": "ice_storm | wind_storm | clear.",
        "affected_customer_count": "Planned customers out on the feeder (60-100% of circuit).",
        "n_customers_out": "Actual fanned-out currently-out customer count (from fact_active_outage_customer_impact).",
        "n_critical_care_out": "Currently-out customers with critical-care priority.",
        "crew_status": "Restoration state: assessing | dispatched | en_route | on_site.",
        "is_major_event_day": "True for large incidents (affected > 200) or long restoration (eta > 360m).",
        "centroid_lat": "Latitude centroid of the impacted premises (for map marker placement).",
        "centroid_lon": "Longitude centroid of the impacted premises (for map marker placement).",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_active_outage_customer_impact": {
        "impact_id": "Natural impact key (one row per active outage x currently-out customer).",
        "active_outage_id": "Natural key of the parent active outage (joins fact_active_outage_event).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "service_point_id": "Durable BIGINT service-point key (joins dim_service_point).",
        "premise_id": "Durable BIGINT premise key (joins dim_premise_h3 for geography).",
        "circuit_id": "Downed distribution-feeder identifier (denormalized).",
        "snapshot_at": "The demo 'now'.",
        "out_since": "When this customer lost power (= active_outage_event.started_at).",
        "estimated_restoration_at": "Projected restoration timestamp for this customer.",
        "minutes_out_so_far": "Minutes this customer has been out as of the snapshot.",
        "priority_restoration_flag": "True for critical-care priority restoration.",
        "still_out": "Always true — the table is the set of currently-out customers.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_csr_interactions": {
        "interaction_id": "Natural interaction key (one row per Genesys session).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "account_id": "Durable BIGINT account key (joins dim_account).",
        "complaint_id": "Natural complaint key when the session is complaint-driven (NULL otherwise).",
        "media_type": "voice | chat | email | sms.",
        "direction": "inbound | outbound.",
        "started_at": "Session start timestamp (UTC).",
        "started_date_key": "yyyymmdd date key for the session start (joins dim_date).",
        "queue": "Genesys queue handling the session.",
        "wait_time_seconds": "Queue wait time in seconds.",
        "talk_time_seconds": "Talk time with the agent in seconds.",
        "hold_time_seconds": "Hold time within the session in seconds.",
        "acw_seconds": "After-call work time in seconds.",
        "transfer_count": "Number of transfers during the session.",
        "handle_time_seconds": "Total handle time in seconds (talk + hold + acw).",
        "abandoned_flag": "True if the customer hung up before agent connect.",
        "disposition_code": "Session outcome code.",
        "ivr_path": "IVR menu navigation trace.",
        "agent_id": "Natural agent key (joins dim_agent).",
        "csat_score_1_5": "Post-call CSAT score (1-5).",
        "interaction_source": "complaint | inquiry.",
        "first_call_resolution_flag": "True if no transfer and a resolved disposition.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_survey_responses": {
        "survey_response_id": "Natural survey-response key (one row per response/evaluation).",
        "source_system": "qualtrics | sqm.",
        "survey_id": "Qualtrics survey id (NULL for SQM rows).",
        "survey_type": "nps_relationship | csat_transactional | sqm_call_evaluation.",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "response_date": "Date of the response/evaluation.",
        "response_date_key": "yyyymmdd date key for the response (joins dim_date).",
        "score_0_10": "Unified 0-10 score (NPS direct; CSAT mapped from 1-5; SQM mapped from total_score/10).",
        "nps_bucket": "promoter (9-10) | passive (7-8) | detractor (<=6).",
        "outage_minutes_prior_90d": "Trailing-90-day outage minutes (Qualtrics NPS only).",
        "outage_events_prior_90d": "Trailing-90-day outage events (Qualtrics NPS only).",
        "complaint_count_prior_90d": "Trailing-90-day complaint count (Qualtrics NPS only).",
        "comment_text": "LLM-generated open-ended comment (Qualtrics NPS only).",
        "comment_sentiment": "positive | neutral | negative, derived from score_0_10 (Qualtrics NPS only, NULL where comment_text is NULL).",
        "comment_theme": "ai_classify theme tag against comment_text, same taxonomy as complaint categories (Qualtrics NPS only, NULL where comment_text is NULL).",
        "interaction_id": "Natural interaction key (SQM rows only; joins fact_csr_interactions).",
        "agent_id": "Natural agent key (SQM rows only; joins dim_agent).",
        "sqm_total_score": "SQM 0-100 total score (SQM rows only).",
        "sqm_fcr_flag": "SQM First-Call-Resolution flag (SQM rows only).",
        "sqm_greeting_score": "SQM greeting sub-score, 0-5 (SQM rows only).",
        "sqm_empathy_score": "SQM empathy sub-score, 0-5 (SQM rows only).",
        "sqm_knowledge_score": "SQM knowledge sub-score, 0-5 (SQM rows only).",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_survey_invitations": {
        "survey_id": "NPS survey id (joins qualtrics_survey / fact_survey_responses.survey_id).",
        "period_date_key": "yyyymmdd date key of the survey's launch date (joins dim_date); the invitation period, not the response date.",
        "segment": "residential | commercial customer class of the invited customer.",
        "n_invited": "Count of customers invited (sampled) for this survey/segment.",
        "n_responded": "Count of those invited who went on to respond.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_social_mentions": {
        "mention_id": "Natural mention key (one row per public post).",
        "customer_id": "Durable BIGINT customer key matched via fuzzy match (joins dim_customer).",
        "platform": "twitter | facebook | google_review | yelp.",
        "posted_at": "Post timestamp.",
        "posted_date_key": "yyyymmdd date key for the post (joins dim_date).",
        "source_complaint_id": "Natural complaint key when the post is complaint-driven (NULL otherwise).",
        "source_outage_id": "Natural outage key when the post is outage-driven (NULL otherwise).",
        "post_driver": "complaint_unresolved | major_outage | baseline_unprompted.",
        "category": "Top-level issue category.",
        "sub_category": "Specific issue within the category.",
        "sentiment_label": "very_negative | negative | mixed | positive.",
        "reach_estimate": "Estimated audience size.",
        "engagement_count": "Likes plus shares plus replies.",
        "mention_text": "LLM-generated post text.",
        "match_confidence_band": "Fuzzy-match confidence band (high | medium | low).",
        "match_score": "Numeric fuzzy-match confidence (0-1).",
        "matching_method": "Method that produced the customer match (handle_exact | name_plus_city | ...).",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_program_enrollment": {
        "enrollment_id": "Natural enrollment key (one row per enrollment).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "program_id": "Natural program-code key (joins dim_program).",
        "enrollment_date": "Date of enrollment.",
        "enrollment_date_key": "yyyymmdd date key for the enrollment (joins dim_date).",
        "completion_date": "Completion date (NULL if not yet completed).",
        "rebate_paid_usd": "Rebate paid in USD.",
        "kwh_saved_estimate": "Estimated annual kWh saved.",
        "enrollment_status": "active | completed | cancelled | pending (raw 'enrolled' normalized to 'active').",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_der_adoption": {
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "device_type": "EV | PV | HEAT_PUMP | SMART_TSTAT.",
        "install_date_alt": "Reserved placeholder column from the UNION schema (always NULL).",
        "install_date": "Date the device was installed.",
        "system_size_kwh_or_dc": "EV battery kWh / PV kW DC / HP tons / NULL for thermostat.",
        "device_subtype": "Type-specific subtype (vehicle class / inverter type / dispatch mode / HP type / thermostat brand).",
        "extra_attr": "Type-specific attribute (e.g. TOU enrollment for EV, net-metered flag for PV).",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_digital_engagement": {
        "event_id": "Natural event key (one row per session or discrete event).",
        "event_type": "portal_session | payment_succeeded | payment_failed | paperless_enrolled | ...",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "account_id": "Durable BIGINT account key (portal sessions only; joins dim_account).",
        "event_timestamp": "Event timestamp.",
        "event_date_key": "yyyymmdd date key for the event (joins dim_date).",
        "platform": "web | ios | android (portal sessions only).",
        "duration_seconds": "Session duration in seconds (portal sessions only).",
        "entry_page_or_subtype": "Entry page for sessions; payment method for payment events.",
        "outcome": "Session outcome (paid_bill / viewed_only / ...).",
        "success_flag": "True if the event succeeded.",
        "failure_reason": "Reason for failure (when success_flag is false).",
        "bill_id": "Natural bill key for payment events (joins fact_customer_billing).",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_assistance_enrollment": {
        "enrollment_id": "Natural enrollment key (one row per enrollment).",
        "program_type": "liheap | payment_plan | critical_care.",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "enrollment_date": "Date of enrollment.",
        "enrollment_date_key": "yyyymmdd date key for the enrollment (joins dim_date).",
        "program_subtype": "Type-specific subtype (LIHEAP program year / payment-plan term / critical-care equipment).",
        "benefit_amount_usd": "Benefit amount in USD (LIHEAP and payment-plan rows only).",
        "status": "Status of the enrollment (varies by program_type).",
        "detail_attr": "Type-specific detail string.",
        "_ingested_at": _INGESTED_AT,
    },
    "fact_legacy_cx_snapshot": {
        "snapshot_id": "Natural snapshot key (one row per quarterly snapshot).",
        "customer_id": "Durable BIGINT customer key (joins dim_customer).",
        "snapshot_date": "End-of-quarter snapshot date.",
        "snapshot_date_key": "yyyymmdd date key for the snapshot (joins dim_date).",
        "marketing_segment": "SAP marketing segmentation.",
        "satisfaction_tier": "SAP satisfaction tier (TIER_DELIGHTED .. TIER_AT_RISK).",
        "lifetime_value_usd": "SAP lifetime-value estimate in USD.",
        "churn_risk_score_0_100": "SAP churn-risk score (0-100).",
        "churn_risk_band": "low | medium | high.",
        "last_contact_date": "Most recent customer contact per SAP.",
        "email_marketing_consent": "Email marketing consent.",
        "phone_marketing_consent": "Phone marketing consent.",
        "direct_mail_consent": "Direct-mail marketing consent.",
        "source_system": "Source system (constant 'sap_crm_legacy').",
        "_ingested_at": _INGESTED_AT,
    },
    # ── Benchmark ───────────────────────────────────────────────────
    "peer_monthly_usage_benchmark": {
        "peer_building_subtype": "Peer-group building type.",
        "peer_sqft_band": "Peer-group square-footage band.",
        "year": "Calendar year of the benchmark month.",
        "month": "Calendar month (1-12).",
        "peer_avg_kwh": "Average monthly kWh delivered across the peer group (peer group = each account's own premise size/type).",
        "peer_p50_kwh": "Median (50th-percentile) monthly kWh across the peer group.",
        "peer_p75_kwh": "75th-percentile monthly kWh across the peer group.",
        "peer_p90_kwh": "90th-percentile monthly kWh across the peer group.",
        "peer_n_customers": "Distinct accounts (≈ sites) in the peer group for the month.",
        "_ingested_at": _INGESTED_AT,
    },
}

# COMMAND ----------

documented = 0
tables_to_document = []
for table_name, column_comments in COLUMN_COMMENTS.items():
    if table_name not in taggable_tables:
        print(f"Skipping {table_name}: not found in schema.")
        continue
    tables_to_document.append((table_name, column_comments))

with ThreadPoolExecutor(max_workers=8) as pool:
    futures = {
        pool.submit(apply_column_comments, table_name, column_comments): table_name
        for table_name, column_comments in tables_to_document
    }
    for future in as_completed(futures):
        table_name = futures[future]
        result = future.result()
        ok = sum(1 for v in result.values() if v == "ok")
        skip = sum(1 for v in result.values() if "skipped" in v)
        fail = len(result) - ok - skip
        print(f"Applying column comments to {table_name}...")
        for col, status in result.items():
            if status != "ok" and "skipped" not in status:
                print(f"    COLUMN FAILED: {col}: {status}")
            elif "skipped" in status:
                print(f"    {col}: {status}")
        print(f"  Applied: {ok}  Skipped: {skip}  Failed: {fail}")
        documented += 1

print(f"\nDocumented {documented} tables.")
