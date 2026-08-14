// Shared row and geometry types used across ExplorerMap, hooks, and extracted
// components. These were extracted from ExplorerMap.tsx so hooks can import
// without circular dependencies.

export type CellRow = {
  h3_index: string;
  n_customers: number;
  n_residential: number;
  n_commercial: number;
  n_payment_stressed: number;
  pct_payment_stressed: number;
  n_churn_high: number;
  pct_churn_high: number;
  n_critical_care: number;
  pct_critical_care: number;
  n_liheap: number;
  pct_liheap: number;
  n_engagement_high: number;
  pct_engagement_high: number;
  n_high_usage: number;
  pct_high_usage: number;
  avg_digital_adoption: number;
  sum_outage_minutes_90d: number;
  avg_outage_min_per_customer_90d: number;
  sum_complaints_90d: number;
  complaints_per_1k_90d: number;
  n_complaints_unmapped: number;
  dominant_theme: string;
  n_enrolled_any_program: number;
  pct_enrolled_any_program: number;
  centroid_lat: number;
  centroid_lon: number;
}

export type ProgramCellRow = {
  h3_index: string;
  n_customers: number;
  n_eligible: number;
  n_enrolled: number;
  n_not_enrolled_eligible: number;
  pct_enrolled: number | null;
  pct_gap: number | null;
  centroid_lat: number;
  centroid_lon: number;
}

export type ActiveOutageCellRow = {
  h3_index: string;
  n_customers: number;
  n_currently_out: number;
  pct_currently_out: number;
}

export interface ActiveOutagePointRow {
  account_number: string;
  premise_number: string;
  latitude: number;
  longitude: number;
  customer_class: string;
  critical_care_flag: boolean;
  priority_restoration_flag: boolean;
  out_since: string;
  estimated_restoration_at: string;
  minutes_out_so_far: number;
  cause_code: string;
  weather_category: string;
  crew_status: string;
  active_outage_id: string;
}

export interface PointRow {
  // Identity = the human account_number (deep-link key). The server also carries
  // customer_id internally for Genie matching, but the client keys on account.
  account_number: string;
  // Present on Genie-matched rows (POINT_COLS always selects it server-side) —
  // used client-side to collapse premise-grain rows back to distinct customers
  // for the "Ask the map" answer copy.
  customer_id?: string;
  // The premise's human natural key (dim_premise.premise_number) — a dot
  // click resolves to the Premise inspector by default, so every dot needs
  // this alongside account_number.
  premise_number: string;
  latitude: number;
  longitude: number;
  customer_class: string;
  usage_band: string;
  engagement_tier: string;
  payment_stressed_flag: boolean;
  high_user_flag: boolean;
  churn_risk_band: string;
  critical_care_flag: boolean;
  liheap_eligible: boolean;
  recent_complaint_count_90d: number;
  recent_outage_minutes_90d: number;
  digital_adoption_score: number;
  complaint_risk_pct: number | null;
  complaint_risk_tier: string | null;
  complaint_risk_category: string | null;
  attention_score: number;
  is_enrolled?: boolean;
  has_der?: boolean;
  in_focus?: boolean;
}

export interface Bounds {
  south: number;
  north: number;
  west: number;
  east: number;
}

// The active focus cohort, as reported by /api/focus/{set,summary}. `extent` is
// the cohort's lat/lon bounding box (null when empty) — used to frame-to-fit.
// `grain` and `subjectKey` are null for legacy cohorts.
export interface FocusSummary {
  active: boolean;
  // Service-location grain — the default counting unit, matches the FocusPanel
  // headline and the map's dot count.
  cohortLocations: number;
  territoryLocations: number;
  // Same cohort collapsed to distinct parties.
  cohortCustomers: number;
  territoryCustomers: number;
  extent: Bounds | null;
  // Grain-contract fields (null = legacy/pre-grain-contract cohort).
  grain: "customer" | "account" | "premise" | null;
  subjectKey: string | null;
}
