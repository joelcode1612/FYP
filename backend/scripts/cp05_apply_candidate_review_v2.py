"""Apply / round-trip the CP-05 candidate review migration on the disposable clone.

Target resolution comes from application settings; no DSN or password is
written here. The script refuses any database whose name is not
``project1_workflow_tests`` and refuses ``Dss`` by name before running DDL.

Usage:
    python scripts/cp05_apply_candidate_review_v2.py --apply
    python scripts/cp05_apply_candidate_review_v2.py --roundtrip
"""
from __future__ import annotations

import argparse
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from sitewise.core.config import settings

CLONE = 'project1_workflow_tests'
MIGRATIONS = Path(__file__).resolve().parents[1] / 'migrations' / 'm2'
FORWARD = MIGRATIONS / '20261118_02_candidate_review_v2.sql'
ROLLBACK = MIGRATIONS / '20261118_02_candidate_review_v2_rollback.sql'
RECEIPT = 'CP-05-CANDIDATE-REVIEW-V2-CLONE'


def clone_engine():
    url = make_url(settings.database_url).set(database=CLONE)
    if url.database != CLONE:
        raise SystemExit('refusing to run: resolved database is not the clone')
    engine = create_engine(url, hide_parameters=True)
    with engine.connect() as connection:
        name = connection.execute(text('select current_database()')).scalar_one()
        if name != CLONE or name == 'Dss':
            raise SystemExit(f'refusing to run DDL on {name}')
        superuser = connection.execute(text(
            'select rolsuper from pg_roles where rolname = current_user')).scalar_one()
        if not superuser:
            raise SystemExit('DDL requires an owner/superuser session on the clone')
    return engine


def run_script(engine, path: Path) -> None:
    sql = path.read_text(encoding='utf-8')
    raw = engine.raw_connection()
    try:
        raw.autocommit = True
        with raw.cursor() as cursor:
            cursor.execute(
                f"SET project1.m2_bcb_migration_target = '{CLONE}'; "
                f"SET project1.m2_bcb_migration_receipt = '{RECEIPT}';")
            raw.commit()  # close the implicit transaction the SETs opened
            cursor.execute(sql)
            for notice in raw.notices:
                print('notice:', notice.strip())
            raw.notices.clear()
    finally:
        raw.close()


def describe(engine) -> None:
    with engine.connect() as connection:
        rows = connection.execute(text("""
            select conname, pg_get_constraintdef(oid)
            from pg_constraint
            where conrelid = 'public.m2_candidate_owner_reviews'::regclass
              and contype = 'c'
            order by conname
        """)).all()
        print('decision/context constraints:')
        for name, definition in rows:
            print(f'  {name}: {definition}')
        print('context_hash column:', connection.execute(text("""
            select data_type || '(' || coalesce(character_maximum_length::text, '-') || ') null='
                   || is_nullable
            from information_schema.columns
            where table_schema = 'public' and table_name = 'm2_candidate_owner_reviews'
              and column_name = 'context_hash'
        """)).scalar_one_or_none())
        print('append-only trigger:', connection.execute(text("""
            select tgname from pg_trigger
            where tgrelid = 'public.m2_candidate_owner_reviews'::regclass and not tgisinternal
            order by tgname
        """)).scalars().all())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--rollback', action='store_true')
    parser.add_argument('--roundtrip', action='store_true',
                        help='rollback then re-apply, proving both scripts execute')
    args = parser.parse_args()
    if not (args.apply or args.rollback or args.roundtrip):
        parser.error('choose --apply, --rollback or --roundtrip')

    engine = clone_engine()
    try:
        if args.roundtrip:
            print(f'--- rollback {ROLLBACK.name}')
            run_script(engine, ROLLBACK)
            describe(engine)
            print(f'--- forward {FORWARD.name}')
            run_script(engine, FORWARD)
        elif args.rollback:
            print(f'--- rollback {ROLLBACK.name}')
            run_script(engine, ROLLBACK)
        else:
            print(f'--- forward {FORWARD.name}')
            run_script(engine, FORWARD)
        describe(engine)
    finally:
        engine.dispose()


if __name__ == '__main__':
    main()
