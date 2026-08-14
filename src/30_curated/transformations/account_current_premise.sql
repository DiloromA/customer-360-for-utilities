-- Grain: one row per account that currently has an active premise assignment.
-- Accounts with no current link — including corporate_parent accounts — have no
-- row, so a LEFT JOIN degrades to NULL rather than silently dropping the account.
--
-- This is the one place to ask "what premise is this account at right now."
-- A dimension column cannot answer it, because an account can move; the full
-- effective-dated history lives in bridge_account_premise.
--
-- account_number is projected alongside account_id so a consumer keyed on
-- account_number reaches the premise in a single LEFT JOIN.

CREATE OR REFRESH MATERIALIZED VIEW account_current_premise (
  account_id       BIGINT NOT NULL,
  account_number   STRING NOT NULL,
  premise_id       BIGINT NOT NULL,
  premise_number   STRING NOT NULL,
  link_start_date  DATE,
  _ingested_at     TIMESTAMP,
  CONSTRAINT fk_acp_account FOREIGN KEY (account_id) REFERENCES dim_account (account_id)  NOT ENFORCED RELY,
  CONSTRAINT fk_acp_premise FOREIGN KEY (premise_id) REFERENCES dim_premise  (premise_id) NOT ENFORCED RELY
)
COMMENT 'Current-premise seam — one row per account that has an active premise assignment today (bridge_account_premise WHERE is_current). No row for accounts with no current link (e.g. corporate_parent accounts), so a LEFT JOIN degrades to NULL. account_number carried so consumers need only one LEFT JOIN to reach the premise. FK: account_id -> dim_account; premise_id -> dim_premise.'
AS
SELECT
  a.account_id,
  a.account_number,
  b.premise_id,
  p.premise_number,
  b.link_start_date,
  current_timestamp()  AS _ingested_at
FROM bridge_account_premise b
JOIN dim_account a ON a.account_id  = b.account_id
JOIN dim_premise  p ON p.premise_id = b.premise_id
WHERE b.is_current;
