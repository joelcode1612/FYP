"""Q05 cells for the two cutoffs of one slot — verification only.

Two cutoffs of one slot are two frozen cohorts, not two revisions of one
finding. The report names the latest one; this script records both so the
report's choice can be checked against the store. Nothing here enters the
report payload, and nothing here is an authorised estimate.

    backend/.venv/Scripts/python.exe tools/rt01b_q05_cells.py <actor-uuid> <out.json>
"""
from __future__ import annotations

import json
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

from sqlalchemy import text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.api.v1.customer_questionnaire import _ee01_engine  # noqa: E402

actor = sys.argv[1]
out_path = Path(sys.argv[2])

engine = _ee01_engine(settings.ee01_database_url.get_secret_value())
with engine.begin() as c:
    c.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {'a': actor})
    snaps = c.execute(text(
        'SELECT id, slot_id, cutoff, q, s, a, v, status, fingerprint '
        'FROM ee01_measurement_snapshots WHERE slot_id = :slot '
        'ORDER BY cutoff DESC'), {'slot': 'Q05'}).mappings().all()
    out = []
    for snap in snaps:
        cells = c.execute(text(
            'SELECT code, x, v, percentage, diagnostic_percentage, status '
            'FROM ee01_category_cells WHERE snapshot_id = :i ORDER BY code'),
            {'i': snap['id']}).mappings().all()
        out.append({
            'snapshot_id': str(snap['id']),
            'cutoff': snap['cutoff'].isoformat(),
            'q': snap['q'], 's': snap['s'], 'a': snap['a'], 'v': snap['v'],
            'status': snap['status'],
            'fingerprint': snap['fingerprint'],
            'cells': [dict(cell) for cell in cells],
        })

payload = {'slot_id': 'Q05', 'snapshots': out}
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(payload, indent=2, default=str), encoding='utf-8')

for snap in out:
    base = {c['code']: c['x'] for c in snap['cells']}
    total = sum(v for k, v in base.items() if k != 'TOP_TWO_STATED_INTEREST')
    print(snap['cutoff'], 'V=%s' % snap['v'], 'base_total=%s' % total,
          'derived=%s' % base.get('TOP_TWO_STATED_INTEREST'), base)
print('written', out_path)
