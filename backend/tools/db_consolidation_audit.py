"""Read-only inventory of the SiteWise databases, for the consolidation audit.

What this does
--------------
Connects to each database, sets ``default_transaction_read_only = on`` before any
query, and dumps a structured inventory: schemas, tables, columns, constraints,
indexes, triggers, routines, views, RLS policies, roles, migration history and
exact row counts.

What this deliberately does not do
----------------------------------
No DDL, no DML, no ownership change, no connection-string change. The read-only
setting is applied per session and would make a write fail rather than silently
succeed if this file ever grew one.

The counts are taken as the database superuser, which bypasses RLS. That is
intentional and is stated in the output: a restricted connection can return zero
rows for a table that is full, and the N04-C audit already demonstrated that
trap. RLS is inventoried separately, so the difference between "empty" and
"invisible" is recorded rather than inferred.

Usage
-----
    python tools/db_consolidation_audit.py
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
OUT = BACKEND / 'var' / 'e2e' / 'db_audit'

TARGETS = [
    ('Dss', 5432),
    ('project1_workflow_tests', 5433),
    ('Final_Location_Analysis', 5432),
]
USER, PASSWORD = 'postgres', '123456'

#: Schemas that belong to the engine or to extensions. Inventoried for
#: completeness of the extension list, excluded from application diffs.
SYSTEM_SCHEMAS = {'pg_catalog', 'information_schema', 'pg_toast'}


def connect(db: str, port: int):
    import psycopg2
    conn = psycopg2.connect(host='127.0.0.1', port=port, dbname=db, user=USER,
                            password=PASSWORD, connect_timeout=10)
    conn.autocommit = True
    with conn.cursor() as cur:
        # Applied before anything else is read, so a mistake in this file cannot
        # become a write.
        cur.execute('SET default_transaction_read_only = on')
    return conn


def q(cur, sql, params=None):
    # Never pass an empty tuple: psycopg2 then treats the ``%`` in LIKE patterns
    # as a placeholder and fails with a bare IndexError.
    if params is None:
        cur.execute(sql)
    else:
        cur.execute(sql, params)
    return cur.fetchall()


def inventory(db: str, port: int) -> dict:
    conn = connect(db, port)
    cur = conn.cursor()
    data: dict = {'database': db, 'port': port, 'read_as': USER,
                  'read_only_session': True,
                  'captured_at': datetime.now(timezone.utc).isoformat()}

    data['version'] = q(cur, 'SHOW server_version')[0][0]
    data['size'] = q(cur, "SELECT pg_size_pretty(pg_database_size(current_database()))")[0][0]
    data['extensions'] = [
        {'name': n, 'version': v, 'schema': s}
        for n, v, s in q(cur, """
            SELECT e.extname, e.extversion, n.nspname
              FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
             ORDER BY e.extname""")]
    data['schemas'] = [r[0] for r in q(cur, """
        SELECT nspname FROM pg_namespace
         WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
         ORDER BY nspname""")]

    data['tables'] = [
        {'schema': s, 'name': t, 'kind': k, 'rls': rls, 'force_rls': force,
         'owner': owner, 'rows': rows}
        for s, t, k, rls, force, owner, rows in q(cur, """
            SELECT n.nspname, c.relname,
                   CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned'
                        WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized'
                        WHEN 'f' THEN 'foreign' END,
                   c.relrowsecurity, c.relforcerowsecurity, pg_get_userbyid(c.relowner),
                   c.reltuples::bigint
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind IN ('r','p','v','m','f')
               AND n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname NOT LIKE 'pg\\_%'
             ORDER BY n.nspname, c.relname""")]

    # Exact counts. reltuples is an estimate and the whole point of this audit is
    # not to report an estimate as a fact.
    exact = {}
    for t in data['tables']:
        if t['kind'] not in ('table', 'partitioned'):
            continue
        ident = f'"{t["schema"]}"."{t["name"]}"'
        try:
            exact[f'{t["schema"]}.{t["name"]}'] = q(cur, f'SELECT count(*) FROM {ident}')[0][0]
        except Exception as exc:  # noqa: BLE001 - recorded, not hidden
            conn.rollback()
            exact[f'{t["schema"]}.{t["name"]}'] = f'ERROR: {type(exc).__name__}'
    data['exact_row_counts'] = exact

    data['columns'] = [
        {'schema': s, 'table': t, 'column': c, 'type': ty, 'nullable': nl,
         'default': d, 'identity': ident, 'generated': gen}
        for s, t, c, ty, nl, d, ident, gen in q(cur, """
            SELECT table_schema, table_name, column_name,
                   CASE WHEN data_type='USER-DEFINED' THEN udt_name
                        ELSE data_type END,
                   is_nullable, column_default, is_identity, is_generated
              FROM information_schema.columns
             WHERE table_schema NOT IN ('pg_catalog','information_schema')
               AND table_schema NOT LIKE 'pg\\_%'
             ORDER BY table_schema, table_name, ordinal_position""")]

    data['constraints'] = [
        {'schema': s, 'table': t, 'name': n, 'type': ty, 'definition': d}
        for s, t, n, ty, d in q(cur, """
            SELECT n.nspname, c.relname, con.conname, con.contype,
                   pg_get_constraintdef(con.oid)
              FROM pg_constraint con
              JOIN pg_class c ON c.oid = con.conrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname NOT LIKE 'pg\\_%'
             ORDER BY n.nspname, c.relname, con.conname""")]

    data['indexes'] = [
        {'schema': s, 'table': t, 'name': i, 'definition': d, 'unique': u}
        for s, t, i, d, u in q(cur, """
            SELECT n.nspname, c.relname, ic.relname, pg_get_indexdef(i.indexrelid),
                   i.indisunique
              FROM pg_index i
              JOIN pg_class ic ON ic.oid = i.indexrelid
              JOIN pg_class c ON c.oid = i.indrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname NOT LIKE 'pg\\_%'
             ORDER BY n.nspname, c.relname, ic.relname""")]

    data['triggers'] = [
        {'schema': s, 'table': t, 'name': n, 'definition': d}
        for s, t, n, d in q(cur, """
            SELECT n.nspname, c.relname, t.tgname, pg_get_triggerdef(t.oid)
              FROM pg_trigger t
              JOIN pg_class c ON c.oid = t.tgrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE NOT t.tgisinternal
               AND n.nspname NOT IN ('pg_catalog','information_schema')
             ORDER BY n.nspname, c.relname, t.tgname""")]

    data['routines'] = [
        {'schema': s, 'name': n, 'kind': k, 'language': l, 'returns': r}
        for s, n, k, l, r in q(cur, """
            SELECT n.nspname, p.proname,
                   CASE p.prokind WHEN 'f' THEN 'function' WHEN 'p' THEN 'procedure'
                        WHEN 'a' THEN 'aggregate' WHEN 'w' THEN 'window' END,
                   l.lanname, pg_get_function_result(p.oid)
              FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace
              JOIN pg_language l ON l.oid = p.prolang
             WHERE n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname NOT LIKE 'pg\\_%'
             ORDER BY n.nspname, p.proname""")]

    data['policies'] = [
        {'schema': s, 'table': t, 'name': n, 'cmd': c, 'roles': r,
         'using': u, 'check': ch}
        for s, t, n, c, r, u, ch in q(cur, """
            SELECT schemaname, tablename, policyname, cmd, roles::text, qual,
                   with_check
              FROM pg_policies
             WHERE schemaname NOT IN ('pg_catalog','information_schema')
             ORDER BY schemaname, tablename, policyname""")]

    data['roles'] = [
        {'name': n, 'super': s, 'bypassrls': b, 'login': l, 'member_of': m}
        for n, s, b, l, m in q(cur, """
            SELECT r.rolname, r.rolsuper, r.rolbypassrls, r.rolcanlogin,
                   coalesce((SELECT string_agg(g.rolname, ',' ORDER BY g.rolname)
                               FROM pg_auth_members am
                               JOIN pg_roles g ON g.oid = am.roleid
                              WHERE am.member = r.oid), '')
              FROM pg_roles r
             WHERE r.rolname NOT LIKE 'pg\\_%'
             ORDER BY r.rolname""")]

    data['migration_history'] = {}
    for candidate in ('schema_migrations', 'alembic_version', 'm2_migrations',
                      'migration_history', 'flyway_schema_history'):
        for schema in data['schemas']:
            try:
                rows = q(cur, f'SELECT * FROM "{schema}"."{candidate}"')
                data['migration_history'][f'{schema}.{candidate}'] = rows
            except Exception:
                conn.rollback()

    cur.close()
    conn.close()
    return data


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for db, port in TARGETS:
        try:
            data = inventory(db, port)
        except Exception as exc:  # noqa: BLE001
            print(f'{db:26} FAILED {type(exc).__name__}: {exc}')
            continue
        path = OUT / f'{db}.json'
        path.write_text(json.dumps(data, indent=2, default=str), encoding='utf-8')
        tables = [t for t in data['tables'] if t['kind'] in ('table', 'partitioned')]
        rows = sum(v for v in data['exact_row_counts'].values()
                   if isinstance(v, int))
        print(f'{db:26} {len(data["schemas"]):2} schemas  {len(tables):3} tables  '
              f'{len(data["columns"]):4} columns  {len(data["policies"]):3} policies  '
              f'{rows:6} rows  -> {path.name}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
