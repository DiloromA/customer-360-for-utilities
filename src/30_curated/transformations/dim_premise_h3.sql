-- Premise H3 index dimension. One row per premise with H3 cell
-- indices at multiple resolutions, plus lat/lon for the map.
-- ~51,580 rows.
--
-- Resolutions chosen for the demo-territory zoom range:
--   res 5: ~252 km^2  — county-level
--   res 6: ~36 km^2   — neighborhood-cluster
--   res 7: ~5 km^2    — neighborhood
--   res 8: ~0.74 km^2 — sub-neighborhood
--   res 9: ~0.10 km^2 — block-level (individual buildings at high zoom)
--
-- All indices are BIGINT (h3 long form). The app converts to string
-- via h3_h3tostring(...) on demand. Stored separately rather than
-- using h3_toparent() at query time so app queries are pure
-- GROUP BY h3_resN with no per-row function call.

CREATE OR REFRESH MATERIALIZED VIEW dim_premise_h3 (
  premise_id     BIGINT NOT NULL PRIMARY KEY,
  premise_number STRING NOT NULL,
  latitude       DOUBLE,
  longitude      DOUBLE,
  h3_res5        BIGINT,
  h3_res6        BIGINT,
  h3_res7        BIGINT,
  h3_res8        BIGINT,
  h3_res9        BIGINT,
  _ingested_at   TIMESTAMP
)
COMMENT 'H3 cell indices per premise at resolutions 5-9 (BIGINT h3 long form). premise_id is the durable BIGINT key (matches dim_premise); premise_number is the FEMA UUID. Joined to dim_premise / dim_account for the Executive map view.'
AS

SELECT
  abs(xxhash64(p.premise_id))                      AS premise_id,
  p.premise_id                                AS premise_number,
  p.latitude,
  p.longitude,
  h3_longlatash3(p.longitude, p.latitude, 5) AS h3_res5,
  h3_longlatash3(p.longitude, p.latitude, 6) AS h3_res6,
  h3_longlatash3(p.longitude, p.latitude, 7) AS h3_res7,
  h3_longlatash3(p.longitude, p.latitude, 8) AS h3_res8,
  h3_longlatash3(p.longitude, p.latitude, 9) AS h3_res9,
  current_timestamp() AS _ingested_at
FROM ${customer_master_schema}.raw_premises p
WHERE p.latitude IS NOT NULL AND p.longitude IS NOT NULL;
