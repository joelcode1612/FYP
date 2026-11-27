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
from sitewise.project1.prompts import PROMPTS, source_prompt_key
from sitewise.project1.provider import ENDPOINT, MODEL
from sitewise.project1.key_custody import LocalKeyCustody
from sitewise.project1.result_store import BdjResultStore, DISCOVERY_RESULT_SCHEMA_VERSION
from sitewise.project1.ruleset_resolver import resolve_ruleset
from sitewise.project1.runs import attempt_count, ensure_run, latest_receipt

STATUS_CONTRACT = 'UNRECONCILED_PROPOSAL'
SYNTHETIC_DATA_CLASS = 'SYNTHETIC_NONHUMAN'
SYNTHETIC_PURPOSE = 'SYNTHETIC_BDJ_DIAGNOSTIC'


def _execution_provenance(runner) -> tuple[str, bool] | None:
    """The execution condition to record, or ``None`` when nothing executed.

    Read from the adapter's own dispatch state, never inferred from
    ``model_returned`` (DD-175): a provider can report a model label for a
    request that failed, and a dispatch can be attempted with no label at all.

    ``TokenHarbor`` tracks ``dispatched`` as a tri-state, and each value means
    exactly one thing:

    * ``True``  — a response was received;
    * ``None``  — the request was sent and the outcome is unknown;
    * ``False`` — nothing was sent.

    ``None`` is recorded as **dispatched**, deliberately. Under-reporting a
    possible spend is the dangerous error because it would permit a second
    dispatch; over-reporting cannot. The uncertainty is not lost — it is carried
    by ``execution_outcome = 'unknown_outcome'``, which the column already
    admits.

    ``False`` returns ``None``: no execution occurred, so there is no result to
    describe. The attempt ledger already holds the refusal, and writing a
    ``bdj_results`` row would assert a disposition for something that never ran
    — and no value in ``ck_bdj_execution_mode`` is true of it.

    A dispatch that could not have reached the provider is recorded as
    ``MOCKED_PROVIDER_TEST``. "Could not have" is read from configuration, not
    inferred from the outcome: only a real ``TokenHarbor`` with **no** injected
    ``transport`` talks to the adopted endpoint. An injected transport — the
    test doubles, and the synthetic trials — never leaves the process, and a
    provider object without a ``transport`` attribute is a stand-in that has no
    network path at all. Recording either as ``LIVE_PROVIDER_EXECUTION`` would
    assert a provider call that did not happen, which is the same class of false
    provenance this defect is about. The pairing is truthful under the deployed
    constraint too: ``ck_bdj_execution_dispatch`` forces
    ``MOCKED_PROVIDER_TEST`` to carry ``provider_dispatched = false``, i.e. "no
    provider was dispatched".

    A receipt that recorded an outcome but not a dispatch state is a composition
    defect, not a guess: it fails closed.
    """
    receipt = getattr(runner, 'last_execution', None)
    if not receipt:
        return None
    if 'dispatched' not in receipt:
        raise WorkflowHeld('BDJ_EXECUTION_PROVENANCE_UNAVAILABLE')
    if receipt['dispatched'] is False:
        return None
    provider = getattr(runner, 'provider', None)
    if not hasattr(provider, 'transport') or provider.transport is not None:
        return 'MOCKED_PROVIDER_TEST', False
    return 'LIVE_PROVIDER_EXECUTION', True


def _persist_with_provenance(store, runner, attempt_no, review_result,
                             execution_outcome, **kwargs):
    """Persist only when an execution actually happened.

    Returns the result id, or ``None`` when nothing was dispatched. Centralised
    so the persistence points cannot drift into recording different provenance
    for the same condition.
    """
    provenance = _execution_provenance(runner)
    if provenance is None:
        return None
    execution_mode, dispatched = provenance
    return store.persist(attempt_no, review_result, execution_outcome,
                         execution_mode=execution_mode,
                         provider_dispatched=dispatched, **kwargs)


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
            _persist_with_provenance(
                store, runner, receipt['attempt_no'], None,
                receipt['receipt_outcome'],
                output_digest=receipt.get('output_sha256'),
                model_returned=receipt.get('model_returned'),
                result_schema_version=DISCOVERY_RESULT_SCHEMA_VERSION, **provenance)
        raise
    receipt = runner.last_execution
    if not receipt or not receipt.get('receipt_recorded'):
        raise WorkflowHeld('MODEL_RECEIPT_OUTCOME_INVALID')
    result_id = _persist_with_provenance(
        store, runner, receipt['attempt_no'], result, receipt['receipt_outcome'],
        output_digest=receipt.get('output_sha256'),
        result_schema_version=DISCOVERY_RESULT_SCHEMA_VERSION,
        model_returned=receipt.get('model_returned'),
        validations=_validations(result), **provenance)
    if result_id is None:
        # Dispatched nothing, so nothing is stored; the ledger holds the refusal.
        raise WorkflowHeld('BDJ_EXECUTION_NOT_DISPATCHED')
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


def require_supported_instrument(rules, instrument: str) -> None:
    """Hold unless the loaded ruleset declares this instrument as supported.

    Fail-closed for **every** instrument. The previous check was
    ``instrument.startswith('M2V1-')``, so an M2V2 packet passed a guard meant
    to protect it and was evaluated against a catalogue whose every source key
    is ``M2V1-*``. Nothing could match, and the run returned an empty,
    successful-looking review instead of a refusal. An unsupported instrument
    is a hold, never an empty success.
    """
    supported = getattr(rules, 'SUPPORTED_INSTRUMENT_VERSIONS', ())
    if not supported or instrument not in supported:
        raise WorkflowHeld('BDJ_INSTRUMENT_RULESET_UNVERIFIED')


def _real_data_authorization(engine, assessment_id, revision, fingerprint, data_class,
                             prompt_key='BDJ', ruleset_version=None, rules_sha256=None,
                             actor_id=None):
    """Real-data authorisation for this exact run, or None.

    None for synthetic data (the normal path) and None when no matching,
    unexpired, unconsumed row exists. Returning None is what keeps the guard
    fail-closed; it never substitutes a permissive default.

    ``actor_id`` is the authenticated owner taken from the verified token, never
    from the request body. It is required to read the row at all: the table's
    ``owner_scope`` policy is actor-scoped and granted to ``p1_m2_runtime``.
    """
    if data_class == 'SYNTHETIC_NONHUMAN':
        return None
    from sitewise.core.config import settings as _settings
    from sitewise.project1.real_data_authorization import load
    # The row must be bound to the prompt that will actually run. This used to
    # hash ``''`` because a Prompt object is not a str, so the prompt binding
    # was void: a row issued for one prompt matched every prompt. The
    # fingerprint is the same value the attempt ledger records, so the
    # authorization and the execution receipt cannot disagree.
    prompt_digest = PROMPTS[prompt_key].fingerprint
    # The row must also be bound to the ruleset that actually resolved for this
    # instrument, not to whichever global default happens to be configured.
    #
    # Read through the M2 engine, not the runtime engine. The authorisation table
    # is an M2-scoped row: its ``owner_scope`` policy is granted to
    # ``p1_m2_runtime`` and to no other role. The runtime login is a member of
    # ``p1ai_runtime`` only, so it cannot assume that principal, and
    # ``p1ai_runtime`` itself has neither the privilege nor a policy here. Using
    # the M2 engine means the read happens as the principal the table was
    # designed for, with no grant and no policy change.
    from sitewise.db.m2_session import get_m2_engine
    return load(
        engine=get_m2_engine(), actor_id=actor_id,
        assessment_id=assessment_id, revision=revision,
        source_fingerprint=fingerprint,
        ruleset_version=ruleset_version or _settings.project1_rules_version,
        rules_sha256=rules_sha256 or _settings.project1_rules_sha256,
        prompt_digest=prompt_digest,
        data_class=data_class)


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
    instrument = packet.get('instrument_version', '')

    # Rules are a precondition. Do not create an immutable run before verifying
    # that the configured adoption receipt and on-disk digest are usable. This
    # runs before the authorization lookup so an unadopted or mis-scoped
    # ruleset is refused without ever touching the authorization table.
    #
    # The binding is per instrument: M2V1 and M2V2 carry their own version,
    # hash and receipt, so adopting one never authorizes the other and neither
    # can silently stand in for the other.
    binding = resolve_ruleset(instrument)
    rules = binding.module
    require_supported_instrument(rules, instrument)
    operator_receipt = binding.adoption_receipt
    # The dispatched prompt must match the instrument. Resolving the key once,
    # here, is what keeps provenance, the run's work identity and the actual
    # provider call from disagreeing about which contract is running.
    prompt_key = source_prompt_key(instrument)

    # The objective prompt and the issue-resolution policy are adopted
    # independently of the findings ruleset above, because the ruleset pin
    # covers neither. A LIVE run whose artefacts are unadopted or drifted is
    # refused here — before ensure_run(), so a refusal cannot leave an orphan
    # run behind on the append-only ledger. Synthetic diagnostics are unaffected.
    if purpose != SYNTHETIC_PURPOSE:
        from sitewise.project1.artifact_adoption import (
            require_objective_artifacts_adopted,
        )
        require_objective_artifacts_adopted(prompt_key)

    # The FULL disclosure predicate runs before provisioning, not just the two
    # cheap checks. Every DISCLOSURE_* condition is decidable from the packet and
    # the policy, and project1_ai.runs is append-only, so a refusal that happens
    # after ensure_run() leaves an orphan run that no later code can delete.
    # require_current() re-runs the same predicate at dispatch, so the two cannot
    # drift apart.
    # The projection schema this instrument must produce, resolved server-side.
    # Passing the packet's own schema_version here would make the disclosure
    # check vacuous, so the expected value comes from the instrument registry and
    # an unregistered instrument is refused.
    from sitewise.project1.m2v2_projection import expected_projection_schema
    projection_schema = expected_projection_schema(instrument)
    assessment_id = UUID(str(packet['assessment_id']))
    revision = packet['assessment_revision']

    def _load_authorization():
        """Read the live authorization for exactly this run.

        Used twice on purpose: once for the pre-provisioning predicate, and
        again as the disclosure's ``revalidate`` hook so dispatch re-reads the
        row immediately before the reservation (DD-005 §1.6). A single cached
        object would let an authorization that expired, was spent by a
        concurrent attempt, or was rebound in between still reach dispatch.
        """
        return _real_data_authorization(
            runtime_engine, assessment_id, revision, fingerprint, data_class,
            prompt_key, binding.version, binding.sha256, actor_id)

    validate_synthetic(
        data_class=data_class, purpose=purpose, stage='BDJ', endpoint=ENDPOINT,
        model=MODEL, max_attempts=1, operator_receipt=operator_receipt,
        source_fingerprint=fingerprint, packet=packet,
        expected_schema=projection_schema,
        real_authorization=_load_authorization())

    run_id = ensure_run(runtime_engine, actor_id, assessment_id, revision, fingerprint,
                        prompt_key=prompt_key, rules_version=binding.version)
    ledger = PostgresAttemptLedger(runtime_engine, actor_id, run_id)
    disclosure = SyntheticBdjDisclosure(SyntheticBdjAuthorization(
        run_id=str(run_id), source_fingerprint=fingerprint,
        operator_receipt=operator_receipt,
        data_class=data_class, purpose=purpose,
        expected_schema=projection_schema,
        real_authorization=_load_authorization()), revalidate=_load_authorization)
    # The engine looks the source prompt up under 'BDJ'. Substituting the
    # instrument-appropriate entry keeps the engine and its callers untouched
    # while making the prompt actually dispatched correct for this instrument.
    prompts_for_run = {**PROMPTS, 'BDJ': PROMPTS[prompt_key]}
    runner = runner_factory(ledger, disclosure, prompts_for_run)
    # The validated result is sealed at rest. This is wired unconditionally
    # rather than opt-in: an opt-in control is inert until someone remembers to
    # pass it, and the next person to enable the workflow flag would otherwise
    # persist finding prose in plaintext. If the custody root is unwritable the
    # write fails closed instead of silently degrading to plaintext.
    store = BdjResultStore(runtime_engine, actor_id, run_id,
                           payload_custody=LocalKeyCustody())

    provenance = {
        'ruleset_version': binding.version,
        'prompt_version': PROMPTS[prompt_key].version,
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
            # Only records a row when something was dispatched. A hold after
            # reserve but before dispatch leaves the ledger as the sole record,
            # which is the truthful place for a refusal (DD-175).
            _persist_with_provenance(
                store, runner, attempt_no, None, execution_outcome,
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
    result_id = _persist_with_provenance(
        store, runner, attempt_no, review_result, execution_outcome,
        output_digest=output_digest,
        review_reason=review_reason, validations=_validations(review_result),
        **provenance)
    if result_id is None:
        # A receipt exists but nothing was dispatched: the ledger is the record.
        return _response(None, packet, 'held')
    stored = store.read(result_id)
    return _response(stored, packet, stored['review_outcome'])
