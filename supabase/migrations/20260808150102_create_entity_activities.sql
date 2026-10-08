-- ============================================================
-- Migration: 20260808150102_create_entity_activities.sql
-- Phase 2.10 — Polymorphic Activity Log
-- ============================================================
-- Creates crm_entity_activities — a NEW table for the polymorphic
-- activity pattern (entity_type + entity_id). This is SEPARATE from
-- the existing crm_activities table which uses deal_id/contact_id/company_id
-- FKs. Both coexist — the existing table handles sync activities, the
-- new table handles entity lifecycle logging (create/update/delete/convert).
--
-- Also adds a trigger to auto-log record changes on deals and companies.
--
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

CREATE TABLE IF NOT EXISTS crm_entity_activities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type TEXT NOT NULL,          -- 'lead', 'deal', 'company', 'contact'
  entity_id UUID NOT NULL,
  activity_type TEXT NOT NULL,        -- 'system', 'note', 'call', 'meeting', 'email', 'task', 'create', 'update', 'delete', 'convert'
  title TEXT,
  description TEXT,
  additional JSONB DEFAULT '{}',       -- change details: {"field": "stage", "old": "lead", "new": "contacted"}
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_entity_activities_entity ON crm_entity_activities(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_entity_activities_type ON crm_entity_activities(activity_type);
CREATE INDEX IF NOT EXISTS idx_entity_activities_created ON crm_entity_activities(created_at DESC);

ALTER TABLE crm_entity_activities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users see own tenant entity activities"
  ON crm_entity_activities FOR SELECT TO authenticated
  USING (entity_belongs_to_tenant(entity_id));

CREATE POLICY "users create own activities"
  ON crm_entity_activities FOR INSERT TO authenticated
  WITH CHECK (entity_belongs_to_tenant(entity_id));

CREATE POLICY "users update own activities"
  ON crm_entity_activities FOR UPDATE TO authenticated
  USING (entity_belongs_to_tenant(entity_id));

-- Auto-log trigger: creates 'system' activity on record update
CREATE OR REPLACE FUNCTION log_record_change()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  changes JSONB;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- Build a JSONB object of changed fields
    SELECT jsonb_object_agg(col, jsonb_build_object('old', to_jsonb(OLD -> col), 'new', to_jsonb(NEW -> col)))
    INTO changes
    FROM jsonb_each(to_jsonb(NEW))
    WHERE col NOT IN ('updated_at', 'created_at', 'computed_status')
      AND (OLD -> col) IS DISTINCT FROM (NEW -> col);

    IF changes IS NOT NULL AND changes != '{}'::jsonb THEN
      INSERT INTO crm_entity_activities (entity_type, entity_id, activity_type, title, additional, created_by)
      VALUES (TG_ARGV[0], NEW.id, 'update', 'Updated', jsonb_build_object('changes', changes), auth.uid());
    END IF;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO crm_entity_activities (entity_type, entity_id, activity_type, title, additional, created_by)
    VALUES (TG_ARGV[0], NEW.id, 'create', 'Created', jsonb_build_object('action', 'create'), auth.uid());
  END IF;
  RETURN NEW;
END;
$$;

-- Apply trigger to key tables (pass entity_type as trigger arg)
DROP TRIGGER IF EXISTS log_deal_changes ON crm_deals;
CREATE TRIGGER log_deal_changes AFTER INSERT OR UPDATE ON crm_deals
  FOR EACH ROW EXECUTE FUNCTION log_record_change('deal');

DROP TRIGGER IF EXISTS log_company_changes ON crm_companies;
CREATE TRIGGER log_company_changes AFTER INSERT OR UPDATE ON crm_companies
  FOR EACH ROW EXECUTE FUNCTION log_record_change('company');