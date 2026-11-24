"""Assemble the exact binding set a governed QG attempt is built from.

Why this is a module and not a route-local query
------------------------------------------------
The operator script and the HTTP route must bind the *same* seven things —
proposal, operative admission, business-context packet, confirmed facts,
measurement, prompt and source fingerprint — or the route becomes a second,
subtly different execution path. This is that one assembly, so a change to what
a QG attempt is bound to happens in one place.

What it will not do
-------------------
It reads; it never writes, never issues an authorization and never dispatches. A
missing or stale input is a ``WorkflowHeld`` with a named code, so the caller
reports the exact reason instead of building a packet from whatever it found.
"""
from __future__ import annotations

from sqlalchemy import text

from sitewise.project1 import measurement_library as ml
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.objective_admission import (
    WORTH_RESEARCHING, admission_state,
)
from sitewise.project1.objective_registry import get as objective_get
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.qg_candidate_adapter import facts_from_objective

DEFAULT_STIMULUS = {'concept_name': 'Slow Bar'}


def operative_admission(conn, proposal_id, actor_id) -> dict:
    """The newest admission for this proposal, which is the operative decision.

    A re-admission after a business-context rebuild is appended, not substituted,
    so "the newest row" is the only correct answer and the original stays as
    history behind it.
    """
    row = conn.execute(text("""
        SELECT admission_id, assessment_id, confirmation_id,
               confirmation_revision, source_fingerprint, context_packet_hash,
               objective_id, policy_version, actor_user_id, decision
          FROM public.m2_bdj_objective_admissions
         WHERE proposal_id = :pid AND actor_user_id = :actor
         ORDER BY created_at DESC
         LIMIT 1
    """), {'pid': str(proposal_id), 'actor': str(actor_id)}).mappings().one_or_none()
    if row is None:
        raise WorkflowHeld('QG_BINDING_ADMISSION_NOT_FOUND')
    # The stored ``decision`` column carries the owner's verdict, which is
    # ``WORTH_RESEARCHING``; ``ADMITTED`` is the *state* ``admission_state``
    # composes from it. Comparing the column to the state name refused every
    # real admission, so the two vocabularies are kept apart deliberately.
    if row['decision'] != WORTH_RESEARCHING:
        raise WorkflowHeld('QG_BINDING_ADMISSION_NOT_ADMITTED')
    return dict(row)


def resolve(engine, actor_id, *, assessment_id, objective_id, proposal_id,
            context_id, prompt_key: str = 'QG_FIXED_OPTION',
            stimulus: dict | None = None) -> dict:
    """Everything one attempt is bound to, or a named refusal.

    ``context_id`` is required rather than derived: the caller must state which
    snapshot it intends to use, and the source gate then proves that snapshot is
    the workflow's current one. Deriving it here would let the assembly and the
    gate agree on the wrong context.
    """
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal

    prompt = PROMPTS.get(prompt_key)
    if prompt is None:
        raise WorkflowHeld('PROVIDER_PROMPT_NOT_REGISTERED')

    with engine.connect() as conn:
        bind_restricted_principal(conn, actor_id)
        admission = operative_admission(conn, proposal_id, actor_id)
        if str(admission['assessment_id']) != str(assessment_id):
            raise WorkflowHeld('QG_BINDING_ADMISSION_ASSESSMENT_MISMATCH')
        packet_row = conn.execute(text("""
            SELECT packet_json, packet_hash FROM public.m2_business_contexts
             WHERE context_id = :cid AND assessment_id = :assessment
        """), {'cid': str(context_id), 'assessment': str(assessment_id)}).mappings().one_or_none()
        if packet_row is None:
            raise WorkflowHeld('QG_BINDING_CONTEXT_NOT_FOUND')
        if str(packet_row['packet_hash']) != str(admission['context_packet_hash']):
            # The caller named one snapshot while the admission was made against
            # another. Returning the admission's hash under the caller's context
            # id would persist a candidate whose id and hash disagree — and the
            # source gate would still pass, because it compares the hash. Refuse
            # the pair rather than relabel it.
            raise WorkflowHeld('QG_BINDING_CONTEXT_NOT_ADMITTED')
        packet = packet_row['packet_json']

    objective = objective_get(objective_id)
    facts = facts_from_objective(packet, objective_id=objective_id,
                                 objective_text=objective.construct,
                                 admission_id=str(admission['admission_id']))
    measurement = ml.resolve(
        ml.PostgresMeasurementStore(engine, actor_id), objective_id,
        stimulus=dict(stimulus or DEFAULT_STIMULUS),
        supported_formats=ml.CANDIDATE_FORMATS,
        allow_synthetic_test_approval=True)
    state = admission_state(engine, proposal_id,
                            source_fingerprint=admission['source_fingerprint'],
                            actor_id=actor_id)
    return {
        'actor': str(actor_id),
        'assessment_id': str(assessment_id),
        'confirmation_id': str(admission['confirmation_id']),
        'assessment_revision': int(admission['confirmation_revision']),
        'source_fingerprint': admission['source_fingerprint'],
        'context_id': str(context_id),
        'context_packet_hash': admission['context_packet_hash'],
        'objective_id': objective_id,
        'objective_text': objective.construct,
        'proposal_id': str(proposal_id),
        'objective_admission_id': state.get('admission_id') or str(admission['admission_id']),
        'measurement': measurement,
        'admission': state,
        'prompt': prompt,
        'prompt_key': prompt_key,
        'facts': facts,
        'packet': packet,
        'policy_version': admission['policy_version'],
    }


__all__ = ['DEFAULT_STIMULUS', 'operative_admission', 'resolve']
