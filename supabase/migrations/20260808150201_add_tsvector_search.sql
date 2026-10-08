-- ============================================================
-- Migration: add_tsvector_search_hardened.sql
-- Purpose: Generated tsvector columns + GIN indexes + safe search function
-- Notes:
--   - Fixes crm_deals "source" column error (uses existing columns instead)
--   - Hardens search_records() to avoid column-mismatch errors per table
--   - Safe to re-run
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Rebuild search_vector on crm_companies
-- ------------------------------------------------------------
DROP INDEX IF EXISTS crm_companies_search_gin;
ALTER TABLE public.crm_companies
  DROP COLUMN IF EXISTS search_vector;

ALTER TABLE public.crm_companies
  ADD COLUMN search_vector tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'simple',
      coalesce(company_name, '') || ' ' ||
      coalesce(website, '')      || ' ' ||
      coalesce(industry, '')     || ' ' ||
      coalesce(city, '')         || ' ' ||
      coalesce(state, '')        || ' ' ||
      coalesce(source, '')
    )
  ) STORED;

CREATE INDEX crm_companies_search_gin
  ON public.crm_companies
  USING GIN (search_vector);

-- ------------------------------------------------------------
-- 2) Rebuild search_vector on crm_contacts
-- ------------------------------------------------------------
DROP INDEX IF EXISTS crm_contacts_search_gin;
ALTER TABLE public.crm_contacts
  DROP COLUMN IF EXISTS search_vector;

ALTER TABLE public.crm_contacts
  ADD COLUMN search_vector tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'simple',
      coalesce(first_name, '') || ' ' ||
      coalesce(last_name, '')  || ' ' ||
      coalesce(full_name, '')  || ' ' ||
      coalesce(email, '')      || ' ' ||
      coalesce(phone, '')      || ' ' ||
      coalesce(title, '')
    )
  ) STORED;

CREATE INDEX crm_contacts_search_gin
  ON public.crm_contacts
  USING GIN (search_vector);

-- ------------------------------------------------------------
-- 3) Rebuild search_vector on crm_deals
--    (FIX: removed non-existent "source" column)
-- ------------------------------------------------------------
DROP INDEX IF EXISTS crm_deals_search_gin;
ALTER TABLE public.crm_deals
  DROP COLUMN IF EXISTS search_vector;

ALTER TABLE public.crm_deals
  ADD COLUMN search_vector tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'simple',
      coalesce(deal_type, '')    || ' ' ||
      coalesce(stage, '')        || ' ' ||
      coalesce(assigned_to, '')  || ' ' ||
      coalesce(next_action, '')  || ' ' ||
      coalesce(loss_reason, '')
    )
  ) STORED;

CREATE INDEX crm_deals_search_gin
  ON public.crm_deals
  USING GIN (search_vector);

-- ------------------------------------------------------------
-- 4) Safe dynamic search function
--    - only allows known tables
--    - tsvector first, ILIKE fallback per-table
--    - avoids referencing columns that don't exist
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.search_records(
  table_name text,
  query text,
  limit_count int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result jsonb;
  safe_limit int := LEAST(GREATEST(COALESCE(limit_count, 50), 1), 500);
BEGIN
  IF table_name NOT IN ('crm_companies', 'crm_contacts', 'crm_deals') THEN
    RAISE EXCEPTION 'Unsupported table_name: %', table_name
      USING ERRCODE = '22023';
  END IF;

  -- Primary: full-text search via generated vector
  EXECUTE format(
    $f$
    SELECT jsonb_agg(row_to_json(t))
    FROM (
      SELECT *
      FROM public.%I
      WHERE search_vector @@ websearch_to_tsquery('simple', %L)
      ORDER BY ts_rank_cd(search_vector, websearch_to_tsquery('simple', %L)) DESC, created_at DESC
      LIMIT %s
    ) t
    $f$,
    table_name, query, query, safe_limit
  )
  INTO result;

  -- Fallback: per-table ILIKE, only valid columns for that table
  IF result IS NULL THEN
    IF table_name = 'crm_companies' THEN
      EXECUTE format(
        $f$
        SELECT jsonb_agg(row_to_json(t))
        FROM (
          SELECT *
          FROM public.crm_companies
          WHERE company_name ILIKE '%%' || %L || '%%'
             OR website      ILIKE '%%' || %L || '%%'
             OR industry     ILIKE '%%' || %L || '%%'
             OR city         ILIKE '%%' || %L || '%%'
             OR state        ILIKE '%%' || %L || '%%'
             OR source       ILIKE '%%' || %L || '%%'
          ORDER BY created_at DESC
          LIMIT %s
        ) t
        $f$,
        query, query, query, query, query, query, safe_limit
      )
      INTO result;

    ELSIF table_name = 'crm_contacts' THEN
      EXECUTE format(
        $f$
        SELECT jsonb_agg(row_to_json(t))
        FROM (
          SELECT *
          FROM public.crm_contacts
          WHERE first_name ILIKE '%%' || %L || '%%'
             OR last_name  ILIKE '%%' || %L || '%%'
             OR full_name  ILIKE '%%' || %L || '%%'
             OR email      ILIKE '%%' || %L || '%%'
             OR phone      ILIKE '%%' || %L || '%%'
             OR title      ILIKE '%%' || %L || '%%'
          ORDER BY created_at DESC
          LIMIT %s
        ) t
        $f$,
        query, query, query, query, query, query, safe_limit
      )
      INTO result;

    ELSIF table_name = 'crm_deals' THEN
      EXECUTE format(
        $f$
        SELECT jsonb_agg(row_to_json(t))
        FROM (
          SELECT *
          FROM public.crm_deals
          WHERE deal_type   ILIKE '%%' || %L || '%%'
             OR stage       ILIKE '%%' || %L || '%%'
             OR assigned_to ILIKE '%%' || %L || '%%'
             OR next_action ILIKE '%%' || %L || '%%'
             OR loss_reason ILIKE '%%' || %L || '%%'
          ORDER BY created_at DESC
          LIMIT %s
        ) t
        $f$,
        query, query, query, query, query, safe_limit
      )
      INTO result;
    END IF;
  END IF;

  RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

COMMIT;
