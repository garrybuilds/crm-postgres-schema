# CRM schema — a production Postgres multi-tenant CRM

**The database layer of a CRM I built and run in production**, published here for review. It is the schema, the security model, and the automation behind a live customer pipeline — not a tutorial.

**26 migrations · 2,724 lines of SQL · 82 row-level-security policies · 13 core tables · EAV extension tables · a workflow engine · an approval executor · webhook ingestion with idempotency.**

> **What this is:** the real schema and migrations, redacted of client data and credentials.
> **What this is not:** the application code or any customer records. No keys, no client names, no PII.

---

## Why it exists

I advise and build for small service businesses. Every one of them ran their pipeline in a spreadsheet that had quietly become the system of record, and every one had the same three failure modes: deals lost in the cracks, no audit trail on who changed what, and no way to answer "where did this lead go."

So I built the thing I kept describing: a multi-tenant CRM where the database enforces the rules instead of trusting the application to. That decision — push correctness into Postgres — is what most of this repository is about.

## The design decisions worth reading

### 1. Multi-tenancy enforced by row-level security, not by WHERE clauses
82 RLS policies. Every table that holds tenant data is scoped by policy to the requesting principal. The application never has to remember to filter; a query that forgets `WHERE tenant_id = ...` returns nothing rather than returning everything. This is the single most important choice in the schema — and the one most CRMs get wrong.

### 2. A permission system that is data, not code
Roles, permissions, and per-field grants live in tables (`permission_system` migration). A client administrator's abilities are rows, not branches. Adding a role is an insert, not a deploy.

### 3. EAV tables with a typed status machine on the side
Flexible entity attributes for the fields that differ per business, with a separate status-machine table governing legal transitions. Flexibility where it's needed, strictness where correctness matters.

### 4. Idempotent webhook ingestion
`sys_webhook_events` records every inbound event, and the handlers are written to be safe to replay. The bug that taught me this: a re-import created duplicate rows because the dedup key wasn't unique-constrained. The fix — a proper unique constraint plus replay-safe handling — is in this schema, and the migration history shows the repair.

### 5. Change auditing as a trigger, not an application concern
Audit triggers record who changed what, when. Because the trail lives in the database, it cannot be bypassed by a service that forgot to log.

### 6. A workflow engine and an approval executor
Automations (stage transitions, follow-ups, approvals) are defined as data and executed by a shared executor — so a business rule change is configuration, not a code change.

## Layout

```
supabase/
  sql/
    00_bootstrap.sql   Supabase runtime primitives (roles, auth schema, helpers)
    crm-schema.sql     the core crm_* tables
    funnel-views.sql   reporting views
    revenue-forecast-views.sql
    stage-transitions.sql
  migrations/   26 ordered migrations (legacy phase*.sql + timestamped)
  functions/    three Deno edge functions (webhook receivers)
                calcom-webhook · smartlead-webhook · lead-capture-submit
install.sh      clean-install script (encodes the non-alphabetical order)
```

The edge functions read every secret from the environment (`Deno.env`), fail closed when a required secret is absent, and validate inbound payloads before writing. None of them contains a credential.

## Reading order for a reviewer

1. `migrations/20260808150001_create_profiles_and_tenants.sql` — the tenancy model
2. `migrations/20260808150002_create_permission_system.sql` — data-driven permissions
3. `sql/crm-schema.sql` — the whole schema in one readable file
4. `migrations/20260903000000_create_sys_webhook_events.sql` — idempotent ingestion
5. `migrations/20260908000000_email_activity_dedup.sql` — the dedup fix, with its verification notes
6. `sql/funnel-views.sql` / `revenue-forecast-views.sql` — the reporting layer

## Running it

Requires Postgres 15+. The install order is not alphabetical, so use the installer:

```bash
pip install 'psycopg[binary]'
DATABASE_URL=postgres://user:pass@host:5432/db python install.py
# or: DATABASE_URL=... ./install.sh   (needs psql)
```

`install.py` defers every `CREATE POLICY` until after all tables exist. That is
deliberate: several migrations create RLS policies referencing `profiles`,
`sys_roles`, or tables introduced by *later* files, so applying policies inline
fails on a genuinely clean database. On real Supabase, skip `00_bootstrap.sql`
(roles and `auth.*` already exist).

**Verified from a clean database** on Postgres 16:

```
=== 61 tables · 133 RLS policies · 75 functions ===
=== migrations: 28 applied, 0 failed | policies: 69 ok, 0 failed ===
```

That run is the one this README reports — reproducible with `install.py`.

## Stack

PostgreSQL · Supabase (RLS, RPCs, triggers, edge functions) · SQL · TypeScript (Deno edge functions)

## License

MIT
