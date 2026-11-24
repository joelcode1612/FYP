"""Read-only: full receipt text of project1_ai.schema_versions, plus any backup
or restore evidence it mentions."""
from __future__ import annotations

import psycopg2

for db, port in (('Dss', 5432), ('project1_workflow_tests', 5433),
                 ('Final_Location_Analysis', 5432)):
    conn = psycopg2.connect(host='127.0.0.1', port=port, dbname=db,
                            user='postgres', password='123456', connect_timeout=10)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute('SET default_transaction_read_only = on')
    cur.execute("""
        SELECT to_regclass('project1_ai.schema_versions') IS NOT NULL
    """)
    present = cur.fetchone()[0]
    print('=' * 78)
    print(f'{db}  project1_ai.schema_versions present: {present}')
    if present:
        cur.execute('SELECT version, applied_at FROM project1_ai.schema_versions ORDER BY applied_at')
        for v, t in cur.fetchall():
            print(f'  {t:%Y-%m-%d %H:%M}  {v}')
    conn.close()
