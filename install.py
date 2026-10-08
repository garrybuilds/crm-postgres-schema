#!/usr/bin/env python3
"""install.py — clean-install the CRM schema into Postgres. No psql required.

Same order as install.sh, but executed over a driver connection so it works
anywhere Python and psycopg are available:

  1. 00_bootstrap.sql      Supabase runtime primitives (roles, auth schema, helpers)
  2. crm-schema.sql        core crm_* tables
  3. phase*.sql            legacy migrations (tables later migrations depend on)
  4. timestamped migrations, in filename order
  5. deferred CREATE POLICY statements — applied last, after every table exists

The deferral in step 5 is deliberate and documented: several migrations create RLS
policies that reference `profiles` / `sys_roles` / tables introduced by later files,
so applying policies inline fails on a truly clean database. Deferring them is what
makes a from-scratch install succeed.

Usage:
    DATABASE_URL=postgres://user:pass@host:5432/db python install.py
    python install.py "postgres://user:pass@host:5432/db"
"""
from __future__ import annotations

import glob
import os
import re
import sys

try:
    import psycopg
except ImportError:  # pragma: no cover
    sys.exit("install.py needs psycopg:  pip install 'psycopg[binary]'")

HERE = os.path.dirname(os.path.abspath(__file__))
SUPA = os.path.join(HERE, "supabase")

POLICY_RE = re.compile(r"CREATE\s+POLICY\b", re.I)
DOLLAR_RE = re.compile(r"\$([A-Za-z_0-9]*)\$")


def _dollar_ranges(sql: str) -> list[tuple[int, int]]:
    """Spans of dollar-quoted blocks ($$ … $$ and $tag$ … $tag$).

    CREATE POLICY text inside these is part of a DO block's dynamic SQL, not a
    standalone statement, and must not be extracted.
    """
    spans: list[tuple[int, int]] = []
    i = 0
    while True:
        m = DOLLAR_RE.search(sql, i)
        if not m:
            break
        tag = m.group(0)
        close = sql.find(tag, m.end())
        if close == -1:
            break
        spans.append((m.start(), close + len(tag)))
        i = close + len(tag)
    return spans


def split_policies(sql: str) -> tuple[str, list[str]]:
    """Separate top-level CREATE POLICY statements from the rest.

    Policies inside dollar-quoted DO blocks (dynamic `EXECUTE format('CREATE POLICY …')`)
    are left alone — only real, executable statements are deferred.
    """
    spans = _dollar_ranges(sql)

    def inside_dollar(pos: int) -> bool:
        return any(a <= pos < b for a, b in spans)

    policies: list[str] = []
    rest: list[str] = []
    i = 0
    while True:
        m = POLICY_RE.search(sql, i)
        if not m:
            rest.append(sql[i:])
            break
        start = m.start()
        if inside_dollar(start) or sql[:start].count("'") % 2 == 1:
            rest.append(sql[i:m.end()])
            i = m.end()
            continue
        j, depth, instr = m.end(), 0, False
        while j < len(sql):
            c = sql[j]
            if c == "'":
                instr = not instr
            elif not instr:
                if c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                elif c == ";" and depth <= 0:
                    break
            j += 1
        policies.append(sql[start:j + 1])
        rest.append(sql[i:start])
        i = j + 1
    return "".join(rest), policies


def read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main() -> int:
    url = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DATABASE_URL")
    if not url:
        sys.exit("set DATABASE_URL or pass a connection string")

    conn = psycopg.connect(url, autocommit=True)
    cur = conn.cursor()

    policies: list[str] = []
    failures: list[str] = []
    applied = 0

    def run_file(path: str, label: str) -> None:
        nonlocal applied
        body, pols = split_policies(read(path))
        policies.extend(pols)
        if not body.strip():
            print(f"  ok   {label} (policies deferred)")
            applied += 1
            return
        try:
            cur.execute(body)
            print(f"  ok   {label}")
            applied += 1
        except Exception as exc:  # noqa: BLE001
            print(f"  FAIL {label}: {str(exc).splitlines()[0][:140]}")
            failures.append(label)

    print("1/4 bootstrap")
    run_file(os.path.join(SUPA, "sql", "00_bootstrap.sql"), "00_bootstrap.sql")

    print("2/4 base schema")
    run_file(os.path.join(SUPA, "sql", "crm-schema.sql"), "crm-schema.sql")

    print("3/4 legacy phase migrations")
    for f in sorted(glob.glob(os.path.join(SUPA, "migrations", "phase*.sql"))):
        run_file(f, os.path.basename(f))

    print("4/4 timestamped migrations")
    for f in sorted(glob.glob(os.path.join(SUPA, "migrations", "*.sql"))):
        base = os.path.basename(f)
        if base.startswith("phase"):
            continue
        run_file(f, base)

    print(f"\napplying {len(policies)} deferred RLS policies …")
    p_ok = p_fail = 0
    for pol in policies:
        try:
            cur.execute(pol)
            p_ok += 1
        except Exception as exc:  # noqa: BLE001
            p_fail += 1
            if p_fail <= 5:
                print(f"  policy FAIL: {str(exc).splitlines()[0][:120]}")

    cur.execute(
        "select count(*) from information_schema.tables "
        "where table_schema='public' and table_type='BASE TABLE'"
    )
    tables = cur.fetchone()[0]
    cur.execute("select count(*) from pg_policies")
    pol_live = cur.fetchone()[0]
    cur.execute(
        "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
        "where n.nspname='public'"
    )
    funcs = cur.fetchone()[0]

    print(f"\n=== {tables} tables · {pol_live} RLS policies · {funcs} functions ===")
    print(f"=== migrations: {applied} applied, {len(failures)} failed | policies: {p_ok} ok, {p_fail} failed ===")
    if failures:
        print("failed files:", failures)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
