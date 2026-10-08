-- ============================================================
-- Migration: 20260808150500_create_phase12_tables.sql
-- Phase 12 — Future (i18n, multi-currency, plugins, backup)
-- ============================================================
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

-- Multi-currency
CREATE TABLE IF NOT EXISTS sys_currencies (
  code TEXT PRIMARY KEY,            -- 'USD', 'EUR', 'GBP'
  symbol TEXT NOT NULL,
  exchange_rate NUMERIC NOT NULL,  -- relative to base currency (USD)
  is_active BOOLEAN DEFAULT true,
  updated_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO sys_currencies (code, symbol, exchange_rate) VALUES
  ('USD', '$', 1.0),
  ('EUR', '€', 0.92),
  ('GBP', '£', 0.79)
ON CONFLICT (code) DO NOTHING;

-- Plugin registry
CREATE TABLE IF NOT EXISTS sys_plugins (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  version TEXT NOT NULL,
  description TEXT,
  manifest JSONB NOT NULL,          -- {permissions, routes, hooks}
  is_active BOOLEAN DEFAULT false,
  installed_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE sys_plugins ENABLE ROW LEVEL SECURITY;
CREATE POLICY "maf_admin manage plugins" ON sys_plugins FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))));
CREATE POLICY "authenticated read plugins" ON sys_plugins FOR SELECT TO authenticated USING (true);

-- Backup log
CREATE TABLE IF NOT EXISTS sys_backup_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  backup_type TEXT NOT NULL,       -- 'full', 'incremental'
  status TEXT NOT NULL,            -- 'started', 'completed', 'failed'
  file_path TEXT,
  file_size_bytes BIGINT,
  error_message TEXT,
  started_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

ALTER TABLE sys_backup_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "maf_admin manage backup_log" ON sys_backup_log FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))));
CREATE POLICY "authenticated read backup_log" ON sys_backup_log FOR SELECT TO authenticated USING (true);

-- Y.js document storage (collaborative editing)
CREATE TABLE IF NOT EXISTS sys_yjs_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type TEXT NOT NULL,
  entity_id UUID NOT NULL,
  doc_name TEXT NOT NULL,          -- 'notes', 'description', 'proposal'
  content BYTEA,                   -- Y.js binary state
  last_updated_by UUID REFERENCES profiles(id),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (entity_type, entity_id, doc_name)
);

ALTER TABLE sys_yjs_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own tenant docs" ON sys_yjs_documents FOR SELECT TO authenticated
  USING (entity_belongs_to_tenant(entity_id));
CREATE POLICY "users write own tenant docs" ON sys_yjs_documents FOR ALL TO authenticated
  USING (entity_belongs_to_tenant(entity_id));

-- MCP tool registry (expose CRM tools via MCP protocol)
CREATE TABLE IF NOT EXISTS sys_mcp_tools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,       -- 'list-leads', 'create-deal', 'search-companies'
  description TEXT,
  input_schema JSONB NOT NULL,    -- JSON Schema for tool input
  handler TEXT NOT NULL,          -- Python module path to handler function
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE sys_mcp_tools ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated read mcp_tools" ON sys_mcp_tools FOR SELECT TO authenticated USING (true);
CREATE POLICY "maf_admin manage mcp_tools" ON sys_mcp_tools FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))));