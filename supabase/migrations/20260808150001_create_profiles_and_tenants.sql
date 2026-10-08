-- ============================================================
-- Migration: 20260808150001_create_profiles_and_tenants.sql
-- Phase 1.1a — Tenant infrastructure (profiles table + helper functions)
-- ============================================================
-- This migration introduces multi-tenant support to the CRM project.
-- Previously the CRM was single-tenant (authenticated-only RLS, no profiles).
-- Now we need:
--   1. profiles table — links Supabase auth.users to roles + client_id
--   2. clients table — tenant records (companies using the CRM)
--   3. get_current_client_id() — helper function for RLS policies
--   4. entity_belongs_to_tenant() — helper to check if a record belongs
--      to the current user's client
--
-- The existing 12 crm_* tables don't have client_id columns yet.
-- They will be added incrementally in Phase 2 when we refactor the
-- data model. For now, the tenant helpers return true for all entities
-- (single-tenant compatibility mode) so existing RLS policies still work.
--
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

-- ============================================================
-- 1. CLIENTS (tenant table)
-- ============================================================
CREATE TABLE IF NOT EXISTS sys_clients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',  -- 'active', 'suspended', 'churned'
  meta JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE sys_clients ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated can read clients"
  ON sys_clients FOR SELECT TO authenticated USING (true);

CREATE POLICY "maf_admin can manage clients"
  ON sys_clients FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
    AND role_id IN (
      SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
    )
  ));

-- ============================================================
-- 2. PROFILES
-- ============================================================
-- Links Supabase auth.users to role + client_id (tenant).
-- In multi-tenant mode, a user belongs to a client and has a role.
-- MAF staff users have role maf_admin/maf_user and no client_id.
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  full_name TEXT,
  avatar_url TEXT,
  client_id UUID REFERENCES sys_clients(id) ON DELETE SET NULL,
  role_id UUID,  -- FK added in migration 20260808150002 (sys_roles must exist first)
  permission_overrides JSONB DEFAULT '{}'::jsonb,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- Users can read their own profile
CREATE POLICY "users can read own profile"
  ON profiles FOR SELECT TO authenticated
  USING (auth.uid() = id OR EXISTS (
    SELECT 1 FROM profiles p WHERE p.id = auth.uid()
    AND p.role_id IN (
      SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
    )
  ));

-- Users can update their own profile (limited fields)
CREATE POLICY "users can update own profile"
  ON profiles FOR UPDATE TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- MAF admins can manage all profiles
CREATE POLICY "maf_admin can manage profiles"
  ON profiles FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles p WHERE p.id = auth.uid()
    AND p.role_id IN (
      SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin')
    )
  ));

-- ============================================================
-- 3. HELPER FUNCTION: get_current_client_id()
-- ============================================================
-- Returns the client_id of the current authenticated user.
-- Returns NULL for MAF staff (they have no client_id — they see all).
-- Used in RLS policies like: client_id = get_current_client_id()
CREATE OR REPLACE FUNCTION get_current_client_id()
RETURNS UUID
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT client_id FROM profiles WHERE id = auth.uid();
$$;

-- ============================================================
-- 4. HELPER FUNCTION: entity_belongs_to_tenant()
-- ============================================================
-- Checks if a given entity record belongs to the current user's tenant.
-- Phase 1: returns true for all (single-tenant compatibility — existing
-- crm_* tables don't have client_id columns yet).
-- Phase 2: will be expanded to check client_id on each entity table.
CREATE OR REPLACE FUNCTION entity_belongs_to_tenant(entity_id UUID)
RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  -- Phase 1: single-tenant compatibility — all entities accessible to authenticated users
  -- Phase 2: will check client_id on crm_companies, crm_deals, etc.
  SELECT true;
$$;

-- ============================================================
-- 5. TRIGGER: Auto-create profile on new auth user
-- ============================================================
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- 6. INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_profiles_email ON profiles(email);
CREATE INDEX IF NOT EXISTS idx_profiles_client_id ON profiles(client_id);
CREATE INDEX IF NOT EXISTS idx_profiles_role_id ON profiles(role_id);