-- ============================================================
-- Migration: 20260808150000_create_schema_migrations.sql
-- Phase 1.2 — Migration versioning
-- ============================================================
-- Creates sys_schema_migrations table to track applied migrations.
-- The Python runner checks this table before executing any .sql file
-- and records the version + checksum after successful execution.
-- Idempotent: safe to re-run.
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_schema_migrations (
  version TEXT PRIMARY KEY,           -- e.g. '20260808150000' (first 14 chars of filename)
  description TEXT,
  applied_at TIMESTAMPTZ DEFAULT now(),
  checksum TEXT                        -- SHA256 of file content for idempotency verification
);

ALTER TABLE sys_schema_migrations ENABLE ROW LEVEL SECURITY;

-- Only MAF admins can read/write migration state
CREATE POLICY "authenticated can read migrations"
  ON sys_schema_migrations FOR SELECT TO authenticated USING (true);

CREATE POLICY "maf_admin can manage migrations"
  ON sys_schema_migrations FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
    AND role_id IN (
      SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
    )
  ));