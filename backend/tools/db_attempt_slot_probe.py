"""Read-only: is `attempt_slot = 1` a fact or an assumption for Dss's 24 attempts?"""
from __future__ import annotations

import psycopg2

conn = psycopg2.connect(host='127.0.0.1', port=5432, dbname='Dss',
                        user='postgres', password='123456', connect_timeout=10)
conn.autocommit = True
cur = conn.cursor()
cur.execute('SET default_transaction_read_only = on')

cur.execute("SELECT attempt_no, count(*) FROM project1_ai.attempts GROUP BY 1 ORDER BY 1")
print('Dss attempts by attempt_no:', cur.fetchall())

cur.execute("SELECT count(DISTINCT run_id) FROM project1_ai.attempts")
print('distinct runs:', cur.fetchone()[0])

cur.execute("""
    SELECT count(*) FROM (
      SELECT run_id FROM project1_ai.attempts GROUP BY run_id HAVING count(*) > 1
    ) t
""")
print('runs with more than one attempt:', cur.fetchone()[0])

cur.execute("SELECT stage, count(*) FROM project1_ai.attempts GROUP BY 1 ORDER BY 1")
print('attempts by stage:', cur.fetchall())

cur.execute("""
    SELECT column_name FROM information_schema.columns
     WHERE table_schema='project1_ai' AND table_name='attempts' ORDER BY ordinal_position
""")
print('attempts columns:', [r[0] for r in cur.fetchall()])
conn.close()

conn = psycopg2.connect(host='127.0.0.1', port=5433, dbname='project1_workflow_tests',
                        user='postgres', password='123456', connect_timeout=10)
conn.autocommit = True
cur = conn.cursor()
cur.execute('SET default_transaction_read_only = on')
cur.execute("SELECT attempt_slot, attempt_no, count(*) FROM project1_ai.attempts GROUP BY 1,2 ORDER BY 1,2")
print('\nwf attempts by (slot, attempt_no):', cur.fetchall())
conn.close()
