-- Demo config anchor — the single app-side source of truth for "now" and the
-- display window (temporal-realism-scoping §3).
-- App queries CROSS JOIN this 1-row table and express windows relative to
-- cfg.as_of_date (e.g. DATE_SUB(cfg.as_of_date, cfg.complaint_window_days))
-- instead of a literal DATE'2018-12-31'. Static/derived from bundle vars —
-- same "small reference table" shape as ref_cx_targets, but sourced from
-- ${as_of_date}/${history_months} rather than a hand-authored VALUES list.
--
-- complaint_window_days / billing_lookback_months are fixed display-window
-- conventions (90-day trailing complaint theme window, 12-month trailing
-- billing history), not independently configurable bundle vars — they're
-- exposed here so the app has one non-literal place to read them from.

CREATE OR REFRESH MATERIALIZED VIEW curated_demo_config
COMMENT 'Demo config anchor — the app''s single source of truth for "now" (as_of_date) and the display window (history_months), plus the fixed complaint/billing lookback conventions. Always exactly 1 row; app queries CROSS JOIN it instead of hardcoding date literals.'
AS
SELECT
  DATE'${as_of_date}'                    AS as_of_date,
  CAST('${history_months}' AS INT)       AS history_months,
  90                                     AS complaint_window_days,
  12                                     AS billing_lookback_months,
  current_timestamp()                    AS _ingested_at;
