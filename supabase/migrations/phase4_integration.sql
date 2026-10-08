-- ============================================================
-- Phase 4: Integration Layer
-- Adds: calendar events + attendees, email sync tables.
-- All statements are idempotent — run twice safely.
-- ============================================================

-- ============================================================
-- 1. crm_calendar_events — synced from Cal.com
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_calendar_events (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  cal_uid TEXT NOT NULL UNIQUE,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  title TEXT NOT NULL,
  location TEXT,
  conference_url TEXT,
  organizer_email TEXT,
  status TEXT DEFAULT 'confirmed',
  deal_id UUID REFERENCES crm_deals(id) ON DELETE SET NULL,
  synced_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_calendar_starts
  ON crm_calendar_events(starts_at);
CREATE INDEX IF NOT EXISTS idx_calendar_cal_uid
  ON crm_calendar_events(cal_uid);
CREATE INDEX IF NOT EXISTS idx_calendar_deal
  ON crm_calendar_events(deal_id);

ALTER TABLE crm_calendar_events ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_calendar_events'
      AND policyname = 'crm_calendar_events_authenticated'
  ) THEN
    CREATE POLICY crm_calendar_events_authenticated ON crm_calendar_events
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- 2. crm_calendar_attendees — matched to CRM contacts
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_calendar_attendees (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  event_id UUID NOT NULL REFERENCES crm_calendar_events(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  name TEXT,
  response_status TEXT DEFAULT 'needs_action',
  is_organizer BOOLEAN DEFAULT FALSE,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_attendees_event
  ON crm_calendar_attendees(event_id);
CREATE INDEX IF NOT EXISTS idx_attendees_email
  ON crm_calendar_attendees(email);
CREATE INDEX IF NOT EXISTS idx_attendees_contact
  ON crm_calendar_attendees(contact_id);

ALTER TABLE crm_calendar_attendees ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_calendar_attendees'
      AND policyname = 'crm_calendar_attendees_authenticated'
  ) THEN
    CREATE POLICY crm_calendar_attendees_authenticated ON crm_calendar_attendees
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- 3. crm_mailbox_sync — IMAP sync state
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_mailbox_sync (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  email_address TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'imap',
  status TEXT NOT NULL DEFAULT 'IDLE',
  cursor TEXT,
  last_synced_at TIMESTAMPTZ,
  last_error TEXT,
  retry_after TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mailbox_email
  ON crm_mailbox_sync(email_address);
CREATE INDEX IF NOT EXISTS idx_mailbox_status
  ON crm_mailbox_sync(status);

ALTER TABLE crm_mailbox_sync ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_mailbox_sync'
      AND policyname = 'crm_mailbox_sync_authenticated'
  ) THEN
    CREATE POLICY crm_mailbox_sync_authenticated ON crm_mailbox_sync
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- 4. crm_email_threads — threaded email conversations
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_email_threads (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  root_message_id TEXT,
  subject TEXT,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  company_id UUID REFERENCES crm_companies(id) ON DELETE SET NULL,
  deal_id UUID REFERENCES crm_deals(id) ON DELETE SET NULL,
  direction TEXT DEFAULT 'inbound',
  message_count INTEGER DEFAULT 0,
  last_message_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_threads_root
  ON crm_email_threads(root_message_id);
CREATE INDEX IF NOT EXISTS idx_threads_contact
  ON crm_email_threads(contact_id);
CREATE INDEX IF NOT EXISTS idx_threads_company
  ON crm_email_threads(company_id);

ALTER TABLE crm_email_threads ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_email_threads'
      AND policyname = 'crm_email_threads_authenticated'
  ) THEN
    CREATE POLICY crm_email_threads_authenticated ON crm_email_threads
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- 5. crm_email_messages — individual messages
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_email_messages (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  thread_id UUID REFERENCES crm_email_threads(id) ON DELETE CASCADE,
  message_id TEXT NOT NULL,
  direction TEXT NOT NULL,
  from_email TEXT NOT NULL,
  to_emails TEXT,
  cc_emails TEXT,
  subject TEXT,
  snippet TEXT,
  body TEXT,
  has_attachments BOOLEAN DEFAULT FALSE,
  contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL,
  company_id UUID REFERENCES crm_companies(id) ON DELETE SET NULL,
  received_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_thread
  ON crm_email_messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_messages_message_id
  ON crm_email_messages(message_id);
CREATE INDEX IF NOT EXISTS idx_messages_contact
  ON crm_email_messages(contact_id);
CREATE INDEX IF NOT EXISTS idx_messages_received
  ON crm_email_messages(received_at);

ALTER TABLE crm_email_messages ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_email_messages'
      AND policyname = 'crm_email_messages_authenticated'
  ) THEN
    CREATE POLICY crm_email_messages_authenticated ON crm_email_messages
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- END OF Phase 4 Migration
-- Verification:
--   SELECT table_name FROM information_schema.tables
--     WHERE table_name IN ('crm_calendar_events','crm_calendar_attendees',
--       'crm_mailbox_sync','crm_email_threads','crm_email_messages');
--   SELECT relname, relrowsecurity FROM pg_class
--     WHERE relname IN ('crm_calendar_events','crm_calendar_attendees',
--       'crm_mailbox_sync','crm_email_threads','crm_email_messages');
-- ============================================================