-- Full service-territory extent — the lat/lon bounding box that contains every
-- customer premise in the dataset. Used by the "Service territory" button to
-- fit the map to the whole customer base (and thus show macro-level KPIs).
SELECT
  MIN(latitude)  AS min_lat,
  MAX(latitude)  AS max_lat,
  MIN(longitude) AS min_lon,
  MAX(longitude) AS max_lon
FROM {{catalog}}.{{schema}}.dim_premise_h3
