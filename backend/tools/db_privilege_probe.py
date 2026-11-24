"""Read-only privilege/ownership probe for the consolidation strategy.

Every session sets ``default_transaction_read_only = on`` before the first
query. Nothing here writes.
"""
from __future__ import annotations

import json

import psycopg2

USER, PASSWORD = 'postgres', '123456'

TARGETS = [('Dss', 5432), ('project1_workflow_tests', 5433)]


def connect(db: str, port: int):
    conn = psycopg2.connect(host='127.0.0.1', port=port, dbname=db, user=USER,
                            password=PASSWORD, connect_timeout=10)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute('SET default_transaction_read_only = on')
    return conn


def q(cur, sql, params=None):
    if params is None:
        cur.execute(sql)
    else:
        cur.execute(sql, params)
    return cur.fetchall()


out = {}
for db, port in TARGETS:
    conn = connect(db, port)
    cur = conn.cursor()
    rec = {}

    rec['schema_grants'] = q(cur, """
        SELECT n.nspname, r.rolname, has_schema_privilege(r.rolname, n.oid, 'USAGE') AS usage,
               has_schema_privilege(r.rolname, n.oid, 'CREATE') AS create
          FROM pg_namespace n
          CROSS JOIN pg_roles r
         WHERE n.nspname IN ('public')
           AND r.rolname IN ('p1_m2_runtime', 'p1ai_runtime', 'p1_ee01_runtime',
                             'p1_schema_reader', 'p1_qgb_runtime', 'postgres')
         ORDER BY 2
    """)

    rec['m2_table_privs'] = q(cur, """
        SELECT c.relname, pg_get_userbyid(c.relowner) AS owner,
               has_table_privilege('p1_m2_runtime', c.oid, 'SELECT') AS sel,
               has_table_privilege('p1_m2_runtime', c.oid, 'INSERT') AS ins,
               has_table_privilege('p1_m2_runtime', c.oid, 'UPDATE') AS upd,
               has_table_privilege('p1_m2_runtime', c.oid, 'DELETE') AS del
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname LIKE 'm2\\_%' AND c.relkind = 'r'
         ORDER BY 1
    """)

    rec['acl_sample'] = q(cur, """
        SELECT c.relname, c.relacl::text
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname IN
               ('m2_assessments', 'm2_business_contexts', 'm2_bdj_objective_proposals',
                'm2_qg_candidates', 'users')
         ORDER BY 1
    """)

    rec['sequence_grants'] = q(cur, """
        SELECT c.relname,
               has_sequence_privilege('p1_m2_runtime', c.oid, 'USAGE') AS usage,
               has_sequence_privilege('p1_m2_runtime', c.oid, 'SELECT') AS sel
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'S'
         ORDER BY 1 LIMIT 20
    """)

    rec['role_attrs'] = q(cur, """
        SELECT rolname, rolsuper, rolbypassrls, rolcanlogin, rolinherit
          FROM pg_roles
         WHERE rolname IN ('p1_m2_runtime', 'p1ai_runtime', 'p1_ee01_runtime', 'postgres')
         ORDER BY 1
    """)

    out[db] = rec
    conn.close()

with open('var/e2e/db_audit/privilege_probe.json', 'w', encoding='utf-8') as fh:
    json.dump(out, fh, indent=2, default=str)

for db, rec in out.items():
    print('=' * 70)
    print(db)
    print('-- schema usage/create on public')
    for row in rec['schema_grants']:
        print('  ', row)
    print('-- p1_m2_runtime privileges on public.m2_*')
    for row in rec['m2_table_privs']:
        print('  ', row)
    print('-- acl sample')
    for row in rec['acl_sample']:
        print('  ', row[0], '->', row[1])
    print('-- sequences')
    for row in rec['sequence_grants']:
        print('  ', row)
    print('-- roles')
    for row in rec['role_attrs']:
        print('  ', row)
