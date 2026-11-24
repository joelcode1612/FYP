"""Read-only: does Dss record a schema version anywhere?"""
from __future__ import annotations

import psycopg2

for db, port in (('Dss', 5432), ('project1_workflow_tests', 5433)):
    conn = psycopg2.connect(host='127.0.0.1', port=port, dbname=db,
                            user='postgres', password='123456', connect_timeout=10)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute('SET default_transaction_read_only = on')
    cur.execute("""
        SELECT table_schema, table_name FROM information_schema.tables
         WHERE table_name IN ('schema_versions', 'alembic_version', 'schema_migrations')
         ORDER BY 1,2
    """)
    rows = cur.fetchall()
    print(f'{db}: {rows}')
    for schema, table in rows:
        cur.execute(f'SELECT * FROM {schema}.{table} ORDER BY 1')
        data = cur.fetchall()
        cols = [d[0] for d in cur.description]
        print(f'  {schema}.{table} cols={cols} rows={len(data)}')
        for r in data[:6]:
            print('   ', r)
    conn.close()
