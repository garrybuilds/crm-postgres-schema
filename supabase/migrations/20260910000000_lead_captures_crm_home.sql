-- lead_captures — CRM home (G decision 2026-09-10: scorecard quiz leads are
-- SALES data; the portal/MAF-Deploy is client-first, post-sale only).
-- Mirrors the live table in the MAF-Deploy project (19 rows migrated
-- separately via SQL); RLS + anon INSERT mirror supabase-setup.sql from
-- garrybuilds/maf-scorecard-landing.

CREATE TABLE IF NOT EXISTS public.lead_captures (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  constraint_id TEXT NOT NULL,
  scores JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.lead_captures ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "allow_public_insert" ON public.lead_captures;
CREATE POLICY "allow_public_insert" ON public.lead_captures
  FOR INSERT TO anon
  WITH CHECK (true);

DROP POLICY IF EXISTS "allow_service_role_select" ON public.lead_captures;
CREATE POLICY "allow_service_role_select" ON public.lead_captures
  FOR SELECT TO service_role
  USING (true);

CREATE INDEX IF NOT EXISTS idx_lead_captures_email ON public.lead_captures(email);
CREATE INDEX IF NOT EXISTS idx_lead_captures_created_at ON public.lead_captures(created_at DESC);