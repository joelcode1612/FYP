"""Read-only: index definitions for the two unique indexes on admissions."""
from __future__ import annotations

import psycopg2

conn = psycopg2.connect(host='127.0.0.1', port=5433, dbname='project1_workflow_tests',
                        user='postgres', password='123456', connect_timeout=10)
conn.autocommit = True
cur = conn.cursor()
cur.execute('SET default_transaction_read_only = on')
cur.execute("""
    SELECT indexname, indexdef FROM pg_indexes
     WHERE schemaname='public'
       AND tablename='m2_bdj_objective_admissions'
     ORDER BY 1
""")
for name, definition in cur.fetchall():
    print(f'{name}:\n  {definition}\n')
conn.close()
