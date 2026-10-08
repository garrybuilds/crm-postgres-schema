-- ============================================================
-- Migration: 20260808150101_create_status_machine.sql
-- Phase 2.8 — Declarative Status State Machine
-- ============================================================
-- Adds computed_status column to deals + a SQL function to compute it.
-- The Python StatusUpdater service mirrors this logic for app-side use.
-- No new tables — this is a service-layer pattern with a DB function.
--
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

-- Add computed_status column to deals
ALTER TABLE crm_deals ADD COLUMN IF NOT EXISTS computed_status TEXT;

-- Function to compute deal status from stage
CREATE OR REPLACE FUNCTION compute_deal_status(deal_uuid UUID)
RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_stage TEXT;
BEGIN
  SELECT stage INTO v_stage FROM crm_deals WHERE id = deal_uuid;
  IF v_stage IS NULL THEN
    RETURN 'new';
  ELSIF v_stage = 'closed_won' THEN
    RETURN 'won';
  ELSIF v_stage = 'closed_lost' THEN
    RETURN 'lost';
  ELSIF v_stage IN ('proposal_sent', 'negotiating') THEN
    RETURN 'proposed';
  ELSIF v_stage IN ('discovery_booked', 'discovery_completed') THEN
    RETURN 'in_progress';
  ELSE
    RETURN 'open';
  END IF;
END;
$$;

-- Trigger to auto-update computed_status on deal stage change
CREATE OR REPLACE FUNCTION update_deal_computed_status()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stage IS DISTINCT FROM OLD.stage OR TG_OP = 'INSERT' THEN
    NEW.computed_status := compute_deal_status(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_deal_computed_status ON crm_deals;
CREATE TRIGGER trg_deal_computed_status
  BEFORE INSERT OR UPDATE OF stage ON crm_deals
  FOR EACH ROW EXECUTE FUNCTION update_deal_computed_status();