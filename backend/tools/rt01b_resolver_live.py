"""Run the report measurement resolver against the real EE-01 store.

The report route reaches the store through ``get_ee01_service()``, which raises
``AttributeError`` because ``Settings`` declares no ``ee01_expected_database``
(DD-RT-05). This script builds the *same* service from the *same* DSN so the
resolver's own behaviour can be observed against real rows. No guard is
bypassed: ``Ee01Service.connection()`` still refuses a principal that is not
``p1_ee01_runtime``, and the binding still filters by actor and assessment.

    backend/.venv/Scripts/python.exe tools/rt01b_resolver_live.py <m2-id> [out.json]
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

sys.path.insert(0, str(BACKEND / 'src'))
sys.path.insert(0, str(BACKEND))

from sqlalchemy import text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.api.v1.customer_questionnaire import _ee01_engine  # noqa: E402
from sitewise.services.ee01_service import Ee01Service  # noqa: E402
from sitewise.services.report_measurement import resolve_report_measurement  # noqa: E402

m2_id = sys.argv[1] if len(sys.argv) > 1 else 'df15adf3-0000-0000-0000-000000000000'
out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else BACKEND / 'var' / 'e2e' / 'rt01b_resolver.json'

engine = _ee01_engine(settings.ee01_database_url.get_secret_value())
service = Ee01Service(engine)

# The campaign lookup needs the RLS actor, exactly as the service sets it. The
# owner is the caller; the binding re-filters by that same actor below, so a
# wrong owner still yields NO_CAMPAIGN rather than another user's campaign.
actor = sys.argv[3] if len(sys.argv) > 3 else None
with engine.begin() as conn:
    conn.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {'a': actor})
    row = conn.execute(
        text('SELECT id, owner_user_id, assessment_id, release_id FROM cq_campaigns '
             'WHERE assessment_id = :aid'),
        {'aid': m2_id},
    ).mappings().first()

if not row:
    print('no campaign for', m2_id)
    raise SystemExit(1)

print('campaign  :', row['id'])
print('owner     :', row['owner_user_id'])

record = {'m2_confirmation': {'m2_assessment_id': str(m2_id)}}

positive = resolve_report_measurement(
    record=record,
    actor_user_id=row['owner_user_id'],
    ee01_factory=lambda: service,
)

# Negatives, using the same resolver: no link, and a foreign actor.
no_link = resolve_report_measurement(
    record={}, actor_user_id=row['owner_user_id'], ee01_factory=lambda: service)
wrong_actor = resolve_report_measurement(
    record=record,
    actor_user_id='00000000-0000-0000-0000-000000000001',
    ee01_factory=lambda: service,
)
unavailable = resolve_report_measurement(
    record=record,
    actor_user_id=row['owner_user_id'],
    ee01_factory=lambda: (_ for _ in ()).throw(RuntimeError('store down')),
)

payload = {
    'm2_assessment_id': m2_id,
    'campaign_id': str(row['id']),
    'actor_user_id': str(row['owner_user_id']),
    'positive': positive,
    'negative_no_link': no_link,
    'negative_wrong_actor': wrong_actor,
    'negative_factory_raises': unavailable,
}
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(payload, indent=2), encoding='utf-8')

print(json.dumps({
    'status': positive['status'],
    'reason_code': positive['reason_code'],
    'counts_disclosed': positive['counts_disclosed'],
    'detail_readable': positive['detail_readable'],
    'slot_count': len(positive['slots']),
    'identity_campaign': (positive['identity'] or {}).get('campaign_id'),
    'identity_slot': (positive['identity'] or {}).get('slot_id'),
    'identity_cutoff': (positive['identity'] or {}).get('cutoff'),
    'slots': [s['slot_id'] for s in positive['slots']],
    'negatives': {
        'no_link': no_link['status'],
        'wrong_actor': wrong_actor['status'],
        'factory_raises': unavailable['status'],
    },
    'written': str(out_path),
}, indent=2))
