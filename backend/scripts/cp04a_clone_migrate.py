"""CP-04A — apply the BDJ result-persistence migration to the ISOLATED CLONE.

This script never touches `Dss`. It connects only to `project1_workflow_tests`,
which was created with `CREATE DATABASE ... TEMPLATE "Dss"` for exactly this
purpose (the migration guard itself permits only `Dss` and this clone name).

Applying to a real database remains BLOCKED_DBA_AUTHORIZATION (MIG-AUTH-01);
this is the "test the migration in an isolated database clone" step, nothing
more.

Run:  .venv/Scripts/python.exe scripts/cp04a_clone_migrate.py
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "src"))

from sqlalchemy import create_engine, text  # noqa: E402

CLONE = "project1_workflow_tests"
ADMIN_DSN = "postgresql+psycopg2://postgres:123456@localhost:5432/" + CLONE
MIGRATIONS = ROOT / "migrations" / "project1_ai"
RECEIPT = "CP-04A 2026-11-17: bdj result persistence tested on isolated clone"

TARGETS = [
    ("20261117_02_finding_provenance.sql", "20261117_02_finding_provenance"),
    ("20261117_03_bdj_result_persistence.sql", "20261117_03_bdj_result_persistence"),
]


def apply(conn, filename: str) -> None:
    sql = (MIGRATIONS / filename).read_text(encoding="utf-8")
    conn.exec_driver_sql(sql)


def main() -> int:
    engine = create_engine(ADMIN_DSN, future=True, isolation_level="AUTOCOMMIT")
    failures = 0
    with engine.connect() as conn:
        db = conn.execute(text("select current_database()")).scalar()
        if db != CLONE:
            raise SystemExit(f"refusing to run against {db!r}: this script is clone-only")
        print(f"target database: {db}")

        conn.exec_driver_sql(f"SET project1.migration_target = '{CLONE}'")
        conn.exec_driver_sql(f"SET project1.migration_receipt = '{RECEIPT}'")

        for filename, version in TARGETS:
            already = conn.execute(text(
                "select count(*) from project1_ai.schema_versions where version = :v"),
                {"v": version}).scalar()
            if already:
                print(f"  SKIP {filename} (receipt already present)")
                continue
            try:
                apply(conn, filename)
                print(f"  APPLIED {filename}")
            except Exception as exc:  # noqa: BLE001
                failures += 1
                print(f"  FAILED  {filename}: {str(exc).splitlines()[0][:180]}")
                # The script carries its own BEGIN; a failure leaves the session
                # in an aborted transaction, which would make every later check
                # report a misleading error instead of its real result.
                try:
                    conn.exec_driver_sql("ROLLBACK")
                except Exception:  # noqa: BLE001
                    pass

        # Idempotency: re-running must be refused, not silently re-applied.
        try:
            apply(conn, "20261117_03_bdj_result_persistence.sql")
            print("  FAIL idempotency: re-run was accepted")
            failures += 1
        except Exception as exc:  # noqa: BLE001
            first = str(exc).splitlines()[0][:120]
            if "already exist" in str(exc):
                print(f"  PASS idempotency: re-run refused ({first})")
            else:
                print(f"  FAIL idempotency: unexpected error ({first})")
                failures += 1
            try:
                conn.exec_driver_sql("ROLLBACK")
            except Exception:  # noqa: BLE001
                pass

        print("\nobjects in project1_ai:")
        for row in conn.execute(text("""
            select c.relname, pg_get_userbyid(c.relowner) as owner, c.relrowsecurity as rls
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'project1_ai' and c.relkind = 'r' order by 1""")):
            print(f"  {row[0]:<28} owner={row[1]:<12} rls={row[2]}")

        print("\nschema_versions:")
        for row in conn.execute(text(
                "select version, left(receipt, 52) from project1_ai.schema_versions order by applied_at")):
            print(f"  {row[0]:<38} {row[1]}")

        print("\npolicies:")
        for row in conn.execute(text("""
            select tablename, policyname, cmd, roles::text
            from pg_policies where schemaname = 'project1_ai' order by 1, 2""")):
            print(f"  {row[0]:<26} {row[1]:<22} {row[2]:<8} {row[3]}")

    print(f"\nVERDICT={'PASS' if failures == 0 else 'FAIL'} failures={failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
