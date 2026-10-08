-- ============================================================
-- 00_bootstrap.sql — provision the Supabase runtime primitives
-- ============================================================
-- A vanilla Postgres has none of the things Supabase provides for free:
-- the anon / authenticated / service_role roles, the auth schema, and the
-- auth.uid() / auth.jwt() helpers that every RLS policy here calls.
--
-- Run this FIRST on a plain Postgres instance. On real Supabase it is a
-- no-op (everything already exists) and is safe to skip.
--
--   psql "$DATABASE_URL" -f supabase/sql/00_bootstrap.sql
-- ============================================================

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    create role supabase_admin nologin;
  end if;
end $$;

create schema if not exists auth;
create schema if not exists extensions;

create extension if not exists pgcrypto;      -- gen_random_uuid()

-- Minimal stand-in for Supabase's auth.users. On real Supabase this table
-- is managed by GoTrue; do not create it there.
create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text unique,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at         timestamptz default now()
);

-- The two JWT helpers every RLS policy depends on.
create or replace function auth.uid() returns uuid
  language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
  $$;

create or replace function auth.jwt() returns jsonb
  language sql stable as $$
    select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
  $$;
