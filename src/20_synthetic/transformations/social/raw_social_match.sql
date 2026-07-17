-- Social Match — confidence score linking a social mention back to a
-- known customer record. In reality, social platforms don't share
-- customer identity; you have to fuzzy-match the social handle
-- (display name, profile city, post content) against customer records.
--
-- We model the match outcome with a confidence band:
--   high    ~70% - clear handle/profile match
--   medium  ~22% - probable match but ambiguous
--   low      ~8% - guess based on weak signals
--
-- For the demo, we know the true customer_id (synthesis-time ground
-- truth). The curated layer can choose to drop low-confidence matches
-- depending on the use case (high-confidence for the CSR view's
-- per-customer drill-down; all bands for CCO sentiment aggregation).

CREATE OR REFRESH MATERIALIZED VIEW raw_social_match (
  CONSTRAINT non_null_match_id      EXPECT (match_id IS NOT NULL),
  CONSTRAINT non_null_mention_id    EXPECT (mention_id IS NOT NULL),
  CONSTRAINT valid_confidence       EXPECT (confidence_band IN ('high','medium','low')),
  CONSTRAINT valid_score            EXPECT (match_score BETWEEN 0.0 AND 1.0)
)
COMMENT 'Social Match - confidence band for the (mention -> customer) link. Real-world social data isn''t directly customer-linked; this models the fuzzy-match step. PK: match_id. FK: mention_id -> social_mention.'
AS

WITH base AS (
  SELECT
    m.mention_id,
    m.customer_id                                                    AS ground_truth_customer_id,
    abs(xxhash64(m.mention_id, 'match_band', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_band,
    abs(xxhash64(m.mention_id, 'match_score', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_score,
    abs(xxhash64(m.mention_id, 'match_method', ${random_seed}))
      / CAST(9223372036854775807 AS DOUBLE)                          AS r_method
  FROM raw_social_mention m
)

SELECT
  md5(CONCAT(mention_id, '_match'))                                  AS match_id,
  mention_id,
  ground_truth_customer_id                                           AS matched_customer_id,

  CASE
    WHEN r_band < 0.70 THEN 'high'
    WHEN r_band < 0.92 THEN 'medium'
    ELSE                    'low'
  END                                                                AS confidence_band,

  -- match_score 0-1: high band 0.85-0.99, medium 0.55-0.85, low 0.20-0.55
  ROUND(
    CASE
      WHEN r_band < 0.70 THEN 0.85 + r_score * 0.14
      WHEN r_band < 0.92 THEN 0.55 + r_score * 0.30
      ELSE                    0.20 + r_score * 0.35
    END
  , 3)                                                               AS match_score,

  -- Matching method describes the strongest signal that produced the link.
  CASE
    WHEN r_band < 0.70 AND r_method < 0.55 THEN 'handle_exact'
    WHEN r_band < 0.70                      THEN 'name_plus_city'
    WHEN r_band < 0.92 AND r_method < 0.50 THEN 'name_only'
    WHEN r_band < 0.92                      THEN 'profile_keywords'
    WHEN r_method < 0.60                    THEN 'content_keywords'
    ELSE                                         'weak_geo_inference'
  END                                                                AS matching_method,

  current_timestamp()                                                AS _ingested_at
FROM base;
