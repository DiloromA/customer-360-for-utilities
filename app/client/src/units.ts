// The counting-unit model — every headline that
// counts "how many" must declare which of these it's counting, because the
// three units diverge for any multi-site (chain/landlord) customer:
//   - premise:  one per occupied premise (the map's dot count; default) —
//               matches the Premise inspector and dim_premise's own name
//   - customer: one per distinct party, multi-site customers collapse to one
//   - account:  one per billing account (between premise and customer granularity)
// Ownership is a relationship attribute (bridge_premise_owner), not a grain.
// This file is presentation-only glue — no new data, just a shared vocabulary
// so counts are never silently mislabeled "customers" when they're really
// premises (the root of the entity-grain unit-mismatch class).
export type CountUnit = "premise" | "customer" | "account";

const UNIT_LABELS: Record<CountUnit, { singular: string; plural: string }> = {
  premise: { singular: "premise", plural: "premises" },
  customer: { singular: "customer", plural: "customers" },
  account: { singular: "billing account", plural: "billing accounts" },
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
