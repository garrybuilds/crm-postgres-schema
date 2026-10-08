-- ============================================================
-- Migration: 20260808150003_create_settings.sql
-- Phase 1.4 — Settings table
-- ============================================================
-- Key-value settings store with JSONB values.
-- Used for CRM configuration: auto-close days, duplicate check fields, etc.
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_settings (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by UUID REFERENCES profiles(id)
);

ALTER TABLE sys_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated can read settings"
  ON sys_settings FOR SELECT TO authenticated USING (true);

CREATE POLICY "maf_admin can write settings"
  ON sys_settings FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (
      SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
    )
  ));

-- ============================================================
-- SEED DATA: Default settings
-- ============================================================
INSERT INTO sys_settings (key, value, description) VALUES
  ('crm.auto_close_days', '30', 'Auto-close opportunities after N days of inactivity'),
  ('crm.carry_forward_activities', 'true', 'Carry forward activities on entity conversion'),
  ('crm.duplicate_check_fields', '["email","phone","company_name"]', 'Fields to check for duplicates'),
  ('crm.default_pipeline_id', 'null', 'Default pipeline ID for new leads'),
  ('webhook.timeout_seconds', '30', 'Webhook execution timeout in seconds'),
  ('webhook.max_retries', '3', 'Max webhook retry attempts'),
  ('agent.discord_notify', 'false', 'Send Discord notifications for approval requests'),
  ('agent.budget_daily_limit', '1000', 'Daily token budget limit for agent operations'),
  ('ui.default_theme', '"dark"', 'Default UI theme for new users'),
  ('ui.records_per_page', '50', 'Default records per page in list views')
ON CONFLICT (key) DO NOTHING;