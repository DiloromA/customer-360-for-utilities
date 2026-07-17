-- Complaint-risk feature table — one row per customer × billing cycle
-- (customer_id, bill_period_end). The generator rolls the complaint dice
-- once per bill, so this grain matches the data-generating process and
-- turns ~2 years of history into a large training set with natural
-- time-based splits.
--
-- Every feature is recomputed from the curated facts as-of the cycle end.
-- fact_customer_complaints carries the generator's diagnostic
-- fields (bill_shock_pct, outages_count_30d, ...) but only on complaint
-- rows — the ~97% of customer-cycles with no complaint have nothing
-- there, and those are exactly the rows scoring has to score. So the
-- complaint fact contributes history features only (prior counts,
-- recency, categories).
--
-- Labels (label_any + one per category head) are joined from complaints
-- filed in the 30 days AFTER bill_period_end — the generator lands
-- complaints 2-27 days after period end, so the window captures the
-- cycle's own dice roll. This is the ONLY place the label is read;
-- scoring (score.py) consumes the feature side only.

CREATE OR REFRESH MATERIALIZED VIEW ml_complaint_risk_features (
  CONSTRAINT non_null_customer_id EXPECT (customer_id IS NOT NULL),
  CONSTRAINT non_null_period_end  EXPECT (bill_period_end IS NOT NULL)
)
COMMENT 'Customer x billing-cycle features for 30-day complaint-risk prediction. Recomputed from curated billing/outage/payment/contact facts as-of each bill_period_end. Labels (label_any + per-category) joined from complaints in the following 30 days, for training/validation only — inference does not use them. PK: (customer_id, bill_period_end).'
AS

WITH bills AS (
  -- Collapse to the customer x cycle grain. Multi-account customers
  -- (multi-site commercial chains) get summed charges/balances and the
  -- worst per-account shock — one shocked site is enough to trigger a
  -- complaint, which is also how the generator rolls (per bill).
  -- COUNT(DISTINCT account_id), not COUNT(*): a relocation's transition
  -- month bills the SAME account across two usage_points (temporal-realism
  -- §5.1/§5.2), producing two bill rows for one account — COUNT(*) would
  -- misread a residential mover's move month as a 2-site chain.
  SELECT
    b.customer_id,
    b.bill_period_end,
    COUNT(DISTINCT b.account_id)               AS n_accounts_billed,
    SUM(b.current_charges)                     AS current_charges,
    SUM(b.total_kwh)                           AS total_kwh,
    MAX(b.bill_shock_pct)                      AS bill_shock_pct,
    MAX(b.yoy_bill_change_pct)                 AS yoy_bill_change_pct,
    MAX(b.yoy_kwh_change_pct)                  AS yoy_kwh_change_pct,
    SUM(b.previous_balance)                    AS previous_balance,
    SUM(b.unpaid_carry)                        AS unpaid_carry,
    MAX(CAST(rs.is_time_of_use AS INT))        AS on_tou_rate_flag,
    MAX(CAST(rs.is_medical_baseline AS INT))   AS medical_baseline_flag
  FROM ${curated_schema}.fact_customer_billing b
  LEFT JOIN ${curated_schema}.dim_rate_schedule rs
    ON rs.rate_schedule_id = b.rate_schedule
  GROUP BY b.customer_id, b.bill_period_end
)

, cycles AS (
  SELECT customer_id, bill_period_end FROM bills
)

, outage_exposure AS (
  -- Same 30d window the generator uses (affected_start within the 30
  -- days ending at period end), plus a 90d view for slower-burn signal.
  SELECT
    c.customer_id,
    c.bill_period_end,
    SUM(CASE WHEN oci.affected_start >= c.bill_period_end - INTERVAL 30 DAYS
             THEN 1 ELSE 0 END)                                        AS outages_count_30d,
    SUM(CASE WHEN oci.affected_start >= c.bill_period_end - INTERVAL 30 DAYS
             THEN oci.minutes_out ELSE 0 END)                          AS outage_minutes_30d,
    MAX(CASE WHEN oci.affected_start >= c.bill_period_end - INTERVAL 30 DAYS
             THEN oci.minutes_out END)                                 AS max_outage_minutes_30d,
    COUNT(*)                                                           AS outages_count_90d,
    SUM(oci.minutes_out)                                               AS outage_minutes_90d,
    DATEDIFF(c.bill_period_end, MAX(DATE(oci.affected_start)))         AS days_since_last_outage
  FROM cycles c
  JOIN ${curated_schema}.fact_outage_customer_impact oci
    ON oci.customer_id = c.customer_id
   AND oci.affected_start BETWEEN c.bill_period_end - INTERVAL 90 DAYS
                              AND c.bill_period_end
  GROUP BY c.customer_id, c.bill_period_end
)

, payment_behavior AS (
  SELECT
    c.customer_id,
    c.bill_period_end,
    SUM(CASE WHEN p.days_late > 0 THEN 1 ELSE 0 END)                   AS late_payments_90d,
    AVG(p.days_late)                                                   AS avg_days_late_90d
  FROM cycles c
  JOIN ${curated_schema}.fact_payment_history p
    ON p.customer_id = c.customer_id
   AND p.payment_date > c.bill_period_end - INTERVAL 90 DAYS
   AND p.payment_date <= c.bill_period_end
  GROUP BY c.customer_id, c.bill_period_end
)

, assistance AS (
  SELECT
    c.customer_id,
    c.bill_period_end,
    1 AS assistance_enrolled_flag
  FROM cycles c
  JOIN ${curated_schema}.fact_assistance_enrollment ae
    ON ae.customer_id = c.customer_id
   AND ae.enrollment_date <= c.bill_period_end
  GROUP BY c.customer_id, c.bill_period_end
)

, complaint_history AS (
  -- Strictly at-or-before the as-of date; the label window is strictly
  -- after it, so history and label can never see the same complaint.
  SELECT
    c.customer_id,
    c.bill_period_end,
    COUNT(*)                                                           AS prior_complaints_365d,
    SUM(CASE WHEN cc.complaint_date > c.bill_period_end - INTERVAL 90 DAYS
             THEN 1 ELSE 0 END)                                        AS prior_complaints_90d,
    DATEDIFF(c.bill_period_end, MAX(cc.complaint_date))                AS days_since_last_complaint,
    SUM(CASE WHEN cc.category = 'billing'         THEN 1 ELSE 0 END)   AS prior_billing_complaints_365d,
    SUM(CASE WHEN cc.category = 'outage'          THEN 1 ELSE 0 END)   AS prior_outage_complaints_365d,
    SUM(CASE WHEN cc.category = 'billing_process' THEN 1 ELSE 0 END)   AS prior_payment_complaints_365d,
    SUM(CASE WHEN cc.category IN ('customer_service','service_quality','program')
             THEN 1 ELSE 0 END)                                        AS prior_service_complaints_365d
  FROM cycles c
  JOIN ${curated_schema}.fact_customer_complaints cc
    ON cc.customer_id = c.customer_id
   AND cc.complaint_date > c.bill_period_end - INTERVAL 365 DAYS
   AND cc.complaint_date <= c.bill_period_end
  GROUP BY c.customer_id, c.bill_period_end
)

, csr_history AS (
  SELECT
    c.customer_id,
    c.bill_period_end,
    COUNT(*)                                                           AS csr_contacts_90d,
    AVG(i.csat_score_1_5)                                              AS avg_csat_90d
  FROM cycles c
  JOIN ${curated_schema}.fact_csr_interactions i
    ON i.customer_id = c.customer_id
   AND i.started_at > c.bill_period_end - INTERVAL 90 DAYS
   AND i.started_at <= c.bill_period_end
  GROUP BY c.customer_id, c.bill_period_end
)

, survey AS (
  SELECT
    c.customer_id,
    c.bill_period_end,
    MAX_BY(s.score_0_10, s.response_date)                              AS latest_nps_365d
  FROM cycles c
  JOIN ${curated_schema}.fact_survey_responses s
    ON s.customer_id = c.customer_id
   AND s.response_date > c.bill_period_end - INTERVAL 365 DAYS
   AND s.response_date <= c.bill_period_end
   AND s.score_0_10 IS NOT NULL
  GROUP BY c.customer_id, c.bill_period_end
)

, digital AS (
  -- Low portal engagement + mail preference correlates with phone
  -- complaints; engaged customers self-serve.
  SELECT
    c.customer_id,
    c.bill_period_end,
    COUNT(*)                                                           AS digital_events_90d
  FROM cycles c
  JOIN ${curated_schema}.fact_digital_engagement de
    ON de.customer_id = c.customer_id
   AND de.event_timestamp > c.bill_period_end - INTERVAL 90 DAYS
   AND de.event_timestamp <= c.bill_period_end
  GROUP BY c.customer_id, c.bill_period_end
)

, profile AS (
  SELECT
    customer_id,
    customer_class,
    income_band,
    household_size,
    tenure,
    language_preference,
    CAST(critical_care_flag AS INT) AS critical_care_flag
  FROM ${curated_schema}.dim_customer
)

, account AS (
  -- Exactly one standard / corporate-parent account per current customer
  -- (same selection the generator uses for channel preference).
  SELECT
    customer_id,
    preferred_channel,
    CAST(autopay_enrolled   AS INT) AS autopay_enrolled_flag,
    CAST(paperless_enrolled AS INT) AS paperless_enrolled_flag,
    account_tenure_years
  FROM ${curated_schema}.dim_account
  WHERE account_group IN ('standard', 'corporate_parent')
)

, labels AS (
  -- Complaint filed in the 30 days AFTER the as-of date. The 6 raw
  -- categories collapse to 4 heads with distinct outreach playbooks.
  SELECT
    c.customer_id,
    c.bill_period_end,
    1                                                                  AS label_any,
    MAX(CASE WHEN cc.category = 'billing'         THEN 1 ELSE 0 END)   AS label_billing,
    MAX(CASE WHEN cc.category = 'outage'          THEN 1 ELSE 0 END)   AS label_outage,
    MAX(CASE WHEN cc.category = 'billing_process' THEN 1 ELSE 0 END)   AS label_payment,
    MAX(CASE WHEN cc.category IN ('customer_service','service_quality','program')
             THEN 1 ELSE 0 END)                                        AS label_service
  FROM cycles c
  JOIN ${curated_schema}.fact_customer_complaints cc
    ON cc.customer_id = c.customer_id
   AND cc.complaint_date >  c.bill_period_end
   AND cc.complaint_date <= c.bill_period_end + INTERVAL 30 DAYS
  GROUP BY c.customer_id, c.bill_period_end
)

SELECT
  b.customer_id,
  b.bill_period_end,

  -- Billing (the generator's dominant driver family)
  b.n_accounts_billed,
  ROUND(b.current_charges, 2)                  AS current_charges,
  ROUND(b.total_kwh, 1)                        AS total_kwh,
  ROUND(b.bill_shock_pct, 3)                   AS bill_shock_pct,
  ROUND(b.yoy_bill_change_pct, 3)              AS yoy_bill_change_pct,
  ROUND(b.yoy_kwh_change_pct, 3)               AS yoy_kwh_change_pct,
  ROUND(b.previous_balance, 2)                 AS previous_balance,
  ROUND(b.unpaid_carry, 2)                     AS unpaid_carry,
  COALESCE(b.on_tou_rate_flag, 0)              AS on_tou_rate_flag,
  COALESCE(b.medical_baseline_flag, 0)         AS medical_baseline_flag,

  -- Outage exposure
  COALESCE(o.outages_count_30d, 0)             AS outages_count_30d,
  COALESCE(o.outage_minutes_30d, 0)            AS outage_minutes_30d,
  COALESCE(o.max_outage_minutes_30d, 0)        AS max_outage_minutes_30d,
  COALESCE(o.outages_count_90d, 0)             AS outages_count_90d,
  COALESCE(o.outage_minutes_90d, 0)            AS outage_minutes_90d,
  COALESCE(o.days_since_last_outage, 999)      AS days_since_last_outage,

  -- Arrears & payments
  COALESCE(p.late_payments_90d, 0)             AS late_payments_90d,
  ROUND(COALESCE(p.avg_days_late_90d, 0), 1)   AS avg_days_late_90d,
  COALESCE(a.assistance_enrolled_flag, 0)      AS assistance_enrolled_flag,

  -- Contact & sentiment history
  COALESCE(ch.prior_complaints_90d, 0)         AS prior_complaints_90d,
  COALESCE(ch.prior_complaints_365d, 0)        AS prior_complaints_365d,
  COALESCE(ch.days_since_last_complaint, 999)  AS days_since_last_complaint,
  COALESCE(ch.prior_billing_complaints_365d, 0)  AS prior_billing_complaints_365d,
  COALESCE(ch.prior_outage_complaints_365d, 0)   AS prior_outage_complaints_365d,
  COALESCE(ch.prior_payment_complaints_365d, 0)  AS prior_payment_complaints_365d,
  COALESCE(ch.prior_service_complaints_365d, 0)  AS prior_service_complaints_365d,
  COALESCE(cs.csr_contacts_90d, 0)             AS csr_contacts_90d,
  ROUND(COALESCE(cs.avg_csat_90d, -1), 2)      AS avg_csat_90d,
  COALESCE(sv.latest_nps_365d, -1)             AS latest_nps_365d,
  COALESCE(d.digital_events_90d, 0)            AS digital_events_90d,

  -- Profile (features + stratification + outreach-channel output)
  pr.customer_class,
  pr.income_band,
  pr.household_size,
  pr.tenure,
  pr.language_preference,
  COALESCE(pr.critical_care_flag, 0)           AS critical_care_flag,
  ac.preferred_channel,
  COALESCE(ac.autopay_enrolled_flag, 0)        AS autopay_enrolled_flag,
  COALESCE(ac.paperless_enrolled_flag, 0)      AS paperless_enrolled_flag,
  COALESCE(ac.account_tenure_years, 0)         AS account_tenure_years,

  -- Labels (training/validation only)
  COALESCE(l.label_any, 0)                     AS label_any,
  COALESCE(l.label_billing, 0)                 AS label_billing,
  COALESCE(l.label_outage, 0)                  AS label_outage,
  COALESCE(l.label_payment, 0)                 AS label_payment,
  COALESCE(l.label_service, 0)                 AS label_service,

  current_timestamp() AS _ingested_at
FROM bills b
LEFT JOIN outage_exposure   o  ON o.customer_id  = b.customer_id AND o.bill_period_end  = b.bill_period_end
LEFT JOIN payment_behavior  p  ON p.customer_id  = b.customer_id AND p.bill_period_end  = b.bill_period_end
LEFT JOIN assistance        a  ON a.customer_id  = b.customer_id AND a.bill_period_end  = b.bill_period_end
LEFT JOIN complaint_history ch ON ch.customer_id = b.customer_id AND ch.bill_period_end = b.bill_period_end
LEFT JOIN csr_history       cs ON cs.customer_id = b.customer_id AND cs.bill_period_end = b.bill_period_end
LEFT JOIN survey            sv ON sv.customer_id = b.customer_id AND sv.bill_period_end = b.bill_period_end
LEFT JOIN digital           d  ON d.customer_id  = b.customer_id AND d.bill_period_end  = b.bill_period_end
LEFT JOIN profile           pr ON pr.customer_id = b.customer_id
LEFT JOIN account           ac ON ac.customer_id = b.customer_id
LEFT JOIN labels            l  ON l.customer_id  = b.customer_id AND l.bill_period_end  = b.bill_period_end;
