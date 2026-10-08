-- ============================================================
-- Migration: 20260903000000_create_sys_webhook_events.sql
-- Speed-to-Lead Bot (spec 03) — raw webhook audit + notification queue
-- GARRY RUNS THIS MANUALLY in the Supabase SQL Editor (standing rule).
--
-- Why: the Edge Function audit-logs every Smartlead event BEFORE dedupe/
-- classify/write (spec §4.2). sys_processed_webhooks (already live) is the
-- idempotency ledger; this table is the raw-payload audit + the queue the
-- box-side notifier reads for P3 (hours gate + Discord). Without it the
-- receiver degrades to CRM-write-only (logged, non-fatal).
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_webhook_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source TEXT NOT NULL DEFAULT 'smartlead',
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL,               -- raw provider payload, pre-dedupe
  dedupe_key TEXT NOT NULL,             -- '<activity_type>:<external_id>'
  status TEXT NOT NULL DEFAULT 'received',
    -- received | deduped | logged | queued | notified | skipped | error
  activity_id UUID,                    -- crm_activities.id once written
  notification_status TEXT,            -- pending | sent | skipped (P3)
  error TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sys_webhook_events_status
  ON sys_webhook_events(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sys_webhook_events_dedupe
  ON sys_webhook_events(dedupe_key);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sys_webhook_events_dedupe_status
  ON sys_webhook_events(dedupe_key)
  WHERE status IN ('logged', 'notified');

-- Partial unique index rationale: exactly one 'logged' row per dedupe_key.
-- 'received' rows may repeat on retried deliveries; deduped/error/skipped are
-- historical and unrestricted.

-- RLS: raw lead PII (names, emails, reply bodies) — service-role only.
-- Applied live 2026-09-04 (confirmed: anon SELECT returns 0 rows, anon INSERT
-- gets 42501). These lines keep the repo file in sync with the live DB.
ALTER TABLE sys_webhook_events ENABLE ROW LEVEL SECURITY;