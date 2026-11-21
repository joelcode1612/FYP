"""P1: a real BCB-V1-1.1.0 packet whose confirmed uncertainty is the exact offer.

Runs only inside the disposable PostgreSQL cluster created by
``tests/m2_bcb/run_isolated.py`` (suite ``current-instrument``). It creates an
explicitly synthetic M2V1 assessment, confirms it through the real FastAPI
surface, derives the confirmed uncertainty from an ENTREPRENEUR research
objective that states the fixed RM13 offer, builds and persists the real
``BCB-V1-1.1.0`` packet with purpose ``QJ_CONTEXT``, and admits it through the
real ``sitewise.project1.research.checked_context`` gate.

No provider/model call is made, no live database is written, and nothing here
claims Owner, scientific, GEO or bank approval.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID

from sqlalchemy import text

from sitewise.project1.contracts import digest
from sitewise.project1.research import checked_context

#: The confirmed uncertainty is this exact research objective, verbatim.
OBJECTIVE = ('How acceptable would potential customers find a hypothetical '
             '12 oz takeaway iced latte priced at RM13?')
OFFER_COMPONENTS = ('12 oz', 'takeaway', 'iced latte', 'RM13')
#: Legacy RC01 item keys that must never appear in a current M2V1 packet.
LEGACY_ITEM_KEYS = {'M2-06', 'M2-07', 'M2-11', 'M2-15', 'M2-20', 'M2-21'}
#: Allowed M2V1-11 research-decision codes (from the adopted definition).
DECISION_CODES = {'UNDECIDED', 'VALIDATE_CHOICE', 'EXPLORE', 'UNSURE'}


def _instrument(lab):
    from scripts.register_m2_v1 import register
    return register(lab['db'], apply=True,
                    expected_database='project1_m2_bcb_test')['instrument_id']


def _save(lab, mid, key, value, revision):
    return lab['request']('PUT', f'/assessments/{mid}/answers/{key}', 200,
                          json={'expected_revision': revision,
                                'answer_state': 'ANSWERED', 'value': value})


def _synthetic_confirmed_assessment(lab):
    """Create + answer + evaluate + review + confirm one synthetic M2V1 assessment."""
    instrument_id = _instrument(lab)
    mid = lab['request']('POST', '/assessments', 201,
                         json={'instrument_version_id': instrument_id}).json()['id']
    answers = [
        ('M2V1-01', 'UNDECIDED'),        # GEO: no area decided, no catalogue inferred
        ('M2V1-02', 'TAKEAWAY'),
        ('M2V1-03', ['COFFEE']),
        ('M2V1-04', ['STUDENTS']),
        ('M2V1-06', 'AFFORDABILITY'),
        ('M2V1-08', ['NONE']),
        # A single research topic is accepted for the MULTI item; NONE is absent.
        ('M2V1-09', ['PRICE_ACCEPTABILITY']),
        ('M2V1-11', 'VALIDATE_CHOICE'),
    ]
    for revision, (key, value) in enumerate(answers):
        _save(lab, mid, key, value, revision)
    assert answers[-1][0] == 'M2V1-11' and answers[-1][1] in DECISION_CODES
    revision = len(answers)
    findings = lab['request']('POST', f'/assessments/{mid}/bdj/evaluate',
                              json={'expected_revision': revision}).json()['findings']
    lab['request']('POST', f'/assessments/{mid}/review', json={'expected_revision': revision})
    confirmation = lab['request'](
        'POST', f'/assessments/{mid}/confirm', 200,
        json={'expected_revision': revision,
              'acknowledged_issue_ids': [f['id'] for f in findings]}).json()
    return mid, revision, confirmation, findings


def _build_qj_packet(lab, mid, cid, revision):
    """Real product composition: BusinessContextBuilderV1 at CURRENT_CONTEXT_VERSION."""
    from sqlalchemy.orm import Session
    from sitewise.repositories.business_context_repository import SqlBusinessContextStore
    from sitewise.repositories.m2_context_bindings import M2ContextBindings
    from sitewise.services.persisted_business_context_service import (
        PersistedBusinessContextService,
    )
    from sitewise.services.ports.business_context_store_port import ContextActor, ContextSelection

    # 90 days is an explicit TEST validity basis, not a product default.
    store = SqlBusinessContextStore(
        lab['db'],
        resolver_factory=lambda session: M2ContextBindings(
            session, purpose='QJ_CONTEXT', validity=timedelta(days=90)))
    service = PersistedBusinessContextService(store)
    selection = ContextSelection(UUID(mid), UUID(cid), revision)
    actor = ContextActor(lab['actor'], 'entrepreneur')
    first = service.construct_and_save(selection, actor)
    second = service.construct_and_save(selection, actor)
    return first, second


def _evidence_directory() -> Path:
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    root = Path(__file__).resolve().parents[3]  # FYP
    out = root / 'artifacts' / f'p1_price_measurement_{stamp}'
    out.mkdir(parents=True, exist_ok=True)
    return out


def check_price_measurement_packet(lab):
    """Assertions with recorded evidence; returns the evidence directory."""
    mid, revision, confirmation, findings = _synthetic_confirmed_assessment(lab)
    cid = confirmation['id']

    objective = lab['request'](
        'POST', f'/confirmations/{cid}/research-objectives', 201,
        json={'origin': 'ENTREPRENEUR', 'objective': OBJECTIVE,
              'expected_revision': revision}).json()
    uncertainty_id = objective['id']
    assert objective['exact_text'] == OBJECTIVE
    assert objective['qj_execution_authorized'] is False
    assert objective['source']['priority'] == 'PRICE_ACCEPTABILITY'

    first, second = _build_qj_packet(lab, mid, cid, revision)
    packet = first['packet']
    assert second['replayed'] is True and second['packet'] == packet

    accepted = checked_context(SimpleNamespace(get_context=lambda _request: packet), None)
    assert accepted is packet

    with lab['db'].connect() as connection:
        stored_revisions = set(connection.execute(
            text('SELECT id::text FROM m2_answer_revisions WHERE assessment_id=:id'),
            {'id': UUID(mid)}).scalars().all())
        uncertainty_row = connection.execute(text(
            'SELECT id::text, confirmation_id::text, exact_text '
            'FROM m2_confirmed_uncertainties WHERE id=:id'),
            {'id': UUID(uncertainty_id)}).mappings().one()

    body = {key: value for key, value in packet.items() if key != 'packet_hash'}
    recomputed_hash = digest(body)
    uncertainty_text = packet['confirmed_uncertainty']['exact_text']
    answer_ids = [answer['answer_revision_id'] for answer in packet['m2_answers']]
    item_keys = {answer['item_key'] for answer in packet['m2_answers']}

    assertions = {}

    def record(name, observed, condition):
        assertions[name] = {'passed': bool(condition), 'observed': observed}
        assert condition, name

    record('context_version_is_BCB_V1_1_1_0',
           packet['context_version'], packet['context_version'] == 'BCB-V1-1.1.0')
    record('schema_version_is_business_context_package_1_1',
           packet['schema_version'], packet['schema_version'] == 'business-context-package/1.1')
    record('geography_is_none', packet['geography'], packet['geography'] is None)
    record('confirmed_uncertainty_is_exact_objective',
           uncertainty_text, uncertainty_text == OBJECTIVE)
    record('confirmed_uncertainty_contains_offer_components',
           [c for c in OFFER_COMPONENTS if c.lower() in uncertainty_text.lower()],
           all(c.lower() in uncertainty_text.lower() for c in OFFER_COMPONENTS))
    record('confirmed_uncertainty_id_matches_persisted_row',
           uncertainty_row['id'], uncertainty_row['id'] == uncertainty_id)
    record('packet_hash_recomputes_from_body',
           {'declared': packet['packet_hash'], 'recomputed': recomputed_hash},
           recomputed_hash == packet['packet_hash'])
    record('answer_revision_ids_are_real_uuids_in_this_assessment',
           {'count': len(answer_ids), 'stored_count': len(stored_revisions)},
           all(isinstance(UUID(value), UUID) for value in answer_ids)
           and set(answer_ids) <= stored_revisions
           and len(set(answer_ids)) == len(answer_ids) == len(stored_revisions))
    record('confirmation_status_is_current_confirmed',
           packet['confirmation']['status'],
           packet['confirmation']['status'] == 'CURRENT_CONFIRMED')
    record('no_legacy_rc01_item_keys',
           sorted(item_keys & LEGACY_ITEM_KEYS), not (item_keys & LEGACY_ITEM_KEYS))
    record('all_item_keys_are_current_m2v1',
           sorted(item_keys), all(key.startswith('M2V1-') for key in item_keys))
    record('purpose_is_qj_context',
           packet['access']['scope']['purpose'],
           packet['access']['scope']['purpose'] == 'QJ_CONTEXT')
    record('no_authority_conferred',
           packet['permissions'],
           all(value is False for value in packet['permissions'].values()))

    out = _evidence_directory()
    (out / 'packet.json').write_text(
        json.dumps(packet, indent=2, ensure_ascii=False, default=str), encoding='utf-8')
    (out / 'assertions.json').write_text(json.dumps({
        'status': 'PROVISIONAL_TEST_ONLY_NOT_APPROVED',
        'production_adoption': False,
        'assessment_id': mid, 'confirmation_id': cid,
        'confirmed_uncertainty_id': uncertainty_id,
        'packet_hash': packet['packet_hash'],
        'assertions': assertions}, indent=2, ensure_ascii=False, default=str),
        encoding='utf-8')
    (out / 'run.json').write_text(json.dumps({
        'suite': 'current-instrument',
        'database': 'project1_m2_bcb_test', 'port': 55441,
        'live_database_writes': False,
        'production_acceptance': False,
        'production_adoption': False,
        'status': 'PROVISIONAL_TEST_ONLY_NOT_APPROVED',
        'data': 'explicit synthetic M2V1 assessment in a disposable cluster',
        'instrument_version': packet['instrument']['version_tag'],
        'assessment_id': mid, 'assessment_revision': revision,
        'confirmation_id': cid, 'confirmed_uncertainty_id': uncertainty_id,
        'objective': OBJECTIVE, 'packet_hash': packet['packet_hash'],
        'findings': [f['rule_id'] for f in findings],
        'qj_admission_gate': 'ACCEPTED'}, indent=2, ensure_ascii=False),
        encoding='utf-8')

    evidence_dir = Path(os.environ.get('M2_BCB_EVIDENCE', out))
    (evidence_dir / 'p1_evidence_location.json').write_text(
        json.dumps({'p1_evidence_directory': str(out)}, indent=2), encoding='utf-8')
    return out
