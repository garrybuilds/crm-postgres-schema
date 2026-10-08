-- ============================================================
-- Migration: 20260808150100_create_eav_tables.sql
-- Phase 2.7 — EAV Custom Fields
-- ============================================================
-- Per-client custom fields via EAV (Entity-Attribute-Value).
-- All CRM entities support custom fields without schema changes.
-- Typed columns preserve type safety (Krayin pattern).
--
-- Garry runs this in the Supabase SQL Editor manually.
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_custom_attributes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID REFERENCES sys_clients(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL,           -- 'lead', 'company', 'contact', 'deal'
  attribute_code TEXT NOT NULL,        -- 'preferred_contact_method'
  attribute_name TEXT NOT NULL,       -- 'Preferred Contact Method'
  attribute_type TEXT NOT NULL,        -- 'text', 'number', 'boolean', 'date', 'datetime', 'select', 'multiselect', 'json'
  is_required BOOLEAN DEFAULT false,
  is_unique BOOLEAN DEFAULT false,
  is_searchable BOOLEAN DEFAULT false,
  options JSONB DEFAULT '[]',          -- for select/multiselect: [{"value":"email","label":"Email"}]
  validation JSONB DEFAULT '{}',       -- {"min":0,"max":100} for numbers, {"pattern":"..."} for text
  sort_order INT DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (client_id, entity_type, attribute_code)
);

CREATE TABLE IF NOT EXISTS sys_custom_attribute_values (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  attribute_id UUID REFERENCES sys_custom_attributes(id) ON DELETE CASCADE,
  entity_id UUID NOT NULL,             -- UUID of the record (lead_id, company_id, etc.)
  text_value TEXT,
  numeric_value NUMERIC,
  boolean_value BOOLEAN,
  date_value DATE,
  datetime_value TIMESTAMPTZ,
  json_value JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (attribute_id, entity_id)
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_custom_attr_entity ON sys_custom_attribute_values(entity_id);
CREATE INDEX IF NOT EXISTS idx_custom_attr_definition ON sys_custom_attribute_values(attribute_id);
CREATE INDEX IF NOT EXISTS idx_custom_attr_search ON sys_custom_attributes(client_id, entity_type) WHERE is_searchable = true;

-- RLS
ALTER TABLE sys_custom_attributes ENABLE ROW LEVEL SECURITY;
ALTER TABLE sys_custom_attribute_values ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users see own client attributes"
  ON sys_custom_attributes FOR SELECT TO authenticated
  USING (client_id IS NULL OR client_id = get_current_client_id());

CREATE POLICY "maf_admin can manage attributes"
  ON sys_custom_attributes FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid()
    AND role_id IN (SELECT id FROM sys_roles WHERE name IN ('maf_admin', 'maf_superadmin'))
  ));

CREATE POLICY "users read own entity values"
  ON sys_custom_attribute_values FOR SELECT TO authenticated
  USING (entity_belongs_to_tenant(entity_id));

CREATE POLICY "users write own entity values"
  ON sys_custom_attribute_values FOR ALL TO authenticated
  USING (entity_belongs_to_tenant(entity_id));