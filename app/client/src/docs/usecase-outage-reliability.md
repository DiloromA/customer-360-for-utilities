## Outages & Reliability

The operations view: track reliability to standard, and see where service is
worst.

### Use cases

- **Reliability reporting** — SAIDI/SAIFI-style indices computed to the **IEEE
  1366-2022** standard, so regulatory reporting and internal targets use the
  same numbers.
- **Major-event-day handling** — classify major-event days so blue-sky
  reliability isn't distorted by storms.
- **Spatial outage view** — active-outage incidents on the map, aggregated by
  area, to prioritize restoration and mutual-aid decisions.

### Business value

Defensible regulatory reporting; faster, better-targeted restoration; a clear
picture of which feeders and neighborhoods drag reliability down.

### Powered by

The outage facts and the `metric_reliability` view ([the data
model](doc:data-model)), rendered spatially on the always-mounted Explorer map
([application architecture](doc:app-architecture)).
