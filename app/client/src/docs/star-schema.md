## The curated star schema

At the center of this demo is a conventional dimensional model — the kind any
BI tool, Genie space, or analyst would recognize immediately. Facts hang off
shared dimensions through durable surrogate keys, so "how many customers,"
"how much revenue," and "how many outages" all answer consistently no matter
which angle you ask from.

- **Dimensions** — `dim_customer`, `dim_account`,
  `dim_premise`, `dim_meter`, `dim_rate_schedule`, and
  more. Each carries a stable surrogate key alongside its natural business key,
  so identity survives even if a source system's numbering doesn't.
- **Facts** — `fact_customer_billing` and
  `fact_meter_readings_daily` carry the measures: charges, usage,
  payments, consumption. Every fact declares real foreign keys back to its
  dimensions, so the relationships you see in the diagram are guarantees, not
  guesses.
- **Bridges** — `bridge_account_premise` resolves the
  many-to-many reality of utility service: one account can span premises, one
  premise can pass through several accounts over time.
- **History** — two SCD2 tables (`dim_customer_history`,
  `dim_account_history`) track how a customer or account changed over
  time, not just where they landed.
- **Metric views** — nine governed views (`metric_*`) sit on top of
  the facts with the business logic already baked in — revenue, consumption,
  enrollment, and more, computed once and reused everywhere so Genie, the app,
  and any dashboard agree with each other by construction. See the **Metrics
  Catalog** for exactly what each one computes.

The demo's clock is frozen at **December 31, 2018** — every "as of" and
effective-dated question in the model anchors to that date, so results stay
reproducible from one demo run to the next.

**Want to see it, not just read about it?** Open the **Data Model** view for a
live, interactive diagram of every table and relationship, generated straight
from Unity Catalog metadata rather than hand-drawn — it's never out of date.
