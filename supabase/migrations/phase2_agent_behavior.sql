-- ============================================================
-- Phase 2: Agent Behavior Layer
-- Adds: agent audit trail, approval requests, and 1 RPC.
-- All CREATE statements use IF NOT EXISTS / OR REPLACE — idempotent.
-- Run twice safely.
-- ============================================================

-- ============================================================
-- 1. crm_agent_events — audit trail for agent sessions
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_agent_events (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  session_id TEXT NOT NULL,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  company_id UUID REFERENCES crm_companies(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  event_data JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_session
  ON crm_agent_events(session_id, created_at);
CREATE INDEX IF NOT EXISTS idx_events_contact
  ON crm_agent_events(contact_id);
CREATE INDEX IF NOT EXISTS idx_events_type
  ON crm_agent_events(event_type);

ALTER TABLE crm_agent_events ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_agent_events'
      AND policyname = 'crm_agent_events_authenticated'
  ) THEN
    CREATE POLICY crm_agent_events_authenticated ON crm_agent_events
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- 2. crm_approval_requests — queued sensitive actions
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_approval_requests (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  action TEXT NOT NULL,
  target_id TEXT NOT NULL,
  params JSONB DEFAULT '{}'::jsonb,
  reason TEXT NOT NULL,
  session_id TEXT,
  status TEXT NOT NULL DEFAULT 'PENDING',
  decided_by TEXT,
  decided_at TIMESTAMPTZ,
  execution_result JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_approvals_status
  ON crm_approval_requests(status, created_at);
CREATE INDEX IF NOT EXISTS idx_approvals_action
  ON crm_approval_requests(action);

ALTER TABLE crm_approval_requests ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_approval_requests'
      AND policyname = 'crm_approval_requests_authenticated'
  ) THEN
    CREATE POLICY crm_approval_requests_authenticated ON crm_approval_requests
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- RPC: log_agent_event — insert audit event via RPC
-- ============================================================
CREATE OR REPLACE FUNCTION log_agent_event(
  p_session_id TEXT,
  p_event_type TEXT,
  p_event_data JSONB DEFAULT '{}'::jsonb,
  p_contact_id UUID DEFAULT NULL,
  p_company_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO crm_agent_events (session_id, event_type, event_data, contact_id, company_id)
  VALUES (p_session_id, p_event_type, p_event_data, p_contact_id, p_company_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ============================================================
-- END OF Phase 2 Migration
-- Verification:
--   SELECT table_name FROM information_schema.tables
--     WHERE table_name IN ('crm_agent_events','crm_approval_requests');
--   SELECT relname, relrowsecurity FROM pg_class
--     WHERE relname IN ('crm_agent_events','crm_approval_requests');
--   SELECT proname FROM pg_proc WHERE proname = 'log_agent_event';
--   SELECT * FROM log_agent_event('test-sess', 'session_start', '{}'::jsonb);
-- ============================================================