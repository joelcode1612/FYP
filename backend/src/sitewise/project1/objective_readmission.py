"""Versioned objective re-admission against the current business context.

Why this exists
---------------
An objective admission records two different things at once: the owner's decision
about a proposal, and the business-context snapshot that decision was made
against. When the snapshot is rebuilt — here, because the owner confirmed the
uncertainty the objective exists to measure — the decision is still the owner's,
but its source binding no longer describes the source the workflow is using. The
application then refuses the old snapshot with ``BCB_CONTEXT_SOURCE_CHANGED`` and
Direct-QG has an admitted objective it cannot legally measure.

The three wrong answers, and why they are refused
-------------------------------------------------
1. *Rewrite the old admission's context hash.* That is overwriting a governance
   record. An auditor could no longer tell which snapshot the owner actually saw.
2. *Re-author the proposal.* That is manufacturing evidence. The proposal is the
   model's output, not the owner's; a re-admission is not a re-proposal.
3. *Ignore the mismatch and dispatch anyway.* That is what the source gate exists
   to prevent.

The chosen answer is a **new admission row over the same approved proposal**,
carrying the current context hash and an explicit ``supersedes_admission_id``
edge. ``admission_version`` makes the ordinal explicit. Nothing is updated and
nothing is deleted: the historical row keeps its context hash and its timestamp,
so "which snapshot did the owner approve, and when did that change?" stays
answerable from the table alone.

What this does not authorise
----------------------------
It does not approve anything new. It requires an already ``APPROVED`` proposal
and an already ``ADMITTED`` decision, and it copies the policy resolution rather
than recomputing it — a re-admission may not quietly change the policy outcome.
It grants no QG, fielding, publication or scientific authority; those remain
separate decisions.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import text

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.objective_admission import WORTH_RESEARCHING

#: The only basis this module writes. A free-text basis would let a caller
#: describe an arbitrary re-admission; a fixed vocabulary keeps the reason
#: auditable and greppable.
READMISSION_BASIS = 'OWNER_READMISSION_CURRENT_CONTEXT'


def _bind(conn, actor_id):
    """Assume the restricted M2 principal and bind the owner GUC.

    Both are required: the admissions table is granted to ``p1_m2_runtime`` and
    its ``owner_scope`` policy reads ``project1.actor_id``. The explicit
    ``actor_user_id`` predicate in every statement stays authoritative; RLS is
    the second layer, not the only one.
    """
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused
    try:
        bind_restricted_principal(conn, actor_id)
    except ContextRefused as exc:
        raise WorkflowHeld(exc.code) from None


def _admission(conn, admission_id, actor_id) -> dict | None:
    row = conn.execute(text("""
        SELECT a.admission_id, a.proposal_id, a.assessment_id, a.confirmation_id,
               a.confirmation_revision, a.source_fingerprint, a.context_packet_hash,
               a.actor_user_id, a.decision, a.proposal_hash, a.objective_id,
               a.policy_version, a.policy_classification, a.policy_disposition,
               a.policy_resolution, a.admission_version,
               p.review_state, p.research_objective
          FROM public.m2_bdj_objective_admissions a
          JOIN public.m2_bdj_objective_proposals p USING (proposal_id)
         WHERE a.admission_id = :aid AND a.actor_user_id = :actor
    """), {'aid': str(admission_id), 'actor': str(actor_id)}).mappings().one_or_none()
    return dict(row) if row else None


def _context(conn, context_id) -> dict | None:
    row = conn.execute(text("""
        SELECT context_id, assessment_id, packet_hash, lifecycle_status,
               assessment_revision
          FROM public.m2_business_contexts
         WHERE context_id = :cid
    """), {'cid': str(context_id)}).mappings().one_or_none()
    return dict(row) if row else None


def readmit(engine, *, actor_id, assessment_id, admission_id,
            confirmation_id, context_id, context_packet_hash,
            basis: str = READMISSION_BASIS) -> dict:
    """Record a new admission binding the same approved objective to a new context.

    Returns ``created: False`` with the reason when the work is already done, so
    a repeated owner action is idempotent rather than an error. Raises
    ``WorkflowHeld`` with a specific code for every refusal.
    """
    if basis != READMISSION_BASIS:
        raise WorkflowHeld('READMISSION_BASIS_NOT_AUTHORIZED')
    with engine.begin() as conn:
        _bind(conn, actor_id)
        prior = _admission(conn, admission_id, actor_id)
        if prior is None:
            # Absent and another owner's are deliberately indistinguishable.
            raise WorkflowHeld('READMISSION_ADMISSION_NOT_FOUND')
        if str(prior['assessment_id']) != str(assessment_id):
            raise WorkflowHeld('READMISSION_ASSESSMENT_MISMATCH')
        if str(prior['confirmation_id']) != str(confirmation_id):
            # A re-admission may move the snapshot, never the confirmation the
            # owner signed. Moving that would silently change what was approved.
            raise WorkflowHeld('READMISSION_CONFIRMATION_MISMATCH')
        if prior['decision'] != WORTH_RESEARCHING:
            # ``ADMITTED`` is the derived state; the stored decision is
            # ``WORTH_RESEARCHING``. Comparing against the derived label would
            # refuse every real admission.
            raise WorkflowHeld('READMISSION_NOT_ADMITTED')
        if prior['review_state'] != 'APPROVED':
            raise WorkflowHeld('READMISSION_PROPOSAL_NOT_APPROVED')
        if prior['objective_id'] is None:
            raise WorkflowHeld('READMISSION_NO_FIXED_OBJECTIVE')

        context = _context(conn, context_id)
        if context is None:
            raise WorkflowHeld('READMISSION_CONTEXT_NOT_FOUND')
        if str(context['assessment_id']) != str(assessment_id):
            raise WorkflowHeld('READMISSION_CONTEXT_ASSESSMENT_MISMATCH')
        if context['lifecycle_status'] != 'PERSISTED':
            raise WorkflowHeld('READMISSION_CONTEXT_NOT_PERSISTED')
        if str(context['packet_hash']) != str(context_packet_hash):
            raise WorkflowHeld('READMISSION_CONTEXT_HASH_MISMATCH')

        if str(prior['context_packet_hash']) == str(context_packet_hash):
            # Already bound to this snapshot. Not an error, and not a new row.
            return {'created': False, 'reason': 'ALREADY_BOUND_TO_THIS_CONTEXT',
                    'admission_id': str(prior['admission_id']),
                    'admission_version': int(prior['admission_version']),
                    'context_id': str(context_id),
                    'context_packet_hash': str(context_packet_hash),
                    'objective_id': prior['objective_id'],
                    'proposal_id': str(prior['proposal_id'])}

        existing = conn.execute(text("""
            SELECT admission_id, admission_version
              FROM public.m2_bdj_objective_admissions
             WHERE proposal_id = :pid AND context_packet_hash = :ctx
               AND readmission_basis IS NOT NULL
        """), {'pid': str(prior['proposal_id']),
               'ctx': str(context_packet_hash)}).mappings().one_or_none()
        if existing is not None:
            return {'created': False, 'reason': 'READMISSION_ALREADY_RECORDED',
                    'admission_id': str(existing['admission_id']),
                    'admission_version': int(existing['admission_version']),
                    'context_id': str(context_id),
                    'context_packet_hash': str(context_packet_hash),
                    'objective_id': prior['objective_id'],
                    'proposal_id': str(prior['proposal_id'])}

        new_id = uuid.uuid4()
        version = int(prior['admission_version']) + 1
        conn.execute(text("""
            INSERT INTO public.m2_bdj_objective_admissions (
                admission_id, proposal_id, assessment_id, confirmation_id,
                confirmation_revision, source_fingerprint, context_packet_hash,
                actor_user_id, decision, proposal_hash, request_id,
                objective_id, policy_version, policy_classification,
                policy_disposition, policy_resolution,
                admission_version, supersedes_admission_id, readmission_basis)
            VALUES (
                :aid, :pid, :assessment, :confirmation, :revision, :fp, :ctx,
                :actor, :decision, :hash, :request,
                :objective, :policy_version, :classification,
                :disposition, :resolution,
                :version, :supersedes, :basis)
        """), {
            'aid': str(new_id), 'pid': str(prior['proposal_id']),
            'assessment': str(prior['assessment_id']),
            'confirmation': str(prior['confirmation_id']),
            'revision': int(prior['confirmation_revision']),
            'fp': prior['source_fingerprint'], 'ctx': str(context_packet_hash),
            'actor': str(actor_id), 'decision': prior['decision'],
            'hash': prior['proposal_hash'], 'request': str(uuid.uuid4()),
            'objective': prior['objective_id'],
            'policy_version': prior['policy_version'],
            'classification': prior['policy_classification'],
            'disposition': prior['policy_disposition'],
            'resolution': prior['policy_resolution'],
            'version': version, 'supersedes': str(prior['admission_id']),
            'basis': basis,
        })
    return {'created': True, 'reason': None, 'admission_id': str(new_id),
            'admission_version': version,
            'supersedes_admission_id': str(prior['admission_id']),
            'context_id': str(context_id),
            'context_packet_hash': str(context_packet_hash),
            'objective_id': prior['objective_id'],
            'proposal_id': str(prior['proposal_id']),
            'recorded_at': datetime.now(timezone.utc).isoformat()}


__all__ = ['READMISSION_BASIS', 'readmit']
