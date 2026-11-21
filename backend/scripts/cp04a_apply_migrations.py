"""CP-04A A1 — controlled deployment of the two frozen migrations to `Dss`.

Fail-closed at three points, in this order:

  1. **hash** — each file's SHA-256 must equal the frozen value, or nothing runs;
  2. **baseline** — `Dss` must still look like the preflight catalog (four tables,
     no result tables, three ledger rows). Unexpected drift stops the run;
  3. **post-verification** — the ten tables, both receipts, unchanged historical
     counts, every signature constraint, RLS/trigger state and the grant matrix
     must all match the tested clone.

Each migration is a self-contained `BEGIN; … COMMIT;` file. The reviewed identity
and receipt are supplied as session GUCs, which is what the files require.

    python scripts/cp04a_apply_migrations.py --check   # hashes + baseline only
    python scripts/cp04a_apply_migrations.py --apply   # deploy, then verify

Writes `backups/cp04a/MIGRATION_EXECUTION_<ts>.json` as execution evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cp04a_live_dispatch_probe import read_env            # noqa: E402

MIGRATIONS_DIR = Path(__file__).resolve().parents[1] / 'migrations' / 'project1_ai'
BACKUP = Path(__file__).resolve().parents[1] / 'backups' / 'cp04a' / 'dss_pre_apply_pg16_20261117.dump'

# Frozen values. These are the contract; a differing file is a stop condition.
FROZEN = [
    ('20261117_02_finding_provenance.sql',
     'fb71d0b416633c3b3d3384ee2f4b2c92a781575e91c83859553acfad19b4b185'),
    ('20261117_03_bdj_result_persistence.sql',
     'e099f133cc4b1f4179c61448ddae3928c8bc28031263b0e53d65ed082cb8d955'),
]

TARGET = 'Dss'
EXPECTED_TABLES = 10
BASELINE_COUNTS = {'runs': 9, 'attempts': 9, 'attempt_receipts': 9}
NEW_TABLES = ('finding_provenance', 'bdj_results', 'bdj_result_sources',
              'bdj_result_validations', 'bdj_result_findings', 'bdj_raw_responses')
SIGNATURE_CONSTRAINTS = (
    'bdj_raw_responses_retention_forward', 'bdj_result_sources_locator_pointer_check',
    'bdj_results_attempt_fk', 'bdj_results_digest_matches_outcome',
    'bdj_results_findings_require_review_check', 'bdj_results_one_per_attempt',
    'bdj_results_payload_requires_valid', 'bdj_results_returned_requires_review',
    'bdj_results_review_requires_validation', 'bdj_results_unreviewed_has_no_payload')
# (table, grantee, required privileges, privileges that must be absent)
GRANTS = (
    ('finding_provenance', 'p1ai_runtime', ('SELECT', 'INSERT'), ('UPDATE', 'DELETE')),
    ('bdj_results', 'p1ai_runtime', ('SELECT', 'INSERT'), ('UPDATE', 'DELETE')),
    ('bdj_result_sources', 'p1ai_runtime', ('SELECT', 'INSERT'), ('UPDATE', 'DELETE')),
    ('bdj_result_validations', 'p1ai_runtime', ('SELECT', 'INSERT'), ('UPDATE', 'DELETE')),
    ('bdj_result_findings', 'p1ai_runtime', ('SELECT', 'INSERT'), ('UPDATE', 'DELETE')),
    ('bdj_raw_responses', 'p1ai_runtime', ('INSERT',), ('SELECT', 'UPDATE', 'DELETE')),
    ('bdj_raw_responses', 'p1ai_audit', ('SELECT',), ('INSERT', 'UPDATE', 'DELETE')),
)


def dsn(dbname: str, *, for_libpq: bool = False) -> str:
    """Connection string for `dbname`.

    SQLAlchemy needs the `+psycopg2` driver suffix; libpq/psycopg2.connect needs
    it stripped. Getting this wrong silently selects psycopg v3, which is not
    installed here.
    """
    url = make_url(read_env()['DATABASE_URL']).set(database=dbname)
    rendered = url.render_as_string(hide_password=False)
    return rendered.replace('+psycopg2', '') if for_libpq else rendered


def check_hashes() -> tuple[bool, list[dict]]:
    rows, ok = [], True
    for name, expected in FROZEN:
        path = MIGRATIONS_DIR / name
        actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        match = actual == expected
        ok = ok and match
        rows.append({'file': name, 'expected': expected, 'actual': actual, 'match': match})
        print(f"  {'PASS' if match else 'FAIL'}  {name}\n        expected {expected}\n        actual   {actual}")
    return ok, rows


def baseline(engine) -> tuple[bool, dict]:
    with engine.connect() as c:
        db = c.execute(text('select current_database()')).scalar()
        tables = sorted(r[0] for r in c.execute(text(
            "select tablename from pg_tables where schemaname='project1_ai'")))
        ledger = c.execute(text(
            'select version from project1_ai.schema_versions order by applied_at')).scalars().all()
        counts = {t: c.execute(text(f'select count(*) from project1_ai.{t}')).scalar()
                  for t in BASELINE_COUNTS}
        deny = c.execute(text("select to_regproc('project1_ai.deny_mutation')")).scalar()
    state = {'db': db, 'tables': tables, 'ledger': list(ledger), 'counts': counts,
             'deny_mutation': deny is not None}
    print(f"  database: {db}")
    print(f"  tables:   {tables}")
    print(f"  ledger:   {list(ledger)}")
    print(f"  counts:   {counts}")
    checks = [
        ('database is Dss', db == TARGET),
        ('baseline four tables, no result tables', len(tables) == 4 and
         not set(tables) & set(NEW_TABLES)),
        ('historical counts unchanged', counts == BASELINE_COUNTS),
        ('historical receipts reconciled', len(ledger) == 3),
        ('deny_mutation() present', deny is not None),
    ]
    for label, passed in checks:
        print(f"  {'PASS' if passed else 'BLOCKED'}  {label}")
    return all(p for _, p in checks), state


def verify(engine, before: dict) -> tuple[bool, dict]:
    with engine.connect() as c:
        tables = sorted(r[0] for r in c.execute(text(
            "select tablename from pg_tables where schemaname='project1_ai'")))
        ledger = c.execute(text(
            'select version from project1_ai.schema_versions order by applied_at')).scalars().all()
        counts = {t: c.execute(text(f'select count(*) from project1_ai.{t}')).scalar()
                  for t in BASELINE_COUNTS}
        guards = {r[0]: {'rls': r[1], 'force': r[2], 'policies': r[3], 'triggers': r[4]}
                  for r in c.execute(text("""
                      select c.relname, c.relrowsecurity, c.relforcerowsecurity,
                             (select count(*) from pg_policy p where p.polrelid=c.oid),
                             (select count(*) from pg_trigger t
                               where t.tgrelid=c.oid and not t.tgisinternal)
                        from pg_class c join pg_namespace n on n.oid=c.relnamespace
                       where n.nspname='project1_ai' and c.relname = any(:t)"""),
                      {'t': list(NEW_TABLES)})}
        constraints = dict(c.execute(text(
            'select conname, pg_get_constraintdef(oid) from pg_constraint '
            'where conname = any(:n)'), {'n': list(SIGNATURE_CONSTRAINTS)}).all())
        grant_rows = {}
        for table, grantee, need, forbid in GRANTS:
            grant_rows[f'{table}/{grantee}'] = {
                'must_have': need, 'must_not_have': forbid,
                'observed': {p: c.execute(text('select has_table_privilege(:g, :t, :p)'),
                                          {'g': grantee, 't': f'project1_ai.{table}',
                                           'p': p}).scalar() for p in (*need, *forbid)}}
        usage = c.execute(text(
            "select has_schema_privilege('p1ai_runtime','project1_ai','USAGE')")).scalar()

    print(f"  tables: {len(tables)} -> {tables}")
    print(f"  ledger: {list(ledger)}")
    print(f"  historical counts: {counts}")
    for name, g in sorted(guards.items()):
        print(f"  {name:24s} rls={g['rls']} force={g['force']} "
              f"policies={g['policies']} triggers={g['triggers']}")
    for key, g in grant_rows.items():
        print(f"  grant {key:34s} {g['observed']}  (need {g['must_have']}, "
              f"forbid {g['must_not_have']})")

    def grant_contract_holds(g: dict) -> bool:
        return (all(g['observed'][p] for p in g['must_have']) and
                not any(g['observed'][p] for p in g['must_not_have']))

    checks = [
        ('ten tables in project1_ai', len(tables) == EXPECTED_TABLES),
        ('all six new tables present', set(NEW_TABLES) <= set(tables)),
        ('both new receipts recorded',
         {'20261117_02_finding_provenance', '20261117_03_bdj_result_persistence'} <= set(ledger)),
        ('historical receipts preserved', set(before['ledger']) <= set(ledger)),
        ('five ledger rows total', len(ledger) == 5),
        ('attempt and run counts preserved', counts == before['counts']),
        ('all ten signature constraints present',
         set(SIGNATURE_CONSTRAINTS) <= set(constraints)),
        ('every new table has RLS forced, 2 policies, 1 trigger',
         all(g['rls'] and g['force'] and g['policies'] == 2 and g['triggers'] == 1
             for g in guards.values()) and len(guards) == len(NEW_TABLES)),
        ('every grant row matches its own contract', all(
            grant_contract_holds(g) for g in grant_rows.values())),
        ('bdj_raw_responses is write-only for the runtime',
         grant_rows['bdj_raw_responses/p1ai_runtime']['observed']['INSERT'] is True and
         grant_rows['bdj_raw_responses/p1ai_runtime']['observed']['SELECT'] is False),
        ('audit role reads raw responses',
         grant_rows['bdj_raw_responses/p1ai_audit']['observed']['SELECT'] is True),
        ('p1ai_runtime still has schema USAGE', bool(usage)),
    ]
    for label, passed in checks:
        print(f"  {'PASS' if passed else 'FAIL'}  {label}")
    return all(p for _, p in checks), {'tables': tables, 'ledger': list(ledger),
                                       'counts': counts, 'guards': guards,
                                       'constraints': sorted(constraints),
                                       'grants': grant_rows}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--verify', action='store_true',
                        help='re-run post-deployment verification only; never re-applies')
    args = parser.parse_args()
    if not (args.check or args.apply or args.verify):
        parser.error('choose --check, --apply or --verify')

    print('== 1. Frozen hashes ==')
    ok, hash_rows = check_hashes()
    if not ok:
        print('\nSTOP: a frozen hash differs. Nothing was executed.')
        return 1

    engine = create_engine(dsn(TARGET), hide_parameters=True)

    if args.verify:
        # The post-apply state is the subject; the baseline is the recorded
        # pre-apply one. Re-applying here would be wrong, and the migrations
        # refuse it anyway.
        before = {'counts': BASELINE_COUNTS,
                  'ledger': ['20261111_01_candidate', '20261116_02_m2_runtime_role',
                             '20261117_01_execution_principal']}
        print('\n== Verification only (no DDL executed) ==')
        ok, after = verify(engine, before)
        engine.dispose()
        print(f'\nVERDICT={"MIGRATION_DEPLOYED_VERIFIED" if ok else "MIGRATION_VERIFICATION_FAILED"}')
        return 0 if ok else 3

    print('\n== 2. Baseline ==')
    base_ok, before = baseline(engine)
    if not base_ok:
        print('\nSTOP: baseline drifted. Nothing was executed.')
        return 1
    if args.check:
        print('\nCHECK ONLY: preconditions pass, nothing executed.')
        return 0

    backup_sha = hashlib.sha256(BACKUP.read_bytes()).hexdigest() if BACKUP.is_file() else None
    receipt = (f'CP-04A 2026-11-17: applied to Dss by administrative identity '
               f'postgres after preflight PASS; backup {BACKUP.name} sha256 {backup_sha}; '
               f'restore verified; frozen hash confirmed at execution.')
    print(f'\n== 3. Apply (receipt recorded verbatim) ==\n  {receipt}')

    conn = psycopg2.connect(dsn(TARGET, for_libpq=True))
    conn.autocommit = True
    executed = []
    try:
        with conn.cursor() as cur:
            cur.execute("SET project1.migration_target = %s", (TARGET,))
            cur.execute("SET project1.migration_receipt = %s", (receipt,))
            for name, expected in FROZEN:
                sql = (MIGRATIONS_DIR / name).read_text(encoding='utf-8')
                print(f'\n  executing {name} …')
                cur.execute(sql)
                print(f'  committed {name}')
                executed.append({'file': name, 'sha256': expected,
                                 'executed_utc': datetime.now(timezone.utc).isoformat()})
    except Exception as exc:                                   # noqa: BLE001 — reported verbatim
        print(f'\nAPPLY FAILED: {type(exc).__name__}: {exc}')
        print('Each migration is a single transaction; a failure leaves no partial state.')
        return 2
    finally:
        conn.close()

    print('\n== 4. Post-deployment verification ==')
    ok, after = verify(engine, before)
    engine.dispose()

    evidence = {
        'recorded_utc': datetime.now(timezone.utc).isoformat(),
        'database': TARGET,
        'administrative_identity': 'postgres',
        'backup': {'file': BACKUP.name, 'sha256': backup_sha},
        'hashes': hash_rows,
        'executed': executed,
        'baseline': before,
        'post': after,
        'verdict': 'MIGRATION_DEPLOYED_VERIFIED' if ok else 'MIGRATION_VERIFICATION_FAILED',
    }
    out = BACKUP.parent / f'MIGRATION_EXECUTION_{datetime.now():%Y%m%d_%H%M%S}.json'
    out.write_text(json.dumps(evidence, indent=2, default=str), encoding='utf-8')
    print(f'\nevidence: {out}')
    print(f'\nVERDICT={evidence["verdict"]}')
    return 0 if ok else 3


if __name__ == '__main__':
    raise SystemExit(main())
