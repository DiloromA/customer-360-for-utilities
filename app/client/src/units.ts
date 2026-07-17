// The counting-unit model (entity-grain-design.md §4.4) — every headline that
// counts "how many" must declare which of these it's counting, because the
// three units diverge for any multi-site (chain/landlord) customer:
//   - premise:  one per occupied premise (the map's dot count; default) —
//               matches the Premise inspector and dim_premise's own name
//   - customer: one per distinct party, multi-site customers collapse to one
//   - owner:    one per owning party (landlord/portfolio)
// This file is presentation-only glue — no new data, just a shared vocabulary
// so counts are never silently mislabeled "customers" when they're really
// premises (the root of the entity-grain unit-mismatch class).
export type CountUnit = "premise" | "customer" | "owner";

const UNIT_LABELS: Record<CountUnit, { singular: string; plural: string }> = {
  premise: { singular: "premise", plural: "premises" },
  customer: { singular: "customer", plural: "customers" },
  owner: { singular: "owner", plural: "owners" },
};

export function unitLabel(n: number, unit: CountUnit): string {
  const l = UNIT_LABELS[unit];
  return n === 1 ? l.singular : l.plural;
}

// Combine a pre-formatted count string (e.g. from fmtNum) with its unit label,
// e.g. formatUnitCount("1,250", "premise") -> "1,250 premises".
export function formatUnitCount(formattedCount: string, count: number, unit: CountUnit): string {
  return `${formattedCount} ${unitLabel(count, unit)}`;
}
