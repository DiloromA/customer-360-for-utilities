// Shared customer-filter vocabulary, used by both the customer search
// (App.tsx) and the Explorer map filter rail (ExplorerMap.tsx) so both
// slice the customer base by exactly the same dimensions and the
// SQL predicates stay in one place.
//
// The option *values* must match the flag names the SQL queries test
// (see exec_map_cells.sql): payment_stress, churn_high,
// critical_care, frequent_outages, high_complaints, liheap.

import { sql } from "@databricks/appkit-ui/js";

export interface FilterOption { value: string; label: string; }

// Build a clean "place, state" line from possibly-empty address parts. Prefers
// city, falls back to "<county> County", and never emits a dangling comma when
// a field is blank — the synthetic data carries county but no city/ZIP, so
// without this the UI showed a stray ", MI".
export function localityText(opts: { city?: string | null; county?: string | null; state?: string | null }): string {
  const city = (opts.city || "").trim();
  const county = (opts.county || "").trim();
  const place = city || (county ? `${county} County` : "");
  const state = (opts.state || "").trim();
  return [place, state].filter(Boolean).join(", ");
}

export const CUSTOMER_CLASS_OPTIONS: FilterOption[] = [
  { value: "Residential", label: "Residential" },
  { value: "Commercial",  label: "Commercial" },
];
export const USAGE_BAND_OPTIONS: FilterOption[] = [
  { value: "low",    label: "Low" },
  { value: "medium", label: "Medium" },
  { value: "high",   label: "High" },
];
export const ENGAGEMENT_OPTIONS: FilterOption[] = [
  { value: "high",   label: "High" },
  { value: "medium", label: "Medium" },
  { value: "low",    label: "Low" },
];
export const ISSUE_FLAG_OPTIONS: FilterOption[] = [
  { value: "payment_stress",   label: "Payment stress" },
  { value: "churn_high",       label: "Dissatisfaction" },
  { value: "critical_care",    label: "Critical care" },
  { value: "frequent_outages", label: "Frequent outages" },
  { value: "high_complaints",  label: "≥2 complaints" },
  { value: "liheap",           label: "LIHEAP-eligible" },
];

// Multi-dim filter state. Each dimension is a Set; an empty Set = no filter
// on that dimension.
export type FilterState = {
  customerClass: Set<string>;
  usageBand:     Set<string>;
  engagement:    Set<string>;
  issueFlags:    Set<string>;
};

export function emptyFilterState(): FilterState {
  return {
    // Partition dimensions default to their full set (= everyone); uncheck
    // a chip to narrow. Issue flags stay opt-in (empty = no restriction) —
    // it's additive (0..many per customer), not a partition, so "all on"
    // would mean "has at least one flag" and silently exclude the healthy
    // majority.
    customerClass: new Set(CUSTOMER_CLASS_OPTIONS.map((o) => o.value)),
    usageBand:     new Set(USAGE_BAND_OPTIONS.map((o) => o.value)),
    engagement:    new Set(ENGAGEMENT_OPTIONS.map((o) => o.value)),
    issueFlags:    new Set(),
  };
}

export function toggleSet(set: Set<string>, value: string): Set<string> {
  const next = new Set(set);
  if (next.has(value)) next.delete(value); else next.add(value);
  return next;
}

// Partition-dimension toggle: never allow the last remaining chip to be
// unchecked. With "empty = all", dropping to zero would flip the group back
// to all-blue, which reads as "I just deselected everything and now
// everything is selected again" — forbid it instead (min 1 selected).
export function togglePartition(set: Set<string>, value: string): Set<string> {
  const next = toggleSet(set, value);
  return next.size === 0 ? set : next;
}

// A partition dimension is unconstrained when empty OR fully selected.
function isUnconstrained(set: Set<string>, opts: FilterOption[]): boolean {
  return set.size === 0 || set.size === opts.length;
}

// Count of dimensions actively constraining the result (for a badge).
export function activeFilterCount(filters: FilterState): number {
  return (isUnconstrained(filters.customerClass, CUSTOMER_CLASS_OPTIONS) ? 0 : 1)
    + (isUnconstrained(filters.usageBand, USAGE_BAND_OPTIONS) ? 0 : 1)
    + (isUnconstrained(filters.engagement, ENGAGEMENT_OPTIONS) ? 0 : 1)
    + (filters.issueFlags.size > 0 ? 1 : 0);
}

// Serialize to the comma-delimited string params the SQL queries expect.
// Partition dims are normalized: empty or full set → "" (no filter).
export function filterSqlParams(filters: FilterState) {
  return {
    customer_classes: sql.string(isUnconstrained(filters.customerClass, CUSTOMER_CLASS_OPTIONS) ? "" : Array.from(filters.customerClass).join(",")),
    usage_bands:      sql.string(isUnconstrained(filters.usageBand, USAGE_BAND_OPTIONS) ? "" : Array.from(filters.usageBand).join(",")),
    engagement_tiers: sql.string(isUnconstrained(filters.engagement, ENGAGEMENT_OPTIONS) ? "" : Array.from(filters.engagement).join(",")),
    issue_flags:      sql.string(Array.from(filters.issueFlags).join(",")),
  };
}

// Raw comma-string filter values (for custom routes that take JSON, not the
// sql.* markers). Same normalization rule as filterSqlParams.
export function filterStrings(filters: FilterState) {
  return {
    customerClasses: isUnconstrained(filters.customerClass, CUSTOMER_CLASS_OPTIONS) ? "" : Array.from(filters.customerClass).join(","),
    usageBands:      isUnconstrained(filters.usageBand, USAGE_BAND_OPTIONS) ? "" : Array.from(filters.usageBand).join(","),
    engagementTiers: isUnconstrained(filters.engagement, ENGAGEMENT_OPTIONS) ? "" : Array.from(filters.engagement).join(","),
    issueFlags:      Array.from(filters.issueFlags).join(","),
  };
}

export function FilterGroup({
  label, options, selected, onToggle,
}: {
  label: string;
  options: FilterOption[];
  selected: Set<string>;
  onToggle: (v: string) => void;
}) {
  return (
    <div className="filter-group">
      <div className="filter-group-label">{label}</div>
      <div className="filter-pills">
        {options.map((o) => (
          <button
            key={o.value}
            type="button"
            className={`filter-pill ${selected.has(o.value) ? "active" : ""}`}
            onClick={() => onToggle(o.value)}
          >
            {o.label}
          </button>
        ))}
      </div>
    </div>
  );
}
