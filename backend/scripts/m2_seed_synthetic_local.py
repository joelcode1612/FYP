#!/usr/bin/env python3
"""Explicitly seed two SYNTHETIC M2 items into a LOCAL disposable *_test database.

Never use on hosted Supabase or a real entrepreneur database. Test-only.
The real 18-field successor is NOT adopted and is NOT seeded here.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
from uuid import uuid5, NAMESPACE_DNS
from sqlalchemy import create_engine, select
from sqlalchemy.engine import make_url

BACKEND=Path(__file__).resolve().parents[1]
if Path.cwd().resolve() != BACKEND:
    raise SystemExit('Run from backend/ to load teammate .env correctly.')
from sitewise.core.config import settings  # noqa: E402
from sitewise.db.models.m2_schema import instruments, items  # noqa: E402

p=argparse.ArgumentParser()
p.add_argument('--confirm-disposable-local-test-database', action='store_true')
a=p.parse_args()
if not a.confirm_disposable_local_test_database:
    raise SystemExit('DENIED: explicit disposable-local-test database confirmation required.')
url=make_url(settings.database_url)
if url.get_backend_name()!='postgresql' or url.host not in ('localhost','127.0.0.1') or not (url.database or '').lower().endswith('_test'):
    raise SystemExit('DENIED: seed only allowed on localhost/127.0.0.1 PostgreSQL ending in _test.')

version='SYNTHETIC_ONLY_20261107'
inst_id=uuid5(NAMESPACE_DNS,'sitewise:'+version)
synthetic_items=[
    {'item_key':'M2-04','question_text':'SYNTHETIC TEST: Describe the planned cafe.',
     'requiredness':'RECOMMENDED','answer_kind':'TEXT','option_values':[],
     'allowed_states':['ANSWERED','NOT_PROVIDED'],'lifecycle':'ACTIVE','sort_order':1},
    {'item_key':'M2-05','question_text':'SYNTHETIC TEST: Choose the service format.',
     'requiredness':'REQUIRED','answer_kind':'SINGLE',
     'option_values':['DINE_IN_FOCUSED','TAKEAWAY_FOCUSED'],
     'allowed_states':['ANSWERED','NOT_DECIDED'],'lifecycle':'ACTIVE','sort_order':2},
]
digest=hashlib.sha256(json.dumps(synthetic_items,sort_keys=True,separators=(',',':')).encode()).hexdigest()
engine=create_engine(settings.database_url,connect_args={'connect_timeout':6})
with engine.begin() as conn:
    existing=conn.execute(select(instruments.c.schema_digest).where(instruments.c.id==inst_id)).scalar_one_or_none()
    if existing is not None:
        if existing!=digest:
            raise RuntimeError('Synthetic fixture already exists with changed digest. No modification performed.')
        print('SYNTHETIC_FIXTURE_EXISTS:',str(inst_id))
    else:
        conn.execute(instruments.insert().values(id=inst_id,code='SYNTHETIC_TEST_ONLY',
            version_tag=version,approval_state='DRAFT',schema_digest=digest))
        for it in synthetic_items:
            conn.execute(items.insert().values(id=uuid5(NAMESPACE_DNS,str(inst_id)+':'+it['item_key']),
                  instrument_id=inst_id,**it))
        print('SYNTHETIC_DRAFT_SEEDED:',str(inst_id))
print('NOTE: approval_state=DRAFT; cannot start real M2 assessments; no QJ/QG activity.')
engine.dispose()

