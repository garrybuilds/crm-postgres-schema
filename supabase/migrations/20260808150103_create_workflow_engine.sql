-- ============================================================
-- Migration: 20260808150103_create_workflow_engine.sql
-- Phase 2.11 — Workflow Engine
-- ============================================================
-- Declarative workflow rules: when entity event fires + conditions match,
-- execute actions (update field, send email, create task, webhook).
--
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_workflows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  entity_type TEXT NOT NULL,          -- 'lead', 'deal', 'company'
  trigger_event TEXT NOT NULL,        -- 'on_create', 'on_update', 'on_status_change'
  conditions JSONB NOT NULL DEFAULT '[]',  -- [{"field": "stage", "operator": "eq", "value": "lead"}, {"logic": "AND"}]
  actions JSONB NOT NULL DEFAULT '[]',     -- [{"type": "update_field", "field": "assigned_to", "value": "garry"}, {"type": "send_email", "template": "welcome"}]
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sys_workflow_instances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID REFERENCES sys_workflows(id) ON DELETE CASCADE,
  entity_id UUID NOT NULL,
  entity_type TEXT NOT NULL,
  status TEXT DEFAULT 'pending',      -- 'pending', 'running', 'completed', 'failed'
  result JSONB,
  started_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_workflows_entity ON sys_workflows(entity_type, is_active);
CREATE INDEX IF NOT EXISTS idx_workflow_instances_entity ON sys_workflow_instances(entity_id);

ALTER TABLE sys_workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE sys_workflow_instances ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated read workflows"
  ON sys_workflows FOR SELECT TO authenticated USING (true);
CREATE POLICY "maf_admin manage workflows"
  ON sys_workflows FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))
  ));
CREATE POLICY "authenticated read workflow_instances"
  ON sys_workflow_instances FOR SELECT TO authenticated USING (true);