-- Service Location — CIM ServiceLocation projection over premises with the
-- service-side attributes a utility CIS would carry (formatted address,
-- service class, in-service date). One row per premise.
--
-- This is the table that the curated layer joins to FEMA's footprint
-- geometry for map rendering — premise_id is the bridge.

CREATE OR REFRESH MATERIALIZED VIEW raw_service_location (
  CONSTRAINT non_null_service_location_id EXPECT (service_location_id IS NOT NULL),
  CONSTRAINT non_null_premise_id          EXPECT (premise_id IS NOT NULL),
  CONSTRAINT valid_service_class EXPECT (
    service_class IN ('Residential', 'Commercial')
  )
)
COMMENT 'Service Location — CIM ServiceLocation projection over premises. One row per premise with formatted service address and service-class attributes. PK: service_location_id. FK: premise_id -> premises.'
AS

WITH base AS (
  SELECT
    p.*,
    abs(xxhash64(p.premise_id, 'in_service', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_in_service,
    abs(xxhash64(p.premise_id, 'street_no', ${random_seed})) / CAST(9223372036854775807 AS DOUBLE) AS r_street_no
  FROM raw_premises p
)

SELECT
  md5(CONCAT(premise_id, '_service_location')) AS service_location_id,
  premise_id,

  -- Service class — mirrors occupancy_class but is the customer-facing classification.
  occupancy_class                                                  AS service_class,

  -- Synthesized street address. FEMA doesn't carry full street addresses
  -- reliably; we generate a plausible one from city + a hashed street number.
  -- The street name pool is intentionally small so customers in the same
  -- tract sometimes share a street name (realistic clustering).
  CONCAT(
    CAST(100 + CAST(r_street_no * 9000 AS INT) AS STRING),
    ' ',
    ELEMENT_AT(
      ARRAY('Main','Oak','Maple','Elm','Cedar','Park','Lake','Pine','Washington',
            'Lincoln','Jefferson','Madison','Adams','Chestnut','Walnut','Spruce',
            'Cherry','Birch','Highland','Hillcrest','Sunset','Meadow','River',
            'Ridge','Spring','Forest','Garden','Liberty','Franklin','Jackson'),
      CAST(1 + abs(xxhash64(premise_id, 'street_name', ${random_seed})) % 30 AS INT)
    ),
    ' ',
    ELEMENT_AT(
      ARRAY('St','Ave','Rd','Dr','Blvd','Ln','Ct','Pl','Way'),
      CAST(1 + abs(xxhash64(premise_id, 'street_type', ${random_seed})) % 9 AS INT)
    )
  )                                                                AS service_address_line_1,

  city                                                             AS service_city,
  'MI'                                                             AS service_state,
  zip_code                                                         AS service_zip,
  county,
  county_fips,
  census_tract,
  latitude,
  longitude,
  centroid_point,
  footprint_polygon,

  -- In-service date: when this premise was first energized. Cluster between
  -- year_built (electric service started with the building) and ~5 yrs after
  -- (for older retrofits).
  CAST(
    DATE_ADD(
      MAKE_DATE(year_built, 1, 1),
      CAST(r_in_service * 365 * 5 AS INT)
    ) AS DATE)                                                     AS in_service_date,

  -- Current service status — vast majority active. The tiny disconnected
  -- fraction here is independent of customer_account.current_status (a
  -- service can be active while the customer account is suspended for
  -- billing reasons, but we don't model that nuance).
  CASE
    WHEN abs(xxhash64(premise_id, 'svc_status', ${random_seed})) % 1000 < 5
      THEN 'disconnected'
    ELSE 'active'
  END                                                              AS service_status,

  current_timestamp()                                              AS _ingested_at
FROM base;
