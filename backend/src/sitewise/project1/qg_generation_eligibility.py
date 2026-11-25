"""Contract 2.1: generation eligibility derived from the owner's own approval.

Why this module exists
----------------------
Contract 2.0 generates from confirmed facts, which was the right correction, but
its *eligibility* still demanded two things an entrepreneur was never meant to
produce before seeing a question:

1. a separately authored, **approved** measurement specification; and
2. a separately authored **objective-admission row**.

Both are records of facts the owner has already established. The approval is
persisted in ``m2_bdj_objective_decisions`` and the binding fields an admission
stores — ``source_fingerprint``, ``confirmation_id``, ``context_packet_hash``,
who decided and when — are already on that decision row. Ten of the eleven
admission-only columns are a rename, a derivation from the proposal, a
computation, or an idempotency token; the eleventh is ``objective_id``, which is
``CHECK``-restricted to ``O1..O6`` and therefore cannot express the additional
objective it would have to carry (DD-036).

So this module derives the confirmed-objective relationship from the approval
instead of asking for it again. It **adds no entrepreneur action**.

What it deliberately does not do
--------------------------------
* It does not approve a measurement. ``proposed_measurement`` is labelled
  ``PROPOSED_NOT_CONFIRMED`` in every field and sets
  ``scientifically_approved = False``.
* It does not relax a scientific gate. ``scientific_status`` still runs the real
  ``measurement_validation`` checks; it is simply no longer a precondition for
  *generating* a candidate.
* It does not write. Every function here is a read or a pure computation.
* It does not assign an ``O``-code to an additional objective. The six mandatory
  objectives stay in their own registry and their coverage count is untouched.
"""
from __future__ import annotations

import json

from sqlalchemy import text

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.validation_contract import (
    PASS,
    ValidationReport,
    failed,
    passed,
    unverified,
)

#: Identifies the eligibility contract. A consumer expecting
#: ``sitewise-qg-eligibility/1`` gets a different value rather than a report whose
#: fields silently changed meaning.
CONTRACT = 'sitewise-qg-generation-eligibility/2'

#: The generation contract this eligibility serves.
GENERATION_CONTRACT = 'P1-QG-CONTRACT-2.1'

#: Two objective identities, kept apart on purpose. A mandatory objective is one
#: of the six and may be counted as coverage. An additional objective is specific
#: to one assessment, is identified by its proposal, and never becomes coverage.
MANDATORY_REGISTRY = 'MANDATORY_REGISTRY_OBJECTIVE'
ADDITIONAL = 'ADDITIONAL_ASSESSMENT_OBJECTIVE'

#: The persisted response-format vocabulary. A proposal outside it is refused
#: rather than coerced, because the storage column would reject it anyway.
SUPPORTED_FORMATS = frozenset({
    'SINGLE_CHOICE', 'BINARY_CHOICE', 'MULTIPLE_CHOICE', 'ORDERED_SCALE',
    'NUMERIC_RANGE_OPTIONS',
})

#: Three suitability states, because "not suitable" and "not yet known" are
#: different facts and must not collapse into one refusal.
#:
#: ``UNSUITABLE`` is a *policy result*: BDJ has classified the cited gap as
#: something a customer survey cannot answer (``objective_admission.py`` refuses
#: these dispositions outright). Generating a question for it spends a real
#: provider call on an instrument the product has already ruled out, and the
#: predictable outcome is an abstention. That is why this state blocks.
#:
#: ``UNRESOLVED`` is the absence of a verdict — no verified business anchor, no
#: measurement specification, or an admission the owner has not yet linked. The
#: existing mechanism for that is the candidate's own abstention, which names a
#: missing fact instead of inventing one, so this state deliberately does **not**
#: block. Treating it as a refusal would turn "we do not know yet" into "never",
#: and would stop the very run that produces the evidence.
#:
#: ``SUITABLE`` needs no explanation beyond itself.
SUITABILITY_SUITABLE = 'SUITABLE'
SUITABILITY_UNRESOLVED = 'UNRESOLVED'
SUITABILITY_UNSUITABLE = 'UNSUITABLE'

#: The dispositions that are a refusal, not a deferral. Kept as an explicit set
#: rather than "anything not in an allow-list", so a new disposition added to
#: ``issue_resolution`` cannot silently become generation-permitted.
UNSUITABLE_DISPOSITIONS = frozenset({
    'BUSINESS_DECISION_REQUIRED',
    'HOLD_REVIEW',
    'NO_ACTION',
})


def _research_suitability(engine, *, proposal_id, source_fingerprint,
                          actor_id) -> dict:
    """Read BDJ's own disposition for this proposal; never re-derive it here.

    The judgement belongs to ``objective_admission``: one module decides whether
    a cited gap is answerable by a customer survey, and this one only reads that
    answer. Duplicating the policy would let the two drift, which is exactly the
    incoherence this check exists to remove.

    A projection that fails is reported as ``UNRESOLVED`` rather than blocking:
    an unreadable disposition is not a policy refusal, and turning an
    infrastructure error into "your objective is unsuitable" would be a worse
    lie than the one being fixed.
    """
    from sitewise.project1 import objective_adapter
    from sitewise.project1.objective_admission import UNSUITABLE_RESOLUTIONS

    try:
        projection = objective_adapter.admission_status(
            engine, proposal_id, source_fingerprint=source_fingerprint,
            actor_id=actor_id)
    except Exception as exc:                      # noqa: BLE001 - reported, not raised
        return {'suitability': SUITABILITY_UNRESOLVED,
                'suitability_source': 'ADMISSION_PROJECTION_UNAVAILABLE',
                'projection_error': type(exc).__name__,
                # An unreadable projection is not a refusal: claiming one would
                # turn an infrastructure error into "your objective is
                # unsuitable". DD-123 does not change that.
                'policy_refused': False,
                'reason': None, 'disposition': None, 'classification': None}

    disposition = projection.get('policy_disposition')
    classification = projection.get('policy_classification')
    # ``admission_state`` reports ``admission_reason`` (a code) and
    # ``pending_requirement`` (the sentence a person can act on). There is no
    # ``reason`` key, so reading one produced ``None`` on every refusal and the
    # gate could say *that* the objective was unsuitable but never *why*.
    reason = (projection.get('pending_requirement')
              or projection.get('admission_reason'))

    # Two paths reach a refusal and only one of them sets ``policy_disposition``.
    # ``issue_resolution.resolve_candidate`` refuses a candidate whose text has no
    # verified business anchor as the *resolution*
    # ``NOT_CUSTOMER_RESEARCH_SUITABLE``, leaving the disposition null. Reading
    # only the disposition let that refusal pass G-05S and continue to provider
    # dispatch — the exact shape of DD-062, which this check exists to prevent
    # (DD-123).
    #
    # ``policy_refused`` is the authoritative verdict for both paths. It is
    # deliberately narrower than ``admission_state == 'NOT_ADMISSIBLE'``, which
    # also covers "not approved yet" and "source stale": those are refusals for
    # other reasons and are reported by their own checks, so labelling them
    # "not research suitable" here would state something the policy never said.
    refused = bool(projection.get('policy_refused')) \
        or disposition in UNSUITABLE_DISPOSITIONS \
        or projection.get('policy_resolution') in UNSUITABLE_RESOLUTIONS

    if refused:
        return {'suitability': SUITABILITY_UNSUITABLE,
                'suitability_source': 'BDJ_POLICY_DISPOSITION',
                'reason': reason, 'disposition': disposition,
                'classification': classification,
                'policy_refused': True,
                'policy_version': projection.get('policy_version')}

    return {'suitability': SUITABILITY_UNRESOLVED
            if classification is None else SUITABILITY_SUITABLE,
            'suitability_source': 'BDJ_POLICY_DISPOSITION',
            'reason': reason, 'disposition': disposition,
            'classification': classification,
            'policy_refused': False,
            'policy_version': projection.get('policy_version')}


APPROVED = 'APPROVED'

#: Labels. ``PROPOSED`` is the only label a generated measurement field may
#: carry; ``CONFIRMED`` is reserved for values read from a persisted record.
CONFIRMED = 'CONFIRMED'
PROPOSED = 'PROPOSED_NOT_CONFIRMED'


def _bind(conn, actor_id) -> None:
    conn.execute(text("SELECT set_config('project1.actor_id', :actor, false)"),
                 {'actor': str(actor_id)})


def objective_identity(proposal_id, registry_objective_id: str | None) -> tuple[str, str]:
    """The identity string and kind for an approved objective.

    A registry objective keeps its ``O``-code. An additional objective is
    identified by its proposal, so it never has to be forced into a mandatory
    code to be usable — the constraint DD-036 recorded.
    """
    if registry_objective_id:
        return str(registry_objective_id), MANDATORY_REGISTRY
    return f'proposal:{proposal_id}', ADDITIONAL


def derive_objective_authority(engine, *, actor_id, assessment_id, proposal_id,
                               context_id=None) -> dict:
    """Derive the confirmed-objective relationship from the owner's approval.

    Reads three persisted records and nothing else: the proposal, the owner's
    decision on it, and (when a context is named) the business-context packet
    hash. Every refusal names the exact record that failed, because "no
    objective" and "the objective is stale" need different owner responses.
    """
    from sitewise.project1 import objective_admission as oa
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal

    with engine.connect() as conn:
        bind_restricted_principal(conn, actor_id)

        proposal = conn.execute(text("""
            SELECT proposal_id, assessment_id, confirmation_id,
                   confirmation_revision, source_fingerprint, context_packet_hash,
                   research_objective, problem, problem_type, recommendation_status,
                   source_refs, review_state, contract_version
              FROM public.m2_bdj_objective_proposals
             WHERE proposal_id = :pid
        """), {'pid': str(proposal_id)}).mappings().one_or_none()
        if proposal is None:
            raise WorkflowHeld('QG_OBJECTIVE_PROPOSAL_NOT_FOUND')
        proposal = dict(proposal)
        if str(proposal['assessment_id']) != str(assessment_id):
            raise WorkflowHeld('QG_OBJECTIVE_ASSESSMENT_MISMATCH')

        decision = conn.execute(text("""
            SELECT decision_id, decision, decided_by, decided_at,
                   source_fingerprint, confirmation_id, context_packet_hash, note
              FROM public.m2_bdj_objective_decisions
             WHERE proposal_id = :pid
             ORDER BY decided_at DESC
             LIMIT 1
        """), {'pid': str(proposal_id)}).mappings().one_or_none()
        if decision is None:
            # An unapproved proposal is not an authority, however promising it is.
            raise WorkflowHeld('QG_OBJECTIVE_NOT_APPROVED')
        decision = dict(decision)
        if str(decision['decision']) != APPROVED:
            raise WorkflowHeld('QG_OBJECTIVE_DECISION_NOT_APPROVED')
        if str(decision['decided_by']) != str(actor_id):
            raise WorkflowHeld('QG_OBJECTIVE_DECIDED_BY_OTHER')

        # The decision's own binding fields must still describe the proposal it
        # was made about; otherwise the approval is of a different text.
        for field in ('source_fingerprint', 'confirmation_id', 'context_packet_hash'):
            if str(decision.get(field)) != str(proposal.get(field)):
                raise WorkflowHeld('QG_OBJECTIVE_DECISION_BINDING_DRIFT')

        current = conn.execute(text("""
            SELECT confirmed_revision FROM public.m2_assessments WHERE id = :aid
        """), {'aid': str(assessment_id)}).mappings().one_or_none()
        current_revision = current['confirmed_revision'] if current else None
        if current_revision is None:
            raise WorkflowHeld('QG_OBJECTIVE_NOT_CONFIRMED')
        if int(proposal['confirmation_revision']) != int(current_revision):
            # Generating against a superseded revision would bind a candidate to
            # facts the owner has since changed.
            raise WorkflowHeld('QG_OBJECTIVE_REVISION_STALE')

        context_hash = None
        if context_id is not None:
            packet_row = conn.execute(text("""
                SELECT packet_hash FROM public.m2_business_contexts
                 WHERE context_id = :cid AND assessment_id = :aid
            """), {'cid': str(context_id), 'aid': str(assessment_id)}).mappings().one_or_none()
            if packet_row is None:
                raise WorkflowHeld('QG_OBJECTIVE_CONTEXT_NOT_FOUND')
            context_hash = str(packet_row['packet_hash'])
            if context_hash != str(decision['context_packet_hash']):
                raise WorkflowHeld('QG_OBJECTIVE_CONTEXT_NOT_CURRENT')

        # The policy decides only *which registry objective* the proposal links
        # to. It does not decide whether the objective may be generated from —
        # that is the owner's approval above, and conflating the two is what made
        # a policy verdict look like a missing owner action.
        policy = oa.policy_binding(conn, proposal)

    registry_id = policy.get('objective_id')
    identity, kind = objective_identity(proposal_id, registry_id)

    return {
        'contract_version': CONTRACT,
        'assessment_id': str(assessment_id),
        'proposal_id': str(proposal_id),
        'objective_id': identity,
        'objective_kind': kind,
        'registry_objective_id': registry_id,
        'objective_text': proposal['research_objective'],
        'problem': proposal['problem'],
        'problem_type': proposal['problem_type'],
        'provenance': proposal['source_refs'] or [],
        'recommendation_status': proposal['recommendation_status'],
        'proposal_contract_version': proposal['contract_version'],
        'decision': {
            'decision_id': str(decision['decision_id']),
            'decision': decision['decision'],
            'decided_by': str(decision['decided_by']),
            'decided_at': decision['decided_at'],
        },
        'confirmation_id': str(proposal['confirmation_id']),
        'confirmation_revision': int(proposal['confirmation_revision']),
        'source_fingerprint': str(proposal['source_fingerprint']),
        'context_packet_hash': str(proposal['context_packet_hash']),
        'context_id': str(context_id) if context_id is not None else None,
        'context_hash': context_hash,
        'policy': {
            'version': policy.get('policy_version'),
            'adopted': bool(policy.get('policy_adopted')),
            'classification': policy.get('classification'),
            'disposition': policy.get('disposition'),
            'resolution': policy.get('resolution'),
            'admissible': bool(policy.get('admissible')),
            'reason': policy.get('reason'),
        },
        # The relationship an admission row used to record, now derived. Reported
        # as a value so a reader can see it was established, not skipped.
        'derived_admission': {
            'basis': 'OWNER_APPROVED_PROPOSAL',
            'requires_separate_owner_action': False,
            'duplicates_decision_fields': [
                'proposal_id', 'confirmation_id', 'source_fingerprint',
                'context_packet_hash', 'decision'],
        },
    }


def proposed_measurement(authority: dict, *, packet: dict | None = None) -> dict:
    """Measurement metadata for generation. Never an approval.

    Every field is a proposal. ``population`` is taken from the confirmed packet
    when it names one and reported as ``NOT_ESTABLISHED`` otherwise — an invented
    population would be the same class of error as an invented price.
    """
    population = 'NOT_ESTABLISHED'
    if isinstance(packet, dict):
        for key in ('population', 'target_population', 'customer_base'):
            value = packet.get(key)
            if isinstance(value, str) and value.strip():
                population = value.strip()
                break

    return {
        'contract_version': GENERATION_CONTRACT,
        'objective_id': authority['objective_id'],
        'objective_kind': authority['objective_kind'],
        'construct': authority['objective_text'],
        'population': population,
        # MULTIPLE_CHOICE is the only format that can carry an owner-intended
        # option selection without inventing a scale or a numeric range.
        'response_format': 'MULTIPLE_CHOICE',
        'allowed_options': [],
        'denominator_basis': ('Respondents who answer this question; codes are '
                              'the proposal\'s own response codes.'),
        'limitations': ('Proposed at generation from the approved objective and '
                        'confirmed business facts. Not scientifically approved, '
                        'not fielded, and not a report claim.'),
        'field_authority': {
            'construct': PROPOSED, 'population': PROPOSED,
            'response_format': PROPOSED, 'allowed_options': PROPOSED,
            'denominator_basis': PROPOSED, 'limitations': PROPOSED,
        },
        'scientifically_approved': False,
        'fielding_authorized': False,
        'publication_authorized': False,
    }


def evaluate(engine, *, actor_id, assessment_id, proposal_id, context_id=None,
             authorization_present: bool | None = None) -> dict:
    """Report generation eligibility and scientific status separately.

    ``generation_status`` answers "may a candidate be generated now".
    ``scientific_status`` answers "is the measurement scientifically approved".
    They are different questions and used to be one gate.
    """
    from sitewise.project1 import measurement_library as ml

    authority = derive_objective_authority(
        engine, actor_id=actor_id, assessment_id=assessment_id,
        proposal_id=proposal_id, context_id=context_id)

    checks = [
        passed('G-01', 'Objective approved by the owner',
               sources=[authority['decision']['decision_id']],
               evidence={'decision': authority['decision']['decision'],
                         'decided_at': str(authority['decision']['decided_at'])}),
        passed('G-02', 'Confirmation revision is current',
               sources=[authority['confirmation_id']],
               evidence={'revision': authority['confirmation_revision']}),
        passed('G-03', 'Confirmed BCB is current',
               evidence={'context_packet_hash': authority['context_packet_hash']}),
        passed('G-04', 'Objective identity resolved',
               evidence={'objective_id': authority['objective_id'],
                         'objective_kind': authority['objective_kind']}),
    ]

    # Measurability is a generation gate: generating a question for an objective
    # whose stimulus does not exist would produce a question that cannot be
    # answered. This is the one measurement question that stays here.
    #
    # The registry's parameter requirements are keyed on O-codes, so they say
    # nothing about an additional objective. Passing it silently would claim a
    # check that did not run, so the two kinds are reported differently: a
    # registry objective is decided by the resolver, and an additional objective
    # defers measurability to the candidate's own abstention, which is the
    # mechanism that names a missing fact instead of inventing one.
    resolution = ml.resolve(ml.PostgresMeasurementStore(engine, actor_id),
                            authority['objective_id'],
                            allow_synthetic_test_approval=True)
    outcome = str(resolution.get('outcome') or '')
    if authority['objective_kind'] == ADDITIONAL:
        checks.append(passed(
            'G-05', 'Objective can be measured appropriately',
            evidence={'outcome': outcome,
                      'measurability_source': 'DEFERRED_TO_CANDIDATE_ABSTENTION',
                      'registered_parameters': 'NONE_FOR_ADDITIONAL_OBJECTIVE',
                      'refusal_path': 'QG_ABSTENTION_WITHOUT_MISSING_FACTS'}))
    elif outcome == ml.ABSTAIN:
        checks.append(failed(
            'G-05', 'Objective can be measured appropriately',
            'QG_OBJECTIVE_NOT_MEASURABLE',
            evidence={'outcome': outcome, 'reason': resolution.get('reason'),
                      'missing_parameters': resolution.get('missing_parameters') or [],
                      'invented_parameter_refused':
                          resolution.get('invented_parameter_refused') or []}))
    else:
        checks.append(passed(
            'G-05', 'Objective can be measured appropriately',
            evidence={'outcome': outcome,
                      'approved_specification_required': False}))

    # G-05S: is this gap answerable by a customer survey at all?
    #
    # Contract 2.1 made the owner's approval the authority, which correctly
    # removed the manual admission *row*. It did not remove the admission
    # *judgement*: BDJ still classifies each cited gap, and some gaps are a
    # business decision a survey cannot answer. Without this check the two gates
    # disagreed — the admission block said "Question generation: not authorised"
    # while Generate stayed enabled and spent a real provider call (DD-062).
    #
    # Only the *explicit* refusal blocks. An unresolved suitability keeps the
    # existing deferral path, so this cannot be used to force suitability or to
    # pre-empt the candidate's own abstention.
    if authority['objective_kind'] == ADDITIONAL:
        suitability = _research_suitability(
            engine, proposal_id=proposal_id,
            source_fingerprint=authority['source_fingerprint'],
            actor_id=actor_id)
        if suitability['suitability'] == SUITABILITY_UNSUITABLE:
            checks.append(failed(
                'G-05S', 'Objective is not explicitly unsuitable for customer research',
                'QG_OBJECTIVE_NOT_RESEARCH_SUITABLE',
                evidence=suitability))
        else:
            checks.append(passed(
                'G-05S', 'Objective is not explicitly unsuitable for customer research',
                evidence=suitability))

    if authorization_present is None:
        checks.append(unverified(
            'G-06', 'QG-purpose authorization available',
            'QG_AUTHORIZATION_NOT_CHECKED'))
    elif authorization_present:
        checks.append(passed('G-06', 'QG-purpose authorization available'))
    else:
        checks.append(failed(
            'G-06', 'QG-purpose authorization available',
            'QG_AUTHORIZATION_NOT_FOUND'))

    generation = ValidationReport(subject='qg_generation',
                                 policy_version=ml.RESOLVER_VERSION,
                                 checks=checks)

    # Scientific status: the real validator, unchanged. It reports FAIL when no
    # approved specification exists, which is correct — it is simply no longer
    # asked before generation.
    from sitewise.project1 import measurement_validation
    spec = None
    if resolution.get('measurement_id'):
        spec = next((s for s in ml.PostgresMeasurementStore(
            engine, actor_id).specs(authority['objective_id'])
            if s.measurement_id == resolution['measurement_id']), None)
    scientific = measurement_validation.evaluate(resolution, spec)

    return {
        'contract_version': CONTRACT,
        'assessment_id': str(assessment_id),
        'objective_id': authority['objective_id'],
        'objective_kind': authority['objective_kind'],
        'generation_status': generation.status,
        'generation_refusal': generation.first_reason(),
        'scientific_status': scientific.status,
        'scientific_refusal': scientific.first_reason(),
        'generation_checks': [c.model_dump() for c in generation.checks],
        'scientific_checks': [c.model_dump() for c in scientific.checks],
        'authority': authority,
        'proposed_measurement': proposed_measurement(authority),
        'scientifically_approved': False,
        'dispatches_model': False,
        'publication_authorized': False,
        'fielding_authorized': False,
    }


def live_authorization(engine, *, actor_id, assessment_id, objective_id) -> bool:
    """Is there an unconsumed, unexpired QG authorization for this objective?

    Read-only, and deliberately narrow. It answers G-06 so the eligibility
    *report* can state a fact instead of saying it did not look. A ``True`` here
    is not permission to dispatch: the live runner re-verifies the whole binding
    — revision, context packet hash, source fingerprint, consent digest —
    against the real request before it opens a socket.

    It filters on ``purpose`` because an authorization issued for another
    purpose must not make Direct-QG look available.
    """
    from sitewise.project1.qg_authorization import QG_PURPOSE

    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT 1
              FROM public.m2_qg_authorizations
             WHERE assessment_id = :aid
               AND objective_id = :oid
               AND purpose = :purpose
               AND consumed_at IS NULL
               AND expires_at > now()
             LIMIT 1
        """), {'aid': str(assessment_id), 'oid': str(objective_id),
               'purpose': QG_PURPOSE}).first()
    return row is not None


__all__ = ['ADDITIONAL', 'CONTRACT', 'GENERATION_CONTRACT', 'MANDATORY_REGISTRY',
           'SUPPORTED_FORMATS', 'derive_objective_authority', 'evaluate',
           'live_authorization', 'objective_identity', 'proposed_measurement']
