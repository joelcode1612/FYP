"""CP-04A A1 — reconcile the two migrations that wrote no schema_versions receipt.

`20261116_02_m2_runtime_role.sql` and `20261117_01_execution_principal.sql` were
applied to this database, but neither inserts into `project1_ai.schema_versions`,
so the version ledger has no row for them. Their effect is nonetheless fully
observable: roles and their attributes, role memberships, schema/table grants and
RLS policies. This script verifies those objects directly and only then records a
receipt.

This is a RECONCILIATION, not a backfill. It does not claim the migrations were
applied on any particular date: that date was never recorded, and inventing one
would put a false statement into an audit trail. The receipt says what was
observed and when it was observed.

Idempotent by construction: a version that already has a receipt is reported and
left untouched. Existing receipts are never updated, replaced or re-dated.

Usage:
    .venv/Scripts/python.exe scripts/cp04a_receipt_reconcile.py \
        --target project1_workflow_tests            # verify, then record
    .venv/Scripts/python.exe scripts/cp04a_receipt_reconcile.py \
        --target project1_workflow_tests --dry-run  # verify only

`--target` must equal `current_database()`; the same GUC the migrations require
is set, so an accidental run against the wrong database is refused rather than
silently recorded.
"""
from __future__ import annotations

import argparse
from datetime import date
import os
import sys

from sqlalchemy import create_engine, text

from sitewise.core.config import local_database_url

ALLOWED = ("Dss", "project1_workflow_tests")

# (label, predicate) — every predicate must return exactly true.
ROLE_CHECKS = [
    ("role {role} exists as LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS", """
        select coalesce((select rolcanlogin and not rolinherit and not rolsuper
                                and not rolbypassrls
                           from pg_roles where rolname = '{role}'), false)"""),
    ("{member} is a MEMBER of {group} but has no inherited USAGE of it", """
        select pg_has_role('{member}', '{group}', 'MEMBER')
           and not pg_has_role('{member}', '{group}', 'USAGE')"""),
]

RECONCILIATIONS = [
    {
        "version": "20261116_02_m2_runtime_role",
        "summary": "least-privilege M2 login role, its grants and owner-scoped RLS",
        "checks": [
            ("role p1_m2_runtime has the documented attributes",
             ROLE_CHECKS[0][1].format(role="p1_m2_runtime")),
            ("p1_m2_runtime has USAGE on schema public",
             "select has_schema_privilege('p1_m2_runtime', 'public', 'USAGE')"),
            ("p1_m2_runtime may read the global reference tables",
             "select bool_and(has_table_privilege('p1_m2_runtime', t, 'SELECT')) "
             "from unnest(array['public.m2_instrument_versions', "
             "'public.m2_item_versions']) as t"),
            ("p1_m2_runtime has SELECT, INSERT, UPDATE on the eight M2 core tables",
             "select bool_and(has_table_privilege('p1_m2_runtime', t, "
             "'SELECT,INSERT,UPDATE')) from unnest(array["
             "'public.m2_assessments', 'public.m2_answer_revisions', "
             "'public.m2_bdj_evaluations', 'public.m2_bdj_findings', "
             "'public.m2_review_events', 'public.m2_confirmation_snapshots', "
             "'public.m2_confirmed_uncertainties', "
             "'public.m2_clarification_events']) as t"),
            ("p1_m2_runtime has SELECT, INSERT, UPDATE on the business-context tables",
             "select bool_and(has_table_privilege('p1_m2_runtime', t, "
             "'SELECT,INSERT,UPDATE')) from unnest(array["
             "'public.m2_business_contexts', "
             "'public.m2_business_context_builds']) as t"),
            ("p1_m2_runtime holds no DELETE on any M2 table",
             "select not exists (select 1 from information_schema.role_table_grants "
             "where grantee = 'p1_m2_runtime' and privilege_type = 'DELETE')"),
            ("the twelve RLS policies the migration creates are present",
             """select count(*) = 12 from pg_policies p
                  join (values ('m2_assessments','owner_scope'),
                               ('m2_answer_revisions','owner_scope'),
                               ('m2_bdj_evaluations','owner_scope'),
                               ('m2_bdj_findings','owner_scope'),
                               ('m2_review_events','owner_scope'),
                               ('m2_confirmation_snapshots','owner_scope'),
                               ('m2_clarification_events','owner_scope'),
                               ('m2_confirmed_uncertainties','owner_scope'),
                               ('m2_business_contexts','owner_scope'),
                               ('m2_business_context_builds','owner_scope'),
                               ('m2_instrument_versions','reference_read'),
                               ('m2_item_versions','reference_read')) as want(t, pol)
                    on p.tablename = want.t and p.policyname = want.pol
                 where p.schemaname = 'public'"""),
        ],
    },
    {
        "version": "20261117_01_execution_principal",
        "summary": "restricted execution principal and audit principal, no direct grants",
        "checks": [
            ("role p1ai_engine has the documented attributes",
             ROLE_CHECKS[0][1].format(role="p1ai_engine")),
            ("role p1ai_auditor has the documented attributes",
             ROLE_CHECKS[0][1].format(role="p1ai_auditor")),
            ("p1ai_engine may SET ROLE p1ai_runtime but does not inherit it",
             ROLE_CHECKS[1][1].format(member="p1ai_engine", group="p1ai_runtime")),
            ("p1ai_auditor may SET ROLE p1ai_audit but does not inherit it",
             ROLE_CHECKS[1][1].format(member="p1ai_auditor", group="p1ai_audit")),
            ("p1ai_engine has no direct USAGE on schema project1_ai",
             "select not has_schema_privilege('p1ai_engine', 'project1_ai', 'USAGE')"),
            ("p1ai_engine has no direct privilege on the ledger tables",
             "select bool_and(not has_table_privilege('p1ai_engine', t, 'SELECT')) "
             "from unnest(array['project1_ai.runs', 'project1_ai.attempts', "
             "'project1_ai.attempt_receipts']) as t"),
            ("p1ai_auditor has no direct USAGE on schema project1_ai",
             "select not has_schema_privilege('p1ai_auditor', 'project1_ai', 'USAGE')"),
        ],
    },
]


def verify(conn, spec) -> tuple[int, int]:
    print(f"\n{spec['version']}  ({spec['summary']})")
    passed = 0
    for label, sql in spec["checks"]:
        observed = conn.execute(text(sql)).scalar()
        ok = observed is True
        passed += ok
        print(f"  {'VERIFIED' if ok else 'MISSING '}  {label}"
              + ("" if ok else f"  [observed={observed!r}]"))
    return passed, len(spec["checks"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default=os.environ.get("PROJECT1_MIGRATION_TARGET"),
                        help="database name; must equal current_database()")
    parser.add_argument("--dry-run", action="store_true",
                        help="verify only; write nothing")
    args = parser.parse_args()

    if not args.target:
        raise SystemExit("--target is required (or set PROJECT1_MIGRATION_TARGET)")

    engine = create_engine(local_database_url(args.target), future=True)
    failures = 0
    with engine.connect() as conn:
        db = conn.execute(text("select current_database()")).scalar()
        if db != args.target or db not in ALLOWED:
            raise SystemExit(f"refusing to run against {db!r}: target mismatch or not allowlisted")
        print(f"target database: {db}   mode: {'DRY RUN' if args.dry_run else 'RECONCILE'}")
        conn.execute(text("select set_config('project1.migration_target', :t, true)"),
                     {"t": db})

        print("\nexisting receipts for the versions in scope:")
        for version, receipt, applied_at in conn.execute(text(
                "select version, receipt, applied_at from project1_ai.schema_versions "
                "where version = any(:v) order by version"),
                {"v": [r["version"] for r in RECONCILIATIONS]}):
            print(f"  {version}: {applied_at}  {receipt[:90]}")

        pending = []
        for spec in RECONCILIATIONS:
            existing = conn.execute(text(
                "select count(*) from project1_ai.schema_versions where version = :v"),
                {"v": spec["version"]}).scalar()
            if existing:
                print(f"\n{spec['version']}  already has a receipt: left untouched")
                continue
            passed, total = verify(conn, spec)
            if passed != total:
                failures += 1
                print(f"  REFUSING to record {spec['version']}: "
                      f"{total - passed} of {total} objects are not as the migration creates them")
                continue
            pending.append((spec, passed, total))

        if args.dry_run:
            print(f"\nDRY RUN: {len(pending)} receipt(s) would be written; nothing written")
            conn.rollback()
        elif pending:
            today = date.today().isoformat()
            for spec, passed, total in pending:
                receipt = (
                    f"RECONCILED {today} by object inspection ({passed}/{total} checks): "
                    f"{spec['version']} objects verified present. No receipt was written "
                    f"when this migration was originally applied, so its application date "
                    f"is unknown and is not claimed here.")
                conn.execute(text(
                    "insert into project1_ai.schema_versions(version, receipt) "
                    "values (:v, :r)"), {"v": spec["version"], "r": receipt})
                print(f"\nRECORDED {spec['version']}")
                print(f"  {receipt}")
            conn.commit()
        else:
            print("\nNothing to record.")
            conn.rollback()

    print(f"\nVERDICT={'PASS' if failures == 0 else 'FAIL'}  failures={failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
