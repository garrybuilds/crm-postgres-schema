-- Lane C: per-user Hermes agent resolution map.
--
-- Security boundary:
--   * Authenticated users can SELECT only the row whose user_email matches
--     their verified JWT email claim.
--   * Only MAF admins can INSERT/UPDATE/DELETE rows.
--   * API keys never appear in logs, views, or public grants outside the
--     authenticated own-row policy.

CREATE TABLE IF NOT EXISTS crm_user_agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_email TEXT NOT NULL UNIQUE CHECK (user_email = lower(user_email)),
  profile_name TEXT NOT NULL UNIQUE,
  profile_url TEXT NOT NULL CHECK (
    profile_url ~ '^https://[a-z0-9.-]+\.ts\.net(:443|:8443)?/crm-agents/[a-z0-9-]+$'
  ),
  api_key TEXT NOT NULL CHECK (length(api_key) >= 32),
  api_port INTEGER NOT NULL UNIQUE CHECK (api_port BETWEEN 8653 AND 65535),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_user_agents_user_email
  ON crm_user_agents(user_email);

ALTER TABLE crm_user_agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_user_agents FORCE ROW LEVEL SECURITY;

CREATE POLICY "users can read own crm agent"
  ON crm_user_agents FOR SELECT TO authenticated
  USING (user_email = lower((SELECT auth.jwt()->>'email')));

CREATE POLICY "maf_admin can insert crm agents"
  ON crm_user_agents FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = auth.uid()
      AND p.role_id IN (
        SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
      )
  ));

CREATE POLICY "maf_admin can update crm agents"
  ON crm_user_agents FOR UPDATE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = auth.uid()
      AND p.role_id IN (
        SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
      )
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = auth.uid()
      AND p.role_id IN (
        SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
      )
  ));

CREATE POLICY "maf_admin can delete crm agents"
  ON crm_user_agents FOR DELETE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = auth.uid()
      AND p.role_id IN (
        SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
      )
  ));

REVOKE ALL ON crm_user_agents FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON crm_user_agents TO authenticated;

-- Adversarial-fold: keep updated_at truthful without relying on every admin
-- write to set it manually.
CREATE OR REPLACE FUNCTION crm_user_agents_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS crm_user_agents_updated_at ON crm_user_agents;
CREATE TRIGGER crm_user_agents_updated_at
  BEFORE UPDATE ON crm_user_agents
  FOR EACH ROW EXECUTE FUNCTION crm_user_agents_touch_updated_at();
