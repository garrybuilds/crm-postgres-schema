-- ============================================================
-- MAF CRM — Funnel Tracking Views
-- Deploy via Supabase SQL Editor (copy + paste + Run)
-- Source: brain/2_Areas/maf/areas/operations/cold-email-system/funnel-tracking-dashboard.md
-- ============================================================

-- ============================================================
-- FUNNEL DASHBOARD: Daily funnel metrics for cold email tracking
-- ============================================================
CREATE OR REPLACE VIEW crm_funnel_dashboard AS
SELECT
  -- Date dimension
  DATE_TRUNC('day', a.occurred_at) AS funnel_date,
  
  -- Campaign dimension (from deal meta or company meta)
  COALESCE(
    d.meta->>'campaign',
    c.meta->>'campaign',
    'unassigned'
  ) AS campaign,
  
  -- Vertical dimension
  COALESCE(
    c.industry,
    'unknown'
  ) AS vertical,
  
  -- Segment dimension
  COALESCE(
    c.meta->>'icp_segment',
    'A'
  ) AS segment,
  
  -- Funnel stage counts
  COUNT(*) FILTER (WHERE a.activity_type = 'email_sent') AS emails_sent,
  COUNT(*) FILTER (WHERE a.activity_type = 'email_opened') AS emails_opened,
  COUNT(*) FILTER (WHERE a.activity_type = 'email_replied') AS emails_replied,
  COUNT(*) FILTER (WHERE a.activity_type = 'email_positive_reply') AS positive_replies,
  COUNT(*) FILTER (WHERE a.activity_type = 'call_booked') AS calls_booked,
  COUNT(*) FILTER (WHERE a.activity_type = 'call_held') AS calls_held,
  COUNT(*) FILTER (WHERE a.activity_type = 'call_no_show') AS calls_no_show,
  COUNT(*) FILTER (WHERE a.activity_type = 'growth_blocker_completed') AS growth_blockers_delivered,
  COUNT(*) FILTER (WHERE a.activity_type = 'proposal_sent') AS proposals_sent,
  COUNT(*) FILTER (WHERE a.activity_type = 'deal_closed_won') AS deals_won,
  COUNT(*) FILTER (WHERE a.activity_type = 'deal_closed_lost') AS deals_lost

FROM crm_activities a
LEFT JOIN crm_deals d ON a.deal_id = d.id
LEFT JOIN crm_companies c ON a.company_id = c.id
WHERE a.activity_type IN (
  'email_sent', 'email_opened', 'email_replied', 'email_positive_reply',
  'call_booked', 'call_held', 'call_no_show',
  'growth_blocker_completed', 'proposal_sent',
  'deal_closed_won', 'deal_closed_lost'
)
GROUP BY 
  DATE_TRUNC('day', a.occurred_at),
  COALESCE(d.meta->>'campaign', c.meta->>'campaign', 'unassigned'),
  COALESCE(c.industry, 'unknown'),
  COALESCE(c.meta->>'icp_segment', 'A')
ORDER BY funnel_date DESC;

-- ============================================================
-- CUMULATIVE FUNNEL: All-time totals + conversion rates
-- ============================================================
CREATE OR REPLACE VIEW crm_funnel_cumulative AS
SELECT
  COALESCE(c.meta->>'campaign', 'all') AS campaign,
  COALESCE(c.industry, 'all') AS vertical,
  
  COUNT(*) FILTER (WHERE a.activity_type = 'email_sent') AS total_emails_sent,
  COUNT(*) FILTER (WHERE a.activity_type = 'email_replied') AS total_replies,
  COUNT(*) FILTER (WHERE a.activity_type = 'email_positive_reply') AS total_positive_replies,
  COUNT(*) FILTER (WHERE a.activity_type = 'call_booked') AS total_calls_booked,
  COUNT(*) FILTER (WHERE a.activity_type = 'call_held') AS total_calls_held,
  COUNT(*) FILTER (WHERE a.activity_type = 'deal_closed_won') AS total_deals_won,
  
  -- Conversion rates
  CASE 
    WHEN COUNT(*) FILTER (WHERE a.activity_type = 'email_sent') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE a.activity_type = 'email_replied')::numeric / 
      COUNT(*) FILTER (WHERE a.activity_type = 'email_sent') * 100, 2
    )
    ELSE 0
  END AS reply_rate_pct,
  
  CASE 
    WHEN COUNT(*) FILTER (WHERE a.activity_type = 'email_replied') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE a.activity_type = 'email_positive_reply')::numeric / 
      COUNT(*) FILTER (WHERE a.activity_type = 'email_replied') * 100, 2
    )
    ELSE 0
  END AS positive_reply_rate_pct,
  
  CASE 
    WHEN COUNT(*) FILTER (WHERE a.activity_type = 'email_positive_reply') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE a.activity_type = 'call_booked')::numeric / 
      COUNT(*) FILTER (WHERE a.activity_type = 'email_positive_reply') * 100, 2
    )
    ELSE 0
  END AS booked_from_positive_pct,
  
  CASE 
    WHEN COUNT(*) FILTER (WHERE a.activity_type = 'call_booked') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE a.activity_type = 'call_held')::numeric / 
      COUNT(*) FILTER (WHERE a.activity_type = 'call_booked') * 100, 2
    )
    ELSE 0
  END AS show_rate_pct,
  
  CASE 
    WHEN COUNT(*) FILTER (WHERE a.activity_type = 'call_held') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE a.activity_type = 'deal_closed_won')::numeric / 
      COUNT(*) FILTER (WHERE a.activity_type = 'call_held') * 100, 2
    )
    ELSE 0
  END AS close_rate_pct,
  
  -- Net close (emails → deals)
  CASE 
    WHEN COUNT(*) FILTER (WHERE a.activity_type = 'email_sent') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE a.activity_type = 'deal_closed_won')::numeric / 
      COUNT(*) FILTER (WHERE a.activity_type = 'email_sent') * 100, 4
    )
    ELSE 0
  END AS net_close_rate_pct

FROM crm_activities a
LEFT JOIN crm_companies c ON a.company_id = c.id
WHERE a.activity_type IN (
  'email_sent', 'email_replied', 'email_positive_reply',
  'call_booked', 'call_held', 'deal_closed_won'
)
GROUP BY 
  COALESCE(c.meta->>'campaign', 'all'),
  COALESCE(c.industry, 'all')
ORDER BY total_emails_sent DESC;

-- ============================================================
-- DEAL VELOCITY: How fast deals move through stages
-- ============================================================
CREATE OR REPLACE VIEW crm_deal_velocity AS
SELECT
  d.id AS deal_id,
  c.company_name,
  c.industry AS vertical,
  d.stage,
  d.stage_entered_at,
  d.created_at AS deal_created,
  EXTRACT(EPOCH FROM (now() - d.stage_entered_at))/86400 AS days_in_current_stage,
  EXTRACT(EPOCH FROM (now() - d.created_at))/86400 AS days_since_creation,
  
  -- Count stage transitions (from activities)
  COUNT(a.id) FILTER (WHERE a.activity_type = 'stage_change') AS stage_transitions,
  
  -- Last activity
  MAX(a.occurred_at) AS last_activity_at,
  EXTRACT(EPOCH FROM (now() - MAX(a.occurred_at)))/86400 AS days_since_last_activity

FROM crm_deals d
LEFT JOIN crm_companies c ON d.company_id = c.id
LEFT JOIN crm_activities a ON a.deal_id = d.id
WHERE d.stage NOT IN ('closed_won', 'closed_lost')
GROUP BY d.id, c.company_name, c.industry, d.stage, d.stage_entered_at, d.created_at
ORDER BY days_in_current_stage DESC;

-- ============================================================
-- Enable security_invoker on all funnel views
-- ============================================================
ALTER VIEW crm_funnel_dashboard SET (security_invoker = true);
ALTER VIEW crm_funnel_cumulative SET (security_invoker = true);
ALTER VIEW crm_deal_velocity SET (security_invoker = true);

-- ============================================================
-- Verification queries (run after deployment)
-- ============================================================
-- SELECT * FROM crm_funnel_dashboard LIMIT 1;
-- SELECT * FROM crm_funnel_cumulative LIMIT 1;
-- SELECT * FROM crm_deal_velocity LIMIT 1;