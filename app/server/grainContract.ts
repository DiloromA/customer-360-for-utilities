// Server-side mirror of the grain/subject contract (app/client/src/subject.ts).
// Shared by focusPlugin and any future route that interprets grain context.

export type Grain = "customer" | "account" | "premise";

// Augmented focus summary returned by /api/focus/{set,summary}.
// grain and subjectKey are null for legacy cohorts written before the migration.
export interface GrainedFocusSummary {
  active: boolean;
  cohortLocations: number;
  territoryLocations: number;
  cohortCustomers: number;
  territoryCustomers: number;
  extent: { south: number; north: number; west: number; east: number } | null;
  grain: Grain | null;
  subjectKey: string | null;
}

export function isValidGrain(v: unknown): v is Grain {
  return v === "customer" || v === "account" || v === "premise";
}
