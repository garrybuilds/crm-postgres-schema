-- ============================================================
-- MAF CRM — Automated Stage Transitions
-- Deploy via Supabase SQL Editor (copy + paste + Run)
-- ============================================================
--
-- When an activity is inserted, auto-update the deal stage
-- based on the activity type. Only moves FORWARD — never backward.
-- Respects the one-open-deal-per-company constraint.
-- ============================================================

CREATE OR REPLACE FUNCTION auto_transition_deal_stage()
RETURNS TRIGGER AS $$
DECLARE
  v_deal_id UUID;
  v_current_stage TEXT;
  v_current_order INTEGER;
  v_target_stage TEXT;
  v_target_order INTEGER;
BEGIN
  -- Get the deal_id from the new activity
  v_deal_id := NEW.deal_id;
  
  -- Skip if no deal linked
  IF v_deal_id IS NULL THEN
    RETURN NEW;
  END IF;
  
  -- Map activity_type to target stage
  v_target_stage := CASE
    WHEN NEW.activity_type = 'email_replied' THEN 'contacted'
    WHEN NEW.activity_type = 'email_positive_reply' THEN 'contacted'
    WHEN NEW.activity_type = 'call_outcome' AND NEW.meta->>'outcome' = 'Connected' THEN 'contacted'
    WHEN NEW.activity_type = 'meeting_booked' THEN 'discovery_booked'
    WHEN NEW.activity_type = 'call_booked' THEN 'discovery_booked'
    WHEN NEW.activity_type = 'meeting_completed' THEN 'discovery_completed'
    WHEN NEW.activity_type = 'call_held' THEN 'discovery_completed'
    WHEN NEW.activity_type = 'growth_blocker_completed' THEN 'audit_delivered'
    WHEN NEW.activity_type = 'proposal_sent' THEN 'proposal_sent'
    ELSE NULL
  END;
  
  -- Skip if no mapping for this activity type
  IF v_target_stage IS NULL THEN
    RETURN NEW;
  END IF;
  
  -- Get current deal stage
  SELECT stage INTO v_current_stage FROM crm_deals WHERE id = v_deal_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;
  
  -- Skip if deal is already closed
  IF v_current_stage IN ('closed_won', 'closed_lost') THEN
    RETURN NEW;
  END IF;
  
  -- Get stage orders to ensure forward-only movement
  SELECT stage_order INTO v_current_order FROM crm_pipeline_stages WHERE stage = v_current_stage;
  SELECT stage_order INTO v_target_order FROM crm_pipeline_stages WHERE stage = v_target_stage;
  
  -- Skip if target is not forward progress
  IF v_target_order IS NULL OR v_current_order IS NULL THEN
    RETURN NEW;
  END IF;
  
  IF v_target_order <= v_current_order THEN
    RETURN NEW;  -- Don't move backward or stay same
  END IF;
  
  -- Update the deal stage (the existing trigger will set stage_entered_at + close_probability)
  UPDATE crm_deals 
  SET stage = v_target_stage,
      updated_at = now()
  WHERE id = v_deal_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop existing trigger if it exists (idempotent)
DROP TRIGGER IF EXISTS trg_activities_auto_stage ON crm_activities;

-- Create the trigger — fires AFTER INSERT on crm_activities
CREATE TRIGGER trg_activities_auto_stage
  AFTER INSERT ON crm_activities
  FOR EACH ROW
  EXECUTE FUNCTION auto_transition_deal_stage();

-- Verification
-- Test: Insert a mock activity and check if the deal stage moved
-- INSERT INTO crm_activities (deal_id, activity_type, channel, direction, subject, body)
-- VALUES ('<deal-uuid>', 'email_replied', 'smartlead', 'inbound', 'Test reply', 'Test')
-- Then check: SELECT stage FROM crm_deals WHERE id = '<deal-uuid>';