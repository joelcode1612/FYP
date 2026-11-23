"""BDJ objective admission — the post-confirmation finding-authority record.

The problem this solves
-----------------------
``m2-confirmation/3`` is declaration-only. Its snapshot pins
``unresolved_candidate_findings = []`` and ``finding_decision_event_refs = {}``,
and ``pins_match()`` rejects a v3 snapshot carrying findings or a
``bdj_evaluation_id``. That is deliberate: confirming declarations must not
confirm model findings.

But ``confirm_objective(origin='BDJ')`` refuses a v3 snapshot with
``M2_UNCERTAINTY_LINK_REQUIRED`` because it requires exactly that finding link.
So the gate is not a bug in one function — it is the visible edge of a record
that the v3 contract removed and never replaced.

What is missing is not more provenance. ``source_refs`` already prove which
answer, revision and item version a proposal cites, and the validator checks
they resolve inside the packet and belong to one item. What is missing is an
*owner decision*: a record that a named person, at a named confirmation, decided
that this particular gap is worth researching. Provenance is not authority.

This module adds that record. It is wired into the objective-proposal router as
the admission step, but only as a *record of an explicit owner decision*: with no
row, the state is ``HELD``/``M2_UNCERTAINTY_LINK_REQUIRED``, and with a row the
state is ``ADMITTED``. Nothing here authorises QJ or QG, and
``admission_state`` still reports ``qj_execution``, ``qg_execution`` and
``fielding_authorized`` as false in every state.
"""
from __future__ import annotations

import hashlib
import json
import uuid

from sqlalchemy import text

from sitewise.project1.contracts import WorkflowHeld

#: Wired into ``project1_objective_proposals`` as of Phase 3B. The routes report
#: ``HELD`` until an admission row exists, so this module still cannot authorise
#: anything by being imported — only by recording an explicit owner decision.
ADOPTION_STATUS = 'WIRED_SYNTHETIC_SCOPE'

#: The single decision vocabulary, matching public.m2_finding_reviews.
WORTH_RESEARCHING = 'WORTH_RESEARCHING'

_HASH_FIELDS = ('proposal_id', 'assessment_id', 'confirmation_id',
                'confirmation_revision', 'source_fingerprint',
                'recommendation_status', 'problem_type', 'problem',
                'research_objective', 'reason', 'source_refs')

#: Dispositions under which the policy says a customer survey *can* answer the
#: gap. These are the only dispositions that may produce an admission. The
#: split is not stylistic: ``BUSINESS_DECISION_REQUIRED`` exists precisely
#: because "a customer survey cannot choose a neighbourhood"
#: (04_BDJ_CLASSIFICATION_AND_OBJECTIVES.md requires a true gap to be
#: customer-survey-suitable before an objective is admitted).
#:
#: ``NEW_OPTIONAL_CANDIDATE`` belongs here and still cannot reach QG on its own:
#: it is survey-suitable, but a novel candidate is by definition not one of the
#: six fixed objectives, so it binds ``objective_id = NULL`` and therefore stays
#: QG-ineligible until a human registers it as a fixed objective.
RESEARCH_SUITABLE = frozenset({
    'LINK_EXISTING_OBJECTIVE',
    'LINK_EXISTING_OBJECTIVE_OR_NO_ACTION',
    'OTHER_EVIDENCE_REQUIRED',
    'NEW_OPTIONAL_CANDIDATE',
})

#: Admissible, but the question may not be drafted yet. The owner's own record
#: that the gap is worth researching is still valid; QG stays blocked until the
#: clarification exists, which is what ``qg_eligible=False`` encodes.
CLARIFICATION_PENDING = frozenset({'ENTREPRENEUR_CLARIFICATION'})

#: Refused outright. ``BUSINESS_DECISION_REQUIRED`` and ``HOLD_REVIEW`` mean the
#: survey is the wrong instrument; ``NO_ACTION`` means there is no gap to admit.
NOT_RESEARCH_SUITABLE = frozenset({
    'BUSINESS_DECISION_REQUIRED', 'HOLD_REVIEW', 'NO_ACTION'})

#: Resolutions (from ``issue_resolution.resolve_candidate``) that deny a
#: candidate objective even when no coded item rule fired.
_UNSUITABLE_RESOLUTIONS = frozenset({'NOT_CUSTOMER_RESEARCH_SUITABLE'})


def proposal_hash(row: dict) -> str:
    """SHA-256 over the admission-relevant content of a proposal row.

    Canonicalised so the writer and every later verifier agree: sorted keys,
    compact separators, no NaN, UTF-8. ``source_refs`` may arrive as a JSON
    string or a list depending on the driver; both canonicalise to the same
    bytes.
    """
    refs = row.get('source_refs')
    if isinstance(refs, (str, bytes)):
        refs = json.loads(refs)
    body = {key: row.get(key) for key in _HASH_FIELDS}
    body['source_refs'] = refs if refs is not None else []
    body['confirmation_revision'] = int(body['confirmation_revision'])
    for key in ('proposal_id', 'assessment_id', 'confirmation_id'):
        body[key] = str(body[key])
    return hashlib.sha256(json.dumps(
        body, sort_keys=True, separators=(',', ':'),
        ensure_ascii=False, allow_nan=False).encode('utf-8')).hexdigest()


def _bind_actor(conn, actor_id):
    """Assume the restricted M2 principal and bind the owner GUC.

    ``set_config`` alone is not enough: the admissions table is granted to
    ``p1_m2_runtime``, so the statement must execute as that role for the
    ``owner_scope`` policy and the grant to both apply. The explicit
    ``actor_user_id`` predicate in each statement remains authoritative; RLS is
    the second layer.
    """
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused
    try:
        bind_restricted_principal(conn, actor_id)
    except ContextRefused as exc:
        raise WorkflowHeld(exc.code) from None


def _load_proposal(conn, proposal_id) -> dict | None:
    row = conn.execute(text("""
        SELECT p.proposal_id, p.assessment_id, p.confirmation_id,
               p.confirmation_revision, p.source_fingerprint,
               p.recommendation_status, p.problem_type, p.problem,
               p.research_objective, p.reason, p.source_refs,
               p.owner_user_id, p.review_state, d.decision
        FROM public.m2_bdj_objective_proposals p
        LEFT JOIN public.m2_bdj_objective_decisions d USING (proposal_id)
        WHERE p.proposal_id = :pid
    """), {'pid': str(proposal_id)}).mappings().one_or_none()
    return dict(row) if row else None


def _cited_declarations(conn, row: dict) -> list[dict]:
    """The declarations the proposal cites, read from the answer revisions.

    Read by ``answer_revision_id`` rather than by "latest answer", so the policy
    is applied to the answer the proposal actually cites. If the entrepreneur
    later revises that answer, the admission's own source fingerprint goes stale
    and this read stops mattering — which is the correct order of precedence.
    """
    import json as _json

    refs = row.get('source_refs')
    if isinstance(refs, (str, bytes)):
        refs = _json.loads(refs)
    declarations = []
    for ref in refs or []:
        cited = conn.execute(text("""
            SELECT iv.item_key, ar.answer_state, ar.value_json
            FROM public.m2_answer_revisions ar
            JOIN public.m2_item_versions iv ON iv.id = ar.item_version_id
            WHERE ar.id = :rid
        """), {'rid': str(ref.get('answer_revision_id'))}).mappings().one_or_none()
        if cited is None:
            continue
        value = cited['value_json']
        declarations.append({
            'item_key': cited['item_key'],
            'answer_state': cited['answer_state'],
            'value': value,
            'answer_revision_id': str(ref.get('answer_revision_id')),
            'item_version_id': str(ref.get('item_version_id')),
        })
    return declarations


def policy_binding(conn, row: dict, *, objective_id: str | None = None) -> dict:
    """Apply the issue-resolution policy to one proposal.

    Returns the classification, disposition and resolution that decided the
    outcome, plus the fixed objective the admission may bind to (``None`` when
    nothing binds). The caller decides whether to write; this function only
    reports, so the same evaluation can be reused by the read path.

    Order of precedence for the objective binding:

    1. an explicit ``objective_id`` from the caller, but only if the policy does
       not contradict it;
    2. a coded item rule's ``link_objective``;
    3. the fixed objective the cited declaration's own topic codes name
       (``M2V2-09``'s registered option codes);
    4. the construct the proposal text actually matches.

    A contradiction is a refusal, never a silent preference: two disagreeing
    sources about *which* objective is being admitted is exactly the case a
    human must settle.
    """
    from sitewise.project1 import issue_resolution as ir

    declarations = _cited_declarations(conn, row)
    issues = ir.classify(declarations)

    disposition = issues[0]['disposition'] if issues else None
    classification = issues[0]['classification'] if issues else None
    rule_objective = next((i['link_objective'] for i in issues
                           if i.get('link_objective')), None)
    topic_objective = None
    for declaration in declarations:
        if declaration.get('item_key') != 'M2V2-09':
            continue
        named = ir.topic_objectives(declaration)
        if len(named) == 1:
            topic_objective = named[0]
        elif named:
            # Two named topics are ambiguous on their own; the proposal text
            # below is what disambiguates, so nothing is chosen here.
            topic_objective = None

    text_resolution = ir.resolve_candidate(row.get('research_objective') or '')
    text_objective = text_resolution.get('covered_by')

    resolution = (text_resolution['resolution'] if not issues
                  else ir.COVERED_BY_FIXED_OBJECTIVE if rule_objective
                  else None)

    derived = [value for value in (rule_objective, topic_objective,
                                   text_objective) if value]
    unique = sorted(set(derived))

    if objective_id is not None:
        if unique and objective_id not in unique:
            return {
                'admissible': False,
                'reason': 'ADMISSION_OBJECTIVE_CONFLICT',
                'policy_version': ir.POLICY_VERSION,
                'policy_adopted': ir.POLICY_ADOPTED,
                'classification': classification,
                'disposition': disposition,
                'resolution': resolution,
                'objective_id': None,
                'candidate_objectives': unique,
                'text_resolution': text_resolution,
                'cited_items': [d['item_key'] for d in declarations],
            }
        bound = objective_id
    elif len(unique) > 1:
        # Several objectives claim the proposal. Choosing one would be an
        # inference, so it is held rather than guessed.
        return {
            'admissible': False,
            'reason': 'ADMISSION_OBJECTIVE_AMBIGUOUS',
            'policy_version': ir.POLICY_VERSION,
            'policy_adopted': ir.POLICY_ADOPTED,
            'classification': classification,
            'disposition': disposition,
            'resolution': resolution,
            'objective_id': None,
            'candidate_objectives': unique,
            'text_resolution': text_resolution,
            'cited_items': [d['item_key'] for d in declarations],
        }
    else:
        bound = unique[0] if unique else None

    base = {
        'policy_version': ir.POLICY_VERSION,
        'policy_adopted': ir.POLICY_ADOPTED,
        'classification': classification,
        'disposition': disposition,
        'resolution': resolution,
        'objective_id': bound,
        'candidate_objectives': unique,
        'text_resolution': text_resolution,
        'cited_items': [d['item_key'] for d in declarations],
    }

    if disposition in NOT_RESEARCH_SUITABLE:
        return {**base, 'admissible': False,
                'reason': f'ADMISSION_NOT_RESEARCH_SUITABLE_{disposition}'}

    if disposition in CLARIFICATION_PENDING:
        # Admissible as an owner decision, never QG-eligible yet.
        return {**base, 'admissible': True, 'qg_eligible': False,
                'reason': 'ADMISSION_ALLOWED_CLARIFICATION_PENDING'}

    if disposition in RESEARCH_SUITABLE:
        return {**base, 'admissible': True,
                'qg_eligible': bound is not None,
                'reason': 'ADMISSION_POLICY_SUITABLE'}

    # No coded item rule fired. The text decides.
    if text_resolution['resolution'] in _UNSUITABLE_RESOLUTIONS:
        return {**base, 'admissible': False,
                'reason': ('ADMISSION_NOT_RESEARCH_SUITABLE_'
                           + text_resolution.get('reason', 'NO_ANCHOR'))}

    return {**base, 'admissible': True,
            'qg_eligible': bound is not None,
            'reason': 'ADMISSION_POLICY_SUITABLE'}


def record_admission(engine, proposal_id, *, actor_id, request_id,
                     source_fingerprint=None, objective_id=None) -> dict:
    """Append one owner admission for an APPROVED, source-current proposal.

    Refusals are deliberate and each has its own code so a caller can tell
    "you have not approved this yet" from "your approval went stale" from
    "this is not your proposal" from "the policy says a survey cannot answer
    this".

    The policy check is not advisory. ``04_BDJ_CLASSIFICATION_AND_OBJECTIVES.md``
    requires that a true gap be customer-survey-suitable before an *objective*
    is admitted, so a proposal whose disposition is
    ``BUSINESS_DECISION_REQUIRED`` is refused here rather than admitted and
    quietly ignored downstream.
    """
    if actor_id is None:
        raise WorkflowHeld('PROPOSAL_OWNER_REQUIRED')
    with engine.begin() as conn:
        _bind_actor(conn, actor_id)
        row = _load_proposal(conn, proposal_id)
        if row is None:
            # RLS makes a foreign owner's row indistinguishable from a missing
            # one. That is the intended behaviour: no existence oracle.
            raise WorkflowHeld('PROPOSAL_NOT_FOUND')
        if row['decision'] != 'APPROVED':
            raise WorkflowHeld('PROPOSAL_NOT_APPROVED')
        if (source_fingerprint is not None
                and row['source_fingerprint'] != source_fingerprint):
            raise WorkflowHeld('PROPOSAL_SOURCE_STALE')

        policy = policy_binding(conn, row, objective_id=objective_id)
        if not policy['admissible']:
            raise WorkflowHeld(policy['reason'])

        existing = conn.execute(text("""
            SELECT admission_id, decision, proposal_hash, created_at,
                   objective_id, policy_disposition
            FROM public.m2_bdj_objective_admissions
            WHERE proposal_id = :pid
        """), {'pid': str(proposal_id)}).mappings().one_or_none()
        if existing is not None:
            # Idempotent by proposal: a repeat is reported, never duplicated.
            # A repeat that asks for a *different* objective is a conflict, not
            # an update — the row is append-only and the owner's earlier decision
            # stands.
            if (objective_id is not None
                    and existing['objective_id'] not in (None, objective_id)):
                raise WorkflowHeld('ADMISSION_ALREADY_BOUND_TO_OTHER_OBJECTIVE')
            return {'admission_id': str(existing['admission_id']),
                    'decision': existing['decision'], 'created': False,
                    'proposal_hash': existing['proposal_hash'],
                    'created_at': existing['created_at'],
                    'objective_id': existing['objective_id'],
                    'policy_disposition': existing['policy_disposition'],
                    'qg_eligible': (existing['objective_id'] is not None
                                    and existing['policy_disposition']
                                    not in CLARIFICATION_PENDING)}

        admission_id = uuid.uuid4()
        digest = proposal_hash(row)
        conn.execute(text("""
            INSERT INTO public.m2_bdj_objective_admissions (
                admission_id, proposal_id, assessment_id, confirmation_id,
                confirmation_revision, source_fingerprint, context_packet_hash,
                actor_user_id, decision, proposal_hash, request_id,
                objective_id, policy_version, policy_classification,
                policy_disposition, policy_resolution)
            VALUES (
                :aid, :pid, :assessment, :confirmation, :revision, :fp, :ctx,
                :actor, :decision, :hash, :request,
                :objective, :policy_version, :classification, :disposition,
                :resolution)
        """), {'aid': str(admission_id), 'pid': str(proposal_id),
               'assessment': str(row['assessment_id']),
               'confirmation': str(row['confirmation_id']),
               'revision': row['confirmation_revision'],
               'fp': row['source_fingerprint'],
               'ctx': _context_hash(conn, row),
               'actor': str(actor_id), 'decision': WORTH_RESEARCHING,
               'hash': digest, 'request': str(request_id),
               'objective': policy['objective_id'],
               'policy_version': policy['policy_version'],
               'classification': policy['classification'],
               'disposition': policy['disposition'],
               'resolution': policy['resolution']})
        return {'admission_id': str(admission_id), 'decision': WORTH_RESEARCHING,
                'created': True, 'proposal_hash': digest, 'created_at': None,
                'objective_id': policy['objective_id'],
                'policy_disposition': policy['disposition'],
                'policy_reason': policy['reason'],
                'qg_eligible': policy['qg_eligible']}


def _context_hash(conn, row) -> str:
    """The context packet hash the proposal was produced against."""
    value = conn.execute(text("""
        SELECT context_packet_hash FROM public.m2_bdj_objective_proposals
        WHERE proposal_id = :pid
    """), {'pid': str(row['proposal_id'])}).scalar_one()
    return value


def admission_state(engine, proposal_id, *, source_fingerprint, actor_id) -> dict:
    """Compose the admission state without ever inventing an authorisation.

    Order matters: approval is checked before the admission record, because an
    admission for a proposal that is not approved is meaningless rather than
    merely late. The policy check comes after approval too — an unapproved
    proposal has no admission question yet, so reporting "the policy would
    refuse this" first would bury the actionable fact.
    """
    if actor_id is None:
        raise WorkflowHeld('PROPOSAL_OWNER_REQUIRED')
    with engine.begin() as conn:
        _bind_actor(conn, actor_id)
        row = _load_proposal(conn, proposal_id)
        if row is None:
            return _state('NOT_ADMISSIBLE', 'PROPOSAL_NOT_FOUND')
        if row['source_fingerprint'] != source_fingerprint:
            return _state('NOT_ADMISSIBLE', 'PROPOSAL_SOURCE_STALE')
        if row['decision'] != 'APPROVED':
            return _state('NOT_ADMISSIBLE', 'PROPOSAL_NOT_APPROVED')

        policy = policy_binding(conn, row)
        record = conn.execute(text("""
            SELECT admission_id, decision, proposal_hash, created_at,
                   objective_id, policy_disposition, policy_resolution
            FROM public.m2_bdj_objective_admissions
            WHERE proposal_id = :pid
        """), {'pid': str(proposal_id)}).mappings().one_or_none()

        if record is None:
            if not policy['admissible']:
                # The owner has approved, but the policy says a customer survey
                # cannot answer this gap. Reporting HELD here would imply that
                # an admission decision is all that is missing; it is not.
                return {**_state('NOT_ADMISSIBLE', policy['reason']),
                        'policy_disposition': policy['disposition'],
                        'policy_classification': policy['classification'],
                        'policy_version': policy['policy_version'],
                        'policy_adopted': policy['policy_adopted'],
                        'cited_items': policy['cited_items'],
                        'pending_requirement': (
                            'The candidate policy classifies this gap as '
                            f"{policy['disposition']}; a customer survey is not "
                            'the instrument that can answer it, so no objective '
                            'admission is available. This is a policy result, '
                            'not a missing owner action.')}
            return {**_state('HELD', 'M2_UNCERTAINTY_LINK_REQUIRED'),
                    'policy_disposition': policy['disposition'],
                    'policy_classification': policy['classification'],
                    'policy_version': policy['policy_version'],
                    'policy_adopted': policy['policy_adopted'],
                    'candidate_objectives': policy['candidate_objectives'],
                    'pending_requirement': (
                        'The owner has approved this objective but has not '
                        'recorded that the cited gap is worth researching. '
                        'An admission decision is required before an '
                        'uncertainty link can be created.')}

        # A stored hash that no longer matches means the proposal changed under
        # the admission. Treat it as stale rather than trusting the decision.
        if record['proposal_hash'] != proposal_hash(row):
            return _state('NOT_ADMISSIBLE', 'ADMISSION_PROPOSAL_CHANGED')

        # QG eligibility is not the same as admission. An admission that binds no
        # objective, or one whose policy still requires clarification, is a valid
        # owner record and an unusable QG input.
        qg_eligible = (record['objective_id'] is not None
                       and record['policy_disposition'] not in CLARIFICATION_PENDING)
        return {**_state('ADMITTED', 'ADMISSION_RECORDED'),
                'admission_id': str(record['admission_id']),
                'admitted_at': record['created_at'],
                'proposal_hash': record['proposal_hash'],
                'objective_id': record['objective_id'],
                'policy_disposition': record['policy_disposition'],
                'policy_resolution': record['policy_resolution'],
                'qg_eligible': qg_eligible,
                'qg_blocker': None if qg_eligible else (
                    'ADMISSION_BINDS_NO_FIXED_OBJECTIVE'
                    if record['objective_id'] is None
                    else 'CLARIFICATION_PENDING')}


def _state(state: str, reason: str) -> dict:
    """Every state carries the same authority block: all false, always.

    ``qg_eligible`` is a *precondition*, not a permission: it says only that the
    admission names a fixed objective and the policy does not still require a
    clarification. A QG candidate additionally needs an approved measurement and
    an unconsumed, exact-bound authorization, and neither is implied here.
    """
    return {
        'admission_state': state,
        'admission_reason': reason,
        'pending_requirement': None,
        'uncertainty_link': None,
        'objective_id': None,
        'policy_disposition': None,
        'policy_classification': None,
        'policy_version': None,
        'policy_adopted': False,
        'qg_eligible': False,
        'qg_blocker': 'ADMISSION_NOT_GRANTED',
        'qj_execution': False,
        'qg_execution': False,
        'fielding_authorized': False,
    }
