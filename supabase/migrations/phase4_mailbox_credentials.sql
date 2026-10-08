-- ============================================================
-- Phase 4 Supplement: Encrypted mailbox credentials
-- Stores IMAP passwords encrypted per-user, not in .env
-- ============================================================

CREATE TABLE IF NOT EXISTS crm_mailbox_credentials (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  email_address TEXT NOT NULL UNIQUE,
  imap_host TEXT NOT NULL DEFAULT 'imap0001.neo.space',
  imap_port INTEGER NOT NULL DEFAULT 993,
  smtp_host TEXT NOT NULL DEFAULT 'smtp0001.neo.space',
  smtp_port INTEGER NOT NULL DEFAULT 465,
  encrypted_password TEXT NOT NULL,
  enabled BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE crm_mailbox_credentials ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'crm_mailbox_credentials'
      AND policyname = 'crm_mailbox_credentials_authenticated'
  ) THEN
    CREATE POLICY crm_mailbox_credentials_authenticated ON crm_mailbox_credentials
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ============================================================
-- END OF Supplement
-- Verification:
--   SELECT table_name FROM information_schema.tables
--     WHERE table_name = 'crm_mailbox_credentials';
-- ============================================================