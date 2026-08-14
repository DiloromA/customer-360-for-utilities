## Application architecture

The app is the top layer of the stack, and — like everything above the curated
model — it runs unchanged on a utility's own data. A few things about how it's
built:

- **One always-mounted map.** The Explorer map is the spine of the app. It stays
  mounted as you move between views, so its viewport, the cohort you've focused,
  and your Genie conversation survive a nav switch instead of resetting.
- **Lenses and grain.** A single map is re-colored by *lenses* (usage, risk,
  program fit) and re-counted by *grain* (customers vs. premises vs. owners),
  rather than a separate chart per question.
- **Client/server split (AppKit).** A thin React client talks to a small server
  that holds credentials and runs queries against Unity Catalog — the browser
  never sees a token.
- **Runtime catalog/schema binding.** Queries are written against
  `{{catalog}}`/`{{schema}}` placeholders bound at container start, so the same
  build points at the demo schema or a customer's schema with no code change.
- **Session state the app owns.** Saved focus sets live in `app_focus_set` — the
  only data the app writes, kept small and separate from the analytical tiers.
- **Genie integration.** "Ask the Map" hands a natural-language question to a
  Genie space scoped to the curated model and metric views, and drops the answer
  onto the map.

### Extending it

The left nav is a single declarative config; a new view is one entry plus its
component, and a new map layer is one entry in the layer spec. The business
functions a utility organizes around are natural next views on the same model —
see [Use cases & business value](doc:usecase-customer-service).
