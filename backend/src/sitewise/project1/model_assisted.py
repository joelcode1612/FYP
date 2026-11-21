"""The cloud-BDJ execution path behind the model-assisted route.

Order is the contract (CP-04A runtime spec §3):

  confirm revision -> authorize synthetic-only -> provision/reuse run ->
  configured runner -> BDJEngine.review -> classify -> persist -> project

The two outcome axes stay separate: ``ledger.finish()`` records D1 transport
inside dispatch; ``BDJEngine.review()`` records D3 afterwards. Nothing here
translates one into the other.

The synthetic-only gate is deliberate. The M2 projection carries no data-class
marker, so a real packet is refused at ``DISCLOSURE_REAL_DATA_NOT_AUTHORIZED``
until the Owner decides provider retention for real declarations (B2/B3).
"""
from __future__ import annotations

from typing import Callable
from uuid import UUID

from sitewise.core.config import settings
from sitewise.project1.bdj import BDJEngine, load_rules
from sitewise.project1.contracts import WorkflowHeld, no_authority
from sitewise.project1.disclosure import (SyntheticBdjAuthorization, SyntheticBdjDisclosure,
                                          validate_synthetic)
from sitewise.project1.ledger import PostgresAttemptLedger
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.provider import ENDPOINT, MODEL
from sitewise.project1.key_custody import LocalKeyCustody
from sitewise.project1.result_store import BdjResultStore, DISCOVERY_RESULT_SCHEMA_VERSION
from sitewise.project1.runs import attempt_count, ensure_run, latest_receipt

STATUS_CONTRACT = 'UNRECONCILED_PROPOSAL'
SYNTHETIC_DATA_CLASS = 'SYNTHETIC_NONHUMAN'
SYNTHETIC_PURPOSE = 'SYNTHETIC_BDJ_DIAGNOSTIC'


def run_registered_synthetic_bdj_trial(*, enabled=False, packet, item_definitions,
                                       rules, runner, store, current_fingerprint,
                                       inventory_envelope=None):
    """Disabled-by-default internal trial composition; no production route.

    Caller must supply a server-authenticated, independently verified private
    source and role-protected registry. Registry decisions are not minted here.
    The runner reserves the existing ledger only after all disclosure checks.
    """
    import hashlib
    from pathlib import Path
    from sitewise.project1.disclosure import RegisteredSyntheticBdjDisclosure
    from sitewise.project1.synthetic_trial_registry import PrivateSyntheticTrialRegistry
    from sitewise.project1.provider import ModelRunner
    if enabled is not True or not isinstance(runner, ModelRunner):
        raise WorkflowHeld('BDJ_TRIAL_DISABLED')
    disclosure = runner.disclosure
    if (not isinstance(disclosure, RegisteredSyntheticBdjDisclosure) or
            not isinstance(disclosure.registry, PrivateSyntheticTrialRegistry) or
            not isinstance(runner.ledger, PostgresAttemptLedger) or
            not isinstance(store, BdjResultStore) or
            runner.ledger.engine is not store.engine or
            runner.ledger.run_id != store.run_id or runner.ledger.actor_id != store.actor_id or
            str(runner.ledger.run_id) != disclosure.expected['run_id'] or
            str(runner.ledger.actor_id) != disclosure.expected['owner_id']):
        raise WorkflowHeld('BDJ_TRIAL_AUTHORITY_COMPOSITION_REQUIRED')
    try:
        rule_hash = hashlib.sha256(Path(rules.__file__).read_bytes()).hexdigest()
    except (AttributeError, OSError):
        raise WorkflowHeld('BDJ_TRIAL_RULE_ARTIFACT_UNAVAILABLE') from None
    if rule_hash != disclosure.expected['rules_sha256']:
        raise WorkflowHeld('BDJ_TRIAL_RULE_ARTIFACT_MISMATCH')
    from sqlalchemy import text
    from sqlalchemy.orm import Session
    with Session(runner.ledger.engine) as session, session.begin():
        runner.ledger._scope(session)
        binding = session.execute(text('SELECT assessment_id, assessment_revision, source_fingerprint '
            'FROM project1_ai.runs WHERE id=:run AND owner_user_id=:actor'),
            {'run':runner.ledger.run_id, 'actor':runner.ledger.actor_id}).one_or_none()
        if (binding is None or str(binding.assessment_id) != str(packet.get('assessment_id')) or
                binding.assessment_revision != packet.get('assessment_revision') or
                binding.source_fingerprint != packet.get('source_fingerprint')):
            raise WorkflowHeld('BDJ_TRIAL_RUN_SOURCE_BINDING_MISMATCH')
    provenance = {'ruleset_version': rules.RULE_VERSION,
                  'prompt_version': runner.prompts['BDJ'].version,
                  'model_requested': runner.model,
                  'source_fingerprint': packet['source_fingerprint'],
                  'sources': _sources(packet)}
    engine = BDJEngine(rules, model_runner=runner)
    try:
        result = engine.review_discovery_trial(packet, item_definitions=item_definitions,
                                               recheck_current=current_fingerprint,
                                               inventory_envelope=inventory_envelope)
    except WorkflowHeld:
        receipt = runner.last_execution
        if receipt and receipt.get('receipt_recorded'):
            store.persist(receipt['attempt_no'], None, receipt['receipt_outcome'],
                output_digest=receipt.get('output_sha256'),
                model_returned=receipt.get('model_returned'),
                result_schema_version=DISCOVERY_RESULT_SCHEMA_VERSION, **provenance)
        raise
    receipt = runner.last_execution
    if not receipt or not receipt.get('receipt_recorded'):
        raise WorkflowHeld('MODEL_RECEIPT_OUTCOME_INVALID')
    result_id = store.persist(receipt['attempt_no'], result, receipt['receipt_outcome'],
        output_digest=receipt.get('output_sha256'), result_schema_version=DISCOVERY_RESULT_SCHEMA_VERSION,
        model_returned=receipt.get('model_returned'),
        validations=_validations(result), **provenance)
    return store.read(result_id)

MODEL_ASSISTED_MESSAGES = {
    'held': 'Your business details are available. The model-assisted review is '
            'waiting for its required setup.',
    'reviewed': 'Your details have been checked. Please review any suggested clarifications.',
    'rejected': 'The suggested review could not be validated. Your answers are unchanged.',
    'stale': 'Your business details changed. Review the latest version first.',
}


def _sources(packet: dict) -> list[dict]:
    """Packet declarations as source pointers. Never the quote."""
    return [{
        'source_id': declaration['answer_revision_id'],
        'source_version': declaration['item_version_id'],
        'source_fingerprint': declaration.get('definition_digest'),
        'locator': f"{declaration['item_key']}@{declaration['item_version_id']}",
    } for declaration in packet.get('declarations', [])]


def _real_data_authorization(engine, assessment_id, revision, fingerprint, data_class):
    """Real-data authorisation for this exact run, or None.

    None for synthetic data (the normal path) and None when no matching,
    unexpired, unconsumed row exists. Returning None is what keeps the guard
    fail-closed; it never substitutes a permissive default.
    """
    if data_class == 'SYNTHETIC_NONHUMAN':
        return None
    from sitewise.core.config import settings as _settings
    from sitewise.project1.real_data_authorization import load, prompt_sha256
    prompt = PROMPTS.get('BDJ') if isinstance(PROMPTS, dict) else None
    _d = prompt_sha256(prompt if isinstance(prompt, str) else '')
    print('LOAD ARGS a=%s r=%s fp=%s ver=%s sha=%s pr=%s data_class=%r'
          % (assessment_id, revision, str(fingerprint)[:12],
             _settings.project1_rules_version, str(_settings.project1_rules_sha256)[:12],
             _d[:12], data_class))
    try:
        return load(
            engine=engine, assessment_id=assessment_id, revision=revision,
            source_fingerprint=fingerprint,
            ruleset_version=_settings.project1_rules_version,
            rules_sha256=_settings.project1_rules_sha256,
            prompt_digest=prompt_sha256(prompt if isinstance(prompt, str) else ''),
            data_class=data_class)
    except Exception as exc:
        import traceback; traceback.print_exc()
        raise


def _validations(review_result: dict | None) -> list[dict]:
    rows = [{'check_no': 1, 'check_code': 'SOURCE_PROJECTION_VERIFIED',
             'severity': 'INFO', 'passed': True}]
    if review_result is not None:
        rejected = review_result.get('outcome') == 'rejected'
        rows.append({
            'check_no': 2, 'check_code': 'CANDIDATE_VALIDATION', 'severity': 'ERROR',
            'passed': not rejected,
            # A closed code, never the offending quote or provider text.
            'detail': 'CANDIDATE_VALIDATION_FAILED' if rejected else None,
        })
    return rows


def _response(stored: dict, packet: dict, message_key: str) -> dict:
    if stored is None:
        return {
            'assessment_id': packet['assessment_id'],
            'assessment_revision': packet['assessment_revision'],
            'review_outcome': None, 'execution_outcome': None,
            'validation_status': 'not_validated',
            'finding_authority': 'CANDIDATE_ONLY', 'findings': [], 'references': [],
            'message': MODEL_ASSISTED_MESSAGES[message_key],
            'status_contract': STATUS_CONTRACT, **no_authority(),
        }
    return {
        'result_id': str(stored['result_id']),
        'assessment_id': str(stored['assessment_id']),
        'assessment_revision': stored['assessment_revision'],
        'review_outcome': stored['review_outcome'],
        'execution_outcome': stored['execution_outcome'],
        'validation_status': stored['validation_status'],
        'finding_authority': 'CANDIDATE_ONLY',
        'findings': stored['findings'],
        'references': stored['references'],
        'message': MODEL_ASSISTED_MESSAGES[message_key],
        'status_contract': STATUS_CONTRACT, **no_authority(),
    }


def run_model_assisted(*, packet: dict, actor_id: UUID, runtime_engine,
                       runner_factory: Callable, current_fingerprint: Callable[[], str]) -> dict:
    """Execute one governed cloud-BDJ attempt and return its projection.

    ``runner_factory`` has the same signature as
    ``provider.configured_runner(ledger, disclosure, prompts)``; tests inject a
    fixture provider through it, so no network call is possible in a test.
    """
    data_class = packet.get('data_class')
    purpose = packet.get('purpose', SYNTHETIC_PURPOSE)
    fingerprint = packet['source_fingerprint']
    operator_receipt = settings.project1_rules_adoption_receipt

    # The FULL disclosure predicate runs before provisioning, not just the two
    # cheap checks. Every DISCLOSURE_* condition is decidable from the packet and
    # the policy, and project1_ai.runs is append-only, so a refusal that happens
    # after ensure_run() leaves an orphan run that no later code can delete.
    # require_current() re-runs the same predicate at dispatch, so the two cannot
    # drift apart.
    validate_synthetic(
        data_class=data_class, purpose=purpose, stage='BDJ', endpoint=ENDPOINT,
        model=MODEL, max_attempts=1, operator_receipt=operator_receipt,
        source_fingerprint=fingerprint, packet=packet,
        real_authorization=_real_data_authorization(
            runtime_engine, UUID(str(packet['assessment_id'])),
            packet['assessment_revision'], fingerprint, data_class))

    assessment_id = UUID(str(packet['assessment_id']))
    revision = packet['assessment_revision']

    # Rules are a precondition. Do not create an immutable run before verifying
    # that the configured adoption receipt and on-disk digest are usable.
    rules = load_rules(settings.project1_rules_version, settings.project1_rules_sha256,
                       settings.project1_rules_adoption_receipt)
    instrument = packet.get('instrument_version', '')
    if instrument.startswith('M2V1-') and instrument not in getattr(
            rules, 'SUPPORTED_INSTRUMENT_VERSIONS', ()):
        # The registered legacy M2-xx detectors are not an adopted M2V1
        # ruleset. A silent empty rule catalogue is not a valid review.
        raise WorkflowHeld('BDJ_INSTRUMENT_RULESET_UNVERIFIED')
    run_id = ensure_run(runtime_engine, actor_id, assessment_id, revision, fingerprint)
    ledger = PostgresAttemptLedger(runtime_engine, actor_id, run_id)
    disclosure = SyntheticBdjDisclosure(SyntheticBdjAuthorization(
        run_id=str(run_id), source_fingerprint=fingerprint,
        operator_receipt=operator_receipt,
        data_class=data_class, purpose=purpose,
        real_authorization=_real_data_authorization(
            runtime_engine, assessment_id, revision, fingerprint, data_class)))
    runner = runner_factory(ledger, disclosure, PROMPTS)
    # The validated result is sealed at rest. This is wired unconditionally
    # rather than opt-in: an opt-in control is inert until someone remembers to
    # pass it, and the next person to enable the workflow flag would otherwise
    # persist finding prose in plaintext. If the custody root is unwritable the
    # write fails closed instead of silently degrading to plaintext.
    store = BdjResultStore(runtime_engine, actor_id, run_id,
                           payload_custody=LocalKeyCustody())

    provenance = {
        'ruleset_version': settings.project1_rules_version,
        'prompt_version': PROMPTS['BDJ'].version,
        'model_requested': MODEL,
        'model_returned': None,
        'source_fingerprint': fingerprint,
        'sources': _sources(packet),
    }

    before = attempt_count(runtime_engine, actor_id, run_id)
    try:
        review_result = BDJEngine(rules, model_runner=runner).review(
            packet, recheck_current=current_fingerprint)
    except WorkflowHeld:
        after = attempt_count(runtime_engine, actor_id, run_id)
        if after > before:
            # Dispatch happened and ModelRunner already recorded a receipt.
            # Persist D1 exactly as the ledger wrote it, then surface the hold.
            receipt = latest_receipt(runtime_engine, actor_id, run_id)
            if receipt is None:
                raise WorkflowHeld('MODEL_RECEIPT_OUTCOME_INVALID') from None
            attempt_no, execution_outcome, output_digest = receipt
            store.persist(attempt_no, None, execution_outcome,
                          output_digest=output_digest,
                          validations=_validations(None), **provenance)
        # A hold before reserve (disclosure, already-reserved, budget) wrote no
        # attempt, so there is no result row to create.
        raise

    # Record what the provider reported, not only what was requested. The
    # adapter populates last_execution at dispatch; a hold that never dispatched
    # leaves it as None, which is the truthful value.
    provenance['model_returned'] = (runner.last_execution or {}).get('model_returned')

    if review_result['outcome'] == 'held':
        # No ruleset adopted: bdj.py returns before reserve, so there is no
        # attempt to bind a result row to. 'held' stays in the response only.
        return _response(None, packet, 'held')

    receipt = latest_receipt(runtime_engine, actor_id, run_id)
    if receipt is None:
        raise WorkflowHeld('MODEL_RECEIPT_OUTCOME_INVALID')
    attempt_no, execution_outcome, output_digest = receipt
    review_reason = ('CANDIDATE_VALIDATION_FAILED'
                     if review_result.get('outcome') == 'rejected' else None)
    result_id = store.persist(
        attempt_no, review_result, execution_outcome, output_digest=output_digest,
        review_reason=review_reason, validations=_validations(review_result),
        **provenance)
    stored = store.read(result_id)
    return _response(stored, packet, stored['review_outcome'])
