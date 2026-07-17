# Ask-the-Map answer count grain — design

**Status:** proposed (not started)
**Date:** 2026-07-14
**Scope:** client-only copy/count fix in `ExplorerMap.tsx` (one component), optional tiny client patch for truncation phrasing.

## Problem

Asking the map *"Which customers are payment-stressed and have filed 2 or more
complaints in the last 90 days?"* produces a chat bubble that says:

> Found **463** customers — highlighted on the map and listed on the right.

while the right rail's group panel for the same answer says:

> **463 premises**
> 344 residential · 119 commercial · **358 customers**

Both numbers are correct — they're just different grains wearing the same
label. 463 is the number of **premises** (map dots) the matched customers
occupy; 358 is the number of **distinct customers**. The chat bubble counts
premises but calls them customers.

## Root cause (verified in code)

The data flow, end to end:

1. **Genie answers at customer grain.** The server's `/api/genie/ask` route
   (`app/server/geniePlugin.ts:80`) runs the question through Genie, then
   `askGenie()` extracts the `customer_id` column from the result:
   `customerIds`, and `count = customerIds.length` (`geniePlugin.ts:1080`).
   For this question that's 358.

2. **Enrichment expands to premise grain.** `enrichCustomers()`
   (`geniePlugin.ts:~980`) resolves each matched customer to its *current*
   premise(s) via `bridge_account_premise` (`is_current`) — deliberately, so a
   multi-site commercial customer paints a dot on **every** site. The comment
   on that query says exactly this. 358 customers → 463 `PointRow`s. The
   route returns both `customers` (premise rows) and `count` (customer count).

3. **The client stores both but only shows one — mislabeled.** `submitAsk`
   (`app/client/src/ExplorerMap.tsx:~1244`) patches the turn with
   `customers` (premise rows) and `count` (customer count). `ChatAnswer`
   (`ExplorerMap.tsx:3212`) then renders:

   ```tsx
   Found <strong>{fmtNum(customers!.length)}</strong> customers — highlighted on
   ```

   `customers.length` is the **premise** count. The comment above that line
   already acknowledges "customers is premise-grain — one row per current
   premise" and chose that number so it matches the dots and the rail
   headline — but kept the noun "customers". The number-vs-noun mismatch is
   the whole bug. `turn.count` (the customer-grain number) is stored and never
   displayed anywhere.

4. **The rail is already right.** The group panel (`ExplorerMap.tsx:~2836`)
   computes its own counts server-side from the promoted focus SQL: headline
   follows the "Count by Premises/Customers/Owners" unit toggle (default
   premise → "463 premises"), and shows the *other* grain as a secondary line
   whenever it diverges ("· 358 customers", entity-grain §4.4). No rail change
   is needed.

## Design

### Fix: dual-grain sentence in `ChatAnswer`

Answer the user's question in the unit they asked in (customers), and name the
premise expansion explicitly since that's what the dots and rail headline show:

- **When the grains diverge** (multi-site customers in the match):

  > Found **358 customers** across **463 premises** — highlighted on the map
  > and listed on the right. Pan/zoom or ask a follow-up to narrow further.

- **When they agree** (the ~97.5% single-site case — most residential-only
  answers), collapse to the current shape so we don't add noise:

  > Found **12 customers** — highlighted on the map and listed on the right. …

### Where the customer count comes from

Compute it client-side from the enriched rows, not from `turn.count`:

```ts
const premiseCount = customers.length;
const customerCount = new Set(customers.map((c) => c.customer_id)).size;
```

`PointRow` already carries `customer_id` (it's in `POINT_COLS`,
`geniePlugin.ts:360`), so no server change is required. Reasons to prefer
rows-derived over `turn.count`:

- `count` is `customerIds.length` on the **raw Genie rows** — if Genie's SQL
  ever returns one row per customer-complaint (or any non-distinct shape), it
  over-counts. A `Set` over the rendered rows is immune.
- Enrichment `INNER JOIN`s on `is_current` — a matched customer with no
  current premise gets **zero dots**. Counting from the rows means the
  sentence describes exactly what's on the map and in the rail, which is the
  consistency the user noticed was broken. (WYSIWYG beats fidelity-to-Genie
  here; same principle as the hex-highlight counting rule at
  `ExplorerMap.tsx:1178`.)

Pluralization: handle 1-vs-many for both nouns ("1 customer", "1 premise").
There's an existing `formatUnitCount` helper used by the rail headline —
reuse it if its phrasing fits, otherwise inline ternaries are fine for two
nouns.

### Alternatives considered (rejected)

- **Just relabel to "premises"** ("Found 463 premises"): answers a question
  phrased about customers in premise units — trades one confusion for
  another, and drops the number the user actually asked for.
- **Follow the rail's unit toggle**: the chat is a transcript; retroactively
  re-rendering old bubbles when the user flips the toggle is surprising, and
  the toggle can change long after the answer landed. A fixed dual-grain
  sentence is stable and self-explanatory.
- **Server-side dedupe / new field**: unnecessary — the client already has
  everything it needs in the rows.

### Optional (cheap, same file): truncation honesty

`AskResult.truncated` is set when Genie hits its 5,000-row cap
(`GENIE_ROW_CAP`, `geniePlugin.ts:23`) but the client's `patch()` in
`submitAsk` doesn't carry it onto the turn. If we're touching this copy
anyway, forward `truncated` and prefix with "Found the first …" when set.
Purely additive; skip if it grows the diff.

## Touched surface

| File | Change |
| --- | --- |
| `app/client/src/ExplorerMap.tsx` | `ChatAnswer` count logic + copy; update the grain comment; (optional) add `truncated` to `GenieTurn` + `patch()` |

No server, pipeline, or Genie-space changes. No rail changes.

## Verification

1. `npx tsc` in `app/` (note: baseline fluctuates with the auto-generated
   `appKitTypes.d.ts` — compare against a pre-change run).
2. Local app boot against real data (see `app-local-dev-boot` memory), then:
   - Ask the payment-stressed + ≥2-complaints question. Expect the bubble to
     read "Found 358 customers across 463 premises" and the rail to read
     "463 premises … 358 customers" — same numbers, same nouns.
   - Ask something that matches only single-site residential customers
     (e.g. a small LIHEAP slice). Expect the collapsed single-count phrasing
     and **no** "across N premises" clause.
   - Flip the rail toggle to Customers: rail headline becomes "358 customers ·
     463 premises" secondary — bubble still agrees with both numbers.
3. If the truncation bit is done: hard to trigger live (needs >5k match);
   verify by temporarily lowering `GENIE_ROW_CAP` in local dev only.
