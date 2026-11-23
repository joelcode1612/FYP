"""Apply one of the database_standardization migration SQL files.

Modes
-----
``apply`` (default)
    Execute the file against the configured backend DATABASE_URL.
    Transactional files (02, 03, 04) run inside one transaction; validation /
    preflight files (01, 05) run in autocommit (they manage their own
    READ ONLY transactions and are side-guarded).
``dry-run``
    Print the statements that would run (no execution).

Usage (PowerShell, from ``backend/``)::

    .venv\\Scripts\\python.exe database_standardization\\scripts\\apply_migration.py ^
        --file database_standardization\\migrations\\01_preflight.sql
    .venv\\Scripts\\python.exe database_standardization\\scripts\\apply_migration.py ^
        --file database_standardization\\migrations\\02_local_schema_migration.sql --dry-run

Credentials come from the backend environment only; nothing is printed.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

TRANSACTIONAL_HINTS = ("02_local", "03_supabase", "04_relationship")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True)
    parser.add_argument(
        "--dry-run", action="store_true", help="Print statements; execute nothing."
    )
    parser.add_argument(
        "--autocommit",
        action="store_true",
        default=None,
        help="Force autocommit execution (auto-selected for preflight/validation files).",
    )
    args = parser.parse_args(argv)

    sql_file = Path(args.file)
    if not sql_file.exists():
        print(f"File not found: {sql_file}", file=sys.stderr)
        return 2
    sql = sql_file.read_text(encoding="utf-8")

    transactional = args.autocommit is False or (
        args.autocommit is None
        and any(h in sql_file.name for h in TRANSACTIONAL_HINTS)
    )

    from sqlalchemy import text

    from sitewise.db.session import engine

    if args.dry_run:
        body = "\n".join(
            ln for ln in sql.splitlines()
            if ln.strip() not in ("BEGIN;", "COMMIT;", "ROLLBACK;")
        )
        print(f"[dry-run] would execute {sql_file.name} "
              f"({'transactional' if transactional else 'autocommit'}) "
              f"— {len(body)} chars")
        return 0

    raw = engine.raw_connection()
    try:
        raw.autocommit = not transactional
        body = sql
        if transactional:
            # The DBAPI owns the transaction; the file's own BEGIN/COMMIT
            # must not nest inside it.
            body = "\n".join(
                ln for ln in sql.splitlines()
                if ln.strip() not in ("BEGIN;", "COMMIT;", "ROLLBACK;")
            )
        cur = raw.cursor()
        cur.execute(body)  # psycopg2 executes the batch server-side
        for notice in getattr(raw, "notices", [])[-20:]:
            print(notice.rstrip())
        raw.notices.clear()
        if transactional:
            raw.commit()
        print(f"OK: {sql_file.name} applied.")
        return 0
    except Exception as exc:  # noqa: BLE001
        if transactional:
            raw.rollback()
        print(f"FAILED: {sql_file.name}: {exc}", file=sys.stderr)
        return 1
    finally:
        raw.close()


if __name__ == "__main__":
    raise SystemExit(main())
