"""Round 24 / Gate 2 — the seven-slot EE-01 chart-eligibility matrix.

For every measured slot of one campaign this records the frozen snapshot's
identity, its counts, its category-cell completeness against the frozen CUST03
question contract, and the exact refusal code ``chart_spec.from_ee01`` produces
if the slot is not convertible. It converts nothing by force: the refusal code
*is* the finding.

Read-only. It writes one JSON document and prints a compact table.

    backend/.venv/Scripts/python.exe tools/rt24_slot_matrix.py <m2-id> <actor-uuid> <out.json>
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
from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization  # noqa: E402
from sitewise.project1 import chart_question_source as cqs  # noqa: E402
from sitewise.project1.chart_spec import ChartRefused, from_ee01  # noqa: E402

m2_id = sys.argv[1]
actor = sys.argv[2]
out_path = Path(sys.argv[3])

engine = _ee01_engine(settings.ee01_database_url.get_secret_value())
# The report readback is a production readback: a synthetic snapshot may only be
# read through a developer grant, which the boundary checks per run.
service = Ee01Service(
    engine,
    synthetic_preview=SyntheticPreviewAuthorization.for_record(developer_user_id=actor),
)

with engine.begin() as conn:
    conn.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {'a': actor})
    campaign = conn.execute(text(
        'SELECT id, assessment_id, release_id, owner_user_id FROM cq_campaigns '
        'WHERE assessment_id = :aid'), {'aid': m2_id}).mappings().first()
    if not campaign:
        print('no campaign for', m2_id)
        raise SystemExit(1)
    snapshots = conn.execute(text(
        'SELECT * FROM ee01_measurement_snapshots WHERE campaign_id = :cid '
        'ORDER BY slot_id, cutoff DESC'), {'cid': campaign['id']}).mappings().all()
    cells_by_snapshot: dict[str, list[dict]] = {}
    for snap in snapshots:
        rows = conn.execute(text(
            'SELECT code,x,v,percentage,diagnostic_percentage,status '
            'FROM ee01_category_cells WHERE snapshot_id = :i ORDER BY code'),
            {'i': snap['id']}).mappings().all()
        cells_by_snapshot[str(snap['id'])] = [dict(r) for r in rows]

# Latest snapshot per slot.
latest: dict[str, dict] = {}
for snap in snapshots:
    slot = snap['slot_id']
    if slot not in latest:
        latest[slot] = dict(snap)

print(f'campaign {campaign["id"]}  release {campaign["release_id"]}')
print(f'snapshots in campaign: {len(snapshots)}  slots: {sorted(latest)}')

matrix = []
for slot in sorted(latest):
    snap = latest[slot]
    sid = str(snap['id'])
    entry: dict = {
        'slot_id': slot,
        'snapshot_id': sid,
        'cutoff': snap['cutoff'].isoformat(),
        'question_version': snap['question_version'],
        'q': snap['q'], 's': snap['s'], 'a': snap['a'], 'v': snap['v'],
        'status': snap['status'],
        'scope': snap['scope'],
        'fingerprint': snap['fingerprint'],
        'origin': (snap.get('metadata_json') or {}).get('origin'),
        'instrument_version': (snap.get('metadata_json') or {}).get('instrument_version'),
        'bank_version': (snap.get('metadata_json') or {}).get('bank_version'),
        'stimulus_hash': (snap.get('metadata_json') or {}).get('stimulus_hash'),
        'cells': cells_by_snapshot[sid],
        'snapshot_count_for_slot': sum(1 for s in snapshots if s['slot_id'] == slot),
        'all_cutoffs_for_slot': [s['cutoff'].isoformat() for s in snapshots if s['slot_id'] == slot],
    }

    # The frozen CUST03 question contract — the authoritative source, not the
    # release manifest's own copy (which lacks substantive_codes/report_sections).
    try:
        source = cqs.source_for(slot)
        question = dict(source.question)
        # report_sections lives on the registry entry, not the item dict; without
        # it from_ee01 refuses CHART_REPORT_SECTION_MISSING for every slot.
        question['report_sections'] = list(source.report_sections)
        entry['question'] = {
            'id': question.get('id'),
            'type': question.get('type'),
            'codes': question.get('codes'),
            'substantive_codes': question.get('substantive_codes'),
            'exclusive_terminal_codes': question.get('exclusive_terminal_codes'),
            'report_sections': question.get('report_sections'),
            'numerator_rule': question.get('numerator_rule'),
            'coverage_limitation': question.get('coverage_limitation'),
            'stem': (question.get('stem') or '')[:120],
            'instrument_gate': source.gate,
            'gate_render_state': source.render_state_override,
            'chart_supported_type': source.supported,
            'template_usable_for_substantive_report': source.template_usable_for_substantive_report,
            'labels_supplied': len(source.labels),
        }
    except Exception as exc:  # noqa: BLE001 - a missing contract is a finding
        question = None
        source = None
        entry['question'] = {'error': f'{type(exc).__name__}: {exc}'}

    # Cell completeness against the frozen contract.
    cell_codes = {c['code'] for c in entry['cells']}
    if question:
        declared = set(question.get('codes') or [])
        entry['cell_completeness'] = {
            'declared_codes': len(declared),
            'persisted_codes': len(cell_codes),
            'missing_codes': sorted(declared - cell_codes),
            'undeclared_codes': sorted(cell_codes - declared),
            'cell_denominators': sorted({c['v'] for c in entry['cells']}),
        }

    # The readback envelope, then the conversion attempt.
    try:
        readback = service.report_readback(actor, campaign['assessment_id'],
                                           campaign['id'], snap['id'])
        entry['readback_ok'] = True
        entry['readback_context_hash'] = readback.get('context_hash')
        entry['readback_authority'] = (readback.get('context') or {}).get('authority')
        entry['readback_gates'] = (readback.get('context') or {}).get('gates')
    except Exception as exc:  # noqa: BLE001
        entry['readback_ok'] = False
        entry['readback_error'] = f'{type(exc).__name__}: {getattr(exc, "code", exc)}'
        matrix.append(entry)
        continue

    snapshot_payload = {
        'contract_version': 'ee01-diagnostic/1',
        **{k: v for k, v in snap.items()},
        'cells': entry['cells'],
    }

    if question is None:
        entry['chart'] = {'ok': False, 'code': 'QUESTION_CONTRACT_MISSING'}
    else:
        def _attempt(override, label):
            try:
                spec = from_ee01(
                    snapshot_payload, readback, question,
                    title=f'{slot} diagnostic',
                    labels=source.labels,
                    render_state_override=override,
                )
                return {
                    'label': label,
                    'ok': True,
                    'render_state': spec.render_state,
                    'response_kind': spec.response_kind,
                    'options': [{'code': o.code, 'count': o.count,
                                 'percentage': None if o.percentage is None else str(o.percentage)}
                                for o in spec.options],
                    'derived': [{'code': d.code, 'count': d.count,
                                 'numerator': d.numerator_codes,
                                 'percentage': None if d.percentage is None else str(d.percentage)}
                                for d in spec.derived_lines],
                    'admission': {'status': spec.admission.status,
                                  'authority': spec.admission.authority,
                                  'gates': spec.admission.gates,
                                  'real_reportable': spec.admission.real_reportable},
                }
            except ChartRefused as exc:
                return {'label': label, 'ok': False, 'code': exc.code, 'status': exc.status}
            except Exception as exc:  # noqa: BLE001
                return {'label': label, 'ok': False,
                        'code': f'{type(exc).__name__}: {exc}'}

        # (a) what the instrument gate alone allows — the production state.
        entry['chart'] = _attempt(source.render_state_override, 'gate_only')
        # (b) what an authorized developer session may inspect. A gate that
        # requires an approved stimulus keeps its restriction: a preview may
        # disclose a count, never manufacture a missing authorization.
        preview_override = source.render_state_override or 'SYNTHETIC_PREVIEW_ONLY'
        entry['chart_preview'] = _attempt(preview_override, 'synthetic_preview')
    matrix.append(entry)

payload = {
    'm2_assessment_id': m2_id,
    'campaign_id': str(campaign['id']),
    'release_id': str(campaign['release_id']),
    'slots': matrix,
}
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(payload, indent=2, default=str), encoding='utf-8')

for e in matrix:
    gate = e.get('chart') or {}
    prev = e.get('chart_preview') or {}
    comp = e.get('cell_completeness') or {}
    def _t(tag, r):
        return f"{tag}=" + (r.get('render_state', '') if r.get('ok') else 'REFUSED:' + str(r.get('code')))
    print(f"{e['slot_id']}  {e['cutoff'][:16]}  V={e['v']:<4} "
          f"{e['status']:<24} {_t('gate', gate):<28} {_t('preview', prev):<34} "
          f"cells {comp.get('persisted_codes')}/{comp.get('declared_codes')} "
          f"missing={comp.get('missing_codes')}")
print('written', out_path)
