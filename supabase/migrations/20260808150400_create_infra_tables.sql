-- ============================================================
-- Migration: 20260808150400_create_infra_tables.sql
-- Phase 11 — File Management, Notifications, Webhooks, Integrations
-- ============================================================
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

-- Files (metadata for uploads to Supabase Storage)
CREATE TABLE IF NOT EXISTS sys_files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type TEXT NOT NULL,
  entity_id UUID NOT NULL,
  folder TEXT NOT NULL,            -- 'attachment', 'proposal', 'invoice', 'avatar'
  file_name TEXT NOT NULL,
  file_size INT NOT NULL,
  mime_type TEXT NOT NULL,
  storage_path TEXT NOT NULL,     -- Supabase Storage path
  uploaded_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_files_entity ON sys_files(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_files_folder ON sys_files(folder);

ALTER TABLE sys_files ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own tenant files" ON sys_files FOR SELECT TO authenticated
  USING (entity_belongs_to_tenant(entity_id));
CREATE POLICY "users create files" ON sys_files FOR INSERT TO authenticated
  WITH CHECK (entity_belongs_to_tenant(entity_id));

-- Notifications
CREATE TABLE IF NOT EXISTS sys_notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  type TEXT NOT NULL,              -- 'mention', 'assignment', 'status_change', 'task_due'
  entity_type TEXT,
  entity_id UUID,
  title TEXT NOT NULL,
  body TEXT,
  is_read BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON sys_notifications(user_id, is_read);
CREATE INDEX IF NOT EXISTS idx_notifications_created ON sys_notifications(created_at DESC);

ALTER TABLE sys_notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own notifications" ON sys_notifications FOR SELECT TO authenticated
  USING (user_id = auth.uid());
CREATE POLICY "users manage own notifications" ON sys_notifications FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- Notification subscriptions
CREATE TABLE IF NOT EXISTS sys_notification_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL,
  entity_id UUID NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (user_id, entity_type, entity_id)
);

ALTER TABLE sys_notification_subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users manage own subscriptions" ON sys_notification_subscriptions FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- Processed webhooks (idempotency)
CREATE TABLE IF NOT EXISTS sys_processed_webhooks (
  event_id TEXT PRIMARY KEY,
  source TEXT NOT NULL,            -- 'stripe', 'github', 'smartlead', 'calcom'
  event_type TEXT,
  processed_at TIMESTAMPTZ DEFAULT now()
);

-- Integrations (OAuth config)
CREATE TABLE IF NOT EXISTS sys_integrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL,         -- 'slack', 'github', 'google'
  name TEXT NOT NULL,
  config JSONB NOT NULL,          -- OAuth client_id, scopes, etc.
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE sys_integrations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "maf_admin manage integrations" ON sys_integrations FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))));
CREATE POLICY "authenticated read integrations" ON sys_integrations FOR SELECT TO authenticated USING (true);

-- Integration tokens (encrypted)
CREATE TABLE IF NOT EXISTS sys_integration_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  integration_id UUID REFERENCES sys_integrations(id) ON DELETE CASCADE,
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  access_token_encrypted BYTEA NOT NULL,
  refresh_token_encrypted BYTEA,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE sys_integration_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own tokens" ON sys_integration_tokens FOR SELECT TO authenticated
  USING (user_id = auth.uid());
CREATE POLICY "users manage own tokens" ON sys_integration_tokens FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- Import batches (for progress tracking)
CREATE TABLE IF NOT EXISTS sys_import_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type TEXT NOT NULL,
  total_rows INT DEFAULT 0,
  processed_rows INT DEFAULT 0,
  status TEXT DEFAULT 'pending',  -- 'pending', 'running', 'completed', 'failed'
  error_message TEXT,
  created_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

ALTER TABLE sys_import_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own import batches" ON sys_import_batches FOR SELECT TO authenticated
  USING (created_by = auth.uid());
CREATE POLICY "users create import batches" ON sys_import_batches FOR INSERT TO authenticated
  WITH CHECK (created_by = auth.uid());