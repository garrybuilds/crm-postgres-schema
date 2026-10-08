-- ============================================================
-- Migration: 20260808150401_create_theming.sql
-- Phase 11.6 — CSS Custom Property Theming
-- ============================================================
-- Stores per-tenant theme overrides.
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_theme_overrides (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID REFERENCES sys_clients(id) ON DELETE CASCADE,
  theme_key TEXT NOT NULL DEFAULT 'accent_primary',  -- CSS variable name without --t- prefix
  theme_value TEXT NOT NULL,                          -- hex color or CSS value
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (client_id, theme_key)
);

ALTER TABLE sys_theme_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own client theme" ON sys_theme_overrides FOR SELECT TO authenticated
  USING (client_id IS NULL OR client_id = get_current_client_id());
CREATE POLICY "maf_admin manage theme" ON sys_theme_overrides FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))));