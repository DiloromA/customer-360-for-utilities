-- Account ownership reassignment episode (internal helper).
-- Picks ONE standard-account residential premise and records that the account
-- was originally held by the prior customer (before the current customer took
-- over). The result feeds bridge_customer_account and raw_service_agreement,
-- which use it to split a single open-ended row into two dated ownership rows.
--
-- GRAIN: exactly one row. The episode is deterministic (hash-ranked pick).
--
-- Selection criteria:
--   • Residential, standard-account premise with a prior customer on file
--   • Not involved in a relocation (mover_role IS NULL)
--   • The premise's CURRENT tenancy window strictly contains transfer_date
--     (see below) — otherwise the pre-transfer agreement slice would have
--     effective_date > termination_date
--   • Deterministic via xxhash64 rank
--
-- Semantics:
--   from_customer_id — the prior customer (held the account before transfer_date)
--   to_customer_id   — the current customer (holds the account now, agrees with
--                      dim_account.customer_id for this account)
--
-- TRANSFER DATE — must land INSIDE the AMI display window, mid-month.
-- The window is ${as_of_date} minus ${history_months} (weather_calendar_map),
-- so the date is derived from those params, never hardcoded to a literal year:
-- a hardcoded year silently falls outside the window whenever as_of_date moves,
-- and then no month ever sees two customers.
--   • Anchored 2-4 whole months before as_of_date, on day 15, so the transfer
--     month always carries readings both before and after the transfer and
--     fact_meter_readings_monthly reports customer_changed_mid_month=true.
--   • Landing in the last few months also keeps transfer_date after any
--     rate-switch date (raw_service_agreement's switch_date), so the switcher
--     agreement slices stay correctly ordered.

CREATE OR REFRESH MATERIALIZED VIEW raw_account_reassignment
COMMENT 'Account ownership reassignment episode — exactly one row. Records the single premise where account ownership transferred from a prior customer (from_customer_id) to the current customer (to_customer_id, agrees with dim_account) at a deterministic mid-month date inside the display window. Consumed by bridge_customer_account (two dated ownership rows) and raw_service_agreement (pre/post agreement split, driving customer_changed_mid_month). PK: account_id (one row only).'
AS

-- Candidate transfer date per premise: day 15 of a month 2-4 months before
-- as_of_date. Derived from the window params so it moves with as_of_date.
WITH dated AS (
  SELECT
    m.premise_id,
    m.prior_customer_id                        AS from_customer_id,
    m.current_customer_id                      AS to_customer_id,
    DATE_ADD(
      TRUNC(
        ADD_MONTHS(
          DATE'${as_of_date}',
          -(2 + CAST(abs(xxhash64(m.premise_id, 'reassign_month', ${random_seed})) % 3 AS INT))
        ),
        'MM'
      ),
      14
    )                                          AS transfer_date
  FROM raw_premise_customer_map m
  WHERE m.has_prior_customer
    AND m.mover_role IS NULL
    AND m.occupancy_class = 'Residential'
),

-- Keep only premises whose current tenancy strictly contains the transfer date,
-- and whose transfer date is inside the display window.
--
-- The rate_schedule guard excludes rate SWITCHERS (res_d8_ev, and the ~half of
-- res_d3 that switch). A switcher's current agreement starts at its switch_date
-- rather than at link_start_date, so transfer_date could fall before the
-- agreement even opens — raw_service_agreement would then decline to split it
-- and no month would carry customer_changed_mid_month=true. Excluding the two
-- switch-eligible rate schedules outright keeps the fixture robust without
-- duplicating the switch-draw logic here.
eligible AS (
  SELECT
    d.premise_id,
    apl.account_id,
    d.from_customer_id,
    d.to_customer_id,
    d.transfer_date,
    ROW_NUMBER() OVER (
      ORDER BY abs(xxhash64(d.premise_id, 'acct_reassign_pick', ${random_seed}))
    )                                          AS rn
  FROM dated d
  JOIN raw_account_premise_link apl
    ON apl.premise_id = d.premise_id
   AND apl.account_id = md5(CONCAT(d.premise_id, '_acct'))
   AND apl.link_start_date < d.transfer_date
   AND apl.link_end_date IS NULL
  JOIN raw_customer_account ca
    ON ca.account_id = apl.account_id
   AND ca.account_group = 'standard'
   AND ca.current_status = 'active'
   AND ca.rate_schedule NOT IN ('res_d8_ev', 'res_d3')
  WHERE d.transfer_date > DATE_ADD(
          ADD_MONTHS(DATE'${as_of_date}', -CAST('${history_months}' AS INT)), 1)
    AND d.transfer_date < DATE'${as_of_date}'
)

SELECT
  account_id,
  from_customer_id,
  to_customer_id,
  transfer_date,
  current_timestamp()                          AS _ingested_at
FROM eligible
WHERE rn = 1;
