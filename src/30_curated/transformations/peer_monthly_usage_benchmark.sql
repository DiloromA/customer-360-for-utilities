-- Per-month usage benchmark for each peer group (building_subtype ×
-- sqft_band). Drives the CSR view's "you vs your peers" overlay on the
-- 24-month bill chart, and the EE-marketing segment definitions.
--
-- GRAIN: the peer group is resolved from each account's OWN premise
-- (dim_premise, via fact_meter_readings_monthly.premise_id) — NOT the
-- customer's anchor premise. This matters for multi-site commercial customers:
-- a chain's 540 sqft office and its 21,000 sqft office each land in their own
-- size band, instead of every site inheriting one arbitrary anchor group. The
-- percentiles are over per-account monthly kWh, so a single site is compared to
-- like sites — matching the account-grained CSR header and load-profile views.
--
-- fact_meter_readings_monthly's grain includes service_point_id: a large
-- sub-metered commercial premise's 2-5 concurrent usage_points
-- (temporal-realism §5.3) each contribute their OWN row for the same
-- account/month. account_monthly below sums them first, so the peer
-- percentiles compare each site's TOTAL monthly kWh, not one meter's slice of
-- it (which would silently deflate the whole peer group toward large
-- sub-metered sites, since every meter shows up as its own "account-month").
--
-- ~150-200 peer groups × 24 months ≈ 4K rows. Tiny.

CREATE OR REFRESH MATERIALIZED VIEW peer_monthly_usage_benchmark (
  peer_building_subtype STRING NOT NULL,
  peer_sqft_band        STRING NOT NULL,
  year                  INT    NOT NULL,
  month                 INT    NOT NULL,
  peer_avg_kwh          DOUBLE,
  peer_p50_kwh          DOUBLE,
  peer_p75_kwh          DOUBLE,
  peer_p90_kwh          DOUBLE,
  peer_n_customers      BIGINT,
  _ingested_at          TIMESTAMP,
  CONSTRAINT pk_pmub PRIMARY KEY (peer_building_subtype, peer_sqft_band, year, month)
)
COMMENT 'Per-month kWh benchmark for each (peer_building_subtype, peer_sqft_band, year, month), where the peer group is each account''s OWN premise size/type (not the customer anchor). PK: (peer_building_subtype, peer_sqft_band, year, month). Joined into the customer bill view to show "you vs your peer p75" by month. peer_n_customers counts distinct accounts (≈ sites) in the group.'
AS

WITH account_monthly AS (
  -- Sum across sibling service_points (usage_points) first, so a sub-metered
  -- premise's total monthly kWh — not one meter's share of it — is what
  -- lands in the peer distribution.
  SELECT
    account_id,
    premise_id,
    year,
    month,
    SUM(kwh_delivered) AS kwh_delivered
  FROM fact_meter_readings_monthly
  GROUP BY account_id, premise_id, year, month
)

SELECT
  p.building_subtype                            AS peer_building_subtype,
  p.sqft_band                                   AS peer_sqft_band,
  m.year,
  m.month,
  ROUND(AVG(m.kwh_delivered),                  2) AS peer_avg_kwh,
  ROUND(PERCENTILE(m.kwh_delivered, 0.5),       2) AS peer_p50_kwh,
  ROUND(PERCENTILE(m.kwh_delivered, 0.75),      2) AS peer_p75_kwh,
  ROUND(PERCENTILE(m.kwh_delivered, 0.9),       2) AS peer_p90_kwh,
  COUNT(DISTINCT m.account_id)                    AS peer_n_customers,
  current_timestamp() AS _ingested_at
FROM account_monthly m
JOIN dim_premise p ON p.premise_id = m.premise_id
WHERE p.building_subtype IS NOT NULL
  AND p.sqft_band        IS NOT NULL
GROUP BY p.building_subtype, p.sqft_band, m.year, m.month;
