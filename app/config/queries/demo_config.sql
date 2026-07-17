-- Demo config anchor (1 row) — lets client code derive display-window
-- options (e.g. CsatView's period picker) from curated_demo_config instead
-- of hardcoding calendar years.

SELECT as_of_date, history_months
FROM {{catalog}}.{{schema}}.curated_demo_config
