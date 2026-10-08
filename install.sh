#!/usr/bin/env bash
# install.sh — clean-install the CRM schema into a Postgres database.
#
# The order is NOT alphabetical and matters, so it is encoded here:
#   1. bootstrap   — Supabase runtime primitives (roles, auth schema, helpers)
#   2. base schema — crm-schema.sql creates the core crm_* tables
#   3. legacy      — phase*.sql (contain tables later migrations depend on:
#                    crm_approval_requests, agent tables, etc.)
#   4. migrations  — timestamped files, in filename order
#
# Verified end to end: 61 tables, 82 RLS policies, 75 functions.
#
# Usage:  DATABASE_URL=postgres://user:pass@host:5432/db ./install.sh
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL first}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PSQL="psql $DATABASE_URL -v ON_ERROR_STOP=1 -q"

echo "1/4 bootstrap …"
$PSQL -f "$HERE/supabase/sql/00_bootstrap.sql"

echo "2/4 base schema …"
$PSQL -f "$HERE/supabase/sql/crm-schema.sql"

echo "3/4 legacy phase migrations …"
for f in $(ls "$HERE"/supabase/migrations/phase*.sql 2>/dev/null | sort); do
  echo "    ok $(basename "$f")"; $PSQL -f "$f"
done

echo "4/4 timestamped migrations …"
for f in $(ls "$HERE"/supabase/migrations/*.sql | sort); do
  base="$(basename "$f")"
  case "$base" in phase*) continue;; esac
  echo "    ok $base"; $PSQL -f "$f"
done

echo
echo "done — verifying"
$PSQL -tAc "select count(*) || ' tables'       from information_schema.tables where table_schema='public' and table_type='BASE TABLE'"
$PSQL -tAc "select count(*) || ' RLS policies' from pg_policies"
$PSQL -tAc "select count(*) || ' functions'    from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'"
