-- ============================================================
-- Phase 1: Agent Intelligence Layer
-- Adds: agent work queue, evidence-based facts, evidence log,
--        contact briefs (stub), and 3 RPCs.
-- All CREATE statements use IF NOT EXISTS / OR REPLACE — idempotent.
-- Run twice safely.
-- ============================================================

-- ============================================================
-- 1. crm_agent_tasks — agent work queue with lease claiming
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_agent_tasks (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  company_id UUID REFERENCES crm_companies(id) ON DELETE SET NULL,
  deal_id UUID REFERENCES crm_deals(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  reason TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  budget INTEGER NOT NULL DEFAULT 4,
  attempts INTEGER NOT NULL DEFAULT 0,
  due_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  leased_until TIMESTAMPTZ,
  session_id TEXT,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  outcome TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_tasks_due_leased
  ON crm_agent_tasks(due_at, leased_until);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_contact
  ON crm_agent_tasks(contact_id);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_kind
  ON crm_agent_tasks(kind);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_unfinished
  ON crm_agent_tasks(finished_at) WHERE finished_at IS NULL;

ALTER TABLE crm_agent_tasks ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_agent_tasks'
      AND policyname = 'crm_agent_tasks_authenticated'
  ) THEN
    CREATE POLICY crm_agent_tasks_authenticated ON crm_agent_tasks
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- 2. crm_contact_facts — evidence-based fact ledger
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_contact_facts (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  contact_id UUID NOT NULL REFERENCES crm_contacts(id) ON DELETE CASCADE,
  field TEXT NOT NULL,
  value TEXT NOT NULL,
  score DOUBLE PRECISION NOT NULL DEFAULT 0,
  band TEXT NOT NULL DEFAULT 'POSSIBLE',
  status TEXT NOT NULL DEFAULT 'PROPOSED',
  method TEXT NOT NULL,
  source_url TEXT,
  session_id TEXT,
  decided_by TEXT,
  decided_at TIMESTAMPTZ,
  observed_at TIMESTAMPTZ DEFAULT now(),
  superseded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_facts_contact_field_status
  ON crm_contact_facts(contact_id, field, status);
CREATE INDEX IF NOT EXISTS idx_facts_status_observed
  ON crm_contact_facts(status, observed_at);

ALTER TABLE crm_contact_facts ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_contact_facts'
      AND policyname = 'crm_contact_facts_authenticated'
  ) THEN
    CREATE POLICY crm_contact_facts_authenticated ON crm_contact_facts
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- 3. crm_evidence_log — individual evidence entries per fact
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_evidence_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  fact_id UUID NOT NULL REFERENCES crm_contact_facts(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  detail TEXT NOT NULL,
  source_url TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_evidence_fact_id
  ON crm_evidence_log(fact_id);
CREATE INDEX IF NOT EXISTS idx_evidence_kind
  ON crm_evidence_log(kind);

ALTER TABLE crm_evidence_log ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_evidence_log'
      AND policyname = 'crm_evidence_log_authenticated'
  ) THEN
    CREATE POLICY crm_evidence_log_authenticated ON crm_evidence_log
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- 4. crm_contact_briefs — AI-generated contact narrative (stub for Phase 3)
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_contact_briefs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  contact_id UUID NOT NULL REFERENCES crm_contacts(id) ON DELETE CASCADE,
  brief TEXT NOT NULL,
  model TEXT,
  generated_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_briefs_contact
  ON crm_contact_briefs(contact_id);

ALTER TABLE crm_contact_briefs ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_contact_briefs'
      AND policyname = 'crm_contact_briefs_authenticated'
  ) THEN
    CREATE POLICY crm_contact_briefs_authenticated ON crm_contact_briefs
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- RPC 1: claim_due_tasks — atomic lease claiming with SKIP LOCKED
-- ============================================================
CREATE OR REPLACE FUNCTION claim_due_tasks(
  p_limit INTEGER DEFAULT 12,
  p_kinds TEXT[] DEFAULT NULL,
  p_lease_ms INTEGER DEFAULT 600000
)
RETURNS TABLE(
  id UUID, contact_id UUID, company_id UUID, deal_id UUID,
  kind TEXT, reason TEXT, priority INTEGER, budget INTEGER,
  attempts INTEGER, due_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now TIMESTAMPTZ := now();
  v_until TIMESTAMPTZ := v_now + (p_lease_ms || ' milliseconds')::INTERVAL;
BEGIN
  RETURN QUERY
  UPDATE crm_agent_tasks AS t
  SET leased_until = v_until,
      started_at = COALESCE(t.started_at, v_now),
      attempts = t.attempts + 1
  FROM (
    SELECT t2.id FROM crm_agent_tasks AS t2
    WHERE t2.finished_at IS NULL
      AND t2.due_at <= v_now
      AND (t2.leased_until IS NULL OR t2.leased_until < v_now)
      AND t2.attempts < 3
      AND (p_kinds IS NULL OR t2.kind = ANY(p_kinds))
    ORDER BY t2.priority DESC, t2.due_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ) AS due
  WHERE t.id = due.id
  RETURNING t.id, t.contact_id, t.company_id, t.deal_id,
            t.kind, t.reason, t.priority, t.budget,
            t.attempts, t.due_at;
END;
$$;

-- ============================================================
-- RPC 2: retire_exhausted_tasks — mark over-attempt tasks as retired
-- ============================================================
CREATE OR REPLACE FUNCTION retire_exhausted_tasks()
RETURNS TABLE(id UUID, contact_id UUID, company_id UUID, kind TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now TIMESTAMPTZ := now();
BEGIN
  RETURN QUERY
  UPDATE crm_agent_tasks AS t
  SET finished_at = v_now,
      outcome = 'Gave up after 3 attempts: the session never reported back.'
  WHERE t.finished_at IS NULL
    AND t.attempts >= 3
    AND (t.leased_until IS NULL OR t.leased_until < v_now)
  RETURNING t.id, t.contact_id, t.company_id, t.kind;
END;
$$;

-- ============================================================
-- RPC 3: score_evidence — compute band from evidence array
-- ============================================================
CREATE OR REPLACE FUNCTION score_evidence(p_evidence JSONB)
RETURNS TABLE(score DOUBLE PRECISION, band TEXT, has_primary BOOLEAN, rationale TEXT)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_item JSONB;
  v_kind TEXT;
  v_weight DOUBLE PRECISION;
  v_combined DOUBLE PRECISION := 1.0;
  v_score DOUBLE PRECISION;
  v_has_primary BOOLEAN := false;
  v_contradicted BOOLEAN := false;
  v_band TEXT;
BEGIN
  IF jsonb_array_length(p_evidence) = 0 THEN
    RETURN QUERY SELECT 0.0::float8, NULL::text, false, 'No evidence.';
    RETURN;
  END IF;

  FOR v_item IN SELECT jsonb_array_elements(p_evidence) LOOP
    v_kind := v_item->>'kind';

    IF v_kind = 'contradiction' THEN
      v_contradicted := true;
      CONTINUE;
    END IF;

    v_weight := CASE v_kind
      WHEN 'profile.email_match' THEN 0.95
      WHEN 'linkedin.employer_and_name' THEN 0.85
      WHEN 'crm.thread_reply' THEN 0.85
      WHEN 'crm.signature_block' THEN 0.80
      WHEN 'apollo.identity' THEN 0.80
      WHEN 'monid.verified' THEN 0.75
      WHEN 'crm.meeting_attendance' THEN 0.70
      WHEN 'web.cited_claim' THEN 0.40
      WHEN 'handle.name_form' THEN 0.35
      WHEN 'search.cites_profile' THEN 0.35
      WHEN 'employer_only' THEN 0.20
      ELSE 0.0
    END;

    IF v_weight >= 0.70 THEN
      v_has_primary := true;
    END IF;

    v_combined := v_combined * (1.0 - v_weight);
  END LOOP;

  v_score := LEAST(0.99, 1.0 - v_combined);

  IF v_contradicted THEN
    v_score := LEAST(v_score, 0.45);
  END IF;

  IF v_score >= 0.85 THEN
    v_band := 'VERIFIED';
  ELSEIF v_score >= 0.55 THEN
    v_band := 'PROBABLE';
  ELSEIF v_score >= 0.30 THEN
    v_band := 'POSSIBLE';
  ELSE
    v_band := NULL;
  END IF;

  RETURN QUERY SELECT v_score, v_band, v_has_primary,
    CASE WHEN v_band IS NULL THEN 'Below floor for keeping.'
         WHEN v_contradicted THEN 'Contradicted — held as possible.'
         ELSE v_band END;
END;
$$;

-- ============================================================
-- END OF Phase 1 Migration
-- Verification:
--   SELECT table_name FROM information_schema.tables
--     WHERE table_name IN ('crm_agent_tasks','crm_contact_facts',
--       'crm_evidence_log','crm_contact_briefs');
--   SELECT relname, relrowsecurity FROM pg_class
--     WHERE relname IN ('crm_agent_tasks','crm_contact_facts','crm_evidence_log');
--   SELECT proname FROM pg_proc
--     WHERE proname IN ('claim_due_tasks','retire_exhausted_tasks','score_evidence');
--   SELECT * FROM claim_due_tasks(1, NULL, 60000);
--   SELECT * FROM score_evidence('[{"kind":"profile.email_match","detail":"test"}]'::jsonb);
-- ============================================================