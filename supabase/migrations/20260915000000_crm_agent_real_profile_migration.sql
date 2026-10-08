-- 20260915000000 — CRM agent bindings point at real profiles (D-4/D-5).
--
-- STATUS: APPLIED 2026-09-15. The DDL below was applied to the live maf-crm
-- project through Supabase's migration API under the name
-- `crm_user_agents_multi_profile_binding` and is recorded in its migration
-- history. This file is the repo record of that change (repo ↔ live parity).
--
-- Context: docs/hermes-maf-integration.md §5.2b, decisions D-4..D-9.
--   * The crm-<name> clone profiles are design-deprecated and retired.
--   * Both CRM seats bind the real `maf` profile (G: "your my maf profile").
--   * D-7 (runtime profile selection) requires multiple bindings per user,
--     so the single-column UNIQUEs had to go. Constraint names verified
--     against live pg_catalog before the drop:
--       crm_user_agents_user_email_key    UNIQUE (user_email)
--       crm_user_agents_profile_name_key  UNIQUE (profile_name)
--       crm_user_agents_api_port_key      UNIQUE (api_port)
--     (profile_url has only a CHECK constraint, no UNIQUE.)
--
-- Data changes applied alongside (NOT in this file — keys never enter git):
--   * Old rows (agent@example.com, founder@example.com) deleted.
--   * Two rows inserted: founder@example.com and agent@example.com, both
--     profile_name='maf', profile_url='https://hermes-vps.tailc4fb0c.ts.net/crm-agents/maf',
--     api_port=8656, api_key=<maf profile's API_SERVER_KEY> (48 chars).
--   * Read-back verified: exactly 2 rows, both → maf:8656.
--
-- Live verification of the full chain (2026-09-15):
--   POST <row_url>/v1/chat/completions with the row key → HTTP 200, real
--   agent turn on the maf profile through router :3400 → Funnel 443.

ALTER TABLE crm_user_agents
  DROP CONSTRAINT IF EXISTS crm_user_agents_user_email_key;
ALTER TABLE crm_user_agents
  DROP CONSTRAINT IF EXISTS crm_user_agents_profile_name_key;
ALTER TABLE crm_user_agents
  DROP CONSTRAINT IF EXISTS crm_user_agents_api_port_key;
ALTER TABLE crm_user_agents
  ADD CONSTRAINT crm_user_agents_user_profile_unique UNIQUE (user_email, profile_name);

-- Notes:
--   * The profile_url CHECK (~ '^https://[a-z0-9.-]+\.ts\.net(:443|:8443)?/crm-agents/[a-z0-9-]+$')
--     and api_port CHECK (8653..65535) still hold: real profiles must mount
--     in the same port range and path shape the router/DB already enforce.
--     maf's API server was moved 8643 → 8656 for this reason (8653 is held
--     by the sirvir profile).
--   * RLS is untouched: own-row SELECT via auth.jwt()->>'email', admin-only
--     writes (4 policies confirmed live).
--   * Rollback (if ever needed): re-add the three single-column UNIQUEs —
--     only valid while each (user, profile_name, port) is distinct per row.
--
-- DO NOT RE-APPLY this file against the live project: the ADD CONSTRAINT has
-- no IF NOT EXISTS form (Postgres does not support it for ADD CONSTRAINT), so
-- `supabase db push` of this file errors on the already-present
-- crm_user_agents_user_profile_unique. The live project already has this
-- migration recorded (crm_user_agents_multi_profile_binding,
-- supabase_migrations.schema_migrations) — this file exists for repo parity
-- and fresh-environment bootstrap only.
