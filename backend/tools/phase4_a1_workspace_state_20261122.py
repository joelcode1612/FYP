"""Phase A1 — read-only inspection of the disposable Stage 3 environment.

Everything here is SELECT-only against `project1_workflow_tests@127.0.0.1:5433`.
No DDL, no DML, no policy changes. Output is JSON for the evidence file.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import psycopg2

ENV = Path(__file__).resolve().parents[1] / "var" / "e2e" / "app.env"


def dsn() -> str:
    """Inspect as the application role itself.

    Deliberate: the point of A1 is to establish what the runtime can and cannot
    see. Reading the catalog as a superuser would hide exactly the privilege
    defect under investigation, and no superuser credential for this cluster is
    available. Every statement below is SELECT.
    """
    text = ENV.read_text(encoding="utf-8", errors="replace")
    url = re.search(r"^DATABASE_URL=(.+)$", text, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


RESEARCH_TABLES = [
    "m2_research_objective_sources",
    "m2_research_clarifications",
    "m2_research_revisions",
    "m2_desired_options",
    "m2_candidate_owner_reviews",
]


def main() -> int:
    out: dict = {}
    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = True
        cur = conn.cursor()

        cur.execute("select current_database(), current_user, version()")
        db, usr, ver = cur.fetchone()
        out["identity"] = {"database": db, "user": usr, "server_version": ver.split(",")[0]}

        cur.execute("show server_version_num")
        out["identity"]["server_version_num"] = cur.fetchone()[0]

        # --- the actor-scoping helper -------------------------------------
        cur.execute(
            """
            select p.oid::regprocedure::text as signature,
                   pg_get_function_result(p.oid) as returns,
                   p.prosecdef as security_definer,
                   p.provolatile as volatility,
                   l.lanname as language,
                   coalesce(array_to_string(p.proconfig, ','), '') as config,
                   pg_get_functiondef(p.oid) as body
            from pg_proc p
            join pg_language l on l.oid = p.prolang
            join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'project1_actor'
            """
        )
        rows = cur.fetchall()
        out["project1_actor"] = [
            {
                "signature": r[0],
                "returns": r[1],
                "security_definer": r[2],
                "volatility": r[3],
                "language": r[4],
                "proconfig": r[5],
                "definition": r[6],
            }
            for r in rows
        ]

        # --- who can execute it -------------------------------------------
        cur.execute(
            """
            select p.oid::regprocedure::text,
                   coalesce(array_to_string(p.proacl, ' | '), '(default: PUBLIC)')
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'project1_actor'
            """
        )
        out["project1_actor_acl"] = [
            {"signature": r[0], "acl": r[1]} for r in cur.fetchall()
        ]

        # --- m2_assessments policies --------------------------------------
        cur.execute(
            """
            select policyname, permissive, roles::text, cmd, qual, with_check
            from pg_policies
            where schemaname = 'public' and tablename = 'm2_assessments'
            order by policyname
            """
        )
        out["m2_assessments_policies"] = [
            {
                "name": r[0],
                "permissive": r[1],
                "roles": r[2],
                "cmd": r[3],
                "qual": r[4],
                "with_check": r[5],
            }
            for r in cur.fetchall()
        ]

        cur.execute(
            "select relrowsecurity, relforcerowsecurity, relowner::regrole::text "
            "from pg_class where oid = 'public.m2_assessments'::regclass"
        )
        r = cur.fetchone()
        out["m2_assessments_rls"] = {
            "enabled": r[0],
            "forced": r[1],
            "owner": r[2],
        }

        # --- the five research tables -------------------------------------
        tables: dict = {}
        for t in RESEARCH_TABLES:
            entry: dict = {}
            cur.execute("select to_regclass(%s)", (f"public.{t}",))
            if cur.fetchone()[0] is None:
                tables[t] = {"exists": False}
                continue
            entry["exists"] = True
            cur.execute(
                "select relrowsecurity, relforcerowsecurity from pg_class "
                "where oid = %s::regclass",
                (f"public.{t}",),
            )
            rr, rf = cur.fetchone()
            entry["rls_enabled"], entry["rls_forced"] = rr, rf
            cur.execute(
                "select policyname, cmd, qual from pg_policies "
                "where schemaname='public' and tablename=%s order by policyname",
                (t,),
            )
            entry["policies"] = [
                {"name": x[0], "cmd": x[1], "qual": x[2]} for x in cur.fetchall()
            ]
            cur.execute(
                "select privilege_type from information_schema.role_table_grants "
                "where table_schema='public' and table_name=%s "
                "and grantee='p1_m2_runtime' order by privilege_type",
                (t,),
            )
            entry["p1_m2_runtime_privileges"] = [x[0] for x in cur.fetchall()]
            # A denied count is itself evidence, so record which it was.
            try:
                cur.execute("select count(*) from public.%s" % t)
                entry["row_count"] = cur.fetchone()[0]
            except psycopg2.errors.InsufficientPrivilege:
                conn.rollback()
                entry["row_count"] = "DENIED"
                entry["row_count_note"] = (
                    "application role cannot SELECT this table; the exact defect"
                )
            # reltuples is a planner estimate and readable from the catalog even
            # when the rows are not, so it corroborates that data exists.
            cur.execute(
                "select reltuples::bigint from pg_class where oid = %s::regclass",
                (f"public.{t}",),
            )
            entry["reltuples_estimate"] = cur.fetchone()[0]
            tables[t] = entry
        out["research_tables"] = tables

        # --- m2_assessment_links / snapshots (the confirmation chain) ------
        for t in ("m2_assessment_links", "m2_confirmation_snapshots"):
            cur.execute("select to_regclass(%s)", (f"public.{t}",))
            if cur.fetchone()[0] is None:
                out.setdefault("chain", {})[t] = {"exists": False}
                continue
            try:
                cur.execute("select count(*) from public.%s" % t)
                out.setdefault("chain", {})[t] = {"exists": True, "rows": cur.fetchone()[0]}
            except psycopg2.errors.InsufficientPrivilege:
                conn.rollback()
                out.setdefault("chain", {})[t] = {
                    "exists": True,
                    "rows": "DENIED",
                    "note": "application role has no SELECT; M2 engine reads it instead",
                }

        # --- runtime role attributes --------------------------------------
        cur.execute(
            "select rolname, rolsuper, rolbypassrls, rolcanlogin "
            "from pg_roles where rolname in ('p1_m2_runtime','sitewise_e2e','p1ai_engine','p1ai_runtime') "
            "order by rolname"
        )
        out["roles"] = [
            {"role": r[0], "superuser": r[1], "bypassrls": r[2], "can_login": r[3]}
            for r in cur.fetchall()
        ]

        # --- migration bookkeeping, if any --------------------------------
        cur.execute(
            "select table_schema, table_name from information_schema.tables "
            "where table_name in ('schema_migrations','migrations','_migrations') "
            "and table_schema not in ('pg_catalog','information_schema')"
        )
        out["migration_tables"] = [f"{a}.{b}" for a, b in cur.fetchall()]

    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
