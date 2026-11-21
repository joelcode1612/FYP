"""CP-03F-04 / D05: pre-flight for the proposed finding_provenance migration.

Read-only. Dispatches nothing and writes nothing.

The migration `migrations/project1_ai/20261117_02_finding_provenance.sql` is
PROPOSED, not applied. A true dry run (apply inside a transaction, assert, roll
back) needs a principal with CREATE on schema `project1_ai`. On this host no
login role holds that:

  * `p1ai_owner` owns the schema, is NOLOGIN and has no members;
  * `p1ai_runtime` / `p1ai_audit` hold USAGE only;
  * `p1ai_engine` is a member of `p1ai_runtime` but is NOINHERIT, so it must
    `SET LOCAL ROLE` and still only reaches USAGE;
  * `p1_m2_runtime` has no grant on the schema at all;
  * `Dss` is owned by `postgres`, for which no credential is configured;
  * a disposable clone is unavailable (Docker daemon not running).

So instead of pretending to dry-run, this probe answers the question that
actually decides whether the migration will succeed once an operator runs it:
does every object and constraint the DDL depends on exist, with the shape the
DDL assumes? It also reports whether an apply principal exists at all.

Verdicts:
  PASS        the dependency exists with the required shape
  FAIL        the dependency exists but the shape is wrong (the DDL would fail)
  NOT_INSPECTABLE  the current principal may not read the evidence; not a
              property of the migration, so it does not gate the verdict
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402

MIGRATION = (Path(__file__).resolve().parents[1]
             / "migrations" / "project1_ai" / "20261117_02_finding_provenance.sql")

# (key, label, sql, expected) — expected ">0" means strictly positive.
CHECKS: list[tuple[str, str, str, str]] = [
    ("R1", "schema project1_ai exists",
     "SELECT count(*) FROM pg_namespace WHERE nspname='project1_ai'", "1"),
    ("R2", "project1_ai.runs exists",
     "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
     "WHERE n.nspname='project1_ai' AND c.relname='runs' AND c.relkind='r'", "1"),
    ("R3", "project1_ai.attempts exists",
     "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
     "WHERE n.nspname='project1_ai' AND c.relname='attempts' AND c.relkind='r'", "1"),
    # The composite FK (run_id, owner_user_id, attempt_no) requires a matching
    # unique constraint on the referenced table, or CREATE TABLE fails with
    # "there is no unique constraint matching given keys for referenced table".
    ("R4", "unique key on attempts(run_id, owner_user_id, attempt_no)",
     "SELECT count(*) FROM pg_constraint k "
     "JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace "
     "WHERE n.nspname='project1_ai' AND c.relname='attempts' "
     "AND k.contype IN ('p','u') AND k.conkey @> ARRAY["
     "  (SELECT attnum FROM pg_attribute WHERE attrelid=c.oid AND attname='run_id'),"
     "  (SELECT attnum FROM pg_attribute WHERE attrelid=c.oid AND attname='owner_user_id'),"
     "  (SELECT attnum FROM pg_attribute WHERE attrelid=c.oid AND attname='attempt_no')]::smallint[]",
     "1"),
    ("R5", "public.m2_bdj_findings exists",
     "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
     "WHERE n.nspname='public' AND c.relname='m2_bdj_findings' AND c.relkind='r'", "1"),
    ("R6", "public.m2_bdj_findings.id is uuid",
     "SELECT format_type(a.atttypid,a.atttypmod) FROM pg_attribute a "
     "JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace "
     "WHERE n.nspname='public' AND c.relname='m2_bdj_findings' AND a.attname='id'", "uuid"),
    ("R7", "public.m2_assessments.id is uuid",
     "SELECT format_type(a.atttypid,a.atttypmod) FROM pg_attribute a "
     "JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace "
     "WHERE n.nspname='public' AND c.relname='m2_assessments' AND a.attname='id'", "uuid"),
    ("R8", "project1_ai.deny_mutation() exists and returns trigger",
     "SELECT p.prorettype = 'trigger'::regtype::oid FROM pg_proc p "
     "JOIN pg_namespace n ON n.oid=p.pronamespace "
     "WHERE n.nspname='project1_ai' AND p.proname='deny_mutation'", "True"),
    ("R9", "target table project1_ai.finding_provenance does NOT exist",
     "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
     "WHERE n.nspname='project1_ai' AND c.relname='finding_provenance'", "0"),
    ("R10", "schema_versions has no 20261117_02 row",
     "SELECT count(*) FROM project1_ai.schema_versions "
     "WHERE version='20261117_02_finding_provenance'", "0"),
    ("R11", "roles p1ai_owner / p1ai_runtime / p1ai_audit exist",
     "SELECT count(*) FROM pg_roles "
     "WHERE rolname IN ('p1ai_owner','p1ai_runtime','p1ai_audit')", "3"),
    # Apply authority: the operator must be able to CREATE in the schema.
    ("R12", "an apply principal exists (superuser or member of p1ai_owner)",
     "SELECT count(*) FROM pg_roles r WHERE r.rolsuper "
     "OR (r.rolcanlogin AND pg_has_role(r.rolname,'p1ai_owner','member'))", ">0"),
]

# R10 needs SELECT on a table the ledger roles were never granted; the migration
# itself fails closed on re-application, so an unreadable row is informational.
INFORMATIONAL = {"R10"}


def run_check(engine, sql: str):
    """One short transaction per check: a denial must not abort the rest."""
    with engine.connect() as c:
        tx = c.begin()
        try:
            # The sanctioned path to USAGE on project1_ai is SET LOCAL ROLE into
            # the NOLOGIN restricted role; the login is NOINHERIT.
            c.execute(text("SET LOCAL ROLE p1ai_runtime"))
        except Exception:  # noqa: BLE001 - already the restricted role, or denied
            pass
        try:
            return c.execute(text(sql)).scalar(), None
        except Exception as exc:  # noqa: BLE001 - report, never raise
            return None, f"{type(exc).__name__}: {str(exc).splitlines()[0]}"
        finally:
            tx.rollback()


def main() -> int:
    engine = create_engine(settings.project1_runtime_database_url.get_secret_value(),
                           hide_parameters=True)
    results: list[tuple[str, str, str, str]] = []
    for key, label, sql, expected in CHECKS:
        value, error = run_check(engine, sql)
        if error is not None:
            verdict = "NOT_INSPECTABLE" if key in INFORMATIONAL else "BLOCKED"
            results.append((key, label, verdict, error))
            continue
        if expected == ">0":
            verdict = "PASS" if int(value or 0) > 0 else "BLOCKED"
            detail = f"expected >0, got {value}"
        else:
            verdict = "PASS" if str(value) == expected else "FAIL"
            detail = f"expected {expected}, got {value}"
        results.append((key, label, verdict, detail))

    owners, _ = run_check(
        engine,
        "SELECT coalesce(string_agg(r.rolname, ',' ORDER BY r.rolname), '') FROM pg_roles r "
        "WHERE r.rolsuper OR (r.rolcanlogin AND pg_has_role(r.rolname,'p1ai_owner','member'))")
    cannot, _ = run_check(
        engine,
        "SELECT coalesce(string_agg(r.rolname, ',' ORDER BY r.rolname), '') FROM pg_roles r "
        "WHERE r.rolcanlogin AND r.rolname LIKE 'p1ai%' "
        "AND NOT pg_has_role(r.rolname,'p1ai_owner','member')")

    width = max(len(label) for _, label, _, _ in results)
    for key, label, verdict, detail in results:
        print(f"{key:<4} {verdict:<15} {label:<{width}}  {detail}")

    gating = [r for r in results if r[0] not in INFORMATIONAL]
    failing = [r for r in gating if r[2] != "PASS"]
    print()
    print(f"MIGRATION       {MIGRATION.name}")
    print(f"APPLY_PRINCIPAL {owners or 'NONE'}")
    print(f"CANNOT_APPLY    {cannot or 'n/a'}")
    print(f"checks          {len(results)}  pass={sum(1 for r in results if r[2]=='PASS')}  "
          f"fail={sum(1 for r in results if r[2]=='FAIL')}  "
          f"blocked={sum(1 for r in results if r[2]=='BLOCKED')}  "
          f"not_inspectable={sum(1 for r in results if r[2]=='NOT_INSPECTABLE')}")
    if any(r[2] == "FAIL" for r in failing):
        verdict = "INCOMPATIBLE"
    elif failing:
        verdict = "BLOCKED"
    else:
        verdict = "READY_FOR_OPERATOR"
    print(f"VERDICT         {verdict}")
    print("NOTE            static pre-flight only; no DDL executed, no dry run performed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
