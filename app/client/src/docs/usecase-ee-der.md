## EE & DER Programs

The energy-efficiency and distributed-energy view: find the load behind the
meter, and target programs where they'll actually land.

### Use cases

- **Behind-the-meter detection** — infer EV charging and rooftop solar (PV) from
  AMI load patterns and the real solar-irradiance signal, without site surveys.
- **Program fit and enrollment gaps** — match customers to efficiency, demand-
  response, and DER programs, and find good-fit customers not yet enrolled.
- **DSM uptake tracking** — measure program participation across the base to see
  what's working.

### Business value

Better distribution planning as EV and PV adoption grows; higher program
enrollment from targeted rather than blanket outreach; measurable DSM impact.

### Powered by

The EV- and PV-detection `ml_*` tables, DER-opportunity signals, and the
`metric_dsm_uptake` view ([the data model](doc:data-model)). Detections surface
today as Explorer map lenses ([application architecture](doc:app-architecture)).
