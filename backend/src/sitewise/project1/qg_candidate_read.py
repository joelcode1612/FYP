"""Stage 4 readback for a persisted Direct-QG candidate.

Why this module exists
----------------------
``public.m2_qg_candidates`` is the authoritative record of a generated
Direct-QG question, but Stage 4 could not see it. The review surface reads
``public.m2_review_question_versions``, whose ``objective_id`` is a ``uuid``
referencing a confirmed uncertainty, while a Direct-QG candidate carries
``objective_id = 'O1'`` (a ``varchar`` registry code). Two different identity
spaces, no bridge.

The bridge chosen here is the one the candidate already has:
``objective_admission_id``. Joining candidate -> admission yields the owning
assessment, the admitted objective (a fixed O1..O6 code *or* the proposal that
carries an optional objective), the exact admission record, the confirmation and
packet hash, and the policy identity. That covers both cases the directive names
without inventing a second identity system and without changing a column type.

What this module refuses to do
------------------------------
* It does not copy the question into ``m2_review_question_versions``. One
  generated question has one authoritative row; a second mutable copy would make
  "which wording did the reviewer judge?" unanswerable.
* It does not approve anything. ``record_review`` stores an opinion; the
  candidate stays ``fielding_authorized = false``.
* It does not read another owner's rows. Ownership is an explicit predicate on
  ``m2_assessments.owner_user_id``, not only an RLS side effect, so a missing
  actor GUC yields zero rows instead of a silent cross-owner read.
"""
from __future__ import annotations

import json

from sqlalchemy import text

from sitewise.project1.contracts import WorkflowHeld

#: Review decisions accepted by the existing Stage 4 vocabulary. Reusing it
#: keeps one word for one act across both candidate surfaces.
REVIEW_DECISIONS = frozenset({'APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION'})

#: The contract this module's envelopes carry. Bumped when a field changes
#: meaning, so a client can refuse a shape it does not understand.
READ_CONTRACT = 'sitewise-qg-candidate/1'


def _bind(conn, actor_id):
    """Bind the owner GUC so the RLS policies on every joined table apply.

    The explicit owner predicate in each statement remains authoritative; this is
    the second layer, and it is what makes a foreign owner's row indistinguishable
    from a missing one.

    ``is_local=true`` (DD-R20-1). The binding must not outlive the transaction
    that made it: these helpers run on pooled connections, and a session-scoped
    ``set_config`` inside a transaction that COMMITS stays on the connection
    after it is returned to the pool, so the next checkout would inherit the
    previous actor. Measured on ``project1_pg18_migrated_tests``: with
    ``is_local=false`` the next checkout on the same backend pid read the
    previous actor; with ``is_local=true`` it read unset. The read-only helpers
    below hid the defect because returning a connection to the pool rolls back,
    which reverts a non-local ``SET`` — only the ``engine.begin()`` writers
    commit, and only they leaked.
    """
    if actor_id is None:
        raise WorkflowHeld('PROPOSAL_OWNER_REQUIRED')
    conn.execute(text("SELECT set_config('project1.actor_id', :actor, true)"),
                 {'actor': str(actor_id)})


def _body(raw) -> dict:
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, (str, bytes)):
        try:
            value = json.loads(raw)
        except (ValueError, TypeError):
            return {}
        return value if isinstance(value, dict) else {}
    return {}


def _options(body: dict) -> list[dict]:
    """The option list, preferring the measurement's ordered set.

    ``fixed_measurement.options`` carries an explicit ``order`` and stable
    ``code``, so it is preferred over the parallel ``response_codes`` /
    ``response_options`` arrays. Falling back to the arrays keeps a candidate
    readable even if the measurement block is absent, and the fallback is
    labelled so the reader knows the order came from array position.
    """
    measurement = body.get('fixed_measurement') or {}
    raw = measurement.get('options') if isinstance(measurement, dict) else None
    if isinstance(raw, list) and raw:
        out = []
        for index, item in enumerate(raw):
            if not isinstance(item, dict):
                continue
            out.append({
                'code': str(item.get('code') or ''),
                'label': str(item.get('label') or ''),
                'order': int(item.get('order', index)),
                'lower': item.get('lower'),
                'upper': item.get('upper'),
                'lower_inclusive': item.get('lower_inclusive'),
                'upper_inclusive': item.get('upper_inclusive'),
                'order_source': 'MEASUREMENT',
            })
        return sorted(out, key=lambda row: row['order'])

    codes = body.get('response_codes') or []
    labels = body.get('response_options') or []
    if not isinstance(codes, list) or not isinstance(labels, list):
        return []
    out = []
    for index, code in enumerate(codes):
        out.append({
            'code': str(code),
            'label': str(labels[index]) if index < len(labels) else '',
            'order': index,
            'lower': None, 'upper': None,
            'lower_inclusive': None, 'upper_inclusive': None,
            'order_source': 'ARRAY_POSITION',
        })
    return out


def _selection_limits(body: dict) -> dict:
    """The candidate's own selection constraints, read from its measurement.

    These bound how many options an owner's intention may hold. They are read
    from the persisted row that is about to be written against, never from the
    request, so an intention can never widen the question's own constraints.
    """
    measurement = body.get('fixed_measurement')
    if not isinstance(measurement, dict):
        return {'min_selections': None, 'max_selections': None,
                'exclusive_codes': ()}
    return {
        'min_selections': measurement.get('min_selections'),
        'max_selections': measurement.get('max_selections'),
        'exclusive_codes': tuple(measurement.get('exclusive_codes') or ()),
    }


def project_candidate(row: dict) -> dict:
    """One candidate row as the Stage 4 envelope.

    Everything here came from a persisted column or from ``candidate_json``.
    Nothing is defaulted into a plausible value: an absent field stays ``None``
    and an absent option list stays empty.
    """
    body = _body(row.get('candidate_json'))
    review_decision = row.get('review_decision')
    limits = _selection_limits(body)
    return {
        'candidate_id': str(row['candidate_id']),
        'assessment_id': str(row['assessment_id']),
        'confirmation_id': str(row['confirmation_id']) if row.get('confirmation_id') else None,
        'assessment_revision': row.get('assessment_revision'),

        # -- objective identity -------------------------------------------------
        'objective_id': row.get('objective_id'),
        'objective_admission_id': (str(row['objective_admission_id'])
                                   if row.get('objective_admission_id') else None),
        'proposal_id': str(row['proposal_id']) if row.get('proposal_id') else None,
        'policy_disposition': row.get('policy_disposition'),
        'policy_classification': row.get('policy_classification'),
        'policy_version': row.get('policy_version'),
        # A contract-2.1 candidate carries no admission row, so `proposal_id`
        # is null and the objective identity is the derived
        # `proposal:<proposal_id>` written by `derive_objective_authority`.
        # Reading only the column classified every such candidate as
        # UNCLASSIFIED even though its objective came from a proposal.
        'objective_classification': ('FIXED_O1_O6'
                                     if row.get('objective_id') in
                                     ('O1', 'O2', 'O3', 'O4', 'O5', 'O6')
                                     else ('OPTIONAL_BDJ'
                                           if (row.get('proposal_id') or
                                               str(row.get('objective_id') or '')
                                               .startswith('proposal:'))
                                           else 'UNCLASSIFIED')),

        # -- measurement --------------------------------------------------------
        'measurement_id': row.get('measurement_id'),
        'measurement_version': row.get('measurement_version'),

        # -- the question -------------------------------------------------------
        'question': body.get('question'),
        'response_format': row.get('response_format'),
        'options': _options(body),
        'routing': body.get('routing') or {},
        # How many options the question admits, and which of them cannot be
        # combined with any other. The server enforces these on every write, so
        # they are not a hint: they are the constraint the owner's intention is
        # validated against, published here so the control can state the rule
        # rather than let the owner discover it from a refusal.
        'selection': {
            'min': limits['min_selections'],
            'max': limits['max_selections'],
            'exclusive_codes': list(limits['exclusive_codes']),
        },
        'reference_period': body.get('reference_period'),
        'limitations': body.get('limitations'),
        'justification': body.get('justification'),

        # -- validation ---------------------------------------------------------
        'candidate_state': row.get('candidate_state'),
        'structural_status': row.get('structural_status'),
        'semantic_status': row.get('semantic_status'),
        'provenance_status': row.get('provenance_status'),
        'contract_version': row.get('contract_version'),
        'adapter_version': row.get('adapter_version'),

        # -- execution provenance ----------------------------------------------
        'execution_mode': row.get('execution_mode'),
        'model_provider': row.get('model_provider'),
        'model_requested': row.get('model_requested'),
        'model_returned': row.get('model_returned'),
        'run_id': str(row['run_id']) if row.get('run_id') else None,
        'attempt_no': row.get('attempt_no'),
        'prompt_version': row.get('prompt_version'),
        'prompt_sha256': row.get('prompt_sha256'),
        'qg_authorization_id': (str(row['qg_authorization_id'])
                                if row.get('qg_authorization_id') else None),
        # A candidate with no run row provably never reached a provider: the
        # runner reserves the attempt before dispatch.
        'dispatched': row.get('run_id') is not None,

        # -- review -------------------------------------------------------------
        'review': {
            'decision': review_decision,
            'rationale': row.get('review_rationale'),
            'recorded_at': (row['review_recorded_at'].isoformat()
                            if row.get('review_recorded_at') else None),
            # The set is authoritative. The singular column is a compatibility
            # projection of it and is NULL for a multi-select intention, so
            # reading the singular first would report "no intention" for exactly
            # the questions that have several.
            'expected_option_codes': list(row.get('expected_option_codes') or []),
            'expected_option_code': row.get('expected_option_code'),
            'reviewed': review_decision is not None,
        },

        # -- authority, always false -------------------------------------------
        'fielding_authorized': False,
        'publication_authorized': False,
        'scientifically_accepted': False,
        'created_at': row['created_at'].isoformat() if row.get('created_at') else None,
    }


_SELECT = """
    SELECT c.candidate_id, c.assessment_id, c.confirmation_id, c.assessment_revision,
           c.objective_id, c.objective_admission_id, c.measurement_id,
           c.measurement_version, c.qg_authorization_id, c.run_id, c.attempt_no,
           c.prompt_version, c.prompt_sha256, c.execution_mode, c.model_provider,
           c.model_requested, c.model_returned, c.response_format, c.candidate_state,
           c.structural_status, c.semantic_status, c.provenance_status,
           c.contract_version, c.adapter_version, c.candidate_json, c.created_at,
           a.proposal_id, a.policy_disposition, a.policy_classification, a.policy_version,
           a.confirmation_revision AS admission_confirmation_revision,
           r.decision AS review_decision, r.rationale AS review_rationale,
           r.recorded_at AS review_recorded_at, r.expected_option_code,
           r.expected_option_codes
      FROM public.m2_qg_candidates c
      JOIN public.m2_assessments m ON m.id = c.assessment_id
      LEFT JOIN public.m2_bdj_objective_admissions a
             ON a.admission_id = c.objective_admission_id
      LEFT JOIN public.m2_qg_candidate_reviews r
             ON r.candidate_id = c.candidate_id AND r.reviewer_id = :actor
     WHERE c.assessment_id = :assessment AND m.owner_user_id = :actor
"""


def list_candidates(engine, *, actor_id, assessment_id, limit: int = 50) -> dict:
    """Every candidate for one assessment, newest first. Read-only."""
    with engine.connect() as conn:
        _bind(conn, actor_id)
        rows = conn.execute(text(_SELECT + ' ORDER BY c.created_at DESC LIMIT :limit'),
                            {'assessment': str(assessment_id),
                             'actor': str(actor_id),
                             'limit': max(1, min(int(limit), 200))}).mappings().all()
    return {
        'contract_version': READ_CONTRACT,
        'assessment_id': str(assessment_id),
        'candidate_count': len(rows),
        'candidates': [project_candidate(dict(row)) for row in rows],
    }


def list_candidates_in_session(session, *, actor_id, assessment_id,
                               limit: int = 200) -> dict:
    """Same read as :func:`list_candidates`, on an existing owner-bound session.

    Exists so composition reads candidates inside the transaction that already
    verified the assessment, revision and confirmation. A second connection
    could observe a different revision, which would let the composed document mix
    a verified header with candidate rows from another state.

    The actor GUC is set ``is_local`` so it is scoped to this transaction and
    cannot leak to a later statement on the pooled connection.
    """
    if actor_id is None:
        raise WorkflowHeld('PROPOSAL_OWNER_REQUIRED')
    session.execute(text("SELECT set_config('project1.actor_id', :actor, true)"),
                    {'actor': str(actor_id)})
    rows = session.execute(
        text(_SELECT + ' ORDER BY c.created_at DESC LIMIT :limit'),
        {'assessment': str(assessment_id),
         'actor': str(actor_id),
         'limit': max(1, min(int(limit), 200))}).mappings().all()
    return {
        'contract_version': READ_CONTRACT,
        'assessment_id': str(assessment_id),
        'candidate_count': len(rows),
        'candidates': [project_candidate(dict(row)) for row in rows],
    }


def read_candidate(engine, *, actor_id, assessment_id, candidate_id) -> dict:
    """One candidate. A foreign owner's id is indistinguishable from a missing one."""
    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text(_SELECT + ' AND c.candidate_id = :cid'),
                           {'assessment': str(assessment_id),
                            'actor': str(actor_id),
                            'cid': str(candidate_id)}).mappings().one_or_none()
    if row is None:
        raise WorkflowHeld('QG_CANDIDATE_NOT_FOUND')
    return {'contract_version': READ_CONTRACT, 'candidate': project_candidate(dict(row))}


def _current_revision(conn, assessment_id) -> int:
    row = conn.execute(text("""
        SELECT revision FROM public.m2_assessments WHERE id = :id
    """), {'id': str(assessment_id)}).mappings().one_or_none()
    return int(row['revision']) if row else -1


def record_review(engine, *, actor_id, assessment_id, candidate_id, decision,
                  rationale: str = '', expected_revision: int | None = None,
                  expected_option_codes=None) -> dict:
    """Store the owner's judgement about one candidate, with their intention.

    Append-only in spirit: one row per (candidate, reviewer), updated in place so
    a reviewer can change their mind without creating a second competing record.
    A stale ``expected_revision`` is refused rather than silently applied to a
    candidate raised against a different assessment revision.

    The decision and the intention are written by **one** statement. They are one
    act: an approval whose intention landed in a second write could fail between
    the two and leave an approved question that no comparison can ever use, which
    is precisely the state §10 forbids.

    ``REQUEST_REVISION`` is refused. It was removed from the application because
    a revision is a new authorised attempt, and the single-use rules already
    govern whether one may happen — offering a decision that looks like a retry
    but cannot produce one was a dead end in the interface.
    """
    if decision not in REVIEW_DECISIONS:
        raise WorkflowHeld('QG_CANDIDATE_REVIEW_DECISION_INVALID')
    if decision == 'REQUEST_REVISION':
        raise WorkflowHeld('QG_CANDIDATE_REVIEW_REVISION_RETIRED')
    rationale = (rationale or '').strip()
    if len(rationale) > 1000:
        raise WorkflowHeld('QG_CANDIDATE_REVIEW_RATIONALE_TOO_LONG')

    from sitewise.services.owner_intended_option import (
        OwnerIntendedOptionError, validate_selection_set)

    with engine.begin() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT c.candidate_id, c.assessment_revision, c.owner_user_id,
                   c.response_format, c.candidate_json
              FROM public.m2_qg_candidates c
              JOIN public.m2_assessments m ON m.id = c.assessment_id
             WHERE c.candidate_id = :cid AND c.assessment_id = :assessment
               AND m.owner_user_id = :actor
        """), {'cid': str(candidate_id), 'assessment': str(assessment_id),
               'actor': str(actor_id)}).mappings().one_or_none()
        if row is None:
            raise WorkflowHeld('QG_CANDIDATE_NOT_FOUND')
        current = _current_revision(conn, assessment_id)
        if expected_revision is not None and int(expected_revision) != current:
            raise WorkflowHeld('QG_CANDIDATE_REVISION_STALE')
        if int(row['assessment_revision']) != current:
            # The candidate was raised against a revision that has since moved.
            raise WorkflowHeld('QG_CANDIDATE_REVISION_STALE')

        body = _body(row['candidate_json'])
        codes = [option['code'] for option in _options(body)]
        limits = _selection_limits(body)

        # An approval must carry a valid intention; a rejection need not. The
        # same validator runs either way, so a rejection that *does* carry codes
        # cannot store an invalid set.
        approving = decision == 'APPROVE_FOR_REVIEW'
        try:
            verdict = validate_selection_set(
                response_format=row['response_format'] or body.get('response_format'),
                option_codes=codes,
                selected=expected_option_codes,
                required=approving,
                **limits,
            )
        except OwnerIntendedOptionError as exc:
            raise WorkflowHeld(exc.code) from None

        chosen = verdict['selected']
        # The singular column is kept in step only when the intention is a
        # single code. For a multi-select question it stays NULL rather than
        # holding an arbitrary first element, which is what the
        # ``expected_codes_single`` constraint requires.
        singular = chosen[0] if len(chosen) == 1 else None

        conn.execute(text("""
            INSERT INTO public.m2_qg_candidate_reviews
                (candidate_id, owner_user_id, reviewer_id, decision, rationale,
                 expected_option_code, expected_option_codes, context_hash)
            VALUES (:cid, :owner, :actor, :decision, :rationale,
                    :singular, :codes, :context_hash)
            ON CONFLICT (candidate_id, reviewer_id) DO UPDATE
               SET decision = excluded.decision,
                   rationale = excluded.rationale,
                   expected_option_code = excluded.expected_option_code,
                   expected_option_codes = excluded.expected_option_codes,
                   context_hash = excluded.context_hash,
                   recorded_at = now()
        """), {'cid': str(candidate_id), 'owner': str(row['owner_user_id']),
               'actor': str(actor_id), 'decision': decision, 'rationale': rationale,
               'singular': singular,
               'codes': chosen or None,
               'context_hash': _candidate_context_hash(conn, candidate_id)})
    return {'contract_version': READ_CONTRACT, 'candidate_id': str(candidate_id),
            'decision': decision, 'rationale': rationale,
            'expected_option_codes': chosen,
            'owner_only': True, 'respondent_visible': False,
            'is_customer_evidence': False,
            'fielding_authorized': False, 'scientifically_accepted': False}


def _candidate_context_hash(conn, candidate_id) -> str | None:
    """The candidate's own context hash, so the review row pins its source.

    Read from the candidate rather than accepted from the caller: a hash the
    caller supplies describes the request, not the record being judged.
    """
    value = conn.execute(text("""
        SELECT context_packet_hash FROM public.m2_qg_candidates
         WHERE candidate_id = :cid
    """), {'cid': str(candidate_id)}).scalar_one_or_none()
    text_value = None if value is None else str(value)
    if text_value is None or not __import__('re').fullmatch(r'[0-9a-f]{64}', text_value):
        # The column is CHECK-constrained to that format, so a non-conforming
        # value would mean the row is not what this schema says it is. Recording
        # NULL is honest; inventing a hash is not.
        return None
    return text_value


def set_expected_answer(engine, *, actor_id, assessment_id, candidate_id,
                        option_code: str | None = None,
                        option_codes=None,
                        expected_revision: int | None = None) -> dict:
    """Record the entrepreneur's *expected* answer.

    Not a respondent answer. It is never written to a customer-response table and
    never read by a CQ or EE-01 calculation. A ``None`` code clears it **only
    while the question is not approved**: after approval the intention is part of
    the approved record and clearing it is refused with
    ``QG_OWNER_INTENTION_LOCKED_BY_APPROVAL``. The approval is never withdrawn on
    the owner's behalf — revoking an approval is a new decision, not a side effect
    of clearing an expectation.

    Three predicates are enforced, all against the row that is about to be
    written -- never against a copy:

    1. the candidate belongs to this assessment and this owner;
    2. the candidate was raised against the assessment's **current** revision,
       so a selection cannot attach to a superseded question version;
    3. the code exists in that candidate's own option set, and the response
       format can represent a selection at all.

    Predicate 2 was missing before 2026-11-24: ``record_review`` refused a stale
    candidate but this function did not, so a superseded candidate could still
    receive an intended answer.

    One row carries both facts, so the write touches only ``expected_option_code``
    and leaves ``recorded_at`` alone. It used to set ``recorded_at = now()`` on
    conflict, which restamped the *decision's* timestamp every time the owner
    changed their expectation — the Stage 4 card printed that column under
    "Recorded review", so a decision made on Monday was shown as recorded on
    Friday because an expectation had been edited. A row created by this function
    alone still takes the column default, which is the time of creation, and no
    decision is displayed against it because ``decision`` stays null.
    """
    from sitewise.services.owner_intended_option import (
        CODE_LOCKED_BY_APPROVAL, OwnerIntendedOptionError, policy_for,
        validate_selection_set)

    # ``option_code`` is the single-value spelling existing callers use;
    # ``option_codes`` is the set. One normalisation point, so the two can never
    # disagree about what was selected.
    if option_codes is None:
        selected = None if option_code is None else [option_code]
    else:
        selected = [str(code) for code in option_codes]

    with engine.begin() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT c.candidate_id, c.assessment_revision, c.owner_user_id,
                   c.response_format, c.candidate_json,
                   r.decision AS current_decision
              FROM public.m2_qg_candidates c
              JOIN public.m2_assessments m ON m.id = c.assessment_id
              LEFT JOIN public.m2_qg_candidate_reviews r
                     ON r.candidate_id = c.candidate_id
                    AND r.reviewer_id = :actor
             WHERE c.candidate_id = :cid AND c.assessment_id = :assessment
               AND m.owner_user_id = :actor
        """), {'cid': str(candidate_id), 'assessment': str(assessment_id),
               'actor': str(actor_id)}).mappings().one_or_none()
        if row is None:
            raise WorkflowHeld('QG_CANDIDATE_NOT_FOUND')
        current = _current_revision(conn, assessment_id)
        if expected_revision is not None and int(expected_revision) != current:
            raise WorkflowHeld('QG_CANDIDATE_REVISION_STALE')
        if int(row['assessment_revision']) != current:
            # The candidate itself is stale, whatever the caller asked for.
            raise WorkflowHeld('QG_CANDIDATE_REVISION_STALE')

        body = _body(row['candidate_json'])
        codes = [option['code'] for option in _options(body)]
        limits = _selection_limits(body)
        try:
            verdict = validate_selection_set(
                response_format=row['response_format'] or body.get('response_format'),
                option_codes=codes,
                selected=selected,
                # Clearing is allowed here: this is the owner changing their
                # mind *before* deciding. It is ``record_review`` that refuses an
                # approval with no intention.
                required=False,
                **limits,
            )
        except OwnerIntendedOptionError as exc:
            raise WorkflowHeld(exc.code) from None

        chosen = verdict['selected']

        # DD-171, owner decision 2026-11-26: clearing the intended option is
        # refused while the question remains approved, and the approval is not
        # withdrawn on the owner's behalf. Before approval the owner may select
        # or clear freely, which is what ``required=False`` above allows.
        #
        # This is checked here as well as by the review-table trigger so the
        # caller gets a named code instead of a raw integrity error. The trigger
        # remains the guarantee about the data; this is the guarantee about the
        # response. Neither path changes ``decision``: an approval that the owner
        # wants to revoke must be revoked by recording a new decision, not by
        # clearing the intention and leaving the approval behind.
        if not chosen and row['current_decision'] == 'APPROVE_FOR_REVIEW':
            raise WorkflowHeld(CODE_LOCKED_BY_APPROVAL)

        singular = chosen[0] if len(chosen) == 1 else None
        conn.execute(text("""
            INSERT INTO public.m2_qg_candidate_reviews
                (candidate_id, owner_user_id, reviewer_id,
                 expected_option_code, expected_option_codes)
            VALUES (:cid, :owner, :actor, :singular, :codes)
            ON CONFLICT (candidate_id, reviewer_id) DO UPDATE
               SET expected_option_code = excluded.expected_option_code,
                   expected_option_codes = excluded.expected_option_codes
        """), {'cid': str(candidate_id), 'owner': str(row['owner_user_id']),
               'actor': str(actor_id), 'singular': singular,
               'codes': chosen or None})
    return {'contract_version': READ_CONTRACT, 'candidate_id': str(candidate_id),
            'expected_option_codes': chosen,
            'expected_option_code': singular,
            'selection_policy': policy_for(
                row['response_format'],
                min_selections=limits['min_selections'],
                max_selections=limits['max_selections']),
            'owner_only': True,
            'respondent_visible': False,
            'is_customer_evidence': False}


__all__ = ['READ_CONTRACT', 'REVIEW_DECISIONS', 'list_candidates', 'read_candidate',
           'record_review', 'set_expected_answer', 'project_candidate']
