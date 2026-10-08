-- ============================================================
-- Phase 3: Data Richness Layer
-- Adds: company enrichment tracking table + extends contact briefs.
-- All statements are idempotent — run twice safely.
-- ============================================================

-- ============================================================
-- 1. Extend crm_contact_briefs (from Phase 1) with new columns
-- ============================================================
ALTER TABLE crm_contact_briefs ADD COLUMN IF NOT EXISTS sections JSONB DEFAULT '{}'::jsonb;
ALTER TABLE crm_contact_briefs ADD COLUMN IF NOT EXISTS refreshed_at TIMESTAMPTZ;
ALTER TABLE crm_contact_briefs ADD COLUMN IF NOT EXISTS session_id TEXT;

-- ============================================================
-- 2. crm_company_enrichment — tracks enrichment pipeline status
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_company_enrichment (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id UUID NOT NULL REFERENCES crm_companies(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING',
  result JSONB DEFAULT '{}'::jsonb,
  error TEXT,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_enrichment_company
  ON crm_company_enrichment(company_id, kind);
CREATE INDEX IF NOT EXISTS idx_enrichment_status
  ON crm_company_enrichment(status);

ALTER TABLE crm_company_enrichment ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_company_enrichment'
      AND policyname = 'crm_company_enrichment_authenticated'
  ) THEN
    CREATE POLICY crm_company_enrichment_authenticated ON crm_company_enrichment
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- END OF Phase 3 Migration
-- Verification:
--   SELECT column_name FROM information_schema.columns
--     WHERE table_name = 'crm_contact_briefs'
--     AND column_name IN ('sections', 'refreshed_at', 'session_id');
--   SELECT table_name FROM information_schema.tables
--     WHERE table_name = 'crm_company_enrichment';
--   SELECT relname, relrowsecurity FROM pg_class
--     WHERE relname = 'crm_company_enrichment';
-- ============================================================