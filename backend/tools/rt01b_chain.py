"""Read the authoritative chain for one marketplace assessment, with the RLS
actor set exactly as the application sets it.

Every policy on these tables is ``TO`` a named runtime role and filters on
``current_setting('project1.actor_id')``, so an unscoped read returns 0 rows
silently rather than failing. This script sets the actor inside the transaction
(``is_local = true``) and reads.

    backend/.venv/Scripts/python.exe tools/rt01b_chain.py <marketplace-id> <actor-uuid>
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ENV_FILE = BACKEND / 'var' / 'e2e' / 'pg18' / 'app_pg18.env'

for line in ENV_FILE.read_text(encoding='utf-8').splitlines():
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key, value = line.split('=', 1)
    os.environ[key.strip()] = value.strip().strip('"').strip("'")

from sqlalchemy import create_engine, text  # noqa: E402

marketplace = sys.argv[1]
actor = sys.argv[2]

engine = create_engine(os.environ['DATABASE_URL'], hide_parameters=True)
with engine.begin() as c:
    c.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {'a': actor})
    links = c.execute(text(
        'SELECT link_id, m2_assessment_id, revoked_at FROM m2_assessment_links '
        'WHERE marketplace_assessment_id = :m'), {'m': marketplace}).mappings().all()
    print('links:', [dict(r) for r in links])
    for link in links:
        m2 = link['m2_assessment_id']
        row = c.execute(text(
            'SELECT id, revision, confirmed_revision FROM m2_assessments WHERE id = :i'),
            {'i': m2}).mappings().first()
        print('m2 assessment:', dict(row) if row else None)
