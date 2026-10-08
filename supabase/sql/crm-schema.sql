-- ============================================================
-- MAF CRM Schema — Supabase Migration (v3 — standalone project)
-- ============================================================
-- Project: maf-crm (new standalone Supabase project)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- Created: 2026-07-24
-- Updated: 2026-07-27 — standalone project, persona gaps closed
--
-- STANDALONE PROJECT:
--   This is a SEPARATE Supabase project from the MSP portal.
--   No client users exist in this project. No profiles table dependency.
--   RLS is simple: authenticated users can read/write, anon gets nothing.
--   The Hermes agent uses the service role key (bypasses RLS).
--
-- CROSS-PROJECT SYNC:
--   CRM ↔ Portal sync happens via Python scripts (see execution-plan.md).
--   5 touchpoints: deal close → fleet, client health, milestones,
--   client activity, fleet alerts.
--   The msp_client_id column on crm_companies links CRM records
--   to portal fleet_registry records (text reference, not FK).
--
-- TABLES (12):
--   1. crm_companies       7. crm_tasks
--   2. crm_contacts         8. crm_deal_milestones
--   3. crm_deals            9. crm_deal_parties
--   4. crm_activities      10. crm_commissions
--   5. crm_pipeline_stages 11. crm_alerts
--   6. crm_sync_log        12. crm_audit_log
--                          13. crm_backup_log
--
-- VIEWS (8):
--   crm_pipeline_summary, crm_deal_board, crm_stale_deals,
--   crm_orphaned_deals, crm_possible_duplicates, crm_deploy_board,
--   crm_today_actions, crm_sync_health
--
-- RPCs (5):
--   upsert_company, merge_companies, soft_delete_company,
--   populate_deploy_milestones, populate_ma_milestones
--
-- HARDENING:
--   1. Simple RLS — authenticated only, no profiles dependency
--   2. Soft-delete on companies (deleted_at), no CASCADE
--   3. One open deal per company (partial unique index)
--   4. Sync dedup: unique on (external_id, activity_type)
--   5. Activity CHECK: at least one FK required
--   6. Stage change trigger → auto-log activity
--   7. merge_companies RPC for duplicate cleanup
--   8. msp_client_id link column (text, not FK — cross-project)
--   9. Contact email uniqueness is per-company, not global
--  10. thread_id on activities (email threading — persona gap 9)
--  11. version on deals (optimistic locking — persona gap 10)
--  12. crm_backup_log table (backup verification — persona gap 11)
--  13. crm_sync_health view (sync monitoring — persona gap 6)
--  14. Audit log trigger on deals (field-level change tracking)
-- ============================================================

-- ============================================================
-- 0. EXTENSIONS (must be first — needed by views below)
-- ============================================================
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

-- ============================================================
-- 1. COMPANIES
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_companies (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  company_name TEXT NOT NULL,
  normalized_name TEXT UNIQUE NOT NULL,
  industry TEXT,
  segment TEXT DEFAULT 'residential',
  website TEXT,
  phone TEXT,
  city TEXT,
  state TEXT,
  zip TEXT,
  revenue_range TEXT,
  employee_count INTEGER,
  years_in_business INTEGER,
  score INTEGER DEFAULT 0,
  icp_fit TEXT DEFAULT 'target',
  airtable_record_id TEXT,
  msp_client_id TEXT,  -- cross-project link to portal fleet_registry.client_id
  source TEXT,
  meta JSONB DEFAULT '{}'::jsonb,
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_companies_industry ON crm_companies(industry);
CREATE INDEX IF NOT EXISTS idx_companies_state ON crm_companies(state);
CREATE INDEX IF NOT EXISTS idx_companies_score ON crm_companies(score DESC);
CREATE INDEX IF NOT EXISTS idx_companies_airtable_id ON crm_companies(airtable_record_id);
CREATE INDEX IF NOT EXISTS idx_companies_icp_fit ON crm_companies(icp_fit);
CREATE INDEX IF NOT EXISTS idx_companies_msp_client_id ON crm_companies(msp_client_id);
CREATE INDEX IF NOT EXISTS idx_companies_deleted_at ON crm_companies(deleted_at);

-- Auto-generate normalized_name from company_name on insert
CREATE OR REPLACE FUNCTION normalize_company_name(name TEXT)
RETURNS TEXT AS $$
BEGIN
  RETURN lower(regexp_replace(name, '[^a-z0-9]', '', 'gi'));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION set_normalized_name()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.normalized_name IS NULL OR NEW.normalized_name = '' THEN
    NEW.normalized_name := normalize_company_name(NEW.company_name);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_companies_normalized_name
  BEFORE INSERT OR UPDATE ON crm_companies
  FOR EACH ROW EXECUTE FUNCTION set_normalized_name();

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_companies_updated_at
  BEFORE UPDATE ON crm_companies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- 2. CONTACTS
-- ============================================================
-- Email uniqueness is per-company, not global.
-- A person can be a contact at multiple companies.
CREATE TABLE IF NOT EXISTS crm_contacts (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id UUID REFERENCES crm_companies(id) ON DELETE SET NULL,
  first_name TEXT,
  last_name TEXT,
  full_name TEXT,
  email TEXT,
  phone TEXT,
  title TEXT,
  linkedin_url TEXT,
  is_decision_maker BOOLEAN DEFAULT false,
  airtable_record_id TEXT,
  meta JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_contacts_email ON crm_contacts(email);
CREATE INDEX IF NOT EXISTS idx_contacts_company_id ON crm_contacts(company_id);
-- Per-company email uniqueness (not global — same person can be at multiple companies)
CREATE UNIQUE INDEX IF NOT EXISTS idx_contacts_company_email_unique
  ON crm_contacts(company_id, email) WHERE email IS NOT NULL;

CREATE TRIGGER trg_contacts_updated_at
  BEFORE UPDATE ON crm_contacts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- 3. DEALS
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_deals (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id UUID REFERENCES crm_companies(id) ON DELETE SET NULL,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  deal_type TEXT NOT NULL DEFAULT 'consulting',
  stage TEXT NOT NULL DEFAULT 'lead',
  stage_entered_at TIMESTAMPTZ DEFAULT now(),
  estimated_value DECIMAL(10,2) DEFAULT 0,
  actual_value DECIMAL(10,2) DEFAULT 0,
  close_date DATE,
  close_probability INTEGER DEFAULT 5,
  loss_reason TEXT,
  stage_skip_reason TEXT,
  cal_com_booking_id TEXT,
  assigned_to TEXT DEFAULT 'garry',
  next_action TEXT,
  next_action_due DATE,
  version INTEGER DEFAULT 1,  -- optimistic locking (persona gap 10)
  meta JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_deals_stage ON crm_deals(stage);
CREATE INDEX IF NOT EXISTS idx_deals_company_id ON crm_deals(company_id);
CREATE INDEX IF NOT EXISTS idx_deals_contact_id ON crm_deals(contact_id);
CREATE INDEX IF NOT EXISTS idx_deals_deal_type ON crm_deals(deal_type);
CREATE INDEX IF NOT EXISTS idx_deals_assigned_to ON crm_deals(assigned_to);
CREATE INDEX IF NOT EXISTS idx_deals_cal_com_id ON crm_deals(cal_com_booking_id);

-- One open deal per company — prevents duplicate pipeline entries
CREATE UNIQUE INDEX IF NOT EXISTS idx_deals_one_open_per_company
  ON crm_deals(company_id)
  WHERE stage NOT IN ('closed_won', 'closed_lost');

CREATE TRIGGER trg_deals_updated_at
  BEFORE UPDATE ON crm_deals
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Update stage_entered_at + close_probability when stage changes
CREATE OR REPLACE FUNCTION set_stage_entered_at()
RETURNS TRIGGER AS $$
DECLARE
  v_old_order INTEGER;
  v_new_order INTEGER;
  v_skip_count INTEGER;
BEGIN
  IF OLD.stage IS DISTINCT FROM NEW.stage THEN
    NEW.stage_entered_at := now();

    SELECT close_probability INTO NEW.close_probability
    FROM crm_pipeline_stages WHERE stage = NEW.stage;
    IF NOT FOUND THEN
      NEW.close_probability := 5;
    END IF;

    -- Detect stage skip (forward-only)
    SELECT stage_order INTO v_old_order FROM crm_pipeline_stages WHERE stage = OLD.stage;
    SELECT stage_order INTO v_new_order FROM crm_pipeline_stages WHERE stage = NEW.stage;
    IF v_old_order IS NOT NULL AND v_new_order IS NOT NULL AND v_new_order > v_old_order + 1 THEN
      v_skip_count := v_new_order - v_old_order - 1;
      -- stage_skip_reason must be set when skipping >1 stage forward
      IF NEW.stage_skip_reason IS NULL OR NEW.stage_skip_reason = '' THEN
        RAISE WARNING 'Stage skip detected: % → % (skipped % stages), no reason provided',
          OLD.stage, NEW.stage, v_skip_count;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_deals_stage_change
  BEFORE UPDATE ON crm_deals
  FOR EACH ROW EXECUTE FUNCTION set_stage_entered_at();

-- Auto-log activity when stage changes (AFTER UPDATE trigger)
CREATE OR REPLACE FUNCTION log_stage_change_activity()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.stage IS DISTINCT FROM NEW.stage THEN
    INSERT INTO crm_activities (deal_id, company_id, contact_id, activity_type, channel, direction, subject, body, occurred_at)
    VALUES (
      NEW.id,
      NEW.company_id,
      NEW.contact_id,
      'stage_change',
      'system',
      'internal',
      format('%s → %s', OLD.stage, NEW.stage),
      COALESCE('Stage changed. Reason: ' || NULLIF(NEW.stage_skip_reason, ''), 'Stage changed.'),
      now()
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_deals_stage_change_log
  AFTER UPDATE ON crm_deals
  FOR EACH ROW
  WHEN (OLD.stage IS DISTINCT FROM NEW.stage)
  EXECUTE FUNCTION log_stage_change_activity();

-- Audit log trigger — track field-level changes on deals (persona gap 5)
CREATE OR REPLACE FUNCTION log_deal_audit()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.estimated_value IS DISTINCT FROM NEW.estimated_value THEN
    INSERT INTO crm_audit_log (table_name, record_id, field_name, old_value, new_value, changed_by)
    VALUES ('crm_deals', NEW.id, 'estimated_value',
      OLD.estimated_value::TEXT, NEW.estimated_value::TEXT,
      COALESCE(current_setting('app.current_user', true), 'system'));
  END IF;
  IF OLD.actual_value IS DISTINCT FROM NEW.actual_value THEN
    INSERT INTO crm_audit_log (table_name, record_id, field_name, old_value, new_value, changed_by)
    VALUES ('crm_deals', NEW.id, 'actual_value',
      OLD.actual_value::TEXT, NEW.actual_value::TEXT,
      COALESCE(current_setting('app.current_user', true), 'system'));
  END IF;
  IF OLD.close_date IS DISTINCT FROM NEW.close_date THEN
    INSERT INTO crm_audit_log (table_name, record_id, field_name, old_value, new_value, changed_by)
    VALUES ('crm_deals', NEW.id, 'close_date',
      OLD.close_date::TEXT, NEW.close_date::TEXT,
      COALESCE(current_setting('app.current_user', true), 'system'));
  END IF;
  IF OLD.deal_type IS DISTINCT FROM NEW.deal_type THEN
    INSERT INTO crm_audit_log (table_name, record_id, field_name, old_value, new_value, changed_by)
    VALUES ('crm_deals', NEW.id, 'deal_type',
      OLD.deal_type::TEXT, NEW.deal_type::TEXT,
      COALESCE(current_setting('app.current_user', true), 'system'));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_deals_audit_log
  AFTER UPDATE ON crm_deals
  FOR EACH ROW
  EXECUTE FUNCTION log_deal_audit();

-- ============================================================
-- 4. ACTIVITIES
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_activities (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  deal_id UUID REFERENCES crm_deals(id) ON DELETE SET NULL,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  company_id UUID REFERENCES crm_companies(id) ON DELETE SET NULL,
  activity_type TEXT NOT NULL,
  channel TEXT,
  direction TEXT DEFAULT 'outbound',
  subject TEXT,
  body TEXT,
  meta JSONB DEFAULT '{}'::jsonb,
  external_id TEXT,
  thread_id TEXT,  -- email threading (persona gap 9)
  occurred_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now(),
  -- At least one FK must be set — no orphan activities
  CONSTRAINT chk_activity_has_link CHECK (
    deal_id IS NOT NULL OR contact_id IS NOT NULL OR company_id IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS idx_activities_deal_id ON crm_activities(deal_id);
CREATE INDEX IF NOT EXISTS idx_activities_contact_id ON crm_activities(contact_id);
CREATE INDEX IF NOT EXISTS idx_activities_company_id ON crm_activities(company_id);
CREATE INDEX IF NOT EXISTS idx_activities_type ON crm_activities(activity_type);
CREATE INDEX IF NOT EXISTS idx_activities_occurred_at ON crm_activities(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_activities_external_id ON crm_activities(external_id);
CREATE INDEX IF NOT EXISTS idx_activities_thread_id ON crm_activities(thread_id);

-- Sync dedup: prevent duplicate activities from re-polling
CREATE UNIQUE INDEX IF NOT EXISTS idx_activities_external_dedup
  ON crm_activities(external_id, activity_type)
  WHERE external_id IS NOT NULL;

-- ============================================================
-- 5. PIPELINE STAGES (lookup)
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_pipeline_stages (
  stage TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  stage_order INTEGER NOT NULL,
  close_probability INTEGER DEFAULT 0,
  is_won_stage BOOLEAN DEFAULT false,
  is_lost_stage BOOLEAN DEFAULT false
);

INSERT INTO crm_pipeline_stages (stage, display_name, stage_order, close_probability, is_won_stage, is_lost_stage) VALUES
  ('lead',              'Lead',              1,  5,  false, false),
  ('contacted',         'Contacted',         2,  10, false, false),
  ('discovery_booked', 'Discovery Booked',   3,  25, false, false),
  ('discovery_completed','Discovery Completed',4, 40, false, false),
  ('audit_delivered',   'Audit Delivered',    5,  55, false, false),
  ('proposal_sent',     'Proposal Sent',     6,  70, false, false),
  ('negotiating',       'Negotiating',       7,  80, false, false),
  ('closed_won',        'Closed Won',         8,  100, true,  false),
  ('closed_lost',       'Closed Lost',       9,  0,   false, true)
ON CONFLICT (stage) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  stage_order = EXCLUDED.stage_order,
  close_probability = EXCLUDED.close_probability,
  is_won_stage = EXCLUDED.is_won_stage,
  is_lost_stage = EXCLUDED.is_lost_stage;

-- ============================================================
-- 6. SYNC LOG
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_sync_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  source TEXT NOT NULL,
  direction TEXT NOT NULL DEFAULT 'inbound',
  target_project TEXT,  -- 'portal' for cross-project syncs, NULL for same-project
  records_processed INTEGER DEFAULT 0,
  records_created INTEGER DEFAULT 0,
  records_updated INTEGER DEFAULT 0,
  records_deduped INTEGER DEFAULT 0,
  errors INTEGER DEFAULT 0,
  error_details TEXT,
  started_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_sync_log_source ON crm_sync_log(source);
CREATE INDEX IF NOT EXISTS idx_sync_log_completed_at ON crm_sync_log(completed_at DESC);

-- ============================================================
-- 7. CONVENIENCE VIEWS
-- ============================================================

-- Pipeline summary by stage
CREATE OR REPLACE VIEW crm_pipeline_summary AS
SELECT
  ps.stage,
  ps.display_name,
  ps.stage_order,
  ps.close_probability,
  COUNT(d.id) AS deal_count,
  COALESCE(SUM(d.estimated_value), 0) AS total_estimated_value,
  COALESCE(SUM(d.estimated_value * d.close_probability / 100.0), 0) AS weighted_value
FROM crm_pipeline_stages ps
LEFT JOIN crm_deals d ON d.stage = ps.stage
WHERE ps.is_won_stage = false AND ps.is_lost_stage = false
  AND d.company_id IS NOT NULL  -- exclude orphaned deals
GROUP BY ps.stage, ps.display_name, ps.stage_order, ps.close_probability
ORDER BY ps.stage_order;

-- Deal board with company + contact info
CREATE OR REPLACE VIEW crm_deal_board AS
SELECT
  d.id AS deal_id,
  d.stage,
  d.deal_type,
  d.estimated_value,
  d.close_probability,
  d.close_date,
  d.assigned_to,
  d.stage_entered_at,
  d.next_action,
  d.next_action_due,
  d.version,
  d.created_at,
  c.company_name,
  c.industry,
  c.segment,
  c.score AS company_score,
  c.icp_fit,
  c.state,
  c.msp_client_id,
  ct.email AS contact_email,
  ct.phone AS contact_phone,
  ct.full_name AS contact_name,
  ct.title AS contact_title,
  (SELECT occurred_at FROM crm_activities a WHERE a.deal_id = d.id ORDER BY occurred_at DESC LIMIT 1) AS last_activity_at,
  (SELECT activity_type FROM crm_activities a WHERE a.deal_id = d.id ORDER BY occurred_at DESC LIMIT 1) AS last_activity_type
FROM crm_deals d
JOIN crm_companies c ON d.company_id = c.id
LEFT JOIN crm_contacts ct ON d.contact_id = ct.id
WHERE c.deleted_at IS NULL  -- exclude soft-deleted companies
ORDER BY d.stage_entered_at DESC;

-- Stale deals (no activity in N days)
CREATE OR REPLACE VIEW crm_stale_deals AS
SELECT
  d.id AS deal_id,
  c.company_name,
  c.industry,
  d.stage,
  d.stage_entered_at,
  d.assigned_to,
  EXTRACT(EPOCH FROM now() - COALESCE(
    (SELECT MAX(occurred_at) FROM crm_activities a WHERE a.deal_id = d.id),
    d.stage_entered_at
  )) / 86400.0 AS days_since_activity
FROM crm_deals d
JOIN crm_companies c ON d.company_id = c.id
WHERE d.stage NOT IN ('closed_won', 'closed_lost')
  AND c.deleted_at IS NULL
  AND COALESCE(
    (SELECT MAX(occurred_at) FROM crm_activities a WHERE a.deal_id = d.id),
    d.stage_entered_at
  ) < now() - INTERVAL '14 days'
ORDER BY days_since_activity DESC;

-- Orphaned deals (company was soft-deleted or deleted)
CREATE OR REPLACE VIEW crm_orphaned_deals AS
SELECT
  d.id AS deal_id,
  d.stage,
  d.deal_type,
  d.estimated_value,
  d.assigned_to,
  d.created_at
FROM crm_deals d
LEFT JOIN crm_companies c ON d.company_id = c.id
WHERE d.company_id IS NULL
   OR c.deleted_at IS NOT NULL
ORDER BY d.estimated_value DESC;

-- Possible duplicate companies (same industry, same state, similar name)
CREATE OR REPLACE VIEW crm_possible_duplicates AS
SELECT
  a.id AS company_a_id,
  a.company_name AS company_a,
  b.id AS company_b_id,
  b.company_name AS company_b,
  a.industry,
  a.state,
  a.normalized_name,
  b.normalized_name AS b_normalized_name
FROM crm_companies a
JOIN crm_companies b ON a.id < b.id
  AND a.industry = b.industry
  AND a.state = b.state
  AND a.deleted_at IS NULL
  AND b.deleted_at IS NULL
  AND (
    -- Same normalized name (shouldn't happen due to UNIQUE, but just in case)
    a.normalized_name = b.normalized_name
    -- Or levenshtein distance <= 2 for short names, <= 4 for longer
    OR (length(a.normalized_name) <= 10 AND levenshtein(a.normalized_name, b.normalized_name) <= 2)
    OR (length(a.normalized_name) > 10 AND levenshtein(a.normalized_name, b.normalized_name) <= 4)
  );

-- Sync health — last successful sync per source (persona gap 6)
CREATE OR REPLACE VIEW crm_sync_health AS
SELECT
  source,
  MAX(completed_at) AS last_sync,
  ROUND(EXTRACT(EPOCH FROM (now() - MAX(completed_at)))/3600.0, 1) AS hours_since_sync,
  COUNT(*) FILTER (WHERE errors > 0) AS runs_with_errors,
  MAX(errors) AS max_errors_last_run,
  MAX(target_project) AS target_project
FROM crm_sync_log
WHERE completed_at > now() - INTERVAL '7 days'
GROUP BY source
ORDER BY source;

-- ============================================================
-- 9. HELPER RPCs
-- ============================================================

-- Upsert company (idempotent import)
CREATE OR REPLACE FUNCTION upsert_company(
  p_company_name TEXT,
  p_industry TEXT DEFAULT NULL,
  p_segment TEXT DEFAULT 'residential',
  p_website TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_city TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL,
  p_zip TEXT DEFAULT NULL,
  p_score INTEGER DEFAULT 0,
  p_source TEXT DEFAULT NULL,
  p_airtable_record_id TEXT DEFAULT NULL,
  p_msp_client_id TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_id UUID;
  v_norm TEXT;
BEGIN
  v_norm := normalize_company_name(p_company_name);
  INSERT INTO crm_companies (company_name, normalized_name, industry, segment, website, phone, city, state, zip, score, source, airtable_record_id, msp_client_id)
  VALUES (p_company_name, v_norm, p_industry, p_segment, p_website, p_phone, p_city, p_state, p_zip, p_score, p_source, p_airtable_record_id, p_msp_client_id)
  ON CONFLICT (normalized_name) DO UPDATE SET
    industry = COALESCE(EXCLUDED.industry, crm_companies.industry),
    segment = COALESCE(EXCLUDED.segment, crm_companies.segment),
    website = COALESCE(EXCLUDED.website, crm_companies.website),
    phone = COALESCE(EXCLUDED.phone, crm_companies.phone),
    city = COALESCE(EXCLUDED.city, crm_companies.city),
    state = COALESCE(EXCLUDED.state, crm_companies.state),
    zip = COALESCE(EXCLUDED.zip, crm_companies.zip),
    score = GREATEST(EXCLUDED.score, crm_companies.score),
    source = COALESCE(EXCLUDED.source, crm_companies.source),
    airtable_record_id = COALESCE(EXCLUDED.airtable_record_id, crm_companies.airtable_record_id),
    msp_client_id = COALESCE(EXCLUDED.msp_client_id, crm_companies.msp_client_id),
    updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Merge companies (duplicate cleanup)
CREATE OR REPLACE FUNCTION merge_companies(
  p_source_id UUID,
  p_target_id UUID
)
RETURNS TABLE(
  contacts_moved INTEGER,
  deals_moved INTEGER,
  activities_moved INTEGER
) AS $$
DECLARE
  v_contacts INTEGER;
  v_deals INTEGER;
  v_activities INTEGER;
BEGIN
  IF p_source_id = p_target_id THEN
    RAISE EXCEPTION 'Cannot merge a company into itself';
  END IF;

  UPDATE crm_contacts SET company_id = p_target_id, updated_at = now()
  WHERE company_id = p_source_id;
  GET DIAGNOSTICS v_contacts = ROW_COUNT;

  UPDATE crm_deals SET company_id = p_target_id, updated_at = now()
  WHERE company_id = p_source_id;
  GET DIAGNOSTICS v_deals = ROW_COUNT;

  UPDATE crm_activities SET company_id = p_target_id
  WHERE company_id = p_source_id;
  GET DIAGNOSTICS v_activities = ROW_COUNT;

  UPDATE crm_companies SET deleted_at = now(), updated_at = now()
  WHERE id = p_source_id;

  RETURN QUERY SELECT v_contacts, v_deals, v_activities;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Soft-delete company (never hard-delete)
CREATE OR REPLACE FUNCTION soft_delete_company(p_company_id UUID)
RETURNS VOID AS $$
DECLARE
  v_deal_count INTEGER;
  v_deal_value DECIMAL(10,2);
BEGIN
  SELECT COUNT(*), COALESCE(SUM(estimated_value), 0)
  INTO v_deal_count, v_deal_value
  FROM crm_deals
  WHERE company_id = p_company_id
    AND stage NOT IN ('closed_won', 'closed_lost');

  IF v_deal_count > 0 THEN
    RAISE EXCEPTION 'Cannot delete company with % open deal(s) worth $%. Close or move deals first.',
      v_deal_count, v_deal_value;
  END IF;

  UPDATE crm_companies SET deleted_at = now(), updated_at = now()
  WHERE id = p_company_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 10. TASKS — what needs to happen next (persona audit gap #1)
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_tasks (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  deal_id UUID REFERENCES crm_deals(id) ON DELETE SET NULL,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  company_id UUID REFERENCES crm_companies(id) ON DELETE SET NULL,
  assigned_to TEXT DEFAULT 'garry',
  title TEXT NOT NULL,
  description TEXT,
  due_date DATE,
  priority TEXT DEFAULT 'normal',
  status TEXT DEFAULT 'pending',
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tasks_deal_id ON crm_tasks(deal_id);
CREATE INDEX IF NOT EXISTS idx_tasks_due_date ON crm_tasks(due_date);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON crm_tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to ON crm_tasks(assigned_to);

CREATE TRIGGER trg_tasks_updated_at
  BEFORE UPDATE ON crm_tasks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- 11. DEAL MILESTONES — LOI, DD, closing, Deploy onboarding
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_deal_milestones (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  deal_id UUID REFERENCES crm_deals(id) ON DELETE CASCADE,
  milestone_type TEXT NOT NULL,
  milestone_name TEXT NOT NULL,
  status TEXT DEFAULT 'not_started',
  due_date DATE,
  completed_date DATE,
  assignee TEXT DEFAULT 'garry',
  notes TEXT,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_milestones_deal_id ON crm_deal_milestones(deal_id);
CREATE INDEX IF NOT EXISTS idx_milestones_type ON crm_deal_milestones(milestone_type);
CREATE INDEX IF NOT EXISTS idx_milestones_status ON crm_deal_milestones(status);
CREATE INDEX IF NOT EXISTS idx_milestones_due_date ON crm_deal_milestones(due_date);

CREATE TRIGGER trg_milestones_updated_at
  BEFORE UPDATE ON crm_deal_milestones
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- 12. DEAL PARTIES — buyer, seller, attorney, lender
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_deal_parties (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  deal_id UUID REFERENCES crm_deals(id) ON DELETE CASCADE,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  role TEXT NOT NULL,
  company_name TEXT,
  nda_status TEXT DEFAULT 'not_required',
  nda_date DATE,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_parties_deal_id ON crm_deal_parties(deal_id);
CREATE INDEX IF NOT EXISTS idx_parties_role ON crm_deal_parties(role);
CREATE INDEX IF NOT EXISTS idx_parties_contact_id ON crm_deal_parties(contact_id);

CREATE TRIGGER trg_parties_updated_at
  BEFORE UPDATE ON crm_deal_parties
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- 13. COMMISSIONS — success fee tracking
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_commissions (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  deal_id UUID REFERENCES crm_deals(id) ON DELETE CASCADE,
  fee_percentage DECIMAL(5,2),
  retainer_received DECIMAL(10,2) DEFAULT 0,
  success_fee_earned DECIMAL(10,2) DEFAULT 0,
  success_fee_paid DECIMAL(10,2) DEFAULT 0,
  payment_status TEXT DEFAULT 'not_earned',
  payment_date DATE,
  invoice_number TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_commissions_deal_id ON crm_commissions(deal_id);
CREATE INDEX IF NOT EXISTS idx_commissions_payment_status ON crm_commissions(payment_status);

CREATE TRIGGER trg_commissions_updated_at
  BEFORE UPDATE ON crm_commissions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- 14. ALERTS — proactive push notifications (persona audit gap #3)
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_alerts (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  deal_id UUID REFERENCES crm_deals(id) ON DELETE CASCADE,
  alert_type TEXT NOT NULL,
  severity TEXT DEFAULT 'warning',
  message TEXT NOT NULL,
  dismissed BOOLEAN DEFAULT false,
  dismissed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_alerts_deal_id ON crm_alerts(deal_id);
CREATE INDEX IF NOT EXISTS idx_alerts_severity ON crm_alerts(severity);
CREATE INDEX IF NOT EXISTS idx_alerts_dismissed ON crm_alerts(dismissed);
CREATE INDEX IF NOT EXISTS idx_alerts_created_at ON crm_alerts(created_at DESC);

-- ============================================================
-- 15. AUDIT LOG — field-level change tracking (persona audit gap #5)
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_audit_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  table_name TEXT NOT NULL,
  record_id UUID NOT NULL,
  field_name TEXT NOT NULL,
  old_value TEXT,
  new_value TEXT,
  changed_by TEXT,
  changed_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_table_name ON crm_audit_log(table_name);
CREATE INDEX IF NOT EXISTS idx_audit_record_id ON crm_audit_log(record_id);
CREATE INDEX IF NOT EXISTS idx_audit_changed_at ON crm_audit_log(changed_at DESC);

-- ============================================================
-- 16. BACKUP LOG — backup verification (persona audit gap #11)
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_backup_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  backup_type TEXT NOT NULL,  -- daily, weekly_restore_test
  status TEXT NOT NULL,       -- success, failed
  row_counts JSONB,           -- {companies: N, deals: N, ...}
  file_path TEXT,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_backup_log_created_at ON crm_backup_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_backup_log_status ON crm_backup_log(status);

-- ============================================================
-- 17. ROW LEVEL SECURITY (standalone — simple authenticated-only)
-- ============================================================
-- MUST come after all tables are created.
-- The Hermes agent uses the service role key (bypasses RLS).
-- These policies protect the authenticated/anon paths.
-- No client users exist in this project — no is_maf_staff() needed.
-- Any authenticated user can read/write all CRM tables.
-- Anon key gets nothing.

ALTER TABLE crm_companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_deals ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_pipeline_stages ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_sync_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_deal_milestones ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_deal_parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_backup_log ENABLE ROW LEVEL SECURITY;

-- Helper: apply RLS to a table (authenticated read + write, anon nothing)
CREATE OR REPLACE FUNCTION apply_crm_rls(tbl TEXT)
RETURNS VOID AS $$
BEGIN
  EXECUTE format('CREATE POLICY %I ON %I FOR SELECT TO authenticated USING (true);', 'auth_read_' || tbl, tbl);
  EXECUTE format('CREATE POLICY %I ON %I FOR INSERT TO authenticated WITH CHECK (true);', 'auth_insert_' || tbl, tbl);
  EXECUTE format('CREATE POLICY %I ON %I FOR UPDATE TO authenticated USING (true) WITH CHECK (true);', 'auth_update_' || tbl, tbl);
  EXECUTE format('CREATE POLICY %I ON %I FOR DELETE TO authenticated USING (true);', 'auth_delete_' || tbl, tbl);
END;
$$ LANGUAGE plpgsql;

-- Apply RLS to all CRM tables
SELECT apply_crm_rls('crm_companies');
SELECT apply_crm_rls('crm_contacts');
SELECT apply_crm_rls('crm_deals');
SELECT apply_crm_rls('crm_activities');
SELECT apply_crm_rls('crm_pipeline_stages');
SELECT apply_crm_rls('crm_sync_log');
SELECT apply_crm_rls('crm_tasks');
SELECT apply_crm_rls('crm_deal_milestones');
SELECT apply_crm_rls('crm_deal_parties');
SELECT apply_crm_rls('crm_commissions');
SELECT apply_crm_rls('crm_alerts');
SELECT apply_crm_rls('crm_audit_log');
SELECT apply_crm_rls('crm_backup_log');

-- ============================================================
-- 18. DEPLOY-SPECIFIC VIEWS
-- ============================================================

-- Deploy deal board — deals of type maf_deploy_* with onboarding milestones
CREATE OR REPLACE VIEW crm_deploy_board AS
SELECT
  d.id AS deal_id,
  d.stage,
  d.deal_type,
  d.estimated_value,
  d.assigned_to,
  d.stage_entered_at,
  d.next_action,
  d.next_action_due,
  c.company_name,
  c.industry,
  c.state,
  c.msp_client_id,
  ct.email AS contact_email,
  ct.phone AS contact_phone,
  ct.full_name AS contact_name,
  (SELECT count(*) FROM crm_deal_milestones m WHERE m.deal_id = d.id AND m.status = 'completed') AS milestones_completed,
  (SELECT count(*) FROM crm_deal_milestones m WHERE m.deal_id = d.id) AS milestones_total,
  (SELECT occurred_at FROM crm_activities a WHERE a.deal_id = d.id ORDER BY occurred_at DESC LIMIT 1) AS last_activity_at
FROM crm_deals d
JOIN crm_companies c ON d.company_id = c.id
LEFT JOIN crm_contacts ct ON d.contact_id = ct.id
WHERE d.deal_type IN ('maf_deploy_t1', 'maf_deploy_t2', 'maf_deploy_t3')
  AND c.deleted_at IS NULL
ORDER BY d.stage_entered_at DESC;

-- Today's actions — deals with tasks due today or overdue
CREATE OR REPLACE VIEW crm_today_actions AS
SELECT
  t.id AS task_id,
  t.title,
  t.due_date,
  t.priority,
  d.id AS deal_id,
  d.stage,
  d.deal_type,
  c.company_name,
  c.industry,
  ct.phone AS contact_phone,
  ct.email AS contact_email
FROM crm_tasks t
LEFT JOIN crm_deals d ON t.deal_id = d.id
LEFT JOIN crm_companies c ON d.company_id = c.id
LEFT JOIN crm_contacts ct ON t.contact_id = ct.id OR d.contact_id = ct.id
WHERE t.status = 'pending'
  AND t.due_date <= CURRENT_DATE
  AND (c.deleted_at IS NULL OR c.deleted_at IS NULL)
ORDER BY
  CASE WHEN t.due_date < CURRENT_DATE THEN 0 ELSE 1 END,
  t.due_date ASC,
  CASE t.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END;

-- ============================================================
-- 19. DEPLOY MILESTONE TEMPLATES
-- ============================================================
-- When a Deploy deal is created (maf_deploy_t1/t2/t3), auto-populate
-- the standard onboarding milestone checklist.
-- Called from crm_api.py after deal creation.

CREATE OR REPLACE FUNCTION populate_deploy_milestones(p_deal_id UUID, p_tier TEXT)
RETURNS VOID AS $$
BEGIN
  -- Pre-sale milestones (sales pipeline stages)
  INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
  VALUES
    (p_deal_id, 'sales', 'Scorecard completed', 'not_started', 1),
    (p_deal_id, 'sales', 'Discovery call completed', 'not_started', 2),
    (p_deal_id, 'sales', '6-Vector audit delivered', 'not_started', 3),
    (p_deal_id, 'sales', 'Growth Blocker Analysis presented', 'not_started', 4),
    (p_deal_id, 'sales', 'Proposal sent', 'not_started', 5),
    (p_deal_id, 'sales', 'SOW signed', 'not_started', 6);

  -- Onboarding milestones (post-sale, pre-go-live)
  INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
  VALUES
    (p_deal_id, 'onboarding', 'Integration checklist — CRM connected', 'not_started', 10),
    (p_deal_id, 'onboarding', 'Integration checklist — Email connected', 'not_started', 11),
    (p_deal_id, 'onboarding', 'Integration checklist — Calendar connected', 'not_started', 12);

  -- Tier-specific onboarding milestones
  IF p_tier IN ('maf_deploy_t2', 'maf_deploy_t3') THEN
    INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
    VALUES
      (p_deal_id, 'onboarding', 'Integration checklist — Accounting connected', 'not_started', 13),
      (p_deal_id, 'onboarding', 'Integration checklist — File storage connected', 'not_started', 14);
  END IF;

  IF p_tier = 'maf_deploy_t3' THEN
    INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
    VALUES
      (p_deal_id, 'onboarding', 'Custom integration — Additional system 1', 'not_started', 15),
      (p_deal_id, 'onboarding', 'Custom integration — Additional system 2', 'not_started', 16);
  END IF;

  -- Agent deployment milestones (all tiers)
  INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
  VALUES
    (p_deal_id, 'agent_deploy', 'Sales Agent configured', 'not_started', 20),
    (p_deal_id, 'agent_deploy', 'Operations Agent configured', 'not_started', 21),
    (p_deal_id, 'agent_deploy', 'Customer Success Agent configured', 'not_started', 22);

  -- Tier-specific agent milestones
  IF p_tier IN ('maf_deploy_t2', 'maf_deploy_t3') THEN
    INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
    VALUES
      (p_deal_id, 'agent_deploy', 'Finance Agent configured', 'not_started', 23),
      (p_deal_id, 'agent_deploy', 'Marketing Agent configured', 'not_started', 24);
  END IF;

  IF p_tier = 'maf_deploy_t3' THEN
    INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
    VALUES
      (p_deal_id, 'agent_deploy', 'Analytics Agent configured', 'not_started', 25);
  END IF;

  -- Go-live milestones
  INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
  VALUES
    (p_deal_id, 'go_live', 'Workflow mapping completed', 'not_started', 30),
    (p_deal_id, 'go_live', 'Dry-run test (20+ scenarios)', 'not_started', 31),
    (p_deal_id, 'go_live', 'Client training Session 1', 'not_started', 32),
    (p_deal_id, 'go_live', 'Client training Session 2', 'not_started', 33),
    (p_deal_id, 'go_live', 'Go-live sign-off', 'not_started', 34),
    (p_deal_id, 'go_live', '30-day check-in scheduled', 'not_started', 35);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 20. M&A MILESTONE TEMPLATES
-- ============================================================
CREATE OR REPLACE FUNCTION populate_ma_milestones(p_deal_id UUID)
RETURNS VOID AS $$
BEGIN
  INSERT INTO crm_deal_milestones (deal_id, milestone_type, milestone_name, status, sort_order)
  VALUES
    (p_deal_id, 'engagement', 'Engagement letter signed', 'not_started', 1),
    (p_deal_id, 'engagement', 'Retainer received', 'not_started', 2),
    (p_deal_id, 'ma', 'NDA executed', 'not_started', 10),
    (p_deal_id, 'ma', 'Financials received', 'not_started', 11),
    (p_deal_id, 'ma', 'Tax returns verified', 'not_started', 12),
    (p_deal_id, 'ma', 'Customer concentration analysis', 'not_started', 13),
    (p_deal_id, 'ma', 'Equipment condition assessment', 'not_started', 14),
    (p_deal_id, 'ma', 'Lien searches', 'not_started', 15),
    (p_deal_id, 'ma', 'Lease assignment reviewed', 'not_started', 16),
    (p_deal_id, 'ma', 'LOI drafted', 'not_started', 20),
    (p_deal_id, 'ma', 'LOI sent', 'not_started', 21),
    (p_deal_id, 'ma', 'LOI accepted', 'not_started', 22),
    (p_deal_id, 'ma', 'Purchase agreement drafted', 'not_started', 30),
    (p_deal_id, 'ma', 'Non-compete drafted', 'not_started', 31),
    (p_deal_id, 'ma', 'Transition agreement', 'not_started', 32),
    (p_deal_id, 'ma', 'Closing checklist — UCC-1 filing', 'not_started', 40),
    (p_deal_id, 'ma', 'Closing checklist — License transfer', 'not_started', 41),
    (p_deal_id, 'ma', 'Closing checklist — Escrow funding', 'not_started', 42),
    (p_deal_id, 'ma', 'Closing checklist — Settlement statement', 'not_started', 43),
    (p_deal_id, 'ma', 'Deal closed', 'not_started', 50),
    (p_deal_id, 'ma', 'Success fee invoiced', 'not_started', 51),
    (p_deal_id, 'ma', 'Success fee received', 'not_started', 52);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- END OF SCHEMA
-- ============================================================
-- Verification queries (run after deploy):
--   SELECT count(*) FROM crm_pipeline_stages;  -- should return 9
--   SELECT * FROM crm_pipeline_summary;         -- should return 7 rows (non-won/lost stages)
--   SELECT * FROM crm_sync_health;              -- should return 0 rows (no syncs yet)
--   SELECT tablename, policyname FROM pg_policies WHERE schemaname = 'public' AND tablename LIKE 'crm_%';
--     -- should show 4 policies per table (read, insert, update, delete)
-- ============================================================