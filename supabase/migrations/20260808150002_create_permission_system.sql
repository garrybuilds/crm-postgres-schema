-- ============================================================
-- Migration: 20260808150002_create_permission_system.sql
-- Phase 1.1 — Three-layer permission system
-- ============================================================
-- Layer 1: Permission flags (dot-notation keys) + roles + role→permission mapping
-- Layer 2: Field-level permissions (role → entity → field → read/write/none)
-- Layer 3: Row-level security (Supabase RLS — already in place)
--
-- Replaces the flat 50+ boolean ALL_PERMS array.
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

-- ============================================================
-- Layer 1: Permission flags
-- ============================================================
CREATE TABLE IF NOT EXISTS sys_permission_flags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT NOT NULL UNIQUE,          -- e.g. 'tickets.view', 'tickets.manage'
  description TEXT,
  category TEXT NOT NULL,            -- e.g. 'tickets', 'fleet', 'settings'
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Layer 1: Roles
-- ============================================================
CREATE TABLE IF NOT EXISTS sys_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,         -- e.g. 'client_admin', 'maf_admin'
  description TEXT,
  is_system BOOLEAN DEFAULT false,    -- system roles can't be deleted
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Layer 1: Role → Permission mapping
-- ============================================================
CREATE TABLE IF NOT EXISTS sys_role_permissions (
  role_id UUID REFERENCES sys_roles(id) ON DELETE CASCADE,
  permission_key TEXT REFERENCES sys_permission_flags(key),
  PRIMARY KEY (role_id, permission_key)
);

-- ============================================================
-- Layer 2: Field-level permissions
-- ============================================================
CREATE TABLE IF NOT EXISTS sys_field_permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_id UUID REFERENCES sys_roles(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL,         -- e.g. 'deal', 'lead', 'company'
  field_key TEXT NOT NULL,           -- e.g. 'estimated_value', 'cost'
  access TEXT NOT NULL DEFAULT 'none', -- 'read', 'write', 'none'
  UNIQUE (role_id, entity_type, field_key)
);

-- ============================================================
-- Add FK: profiles.role_id → sys_roles.id
-- (profiles table created in migration 20260808150001 with role_id column
-- but no FK constraint, since sys_roles didn't exist yet)
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'profiles_role_id_fkey'
    AND table_name = 'profiles'
  ) THEN
    ALTER TABLE profiles
      ADD CONSTRAINT profiles_role_id_fkey
      FOREIGN KEY (role_id) REFERENCES sys_roles(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE sys_permission_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE sys_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE sys_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE sys_field_permissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "all authenticated can read permission_flags"
  ON sys_permission_flags FOR SELECT TO authenticated USING (true);
CREATE POLICY "all authenticated can read roles"
  ON sys_roles FOR SELECT TO authenticated USING (true);
CREATE POLICY "all authenticated can read role_permissions"
  ON sys_role_permissions FOR SELECT TO authenticated USING (true);
CREATE POLICY "all authenticated can read field_permissions"
  ON sys_field_permissions FOR SELECT TO authenticated USING (true);

-- Only maf_admin/superadmin can write
CREATE POLICY "maf_admin can manage roles"
  ON sys_roles FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))
  ));

CREATE POLICY "maf_admin can manage permission_flags"
  ON sys_permission_flags FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))
  ));

CREATE POLICY "maf_admin can manage role_permissions"
  ON sys_role_permissions FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))
  ));

CREATE POLICY "maf_admin can manage field_permissions"
  ON sys_field_permissions FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))
  ));

-- ============================================================
-- SEED DATA: System roles
-- ============================================================
INSERT INTO sys_roles (name, description, is_system) VALUES
  ('maf_superadmin', 'MAF super admin — all permissions, no restrictions', true),
  ('maf_admin', 'MAF staff admin — manage users, settings, all CRM data', true),
  ('maf_user', 'MAF staff user — full CRM access, no admin/settings', true),
  ('client_admin', 'Client administrator — manage own client data', true),
  ('client_manager', 'Client manager — manage own client data', true),
  ('client_viewer', 'Client viewer — read-only access to own client data', true)
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- SEED DATA: Permission flags
-- ============================================================
INSERT INTO sys_permission_flags (key, category, description) VALUES
  -- Dashboard
  ('dashboard.view', 'dashboard', 'View dashboard'),
  -- Leads
  ('leads.view', 'leads', 'View leads'),
  ('leads.create', 'leads', 'Create leads'),
  ('leads.edit', 'leads', 'Edit leads'),
  ('leads.delete', 'leads', 'Delete leads'),
  -- Deals
  ('deals.view', 'deals', 'View deals'),
  ('deals.create', 'deals', 'Create deals'),
  ('deals.edit', 'deals', 'Edit deals'),
  ('deals.delete', 'deals', 'Delete deals'),
  -- Companies
  ('companies.view', 'companies', 'View companies'),
  ('companies.create', 'companies', 'Create companies'),
  ('companies.edit', 'companies', 'Edit companies'),
  -- Contacts
  ('contacts.view', 'contacts', 'View contacts'),
  ('contacts.create', 'contacts', 'Create contacts'),
  ('contacts.edit', 'contacts', 'Edit contacts'),
  ('contacts.delete', 'contacts', 'Delete contacts'),
  -- Activities
  ('activities.view', 'activities', 'View activities'),
  ('activities.create', 'activities', 'Create activities'),
  -- Pipeline
  ('pipeline.view', 'pipeline', 'View pipeline'),
  ('pipeline.manage', 'pipeline', 'Manage pipeline stages'),
  -- Tickets
  ('tickets.view', 'tickets', 'View tickets'),
  ('tickets.create', 'tickets', 'Create tickets'),
  ('tickets.manage', 'tickets', 'Manage all tickets'),
  ('tickets.view_all', 'tickets', 'View tickets across all clients'),
  -- Fleet
  ('fleet.view', 'fleet', 'View fleet'),
  ('fleet.manage_onboarding', 'fleet', 'Manage onboarding'),
  ('fleet.view_clients', 'fleet', 'View client details'),
  ('fleet.view_alerts', 'fleet', 'View fleet alerts'),
  ('fleet.view_costs', 'fleet', 'View fleet costs'),
  -- Settings
  ('settings.view', 'settings', 'View settings'),
  ('settings.manage', 'settings', 'Manage settings'),
  -- Team
  ('team.view', 'team', 'View team members'),
  ('team.manage', 'team', 'Manage team members'),
  ('team.set_permissions', 'team', 'Set user permissions'),
  -- Billing
  ('billing.view', 'billing', 'View billing'),
  ('billing.manage', 'billing', 'Manage billing'),
  -- Docs
  ('docs.view', 'docs', 'View documents'),
  ('docs.manage', 'docs', 'Manage documents'),
  -- Training
  ('training.view', 'training', 'View training materials'),
  ('training.manage', 'training', 'Manage training materials'),
  -- Reports
  ('reports.view', 'reports', 'View reports'),
  ('reports.manage', 'reports', 'Manage reports')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- SEED DATA: Role → Permission mappings
-- ============================================================

-- maf_superadmin: ALL permissions
INSERT INTO sys_role_permissions (role_id, permission_key)
SELECT r.id, p.key FROM sys_roles r, sys_permission_flags p
WHERE r.name = 'maf_superadmin'
ON CONFLICT DO NOTHING;

-- maf_admin: ALL permissions
INSERT INTO sys_role_permissions (role_id, permission_key)
SELECT r.id, p.key FROM sys_roles r, sys_permission_flags p
WHERE r.name = 'maf_admin'
ON CONFLICT DO NOTHING;

-- maf_user: full CRM access, no admin/settings
INSERT INTO sys_role_permissions (role_id, permission_key)
SELECT r.id, p.key FROM sys_roles r, sys_permission_flags p
WHERE r.name = 'maf_user'
AND p.key IN (
  'dashboard.view',
  'leads.view', 'leads.create', 'leads.edit', 'leads.delete',
  'deals.view', 'deals.create', 'deals.edit', 'deals.delete',
  'companies.view', 'companies.create', 'companies.edit',
  'contacts.view', 'contacts.create', 'contacts.edit', 'contacts.delete',
  'activities.view', 'activities.create',
  'pipeline.view',
  'reports.view'
)
ON CONFLICT DO NOTHING;

-- client_admin: manage own client data + billing
INSERT INTO sys_role_permissions (role_id, permission_key)
SELECT r.id, p.key FROM sys_roles r, sys_permission_flags p
WHERE r.name = 'client_admin'
AND p.key IN (
  'dashboard.view',
  'leads.view', 'leads.create', 'leads.edit',
  'deals.view', 'deals.create', 'deals.edit',
  'companies.view', 'companies.create', 'companies.edit',
  'contacts.view', 'contacts.create', 'contacts.edit',
  'activities.view', 'activities.create',
  'pipeline.view',
  'tickets.view', 'tickets.create',
  'billing.view',
  'docs.view',
  'reports.view'
)
ON CONFLICT DO NOTHING;

-- client_manager: manage own client data, no billing
INSERT INTO sys_role_permissions (role_id, permission_key)
SELECT r.id, p.key FROM sys_roles r, sys_permission_flags p
WHERE r.name = 'client_manager'
AND p.key IN (
  'dashboard.view',
  'leads.view', 'leads.create', 'leads.edit',
  'deals.view', 'deals.create', 'deals.edit',
  'companies.view', 'companies.create', 'companies.edit',
  'contacts.view', 'contacts.create', 'contacts.edit',
  'activities.view', 'activities.create',
  'pipeline.view',
  'tickets.view', 'tickets.create',
  'docs.view'
)
ON CONFLICT DO NOTHING;

-- client_viewer: read-only
INSERT INTO sys_role_permissions (role_id, permission_key)
SELECT r.id, p.key FROM sys_roles r, sys_permission_flags p
WHERE r.name = 'client_viewer'
AND p.key IN (
  'dashboard.view',
  'leads.view',
  'deals.view',
  'companies.view',
  'contacts.view',
  'activities.view',
  'pipeline.view',
  'tickets.view',
  'docs.view',
  'reports.view'
)
ON CONFLICT DO NOTHING;

-- ============================================================
-- SEED DATA: Field-level permissions
-- ============================================================
-- Client roles cannot see cost/billing fields
INSERT INTO sys_field_permissions (role_id, entity_type, field_key, access)
SELECT r.id, 'deal', 'estimated_value', 'none'
FROM sys_roles r WHERE r.name IN ('client_manager', 'client_viewer')
ON CONFLICT DO NOTHING;

INSERT INTO sys_field_permissions (role_id, entity_type, field_key, access)
SELECT r.id, 'company', 'msp_client_id', 'none'
FROM sys_roles r WHERE r.name IN ('client_manager', 'client_viewer')
ON CONFLICT DO NOTHING;

INSERT INTO sys_field_permissions (role_id, entity_type, field_key, access)
SELECT r.id, 'company', 'score', 'none'
FROM sys_roles r WHERE r.name IN ('client_manager', 'client_viewer')
ON CONFLICT DO NOTHING;