-- ============================================================
-- MAF CRM — Revenue Forecast View
-- Deploy via Supabase SQL Editor (copy + paste + Run)
-- ============================================================

-- ============================================================
-- REVENUE FORECAST: Weighted pipeline by month
-- Shows estimated revenue by close month,
-- weighted by close probability
-- ============================================================
CREATE OR REPLACE VIEW crm_revenue_forecast AS
SELECT
  DATE_TRUNC('month', d.close_date) AS close_month,
  d.stage,
  d.deal_type,
  COUNT(*) AS deal_count,
  SUM(d.estimated_value) AS total_estimated,
  SUM(d.estimated_value * d.close_probability / 100.0) AS total_weighted,
  AVG(d.close_probability) AS avg_close_probability,
  
  -- Breakdown by stage category
  COUNT(*) FILTER (WHERE d.stage IN ('lead', 'contacted')) AS early_stage_count,
  SUM(d.estimated_value * d.close_probability / 100.0) FILTER (WHERE d.stage IN ('lead', 'contacted')) AS early_stage_weighted,
  
  COUNT(*) FILTER (WHERE d.stage IN ('discovery_booked', 'discovery_completed', 'audit_delivered')) AS mid_stage_count,
  SUM(d.estimated_value * d.close_probability / 100.0) FILTER (WHERE d.stage IN ('discovery_booked', 'discovery_completed', 'audit_delivered')) AS mid_stage_weighted,
  
  COUNT(*) FILTER (WHERE d.stage IN ('proposal_sent', 'negotiating')) AS late_stage_count,
  SUM(d.estimated_value * d.close_probability / 100.0) FILTER (WHERE d.stage IN ('proposal_sent', 'negotiating')) AS late_stage_weighted,
  
  COUNT(*) FILTER (WHERE d.stage = 'closed_won') AS won_count,
  SUM(d.estimated_value) FILTER (WHERE d.stage = 'closed_won') AS won_value,
  
  COUNT(*) FILTER (WHERE d.stage = 'closed_lost') AS lost_count,
  SUM(d.estimated_value) FILTER (WHERE d.stage = 'closed_lost') AS lost_value

FROM crm_deals d
WHERE d.close_date IS NOT NULL
  AND d.stage NOT IN ('closed_won', 'closed_lost')
GROUP BY 
  DATE_TRUNC('month', d.close_date),
  d.stage,
  d.deal_type
ORDER BY close_month ASC;

-- ============================================================
-- PIPELINE HEALTH: Conversion rates between stages
-- ============================================================
CREATE OR REPLACE VIEW crm_pipeline_health AS
SELECT
  ps.stage,
  ps.stage_order,
  ps.close_probability,
  COUNT(d.id) AS deal_count,
  COALESCE(SUM(d.estimated_value), 0) AS total_value,
  COALESCE(SUM(d.estimated_value * d.close_probability / 100.0), 0) AS total_weighted,
  AVG(EXTRACT(EPOCH FROM (now() - d.stage_entered_at))/86400) AS avg_days_in_stage,
  
  -- Conversion to next stage (count of deals that moved past this stage)
  LEAD(COUNT(d.id)) OVER (ORDER BY ps.stage_order) AS next_stage_count,
  CASE 
    WHEN COUNT(d.id) > 0 
    THEN ROUND(
      LEAD(COUNT(d.id)) OVER (ORDER BY ps.stage_order)::numeric / 
      COUNT(d.id) * 100, 1
    )
    ELSE 0 
  END AS conversion_to_next_pct

FROM crm_pipeline_stages ps
LEFT JOIN crm_deals d ON d.stage = ps.stage
WHERE ps.stage NOT IN ('closed_won', 'closed_lost')
GROUP BY ps.stage, ps.stage_order, ps.close_probability
ORDER BY ps.stage_order;

-- Enable security_invoker
ALTER VIEW crm_revenue_forecast SET (security_invoker = true);
ALTER VIEW crm_pipeline_health SET (security_invoker = true);

-- Verification
-- SELECT * FROM crm_revenue_forecast LIMIT 5;
-- SELECT * FROM crm_pipeline_health;