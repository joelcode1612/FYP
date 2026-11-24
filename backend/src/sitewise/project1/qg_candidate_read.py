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
    """
    if actor_id is None:
        raise WorkflowHeld('PROPOSAL_OWNER_REQUIRED')
    conn.execute(text("SELECT set_config('project1.actor_id', :actor, false)"),
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


def project_candidate(row: dict) -> dict:
    """One candidate row as the Stage 4 envelope.

    Everything here came from a persisted column or from ``candidate_json``.
    Nothing is defaulted into a plausible value: an absent field stays ``None``
    and an absent option list stays empty.
    """
    body = _body(row.get('candidate_json'))
    review_decision = row.get('review_decision')
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
        'objective_classification': ('FIXED_O1_O6'
                                     if row.get('objective_id') in
                                     ('O1', 'O2', 'O3', 'O4', 'O5', 'O6')
                                     else ('OPTIONAL_BDJ' if row.get('proposal_id')
                                           else 'UNCLASSIFIED')),

        # -- measurement --------------------------------------------------------
        'measurement_id': row.get('measurement_id'),
        'measurement_version': row.get('measurement_version'),

        # -- the question -------------------------------------------------------
        'question': body.get('question'),
        'response_format': row.get('response_format'),
        'options': _options(body),
        'routing': body.get('routing') or {},
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
           r.recorded_at AS review_recorded_at, r.expected_option_code
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
                  rationale: str = '', expected_revision: int | None = None) -> dict:
    """Store the owner's judgement about one candidate.

    Append-only in spirit: one row per (candidate, reviewer), updated in place so
    a reviewer can change their mind without creating a second competing record.
    A stale ``expected_revision`` is refused rather than silently applied to a
    candidate raised against a different assessment revision.
    """
    if decision not in REVIEW_DECISIONS:
        raise WorkflowHeld('QG_CANDIDATE_REVIEW_DECISION_INVALID')
    rationale = (rationale or '').strip()
    if len(rationale) > 1000:
        raise WorkflowHeld('QG_CANDIDATE_REVIEW_RATIONALE_TOO_LONG')
    with engine.begin() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT c.candidate_id, c.assessment_revision, c.owner_user_id
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

        conn.execute(text("""
            INSERT INTO public.m2_qg_candidate_reviews
                (candidate_id, owner_user_id, reviewer_id, decision, rationale)
            VALUES (:cid, :owner, :actor, :decision, :rationale)
            ON CONFLICT (candidate_id, reviewer_id) DO UPDATE
               SET decision = excluded.decision,
                   rationale = excluded.rationale,
                   recorded_at = now()
        """), {'cid': str(candidate_id), 'owner': str(row['owner_user_id']),
               'actor': str(actor_id), 'decision': decision, 'rationale': rationale})
    return {'contract_version': READ_CONTRACT, 'candidate_id': str(candidate_id),
            'decision': decision, 'rationale': rationale,
            'fielding_authorized': False, 'scientifically_accepted': False}


def set_expected_answer(engine, *, actor_id, assessment_id, candidate_id,
                        option_code: str | None, expected_revision: int | None = None) -> dict:
    """Record the entrepreneur's *expected* answer.

    Not a respondent answer. It is never written to a customer-response table and
    never read by a CQ or EE-01 calculation. A ``None`` code clears it.
    """
    with engine.begin() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT c.candidate_id, c.assessment_revision, c.owner_user_id,
                   c.candidate_json
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

        if option_code is not None:
            allowed = {option['code'] for option in _options(_body(row['candidate_json']))}
            if option_code not in allowed:
                raise WorkflowHeld('QG_CANDIDATE_OPTION_NOT_AVAILABLE')

        conn.execute(text("""
            INSERT INTO public.m2_qg_candidate_reviews
                (candidate_id, owner_user_id, reviewer_id, expected_option_code)
            VALUES (:cid, :owner, :actor, :code)
            ON CONFLICT (candidate_id, reviewer_id) DO UPDATE
               SET expected_option_code = excluded.expected_option_code,
                   recorded_at = now()
        """), {'cid': str(candidate_id), 'owner': str(row['owner_user_id']),
               'actor': str(actor_id), 'code': option_code})
    return {'contract_version': READ_CONTRACT, 'candidate_id': str(candidate_id),
            'expected_option_code': option_code}


__all__ = ['READ_CONTRACT', 'REVIEW_DECISIONS', 'list_candidates', 'read_candidate',
           'record_review', 'set_expected_answer', 'project_candidate']
