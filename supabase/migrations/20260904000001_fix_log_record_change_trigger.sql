-- ============================================================
-- Migration: 20260904000001_fix_log_record_change_trigger.sql
-- Fix the log_record_change() trigger function — 'col' does not exist (42703)
--
-- WHAT THIS FIXES
--   Migration 20260808150102's log_record_change() does
--       SELECT jsonb_object_agg(col, ...) FROM jsonb_each(to_jsonb(NEW))
--       WHERE col NOT IN (...)
--   but jsonb_each yields columns named key/value, never col — so EVERY
--   UPDATE on crm_companies and crm_deals failed with
--       42703: column "col" does not exist
--   Casualties: update_deal_stage, soft_delete_company, merge_companies,
--   and the MAF System anchor restore (hard-UNIQUE name blocked re-insert).
--
--   The live DB was hotfixed manually in the Supabase SQL editor on
--   2026-09-04 (see brain: crm-design-refactor/HOTFIX-...-2026-09-04.sql).
--   This migration lands the same fix in the repo so FRESH environments
--   get the corrected function from the start. On the live DB this is a
--   no-op: CREATE OR REPLACE with the identical body G already applied.
--
-- SAFE NOTES
--   - CREATE OR REPLACE only touches the trigger function; existing
--     triggers (log_deal_changes, log_company_changes) re-bind to the new
--     body automatically — no trigger drops needed.
--   - Behavior identical to the original intent: log changed fields to
--     crm_entity_activities on UPDATE, a 'create' row on INSERT.
--   - crm_entity_activities.created_by is nullable — auth.uid() NULL
--     (migrations, SQL editor) is safe. Verified against DDL.
-- ============================================================

CREATE OR REPLACE FUNCTION log_record_change()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  changes JSONB;
  oldj JSONB := to_jsonb(OLD);
  newj JSONB := to_jsonb(NEW);
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- jsonb_each yields columns named key/value (never 'col' — the 42703 bug)
    SELECT jsonb_object_agg(key, jsonb_build_object('old', oldj -> key, 'new', newj -> key))
    INTO changes
    FROM jsonb_each(newj)
    WHERE key NOT IN ('updated_at', 'created_at', 'computed_status')
      AND (oldj -> key) IS DISTINCT FROM (newj -> key);

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