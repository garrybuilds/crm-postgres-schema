-- ============================================================
-- Migration: 20260808150200_create_saved_views.sql
-- Phase 5.4 — Saved Views System
-- ============================================================
-- Persists filter+sort+column layouts per user per entity.
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_saved_views (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type TEXT NOT NULL,
  name TEXT NOT NULL,
  view_type TEXT NOT NULL,         -- 'table', 'board', 'calendar'
  filters JSONB DEFAULT '[]',
  sorts JSONB DEFAULT '[]',
  column_layout JSONB DEFAULT '[]', -- column order, widths, visibility
  board_config JSONB DEFAULT '{}',  -- stage grouping for board view
  is_shared BOOLEAN DEFAULT false,
  is_default BOOLEAN DEFAULT false,
  created_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (entity_type, name, created_by)
);

CREATE INDEX IF NOT EXISTS idx_saved_views_entity ON sys_saved_views(entity_type, created_by);
CREATE INDEX IF NOT EXISTS idx_saved_views_default ON sys_saved_views(entity_type, is_default) WHERE is_default = true;

ALTER TABLE sys_saved_views ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users see own + shared views"
  ON sys_saved_views FOR SELECT TO authenticated
  USING (created_by = auth.uid() OR is_shared = true);

CREATE POLICY "users manage own views"
  ON sys_saved_views FOR ALL TO authenticated
  USING (created_by = auth.uid())
  WITH CHECK (created_by = auth.uid());