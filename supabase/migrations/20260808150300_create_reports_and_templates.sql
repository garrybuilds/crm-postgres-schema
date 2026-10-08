-- ============================================================
-- Migration: 20260808150300_create_reports_and_templates.sql
-- Phase 9 — Reports, Dashboard Cards, Print Templates
-- ============================================================
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

-- Reports
CREATE TABLE IF NOT EXISTS sys_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  type TEXT NOT NULL,              -- 'script', 'query', 'visual'
  entity_type TEXT,
  config JSONB NOT NULL,          -- columns, filters, aggregations, chart config
  created_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sys_dashboard_cards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dashboard_id UUID,
  report_id UUID REFERENCES sys_reports(id) ON DELETE CASCADE,
  aggregation TEXT,               -- 'count', 'sum', 'avg'
  filters JSONB DEFAULT '[]',
  position JSONB,                 -- {x, y, w, h} for grid layout
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dashboard_cards_report ON sys_dashboard_cards(report_id);

ALTER TABLE sys_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE sys_dashboard_cards ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated read reports" ON sys_reports FOR SELECT TO authenticated USING (true);
CREATE POLICY "maf_admin manage reports" ON sys_reports FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))));
CREATE POLICY "authenticated read dashboard_cards" ON sys_dashboard_cards FOR SELECT TO authenticated USING (true);

-- Print templates
CREATE TABLE IF NOT EXISTS sys_print_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  template_type TEXT NOT NULL,    -- 'quote', 'proposal', 'invoice'
  html_content TEXT NOT NULL,     -- Jinja2 template
  css_content TEXT,
  is_default BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE sys_print_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated read print_templates" ON sys_print_templates FOR SELECT TO authenticated USING (true);
CREATE POLICY "maf_admin manage print_templates" ON sys_print_templates FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))));