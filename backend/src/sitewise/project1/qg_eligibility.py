"""Why can (or cannot) Direct-QG run for this assessment and objective?

The N04-A audit found that every refusal on this path was a single opaque string:
``QG_FIXED_OPTION_ADMISSION_UNAVAILABLE``, ``DIRECT_QG_MEASUREMENT_NOT_SUPPLIED``.
Those are correct refusals and poor explanations — an operator cannot tell which
of the prerequisites is missing, and cannot tell "definitively wrong" from "not
yet decided".

This module composes the *existing* verifiers into one report. It decides
nothing itself:

* the measurement requirement is decided by ``measurement_library.resolve``
  (this module only reports what it concluded);
* the admission requirement is decided by the persisted admission row;
* the *persisted* execution requirement is decided by
  ``public.m2_qg_authorizations`` — an unconsumed, unexpired row for this
  assessment, objective and measurement version;
* the *runner* execution requirement is decided by the on-disk artifact that
  ``qg_live`` itself will re-check before dispatch.

The last two are separate on purpose. An authorization row can exist while the
runner's artifact names a different assessment; reporting one as if it were the
other hides whichever gate actually failed.

The report is diagnostic only. It never dispatches, never writes, and never
returns an authorization. A caller that reads ``dispatch_status = PASS`` still
cannot make a provider call from here — ``QgLiveRunner`` re-verifies every
condition against the actual request.

Two statuses, kept apart because they fail for different reasons:

``prepare_status``  can a candidate be generated at all (objective admitted,
                    measurement applies, policy compatible)?
``dispatch_status``  may that generation reach the real provider (the artifact
                    must be bound to *this* assessment and source fingerprint)?
"""
from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

from sqlalchemy import text

from sitewise.project1 import measurement_library as ml
from sitewise.project1 import measurement_validation
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.validation_contract import (
    PASS,
    ValidationReport,
    failed,
    passed,
    unverified,
)

CONTRACT = 'sitewise-qg-eligibility/1'

#: Where ``qg_live`` looks for its authorization. Read here only to *report*
#: whether it covers this assessment; never modified.
AUTHORIZATION_PATH = (Path(__file__).resolve().parents[3]
                      / 'var' / 'qg_synthetic_authorization.json')


def _bind(conn, actor_id):
    conn.execute(text("SELECT set_config('project1.actor_id', :actor, false)"),
                 {'actor': str(actor_id)})


def _load_admission(conn, *, actor_id, assessment_id, objective_id=None,
                    proposal_id=None) -> dict | None:
    """The most recent admission for this assessment, optionally narrowed.

    Narrowed by ``proposal_id`` when the caller names one, because an optional
    BDJ objective is identified by its proposal, not by an O-code.
    """
    sql = """
        SELECT a.admission_id, a.proposal_id, a.assessment_id, a.confirmation_id,
               a.confirmation_revision, a.context_packet_hash, a.decision,
               a.objective_id, a.policy_version, a.policy_classification,
               a.policy_disposition, a.policy_resolution, a.actor_user_id,
               a.created_at
          FROM public.m2_bdj_objective_admissions a
          JOIN public.m2_assessments m ON m.id = a.assessment_id
         WHERE a.assessment_id = :assessment AND m.owner_user_id = :actor
    """
    params = {'assessment': str(assessment_id), 'actor': str(actor_id)}
    if proposal_id:
        sql += ' AND a.proposal_id = :proposal'
        params['proposal'] = str(proposal_id)
    elif objective_id:
        sql += ' AND a.objective_id = :objective'
        params['objective'] = str(objective_id)
    sql += ' ORDER BY a.created_at DESC LIMIT 1'
    row = conn.execute(text(sql), params).mappings().one_or_none()
    return dict(row) if row else None


def _load_measurement(conn, objective_id):
    """The specification and its approval decisions for one objective."""
    if not objective_id:
        return None, []
    spec = conn.execute(text("""
        SELECT measurement_id, measurement_version, objective_id, construct,
               population, status, response_format, allowed_parameter_names,
               spec_json, content_digest, owner_user_id
          FROM public.m2_measurement_specs
         WHERE objective_id = :objective
         ORDER BY created_at DESC LIMIT 1
    """), {'objective': str(objective_id)}).mappings().one_or_none()
    if spec is None:
        return None, []
    decisions = conn.execute(text("""
        SELECT measurement_id, measurement_version, decision, authority, scope,
               content_digest
          FROM public.m2_measurement_decisions
         WHERE measurement_id = :mid AND measurement_version = :mver
    """), {'mid': spec['measurement_id'],
           'mver': spec['measurement_version']}).mappings().all()
    return dict(spec), [dict(row) for row in decisions]


def _measurement_report(spec: dict | None, decisions: list[dict]) -> ValidationReport:
    """Run the real resolver, then report its requirements.

    The store is an in-memory view of the rows already read, so the resolver
    remains the single decision-maker without a second database round trip.
    """
    if spec is None:
        resolution = {
            'resolver_version': ml.RESOLVER_VERSION,
            'objective_id': None, 'outcome': ml.PROPOSE,
            'reason': 'NO_APPROVED_MEASUREMENT', 'missing_parameters': [],
            'measurement_id': None, 'measurement_version': None,
            'scientifically_approved': False, 'considered_specifications': [],
            'fielding_authorized': False,
        }
        return measurement_validation.evaluate(resolution, None)

    entity = SimpleNamespace(
        measurement_id=spec['measurement_id'],
        measurement_version=spec['measurement_version'],
        objective_id=spec['objective_id'],
        construct=spec['construct'],
        population=spec['population'],
        status=spec['status'],
        response_format=spec['response_format'],
        allowed_parameter_names=tuple(spec['allowed_parameter_names'] or ()),
        spec=spec['spec_json'] or {},
        content_digest=spec['content_digest'],
        owner_user_id=str(spec['owner_user_id']),
        key=(spec['measurement_id'], spec['measurement_version']),
    )
    store = ml.InMemoryMeasurementStore(specs=[entity], decisions=decisions)
    # A synthetic-scope approval is reported, never promoted: the resolver labels
    # it REUSE_SYNTHETIC and MV-10 stays UNVERIFIED.
    return measurement_validation.resolve_and_evaluate(
        store, spec['objective_id'], allow_synthetic_test_approval=True)


def _admission_checks(admission: dict | None) -> list:
    """The admission requirement, as three separately reportable facts."""
    if admission is None:
        return [failed('QG-ADM', 'Admitted research objective',
                       'ADMISSION_NOT_FOUND',
                       evidence={'admission': None})]
    checks = [passed('QG-ADM', 'Admitted research objective',
                     sources=[str(admission['admission_id']),
                              str(admission['proposal_id'])],
                     evidence={'objective_id': admission.get('objective_id'),
                               'policy_disposition': admission.get('policy_disposition')})]
    if str(admission.get('decision')) != 'WORTH_RESEARCHING':
        checks.append(failed('QG-ADM-2', 'Owner recorded the gap as worth researching',
                             'ADMISSION_DECISION_NOT_WORTH_RESEARCHING',
                             evidence={'decision': admission.get('decision')}))
    if admission.get('objective_id') is None and admission.get('proposal_id') is None:
        checks.append(unverified('QG-ADM-3', 'Admission binds an objective',
                                 'ADMISSION_BINDS_NO_OBJECTIVE'))
    return checks


def _persisted_authorization_checks(conn, *, assessment_id, objective_id,
                                    measurement_version) -> list:
    """Whether the authorization *ledger* holds a usable grant.

    There are two distinct authorization mechanisms and this report previously
    named only one of them, which understated what exists:

    * ``public.m2_qg_authorizations`` — the persisted ledger. A row is usable when
      it has not been consumed and has not expired. This is the auditable record
      of "the owner authorised this specific generation".
    * ``var/qg_synthetic_authorization.json`` — the on-disk artifact that
      ``QgLiveRunner`` itself reads before opening a socket. It is checked
      separately by :func:`_runner_artifact_checks`.

    Reporting only the artifact produced a misleading refusal: it said no
    authorization was bound to the assessment while the ledger held dozens. Both
    gates are real, so both are reported, each under its own check id.
    """
    row = conn.execute(text("""
        SELECT count(*) AS total,
               count(consumed_at) AS consumed,
               count(*) FILTER (
                   WHERE consumed_at IS NULL
                     AND (expires_at IS NULL OR expires_at > now())) AS usable,
               count(DISTINCT prompt_version) FILTER (
                   WHERE consumed_at IS NULL
                     AND (expires_at IS NULL OR expires_at > now())) AS usable_prompts,
               coalesce(string_agg(DISTINCT prompt_version, ',') FILTER (
                   WHERE consumed_at IS NULL
                     AND (expires_at IS NULL OR expires_at > now())), '') AS prompt_versions
          FROM public.m2_qg_authorizations
         WHERE assessment_id = :assessment
           AND (:objective IS NULL OR objective_id = :objective)
           AND (:mversion IS NULL OR measurement_version = :mversion)
    """), {'assessment': str(assessment_id), 'objective': objective_id,
           'mversion': measurement_version}).mappings().one()

    total, consumed, usable = int(row['total']), int(row['consumed']), int(row['usable'])
    evidence = {'total': total, 'consumed': consumed, 'usable': usable,
                'usable_prompt_versions': row['prompt_versions'],
                'objective_id': objective_id,
                'measurement_version': measurement_version}
    if usable > 0:
        # A usable row proves *an* attempt is authorized; it does not prove the
        # authorized prompt is the one a caller intends to use. The bound prompt
        # versions are reported so that distinction is visible rather than
        # inferred: an authorization for one prompt cannot dispatch another.
        return [passed('QG-AUTH', 'Persisted generation authorization',
                       evidence=evidence)]
    if total == 0:
        return [unverified('QG-AUTH', 'Persisted generation authorization',
                           'QG_AUTH_LEDGER_EMPTY', evidence=evidence)]
    # Rows exist but every one is consumed or expired. That is a definite refusal,
    # not an unknown: issuing more requires a new owner decision.
    return [failed('QG-AUTH', 'Persisted generation authorization',
                   'QG_AUTH_LEDGER_EXHAUSTED', evidence=evidence)]


def _runner_artifact_checks(*, assessment_id, source_fingerprint,
                            authorization_path=AUTHORIZATION_PATH) -> list:
    """Whether the on-disk artifact covers *this* assessment.

    This is the gate that stops a real provider call from ``QgLiveRunner``. It is
    read here exactly as ``qg_live.load_authorization`` will read it, so the
    report and the dispatch cannot disagree.

    It is deliberately a *separate* check from the persisted ledger: an
    authorization row can exist while the runner's artifact names a different
    assessment, and collapsing the two would hide whichever one failed.
    """
    path = Path(authorization_path)
    if not path.is_file():
        return [unverified('QG-LIVE', 'Runner execution artifact',
                           'QG_LIVE_AUTHORIZATION_MISSING',
                           evidence={'path_present': False})]
    try:
        payload = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return [unverified('QG-LIVE', 'Runner execution artifact',
                           'QG_LIVE_AUTHORIZATION_INVALID')]

    bound_assessment = str(payload.get('assessment_id') or '')
    bound_fingerprint = str(payload.get('source_fingerprint') or '')
    checks = []
    if bound_assessment != str(assessment_id):
        checks.append(unverified(
            'QG-LIVE', 'Runner execution artifact',
            'QG_LIVE_AUTHORIZATION_NOT_BOUND_TO_ASSESSMENT',
            sources=[bound_assessment],
            evidence={'authorized_assessment': bound_assessment,
                      'requested_assessment': str(assessment_id)}))
    elif source_fingerprint and bound_fingerprint != str(source_fingerprint):
        checks.append(unverified(
            'QG-LIVE', 'Runner execution artifact',
            'QG_LIVE_AUTHORIZATION_SOURCE_MISMATCH',
            sources=[bound_fingerprint],
            evidence={'authorized_fingerprint': bound_fingerprint,
                      'requested_fingerprint': str(source_fingerprint)}))
    else:
        checks.append(passed(
            'QG-LIVE', 'Runner execution artifact',
            sources=[bound_assessment],
            evidence={'max_attempts': payload.get('max_attempts'),
                      'purpose': payload.get('purpose')}))
    return checks


def evaluate(conn, *, actor_id, assessment_id, objective_id=None,
             proposal_id=None, authorization_path=AUTHORIZATION_PATH) -> dict:
    """Compose the report. Read-only: no write, no dispatch, no authorization."""
    _bind(conn, actor_id)

    admission = _load_admission(conn, actor_id=actor_id,
                                assessment_id=assessment_id,
                                objective_id=objective_id,
                                proposal_id=proposal_id)
    # The objective the admission binds is authoritative; the query parameter is
    # only a hint for which admission to select.
    bound_objective = admission.get('objective_id') if admission else objective_id
    spec, decisions = _load_measurement(conn, bound_objective)
    measurement = _measurement_report(spec, decisions)

    prepare_checks = _admission_checks(admission) + list(measurement.checks)
    prepare = ValidationReport(subject='qg_prepare',
                               policy_version=measurement.policy_version,
                               checks=prepare_checks)

    fingerprint = None
    if admission:
        row = conn.execute(text("""
            SELECT source_fingerprint FROM public.m2_bdj_objective_proposals
             WHERE proposal_id = :pid
        """), {'pid': str(admission['proposal_id'])}).mappings().one_or_none()
        fingerprint = row['source_fingerprint'] if row else None

    # Both authorization gates, reported separately and in the order a reader
    # would resolve them: the auditable ledger first, then the runner's artifact.
    ledger = _persisted_authorization_checks(
        conn, assessment_id=assessment_id, objective_id=bound_objective,
        measurement_version=spec['measurement_version'] if spec else None)
    artifact = _runner_artifact_checks(
        assessment_id=assessment_id, source_fingerprint=fingerprint,
        authorization_path=authorization_path)
    dispatch = ValidationReport(
        subject='qg_dispatch',
        policy_version=measurement.policy_version,
        checks=list(prepare.checks) + list(ledger) + list(artifact))

    return {
        'contract_version': CONTRACT,
        'assessment_id': str(assessment_id),
        'objective_id': bound_objective,
        'admission_id': str(admission['admission_id']) if admission else None,
        'proposal_id': str(admission['proposal_id']) if admission else None,
        'measurement_id': spec['measurement_id'] if spec else None,
        'measurement_version': spec['measurement_version'] if spec else None,
        'prepare_status': prepare.status,
        'prepare_refusal': prepare.first_reason(),
        'dispatch_status': dispatch.status,
        'dispatch_refusal': dispatch.first_reason(),
        'checks': [check.model_dump() for check in dispatch.checks],
        # Stated explicitly so a reader never infers authority from a PASS.
        'dispatches_model': False,
        'fielding_authorized': False,
        'publication_authorized': False,
        'scientifically_accepted': False,
    }


__all__ = ['CONTRACT', 'AUTHORIZATION_PATH', 'evaluate']
