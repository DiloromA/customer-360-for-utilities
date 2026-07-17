## Where the data comes from

There's no public dataset of "a utility's customers" to download — utility
CRM, billing, and AMI data is private by nature. So this demo is built from a
foundation of **real, public geography and climate data**, with realistic
customer and utility behavior **synthesized** on top of it.

### The real foundation

| Source | What it gives the demo |
|---|---|
| FEMA / ORNL USA Structures | Building footprints — the physical anchor for every premise on the map. |
| US Census TIGER/Line | County boundaries, for geography and service-territory scoping. |
| NREL End-Use Load Profiles (EULP) weather | Hourly temperature + solar irradiance per county, feeding the heat-pump and PV models. *(Keyless — public S3.)* |
| NREL ResStock / ComStock | Realistic building load-shape profiles + PV generation shape, feeding AMI usage patterns. *(Optional.)* |

### The synthetic layer

Thirteen generator modules take that real foundation and build out everything
a utility CRM would actually track: meters and billing history, outages and
reliability events, complaints, digital-channel engagement, DSM program
enrollment, and more. It's tuned to be **behaviorally realistic** — the kinds
of correlations and edge cases you'd actually see in a customer base — without
using anyone's real data.

### Your data, same model

This same curated model and app are built to run unchanged on a real utility's
own billing, AMI, and CRM feeds — swapping out the synthetic generators is the
intended seam for turning this demo into a production pipeline, not a rewrite.

### Attributions

FEMA/ORNL USA Structures (CC BY 4.0) · NREL End-Use Load Profiles (EULP)
AMY2018 weather · NREL ResStock/ComStock (OEDI public S3) · US Census
TIGER/Line (public domain). Full attribution details live in the repo's
`README.md`.
