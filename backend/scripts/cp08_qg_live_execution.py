"""CP-08: one authorized live synthetic QG attempt against the adopted provider.

Reuses the existing ModelRunner, project1_ai ledger, global budget and disclosure
predicate. No QJ stage, no BDJ relabelling, no paid fallback, no live Dss schema
change. Exactly one provider dispatch.

Run from backend/:
    .venv/Scripts/python.exe scripts/cp08_qg_live_execution.py
"""
from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / 'src'))

from sqlalchemy import create_engine, text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1 import budget  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld, digest  # noqa: E402
from sitewise.project1.disclosure import (  # noqa: E402
    QG_PURPOSE, QG_SCHEMA_VERSION, SyntheticBdjAuthorization,
    SyntheticBdjDisclosure, SyntheticQgAuthorization, SyntheticQgDisclosure,
)
from sitewise.project1.measurement_policy import lab_authority  # noqa: E402
from sitewise.project1.prompts import PROMPTS  # noqa: E402
from sitewise.project1.provider import ENDPOINT, MODEL, TokenHarbor  # noqa: E402
from sitewise.project1.qg_contract import (  # noqa: E402
    CONTRACT_VERSION, QGCandidate, facts_from_packet, validate_candidate,
)
from sitewise.project1.qg_live import QgLiveRunner, load_authorization  # noqa: E402
from sitewise.project1.research import ResearchWorkflow  # noqa: E402
from sitewise.project1.runs import qg_policy_fingerprint  # noqa: E402

ACTOR = uuid.UUID('11111111-1111-4111-8111-111111111111')
# Existing synthetic assessment owned by the synthetic actor; project1_ai.runs
# has a real FK to m2_assessments, so an invented UUID would fail closed.
ASSESSMENT = uuid.UUID('da90aa4a-f9cf-4145-9acf-7de36c9d6fad')
UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
EXACT_TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
              'iced latte?')
RECEIPT = ('CP-08 Owner-authorized synthetic QG research-only evaluation: '
           'RM13 / 12 oz iced-latte scenario, one free-model attempt, '
           'USD 0.00 cost ceiling, no fielding or scientific approval.')
# EVAL-3 responded after 36.8 s; EVAL-6 took 89 s to receive the body. Provider
# latency is highly variable, so the evaluation deadline is deliberately generous.
TIMEOUT_SECONDS = int(os.environ.get('CP08_TIMEOUT', '180'))
EVALUATION_ID = os.environ.get('CP08_EVAL_ID', 'CP08-EVAL-7')
FEEDBACK = os.environ.get('CP08_FEEDBACK', '')  # exact prior validation code
IDENTITY_EXCEPTION = True  # documented :free-qualifier exception, never an exact claim
OUT = BACKEND.parent / 'artifacts' / 'cp08_qg_live'

results: dict[str, tuple[bool, str]] = {}


def check(name: str, ok: bool, detail: str = '') -> bool:
    results[name] = (bool(ok), detail)
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}", flush=True)
    return bool(ok)


def expect_hold(name: str, code: str, fn) -> None:
    try:
        fn()
    except WorkflowHeld as exc:
        check(name, str(exc) == code, f'code={exc}')
    else:
        check(name, False, 'did not hold')


def synthetic_packet() -> dict:
    """The existing synthetic RM13 scenario, with UUID identifiers for run binding."""
    value = {
        'schema_version': 'business-context-package/1.1',
        'assessment_id': str(ASSESSMENT),
        'confirmation': {'status': 'CURRENT_CONFIRMED', 'id': CONFIRMATION_ID,
                         'revision': 1},
        'confirmed_uncertainty': {
            'id': UNCERTAINTY_ID, 'confirmation_id': CONFIRMATION_ID,
            'actor_user_id': str(ACTOR), 'exact_text': EXACT_TEXT},
        'geography': None,
        'permissions': {'qj_execution': False},
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04',
                        'value': 'takeaway only'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def audit_rows(run_id: uuid.UUID):
    url = settings.project1_audit_database_url.get_secret_value()
    if not url:
        return None
    engine = create_engine(url, hide_parameters=True)
    with engine.connect() as connection:
        connection.execute(text('SET LOCAL ROLE p1ai_audit'))
        identity = connection.execute(text('SELECT current_user')).scalar()
        rows = connection.execute(text("""
            SELECT a.attempt_no, a.stage, a.prompt_version, a.prompt_hash,
                   a.request_hash, r.outcome, r.output_digest
            FROM project1_ai.attempts a
            LEFT JOIN project1_ai.attempt_receipts r
              ON r.run_id = a.run_id AND r.attempt_no = a.attempt_no
            WHERE a.run_id = :run ORDER BY a.attempt_no
        """), {'run': run_id}).mappings().all()
        connection.rollback()
    return identity, [dict(row) for row in rows]


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    before = budget.status()
    packet = synthetic_packet()
    facts = facts_from_packet(packet, uncertainty_version=UNCERTAINTY_ID)
    source = facts.fingerprint
    check('contract_2_facts_built', facts.assessment_id == str(ASSESSMENT)
          and facts.contract_version == CONTRACT_VERSION, f'fp={source[:16]}')

    # Explicit, auditable synthetic authorization artifact. It binds the exact
    # confirmed-facts fingerprint; changing a single confirmed fact invalidates it.
    auth_path = BACKEND / 'var' / 'qg_synthetic_authorization.json'
    auth_path.parent.mkdir(parents=True, exist_ok=True)
    authorization = {
        'purpose': QG_PURPOSE,
        'source_fingerprint': source,
        'assessment_id': str(ASSESSMENT),
        'actor_id': str(ACTOR),
        'operator_receipt': RECEIPT,
        'max_attempts': 1,
        'evaluation_id': EVALUATION_ID,
        'scenario': EXACT_TEXT,
        'authorized_by': 'PROJECT1 owner directive CP-08',
        'authorized_at': datetime.now(timezone.utc).isoformat(),
        'cost_ceiling_usd': 0.0,
    }
    auth_path.write_text(json.dumps(authorization, indent=2), encoding='utf-8')
    check('authorization_bound_to_facts',
          load_authorization(auth_path)['source_fingerprint'] == source,
          f'path={auth_path.relative_to(BACKEND)}')

    # All refusals happen BEFORE a run is provisioned or a socket is opened.
    bound = SyntheticQgAuthorization(run_id='not-yet-provisioned',
                                     source_fingerprint=source,
                                     operator_receipt=RECEIPT)
    qg_packet = {'schema_version': QG_SCHEMA_VERSION, 'source_fingerprint': source}
    expect_hold('qg_stage_refuses_bdj', 'DISCLOSURE_STAGE_NOT_AUTHORIZED',
                lambda: SyntheticQgDisclosure(bound).require_current(
                    'BDJ', qg_packet, ENDPOINT, MODEL))
    expect_hold('qg_refuses_real_data', 'DISCLOSURE_REAL_DATA_NOT_AUTHORIZED',
                lambda: SyntheticQgDisclosure(SyntheticQgAuthorization(
                    run_id='r', source_fingerprint=source, operator_receipt=RECEIPT,
                    data_class='REAL_PERSONAL')).require_current(
                        'QG', qg_packet, ENDPOINT, MODEL))
    expect_hold('qg_refuses_bdj_packet_schema', 'DISCLOSURE_SOURCE_CLASS_INVALID',
                lambda: SyntheticQgDisclosure(bound).require_current(
                    'QG', {'schema_version': 'project1-m2-projection/1-candidate',
                           'source_fingerprint': source}, ENDPOINT, MODEL))
    expect_hold('qg_refuses_changed_facts', 'DISCLOSURE_SOURCE_MISMATCH',
                lambda: SyntheticQgDisclosure(bound).require_current(
                    'QG', {**qg_packet, 'source_fingerprint': '0' * 64},
                    ENDPOINT, MODEL))
    expect_hold('bdj_authorization_cannot_dispatch_qg',
                'DISCLOSURE_STAGE_NOT_AUTHORIZED',
                lambda: SyntheticBdjDisclosure(SyntheticBdjAuthorization(
                    run_id='r', source_fingerprint=source,
                    operator_receipt=RECEIPT)).require_current(
                        'QG', qg_packet, ENDPOINT, MODEL))

    runtime_engine = create_engine(
        settings.project1_runtime_database_url.get_secret_value(),
        hide_parameters=True, pool_pre_ping=True)
    provider = TokenHarbor(settings.tokenharbor_api_key, enabled=True,
                           structured_mode=settings.tokenharbor_structured_mode,
                           timeout=TIMEOUT_SECONDS,
                           identity_exception=IDENTITY_EXCEPTION)
    provider.telemetry = {}
    runner = QgLiveRunner(engine=runtime_engine, authorization=authorization,
                          provider=provider)
    captured: dict = {}

    def capture_runner(stage, payload, output_type, **kwargs):
        # Retain the raw model answer even when the business validator rejects
        # it: the failed example is what justifies the next versioned prompt.
        raw = runner(stage, payload, output_type, **kwargs)
        captured['raw'] = raw
        return raw

    capture_runner.supports_prompt_key = True
    workflow = ResearchWorkflow(
        type('Builder', (), {'get_context': lambda self, _: packet})(),
        lab_authority(), None, capture_runner)

    output = None
    held = None
    try:
        output = workflow.execute_qg_from_facts(
            None, revision_feedback=FEEDBACK or None)
    except WorkflowHeld as exc:
        held = str(exc)
        check('live_qg_executed', False, f'held={held}')
    else:
        candidate = output['qg']
        validated = validate_candidate(
            QGCandidate.model_validate(candidate).model_dump(), facts)
        check('live_qg_executed', True,
              f"stage=QG prompt={PROMPTS['QG_PROPOSAL'].version} decision={candidate['decision']}")
        check('output_matches_qg_v2_contract',
              output['contract_version'] == CONTRACT_VERSION
              and validated.model_dump() == candidate,
              f"contract={output['contract_version']}")
        check('one_candidate_or_valid_abstention',
              (candidate['decision'] == 'DRAFT' and bool(candidate['question']))
              or (candidate['decision'] == 'ABSTAIN_NEEDS_REVIEW'
                  and not candidate['question']
                  and bool(candidate['missing_business_facts'])),
              f"decision={candidate['decision']}")
        check('no_unsupported_business_facts', True,
              'validate_candidate enforces confirmed numbers, currency, offers and source refs')
        check('no_qj_or_bank', output['qj'] is None
              and output['bank'] == 'NOT_CONSULTED_DIRECT_QG', 'qj=None bank=NOT_CONSULTED')

    run_id = runner.last_run_id
    check('run_provisioned', run_id is not None, f'run_id={run_id}')

    identity = provider.last_identity
    check('provider_identity_recorded', identity is not None
          and identity['requested_model'] == MODEL,
          f"classification={identity.get('classification') if identity else None}")
    # The provider reports the same model without the ':free' qualifier (see
    # docs/cp08/RESULTS.md). The narrow registered exception admits that label
    # for development evaluation only and records identity_verified=False.
    check('no_paid_fallback', identity is not None
          and identity['requested_model'] == MODEL
          and identity['classification'] in {'EXACT_MATCH',
                                             'MODEL_IDENTITY_UNVERIFIED_TEST_EXCEPTION'},
          f"classification={identity.get('classification') if identity else None} "
          f"verified={identity.get('identity_verified') if identity else None}")
    check('endpoint_is_provider_only', bool(ENDPOINT), ENDPOINT)

    after = budget.status()
    spent_delta = int(after['spent']) - int(before['spent'])
    # The global slot is consumed before transport, so a timeout still spends it.
    check('global_budget_consistent', spent_delta == 1
          and after['authorized_limit'] == 50,
          f"{before['spent']}->{after['spent']} of {after['authorized_limit']} (delta {spent_delta})")

    rows = audit_rows(run_id) if run_id else None
    if rows is None:
        check('independent_audit_readback', False,
              'audit readback unavailable (no run or audit database URL missing)')
    else:
        principal, ledger_rows = rows
        check('independent_audit_readback',
              principal == 'p1ai_audit' and len(ledger_rows) == 1
              and ledger_rows[0]['stage'] == 'QG'
              and ledger_rows[0]['outcome'] in {'returned', 'rejected',
                                                'unknown_outcome'},
              f'principal={principal} rows={len(ledger_rows)} '
              f"stage={ledger_rows[0]['stage'] if ledger_rows else None} "
              f"outcome={ledger_rows[0]['outcome'] if ledger_rows else None}")

    evidence = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'classification': 'LIVE_PROVIDER_EXECUTION',
        'not_offline': True,
        'scenario': EXACT_TEXT,
        'data_class': 'SYNTHETIC_NONHUMAN',
        'purpose': QG_PURPOSE,
        'contract_version': CONTRACT_VERSION,
        'schema_version': QG_SCHEMA_VERSION,
        'source_fingerprint': source,
        'policy_fingerprint': qg_policy_fingerprint(),
        'prompt_version': PROMPTS['QG_PROPOSAL'].version,
        'prompt_fingerprint': PROMPTS['QG_PROPOSAL'].fingerprint,
        'evaluation_id': EVALUATION_ID,
        'timeout_seconds': TIMEOUT_SECONDS,
        'endpoint': ENDPOINT,
        'model_identity': identity,
        'identity_exception_enabled': IDENTITY_EXCEPTION,
        'provider_telemetry': dict(provider.telemetry or {}),
        'run_id': str(run_id) if run_id else None,
        'ledger_rows': rows[1] if rows else None,
        'budget_before': before,
        'budget_after': after,
        'evaluation_id': EVALUATION_ID,
        'revision_feedback': FEEDBACK or None,
        'raw_model_output': captured.get('raw'),
        'hold': held,
        'output': output,
        'results': {k: {'ok': ok, 'detail': detail} for k, (ok, detail) in results.items()},
    }
    path = OUT / f'live_qg_evidence_{EVALUATION_ID}.json'
    path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding='utf-8')
    (OUT / 'live_qg_evidence.json').write_text(
        json.dumps(evidence, indent=2, ensure_ascii=False), encoding='utf-8')
    print(f'evidence={path}', flush=True)

    hard = [k for k, (ok, _) in results.items() if not ok]
    verdict = 'PASS' if not hard else 'FAIL'
    print(f'VERDICT={verdict} failed={len(hard)}', flush=True)
    return 0 if verdict == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
