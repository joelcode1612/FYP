"""Read-only: enumerate every FK on the eight tables, both directions."""
from __future__ import annotations

import psycopg2

conn = psycopg2.connect(host='127.0.0.1', port=5433, dbname='project1_workflow_tests',
                        user='postgres', password='123456', connect_timeout=10)
conn.autocommit = True
cur = conn.cursor()
cur.execute('SET default_transaction_read_only = on')

TABS = ('m2_bdj_objective_proposals', 'm2_bdj_objective_decisions',
        'm2_bdj_objective_admissions', 'm2_qg_candidates', 'm2_qg_authorizations',
        'm2_qg_candidate_reviews', 'm2_measurement_specs', 'm2_measurement_decisions')

cur.execute("""
    SELECT c.relname AS child, con.conname,
           pg_get_constraintdef(con.oid) AS def,
           fn.nspname || '.' || fc.relname AS parent
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_class fc ON fc.oid = con.confrelid
      JOIN pg_namespace fn ON fn.oid = fc.relnamespace
     WHERE con.contype = 'f' AND n.nspname = 'public' AND c.relname = ANY(%s)
     ORDER BY 1, 2
""", (list(TABS),))
rows = cur.fetchall()
print(f'FOREIGN KEYS FROM the eight tables: {len(rows)}')
for child, name, definition, parent in rows:
    print(f'  {child:30s} -> {parent:34s} {name}')

cur.execute("""
    SELECT c.relname, con.conname
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_class fc ON fc.oid = con.confrelid
     WHERE con.contype = 'f' AND n.nspname = 'public' AND fc.relname = ANY(%s)
     ORDER BY 1,2
""", (list(TABS),))
print('\nFOREIGN KEYS INTO the eight tables (from anywhere):',
      len(cur.fetchall()))

print('\nFK count per table:')
for t in TABS:
    cur.execute("""
        SELECT count(*) FROM pg_constraint con
          JOIN pg_class c ON c.oid = con.conrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE con.contype='f' AND n.nspname='public' AND c.relname=%s
    """, (t,))
    print(f'  {t:30s} {cur.fetchone()[0]}')
conn.close()
