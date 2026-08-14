// Typed grain/subject model for the grain-aware focus contract.
// This is a pure-type leaf module — zero imports from other app/client/src files.

/** The three selectable viewing grains for the Explorer map and rail. */
export type Grain = "customer" | "account" | "premise";

/**
 * direct — cohort scoped to the literal selection (one account → its current
 * premises only; matches the existing `accountNumbers` focus path).
 * portfolio — expand to all accounts under the same customer_id (matches the
 * existing `sql`/`filters` focus paths).
 */
export type SubjectScope = "direct" | "portfolio";

/**
 * A stable, URL-safe string that identifies a single entity without embedding
 * a JS-unsafe BIGINT surrogate. Format: "<grain>:<naturalKey>".
 * Examples: "account:A-00123456", "premise:{uuid}", "customer:C-00001"
 */
export type SubjectKey = string;

export function toSubjectKey(grain: Grain, naturalKey: string): SubjectKey {
  return `${grain}:${naturalKey}`;
}

export function parseSubjectKey(key: SubjectKey): { grain: Grain; naturalKey: string } | null {
  const colon = key.indexOf(":");
  if (colon === -1) return null;
  const grain = key.slice(0, colon) as Grain;
  if (grain !== "customer" && grain !== "account" && grain !== "premise") return null;
  return { grain, naturalKey: key.slice(colon + 1) };
}

/** The default expansion scope for each grain. */
export function defaultScopeForGrain(grain: Grain): SubjectScope {
  if (grain === "customer") return "portfolio";
  return "direct";
}

/**
 * Build the focus-set request body for a single-entity selection at the given
 * grain. This defines it as a stable insertion point.
 */
export function buildFocusDefinition(
  grain: Grain,
  naturalKey: string,
  sessionId: string,
): {
  sessionId: string;
  grain: Grain;
  subjectKey: SubjectKey;
  accountNumbers?: string[];
} {
  const subjectKey = toSubjectKey(grain, naturalKey);
  if (grain === "account") {
    return { sessionId, grain, subjectKey, accountNumbers: [naturalKey] };
  }
  // customer and premise grains require server-side resolution; the server
  // will interpret grain + subjectKey once those paths are implemented in 8c.
  return { sessionId, grain, subjectKey };
}
