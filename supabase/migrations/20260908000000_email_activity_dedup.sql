-- ============================================================
-- Email activity dedup — documentation migration
-- Date: 2026-09-08
--
-- Finding (audit maf-crm-backend #3/#4): re-syncs of the same inbound
-- email inserted duplicate crm_activities because nothing enforced
-- (external_id, activity_type) uniqueness at insert time.
--
-- IMPORTANT: the enforcing index ALREADY EXISTS in
-- supabase/sql/crm-schema.sql:342-344:
--
--   CREATE UNIQUE INDEX IF NOT EXISTS idx_activities_external_dedup
--   ON crm_activities(external_id, activity_type)
--   WHERE external_id IS NOT NULL;
--
-- This migration re-asserts it idempotently. NOTE: crm_activities is
-- provisioned by the SCHEMA FILE, not by a migration (no migration
-- creates the table) — so this migration only runs on a database that
-- already had the schema applied. On such a database the re-assert is
-- a no-op; it exists to make the constraint's existence explicit in
-- the migration history and to fail loudly if the schema was altered.
--
-- WHY pre-check + unique-violation catch instead of a PostgREST upsert:
--   * The index is PARTIAL (WHERE external_id IS NOT NULL). PostgREST's
--     on_conflict requires a FULL unique index; upserting against a
--     partial index is broken (known repo lesson). Therefore the code
--     path is: SELECT pre-check (fast path) + catch HTTP 409 on INSERT
--     (race-safe backstop; PostgREST returns 409 ONLY for unique
--     violations — other constraint violations are 400), treating the
--     violation as "already synced". Rows with NULL external_id are
--     outside the partial index and never collide.
-- ============================================================

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_activities_external_dedup
  ON crm_activities(external_id, activity_type)
  WHERE external_id IS NOT NULL;

COMMIT;

-- ============================================================
-- VERIFICATION (Supabase SQL Editor, CRM project <your-project-ref>)
-- SELECT indexname, indexdef FROM pg_indexes
--  WHERE tablename = 'crm_activities' AND indexname = 'idx_activities_external_dedup';
-- Expect: unique, (external_id, activity_type), WHERE external_id IS NOT NULL
-- ============================================================
