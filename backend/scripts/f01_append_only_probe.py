"""Prove F-01's append-only claim against a disposable database, not by reading DDL.

F-01 adopted `confirmed_uncertainty.id` as the uncertainty version label. That
adoption rests on one claim: a stored uncertainty row can never be rewritten, so
one id always denotes one (confirmation, revision, text) triple.

The claim was evidenced from `migrations/m2/20261113_01_confirmed_context_persistence.sql`,
which creates a `m2_bcb_append_only` trigger. Evidence from a migration file is not
evidence that the trigger is installed and firing. This probe executes it.

Safety:
* refuses to run unless `current_database()` is the disposable clone
* never opens a connection to `Dss` or `Final_Location_Analysis`
* rolls back everything it touches

Usage:
    .venv/Scripts/python.exe scripts/f01_append_only_probe.py
    .venv/Scripts/python.exe scripts/f01_append_only_probe.py --json out.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
CLONE = 'project1_workflow_tests'
FORBIDDEN = {'Dss', 'Final_Location_Analysis'}
APPEND_ONLY_SQLSTATE = '55000'


def _url(name: str) -> tuple[str, str, str, int, str]:
    for line in (BACKEND / '.env').read_text(encoding='utf-8').splitlines():
        if line.startswith(name + '='):
            raw = line.split('=', 1)[1].strip()
            match = re.match(r'postgresql\+psycopg2://([^:]+):([^@]+)@([^:]+):(\d+)/(\w+)', raw)
            if match:
                return match.groups()
    raise SystemExit(f'{name} is not configured; refusing to guess a principal')


def _connect(name: str):
    user, password, host, port, _db = _url(name)
    connection = psycopg2.connect(host=host, port=int(port), user=user,
                                  password=password, dbname=CLONE)
    connection.autocommit = False
    with connection.cursor() as cursor:
        cursor.execute('SELECT current_database()')
        actual = cursor.fetchone()[0]
    if actual in FORBIDDEN or actual != CLONE:
        connection.close()
        raise SystemExit(f'refusing: connected to {actual!r}, expected {CLONE!r}')
    return connection


def _identity(connection) -> dict:
    with connection.cursor() as cursor:
        cursor.execute('SELECT current_user, rolsuper, rolbypassrls '
                       'FROM pg_roles WHERE rolname = current_user')
        user, superuser, bypass = cursor.fetchone()
    return {'user': user, 'superuser': superuser, 'bypassrls': bypass}


def _expect_refusal(connection, sql: str, params: dict, acceptable: tuple[str, ...]) -> dict:
    """Run one mutation inside a savepoint; return whether it was refused.

    ``acceptable`` names the SQLSTATEs that count as a refusal for this statement.
    They are not interchangeable: ``55000`` is the append-only trigger, ``42501`` is
    a missing privilege. Which one fires tells you *where* the protection lives.
    """
    record = {'sql': ' '.join(sql.split()), 'params': sorted(params),
              'acceptable_sqlstates': list(acceptable)}
    try:
        with connection.cursor() as cursor:
            cursor.execute('SAVEPOINT probe')
            try:
                cursor.execute(sql, params)
            finally:
                cursor.execute('ROLLBACK TO SAVEPOINT probe')
        record.update(refused=False, sqlstate=None,
                      note='STATEMENT SUCCEEDED — the append-only claim is FALSE')
    except psycopg2.Error as exc:
        connection.rollback()
        record.update(refused=(exc.pgcode in acceptable),
                      sqlstate=exc.pgcode, error=str(exc).strip().splitlines()[0])
    return record


def probe() -> dict:
    admin = _connect('DATABASE_URL')
    admin_identity = _identity(admin)
    restricted = _connect('M2_DATABASE_URL')
    restricted_identity = _identity(restricted)

    with admin.cursor() as cursor:
        cursor.execute('SELECT id, confirmation_id, actor_user_id, exact_text, '
                       'md5(exact_text) FROM public.m2_confirmed_uncertainties '
                       'ORDER BY created_at, id LIMIT 1')
        row = cursor.fetchone()
        cursor.execute('SELECT count(*) FROM public.m2_confirmed_uncertainties')
        count_before = cursor.fetchone()[0]
    if row is None:
        raise SystemExit('the clone has no uncertainty row; seed it before probing')
    uncertainty_id, confirmation_id, actor_id, _text, text_digest = row

    checks: list[dict] = []

    # The restricted principal is the one that matters: it holds UPDATE on this
    # table, so only the trigger stands between it and a rewrite.
    with restricted.cursor() as cursor:
        cursor.execute("SELECT set_config('project1.actor_id', %s, true)", (str(actor_id),))
        cursor.execute('SELECT count(*) FROM public.m2_confirmed_uncertainties')
        visible = cursor.fetchone()[0]
    restricted.commit()
    checks.append({'check': 'restricted principal can see the row (so RLS is not '
                            'what blocks the next step)',
                   'rows_visible': visible, 'pass': visible >= 1})

    # A superuser holds every privilege and bypasses RLS, so for it only the
    # trigger can refuse. The restricted role is refused by whichever comes first:
    # the missing grant (42501) or the trigger (55000). Both are real refusals, but
    # for UPDATE the grant exists, so the trigger must be the thing that fires.
    trigger = (APPEND_ONLY_SQLSTATE,)
    either = (APPEND_ONLY_SQLSTATE, '42501')
    statements = [
        ('UPDATE exact_text', 'UPDATE public.m2_confirmed_uncertainties '
                              'SET exact_text = %(v)s WHERE id = %(id)s',
         {'v': 'TAMPERED BY PROBE', 'id': uncertainty_id}, trigger),
        ('UPDATE id', 'UPDATE public.m2_confirmed_uncertainties '
                      'SET id = %(v)s WHERE id = %(id)s',
         {'v': str(uuid4()), 'id': uncertainty_id}, trigger),
        ('UPDATE confirmation_id', 'UPDATE public.m2_confirmed_uncertainties '
                                   'SET confirmation_id = %(v)s WHERE id = %(id)s',
         {'v': str(uuid4()), 'id': uncertainty_id}, trigger),
        ('DELETE', 'DELETE FROM public.m2_confirmed_uncertainties WHERE id = %(id)s',
         {'id': uncertainty_id}, None),
    ]
    for label, sql, params, update_expectation in statements:
        for connection, who in ((restricted, 'p1_m2_runtime'), (admin, 'superuser')):
            if who == 'p1_m2_runtime':
                with connection.cursor() as cursor:
                    cursor.execute("SELECT set_config('project1.actor_id', %s, true)",
                                   (str(actor_id),))
            if update_expectation is not None:
                acceptable = update_expectation
            else:
                # DELETE: the restricted role is expected to lack the grant, which
                # is a stronger defence than the trigger; the superuser has it and
                # must therefore be stopped by the trigger.
                acceptable = trigger if who == 'superuser' else either
            outcome = _expect_refusal(connection, sql, params, acceptable)
            checks.append({'check': label, 'principal': who, **outcome,
                           'pass': outcome['refused'] is True})

    with admin.cursor() as cursor:
        cursor.execute('SELECT count(*), max(md5(exact_text)) '
                       'FROM public.m2_confirmed_uncertainties WHERE id = %s',
                       (uncertainty_id,))
        count_after, digest_after = cursor.fetchone()
    checks.append({'check': 'row is byte-identical after every attempt',
                   'pass': count_after == 1 and digest_after == text_digest,
                   'count_before': count_before, 'count_after': count_after,
                   'text_digest_unchanged': digest_after == text_digest})

    with admin.cursor() as cursor:
        cursor.execute("SELECT tgname FROM pg_trigger WHERE tgrelid = "
                       "'public.m2_confirmed_uncertainties'::regclass AND NOT tgisinternal")
        triggers = [r[0] for r in cursor.fetchall()]

    admin.rollback()
    restricted.rollback()
    admin.close()
    restricted.close()

    return {'probe': 'F01_APPEND_ONLY', 'database': CLONE,
            'ran_at': datetime.now(timezone.utc).isoformat(),
            'triggers': triggers,
            'admin_identity': admin_identity, 'restricted_identity': restricted_identity,
            'uncertainty_id': str(uncertainty_id),
            'checks': checks,
            'all_pass': all(c['pass'] for c in checks)}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', type=Path, default=None)
    args = parser.parse_args(argv)
    result = probe()
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2, default=str), encoding='utf-8')
    print(json.dumps(result, indent=2, default=str))
    return 0 if result['all_pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
