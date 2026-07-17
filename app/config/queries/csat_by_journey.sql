-- CSAT view — Row 3b journey/transaction-type breakdown. Genesys queue
-- mapped to a human journey label (billing, outage, payment arrangement,
-- move-in/out, DSM/EE program, general service).
--
-- Reads metric_csat. Same `Interaction Month` /
-- `Customer Class` caveats as csat_by_channel.sql apply here.

-- @param date_from STRING
-- @param date_to STRING
-- @param segment STRING  -- all | residential | commercial

SELECT
  `Queue` AS queue,
  CASE `Queue`
    WHEN 'BIL_INBOUND'      THEN 'Billing inquiry'
    WHEN 'BIL_PAYMENT_PLAN' THEN 'Payment arrangement'
    WHEN 'OUT_RESTORATION'  THEN 'Outage'
    WHEN 'TECH_FIELD'       THEN 'Technical / field'
    WHEN 'PRG_DSM'          THEN 'DSM / EE program'
    WHEN 'MOVE_START_STOP'  THEN 'Move-in / move-out'
    ELSE                         'General service'
  END                                                                                   AS journey,
  MEASURE(`Response Count`)                                                            AS n,
  ROUND(100.0 * MEASURE(`Top2Box Rate`), 1)                                            AS top2box_pct,
  ROUND(MEASURE(`Avg CSAT 1-5`), 2)                                                     AS mean_score
FROM {{catalog}}.{{schema}}.metric_csat
WHERE `Interaction Month` BETWEEN CAST(:date_from AS DATE) AND CAST(:date_to AS DATE)
  AND (:segment = 'all' OR LOWER(`Customer Class`) = :segment)
GROUP BY ALL
ORDER BY n DESC
