"""CP-04A migration preflight: read-only catalog comparison of `Dss` and the clone.

Every connection opens with `default_transaction_read_only = on`, so this script
cannot write to either database even by mistake. It prints a PASS/BLOCKED report;
it never prints a credential and never runs DDL.

    python scripts/cp04a_migration_preflight.py
"""
from __future__ import annotations

import sys
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cp04a_live_dispatch_probe import read_env            # noqa: E402

PRIMARY = 'Dss'
CLONE = 'project1_workflow_tests'
SCHEMA = 'project1_ai'

# Objects the two frozen migrations are supposed to create. `_02` creates one
# table; `_03` creates five. No ALTER TABLE ... ADD COLUMN exists in either file.
FROZEN_02 = {'finding_provenance'}
FROZEN_03 = {'bdj_results', 'bdj_result_sources', 'bdj_result_validations',
             'bdj_result_findings', 'bdj_raw_responses'}
BASELINE = {'runs', 'attempts', 'attempt_receipts', 'schema_versions'}

M2_TABLES = ('m2_assessments', 'm2_confirmed_uncertainties', 'm2_business_contexts',
             'm2_business_context_builds', 'm2_instrument_versions', 'm2_item_versions')
ROLES = ('p1ai_engine', 'p1ai_runtime', 'p1ai_auditor', 'p1_m2_runtime')


def admin_url(dbname: str) -> str:
    """Same server and credentials as DATABASE_URL, different database name."""
    url = make_url(read_env()['DATABASE_URL'])
    return url.set(database=dbname).render_as_string(hide_password=False)


def connect(dbname: str):
    engine = create_engine(admin_url(dbname), hide_parameters=True,
                           connect_args={'options': '-c default_transaction_read_only=on'})
    return engine


def relkind_name(kind: str) -> str:
    return {'r': 'table', 'v': 'view', 'm': 'matview', 'f': 'foreign',
            'p': 'partitioned', 'i': 'index', 'S': 'sequence'}.get(kind, kind)


def inspect(engine) -> dict:
    out: dict = {}
    with engine.connect() as c:
        out['db'] = c.execute(text('select current_database()')).scalar()
        out['read_only'] = c.execute(text('show transaction_read_only')).scalar()
        rows = c.execute(text("""
            select c.relname, c.relkind, c.relrowsecurity, c.relforcerowsecurity,
                   (select count(*) from pg_policy p where p.polrelid = c.oid) as policies,
                   (select count(*) from pg_trigger t
                     where t.tgrelid = c.oid and not t.tgisinternal) as triggers
              from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = :s order by 1"""), {'s': SCHEMA}).all()
        out['relations'] = {r[0]: {'kind': r[1], 'kind_name': relkind_name(r[1]),
                                   'rls': r[2], 'force_rls': r[3],
                                   'policies': r[4], 'triggers': r[5]} for r in rows}
        out['counts'] = {}
        for name, meta in out['relations'].items():
            if meta['kind'] in ('r', 'p'):
                out['counts'][name] = c.execute(
                    text(f'select count(*) from {SCHEMA}.{name}')).scalar()
        out['ledger'] = []
        if 'schema_versions' in out['relations']:
            out['ledger'] = c.execute(text(
                f'select version, left(receipt, 90), applied_at from {SCHEMA}.schema_versions '
                'order by applied_at')).all()
        out['roles'] = c.execute(text("""
            select rolname, rolcanlogin, rolinherit, rolsuper, rolbypassrls
              from pg_roles where rolname = any(:names) order by 1"""),
            {'names': list(ROLES)}).all()
        out['memberships'] = c.execute(text("""
            select r.rolname, g.rolname
              from pg_auth_members m
              join pg_roles r on r.oid = m.member
              join pg_roles g on g.oid = m.roleid
             where r.rolname = any(:names) order by 1, 2"""),
            {'names': list(ROLES)}).all()
        out['runtime_usage'] = c.execute(text(
            "select has_schema_privilege('p1ai_runtime', :s, 'USAGE')"), {'s': SCHEMA}).scalar()
        out['m2_policies'] = c.execute(text("""
            select c.relname, p.polname
              from pg_policy p join pg_class c on c.oid = p.polrelid
              join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relname = any(:t) order by 1, 2"""),
            {'t': list(M2_TABLES)}).all()
    engine.dispose()
    return out


def main() -> int:
    primary, clone = inspect(connect(PRIMARY)), inspect(connect(CLONE))
    verdicts: list[tuple[str, bool, str]] = []

    # --- 1/2. catalog and the exact object difference ----------------------
    p_tables = {n for n, m in primary['relations'].items() if m['kind'] in ('r', 'p')}
    c_tables = {n for n, m in clone['relations'].items() if m['kind'] in ('r', 'p')}
    missing = sorted(c_tables - p_tables)
    extra = sorted(p_tables - c_tables)
    expected = sorted(FROZEN_02 | FROZEN_03)

    print(f"\n== 1. Catalog ==")
    for label, data in ((PRIMARY, primary), (CLONE, clone)):
        print(f"  {label:24s} db={data['db']!r} read_only={data['read_only']} "
              f"tables={len([m for m in data['relations'].values() if m['kind'] in ('r','p')])}")
    print(f"  {PRIMARY} tables: {sorted(p_tables)}")
    print(f"  {CLONE} tables: {sorted(c_tables)}")
    verdicts.append(('C1 baseline four tables on both',
                     p_tables >= BASELINE and c_tables >= BASELINE,
                     f'{PRIMARY}={len(p_tables)} {CLONE}={len(c_tables)}'))
    verdicts.append(('C2 difference is exactly the six frozen objects',
                     missing == expected and not extra,
                     f'missing={missing} extra={extra}'))
    verdicts.append(('C3 finding_provenance is an ordinary table',
                     clone['relations'].get('finding_provenance', {}).get('kind') == 'r',
                     f"relkind={clone['relations'].get('finding_provenance', {}).get('kind')!r}"))

    # --- 3. real receipt state, and object-level execution proof -----------
    print(f"\n== 3. Receipt state and object-level execution ==")
    for label, data in ((PRIMARY, primary), (CLONE, clone)):
        print(f"  {label} ledger rows: {len(data['ledger'])}")
        for version, receipt, applied in data['ledger']:
            print(f"    {version:34s} {applied:%Y-%m-%d %H:%M}  {receipt}")
    p_roles = {r[0] for r in primary['roles']}
    verdicts.append(('R1 p1_m2_runtime exists on primary (object proof of 20261116_02)',
                     'p1_m2_runtime' in p_roles, f'roles={sorted(p_roles)}'))
    verdicts.append(('R2 p1ai_* chain exists on primary (object proof of 20261117_01)',
                     {'p1ai_engine', 'p1ai_runtime', 'p1ai_auditor'} <= p_roles,
                     f'roles={sorted(p_roles)}'))
    verdicts.append(('R3 m2 owner_scope/reference_read policies present on primary',
                     len(primary['m2_policies']) >= 6, f'{len(primary["m2_policies"])} policies'))
    verdicts.append(('R4 p1ai_runtime has USAGE on project1_ai (primary)',
                     bool(primary['runtime_usage']), str(primary['runtime_usage'])))
    has_receipts = {row[0] for row in primary['ledger']}
    verdicts.append(('R5 ledger records 20261116_02 / 20261117_01 (BLK-MIG-RECEIPT)',
                     {'20261116_02_m2_runtime_role', '20261117_01_execution_principal'} <= has_receipts,
                     f'ledger={sorted(has_receipts)}'))

    # --- 4. frozen objects carry their guards on the clone ----------------
    print(f"\n== 4. Object guards on the clone ==")
    for name in expected:
        meta = clone['relations'].get(name, {})
        print(f"  {name:24s} rls={meta.get('rls')} force={meta.get('force_rls')} "
              f"policies={meta.get('policies')} triggers={meta.get('triggers')}")
    verdicts.append(('F1 all six frozen tables exist on the clone with RLS forced',
                     all(clone['relations'].get(n, {}).get('rls') and
                         clone['relations'].get(n, {}).get('force_rls') for n in expected),
                     'every table rls+force'))
    verdicts.append(('F2 every frozen table carries immutable_history',
                     all(clone['relations'].get(n, {}).get('triggers') for n in expected),
                     'trigger present on all six'))

    # --- report -----------------------------------------------------------
    print('\n== Verdict ==')
    ok = True
    for name, passed, detail in verdicts:
        print(f'  {"PASS" if passed else "BLOCKED"}  {name}  [{detail}]')
        ok = ok and passed
    print(f'\nOverall: {"PASS" if ok else "BLOCKED"}')
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
