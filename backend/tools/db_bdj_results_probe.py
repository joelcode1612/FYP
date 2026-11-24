"""Read-only: what do the five existing Dss bdj_results rows look like, so the
`execution_mode` backfill can be derived from evidence rather than guessed?
"""
from __future__ import annotations

import psycopg2

conn = psycopg2.connect(host='127.0.0.1', port=5432, dbname='Dss',
                        user='postgres', password='123456', connect_timeout=10)
conn.autocommit = True
cur = conn.cursor()
cur.execute('SET default_transaction_read_only = on')

cur.execute("""
    SELECT result_id, run_id, attempt_no, execution_outcome,
           model_requested, model_returned,
           (output_digest IS NOT NULL) AS has_digest,
           (result_payload IS NOT NULL) AS has_payload,
           validation_status, review_outcome, finding_count, created_at
      FROM project1_ai.bdj_results
     ORDER BY created_at
""")
cols = [d[0] for d in cur.description]
print(' | '.join(cols))
for row in cur.fetchall():
    print(' | '.join('' if v is None else str(v) for v in row))

cur.execute("SELECT count(*) FROM project1_ai.bdj_results WHERE model_returned IS NOT NULL")
print('\nrows with model_returned:', cur.fetchone()[0])
cur.execute("SELECT count(*) FROM project1_ai.bdj_results WHERE output_digest IS NOT NULL")
print('rows with output_digest:', cur.fetchone()[0])

# the parent runs: does project1_ai.runs record an execution mode?
cur.execute("""
    SELECT column_name, data_type FROM information_schema.columns
     WHERE table_schema='project1_ai' AND table_name='runs' ORDER BY ordinal_position
""")
print('\nproject1_ai.runs columns:', [r[0] for r in cur.fetchall()])
conn.close()
