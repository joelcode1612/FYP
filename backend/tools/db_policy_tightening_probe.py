"""Read-only: would tightening the 9 policies to the `project1_actor()` form
hide any existing row in Dss?

For each table whose predicate would change, count rows that the *stronger*
predicate would still show vs. rows it would hide. Runs as superuser so RLS does
not distort the count; the comparison is done explicitly in SQL rather than by
opening two sessions.
"""
from __future__ import annotations

import json

import psycopg2

USER, PASSWORD = 'postgres', '123456'

conn = psycopg2.connect(host='127.0.0.1', port=5432, dbname='Dss',
                        user=USER, password=PASSWORD, connect_timeout=10)
conn.autocommit = True
cur = conn.cursor()
cur.execute('SET default_transaction_read_only = on')

CHECKS = [
    # (label, sql)
    ('m2_answer_revisions: child.assessment_id has no parent',
     """SELECT count(*) FROM public.m2_answer_revisions c
         WHERE NOT EXISTS (SELECT 1 FROM public.m2_assessments a WHERE a.id = c.assessment_id)"""),
    ('m2_bdj_evaluations: child.assessment_id has no parent',
     """SELECT count(*) FROM public.m2_bdj_evaluations c
         WHERE NOT EXISTS (SELECT 1 FROM public.m2_assessments a WHERE a.id = c.assessment_id)"""),
    ('m2_bdj_findings: child.assessment_id has no parent',
     """SELECT count(*) FROM public.m2_bdj_findings c
         WHERE NOT EXISTS (SELECT 1 FROM public.m2_assessments a WHERE a.id = c.assessment_id)"""),
    ('m2_confirmation_snapshots: child.assessment_id has no parent',
     """SELECT count(*) FROM public.m2_confirmation_snapshots c
         WHERE NOT EXISTS (SELECT 1 FROM public.m2_assessments a WHERE a.id = c.assessment_id)"""),
    ('m2_review_events: child.assessment_id has no parent',
     """SELECT count(*) FROM public.m2_review_events c
         WHERE NOT EXISTS (SELECT 1 FROM public.m2_assessments a WHERE a.id = c.assessment_id)"""),
    ('m2_business_context_builds: owner_user_id != parent owner',
     """SELECT count(*) FROM public.m2_business_context_builds c
          JOIN public.m2_assessments a ON a.id = c.assessment_id
         WHERE c.owner_user_id IS DISTINCT FROM a.owner_user_id"""),
    ('m2_business_context_builds: total rows',
     """SELECT count(*) FROM public.m2_business_context_builds"""),
    ('m2_business_contexts: owner_user_id != parent owner',
     """SELECT count(*) FROM public.m2_business_contexts c
          JOIN public.m2_assessments a ON a.id = c.assessment_id
         WHERE c.owner_user_id IS DISTINCT FROM a.owner_user_id"""),
    ('m2_business_contexts: total rows',
     """SELECT count(*) FROM public.m2_business_contexts"""),
    ('m2_confirmed_uncertainties: confirmation_id has no parent',
     """SELECT count(*) FROM public.m2_confirmed_uncertainties c
         WHERE NOT EXISTS (SELECT 1 FROM public.m2_confirmation_snapshots s WHERE s.id = c.confirmation_id)"""),
    ('m2_confirmed_uncertainties: confirmation owner != parent assessment owner',
     """SELECT count(*) FROM public.m2_confirmed_uncertainties c
          JOIN public.m2_confirmation_snapshots s ON s.id = c.confirmation_id
          JOIN public.m2_assessments a ON a.id = s.assessment_id
         WHERE a.owner_user_id IS NULL"""),
    ('m2_assessments: rows with NULL owner_user_id',
     """SELECT count(*) FROM public.m2_assessments WHERE owner_user_id IS NULL"""),
    ('m2_assessment_links: marketplace_assessment_id resolvable in Dss',
     """SELECT count(*) FROM public.m2_assessment_links l
          JOIN public.assessment a ON a.assessment_id = l.marketplace_assessment_id"""),
    ('m2_assessment_links: total',
     """SELECT count(*) FROM public.m2_assessment_links"""),
    ('m2_assessment_links: orphaned ids',
     """SELECT count(*) FROM public.m2_assessment_links l
         WHERE NOT EXISTS (SELECT 1 FROM public.assessment a
                            WHERE a.assessment_id = l.marketplace_assessment_id)"""),
]

results = {}
for label, sql in CHECKS:
    cur.execute(sql)
    value = cur.fetchone()[0]
    results[label] = value
    print(f'{value:>6}  {label}')

# Which of the orphaned marketplace ids do resolve in Final_Location_Analysis?
cur.execute("""
    SELECT l.marketplace_assessment_id::text
      FROM public.m2_assessment_links l
     WHERE NOT EXISTS (SELECT 1 FROM public.assessment a
                        WHERE a.assessment_id = l.marketplace_assessment_id)
""")
orphans = [r[0] for r in cur.fetchall()]
print('\norphaned marketplace_assessment_id values in Dss:', orphans)
conn.close()

conn = psycopg2.connect(host='127.0.0.1', port=5432, dbname='Final_Location_Analysis',
                        user=USER, password=PASSWORD, connect_timeout=10)
conn.autocommit = True
cur = conn.cursor()
cur.execute('SET default_transaction_read_only = on')
if orphans:
    cur.execute("SELECT assessment_id::text FROM public.assessment WHERE assessment_id::text = ANY(%s)",
                (orphans,))
    found = [r[0] for r in cur.fetchall()]
else:
    found = []
print('of those, present in Final_Location_Analysis:', found)
conn.close()

with open('var/e2e/db_audit/policy_tightening_probe.json', 'w', encoding='utf-8') as fh:
    json.dump({'checks': results, 'orphaned_ids': orphans,
               'orphans_present_in_fla': found}, fh, indent=2)
