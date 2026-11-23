"""Per-assessment QG authorization: issue, verify and consume one attempt.

Owner decision OD-18 is explicit: authorization is a **DB row scoped to one
assessment**, not a global flag. This module implements that row and the three
operations a governed QG stage needs.

Why a row and not a boolean
---------------------------
An authorization that is not bound to the exact source cannot be checked. A
boolean says "QG is allowed"; a row says *which* confirmed revision, *which*
source fingerprint, *which* context packet, *which* admitted objective, *which*
measurement version and *which* prompt hash were approved, for *which* owner,
until *when*, and whether it has already been spent. Only the second can refuse
a stale or substituted request, which is the whole point of the gate.

The three refusals that matter
------------------------------
``ABSENT`` / ``EXPIRED`` / ``CONSUMED`` / ``MISMATCHED`` each get their own code,
because they mean different things to the operator: issue one, renew one, ask
for a new decision, or investigate a substituted request. Collapsing them into
"not authorized" makes a governance failure indistinguishable from a typo.

What this module deliberately does not do
-----------------------------------------
* It does not grant scientific approval. A QG authorization says "spend one
  generation attempt on this admitted objective and this approved measurement";
  it says nothing about whether the measurement is any good.
* It does not authorize fielding, publication or respondent contact.
* It cannot be re-used: the single permitted UPDATE sets ``consumed_at`` once,
  and a trigger refuses every other mutation, including rewriting the binding.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import text

from sitewise.project1.contracts import WorkflowHeld

#: Version of the authorization rule set.
AUTHORIZATION_VERSION = 'P1-QG-AUTHORIZATION-1.0'

#: Default validity horizon. Deliberately short: an authorization is a
#: decision to run one attempt soon, not a standing permission.
DEFAULT_TTL = timedelta(hours=24)

_BINDING_FIELDS = ('assessment_id', 'confirmation_id', 'assessment_revision',
                   'source_fingerprint', 'context_id', 'context_packet_hash',
                   'objective_id', 'objective_admission_id', 'measurement_id',
                   'measurement_version', 'prompt_version', 'prompt_sha256')


def _bind(conn, actor_id):
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused
    try:
        bind_restricted_principal(conn, actor_id)
    except ContextRefused as exc:
        raise WorkflowHeld(exc.code) from None


def _sha(value, name: str) -> str:
    text_value = str(value or '')
    if len(text_value) != 64 or any(c not in '0123456789abcdef' for c in text_value):
        raise WorkflowHeld(f'QG_AUTHORIZATION_{name}_INVALID')
    return text_value


def issue(engine, *, actor_id, assessment_id, confirmation_id,
          assessment_revision, source_fingerprint, context_id,
          context_packet_hash, objective_id, objective_admission_id,
          measurement_id, measurement_version, prompt_version, prompt_sha256,
          request_id=None, ttl: timedelta = DEFAULT_TTL) -> dict:
    """Create one exact-bound authorization.

    The caller must already hold an ADMITTED objective; this function does not
    check that itself because the adapter does, immediately before it calls
    here, and duplicating the check in two places is how they drift apart.
    """
    if actor_id is None:
        raise WorkflowHeld('QG_AUTHORIZATION_OWNER_REQUIRED')
    source_fingerprint = _sha(source_fingerprint, 'SOURCE_FINGERPRINT')
    context_packet_hash = _sha(context_packet_hash, 'CONTEXT_HASH')
    prompt_sha256 = _sha(prompt_sha256, 'PROMPT_HASH')
    request_id = request_id or uuid.uuid4()
    authorization_id = uuid.uuid4()
    now = datetime.now(timezone.utc)
    expires = now + ttl

    with engine.begin() as conn:
        _bind(conn, actor_id)
        # The admission must exist, belong to this owner and still describe the
        # same source. An authorization over a stale admission is worthless.
        admission = conn.execute(text("""
            SELECT a.admission_id, a.assessment_id, a.confirmation_id,
                   a.confirmation_revision, a.source_fingerprint, a.actor_user_id
            FROM public.m2_bdj_objective_admissions a
            WHERE a.admission_id = :aid
        """), {'aid': str(objective_admission_id)}).mappings().one_or_none()
        if admission is None:
            raise WorkflowHeld('QG_AUTHORIZATION_ADMISSION_NOT_FOUND')
        if str(admission['actor_user_id']) != str(actor_id):
            raise WorkflowHeld('QG_AUTHORIZATION_ADMISSION_NOT_FOUND')
        if (str(admission['assessment_id']) != str(assessment_id)
                or str(admission['confirmation_id']) != str(confirmation_id)
                or admission['confirmation_revision'] != int(assessment_revision)
                or admission['source_fingerprint'] != source_fingerprint):
            raise WorkflowHeld('QG_AUTHORIZATION_ADMISSION_STALE')

        conn.execute(text("""
            INSERT INTO public.m2_qg_authorizations (
                authorization_id, assessment_id, confirmation_id,
                assessment_revision, source_fingerprint, context_id,
                context_packet_hash, objective_id, objective_admission_id,
                measurement_id, measurement_version, prompt_version,
                prompt_sha256, issued_by, issued_at, expires_at, request_id)
            VALUES (
                :id, :assessment, :confirmation, :revision, :source, :context,
                :context_hash, :objective, :admission, :measurement, :version,
                :prompt_version, :prompt_sha, :actor, :issued, :expires, :request)
        """), {
            'id': str(authorization_id), 'assessment': str(assessment_id),
            'confirmation': str(confirmation_id),
            'revision': int(assessment_revision),
            'source': source_fingerprint, 'context': str(context_id),
            'context_hash': context_packet_hash, 'objective': str(objective_id),
            'admission': str(objective_admission_id),
            'measurement': str(measurement_id),
            'version': str(measurement_version),
            'prompt_version': str(prompt_version),
            'prompt_sha': prompt_sha256, 'actor': str(actor_id),
            'issued': now, 'expires': expires, 'request': str(request_id),
        })

    return {'authorization_id': str(authorization_id),
            'issued_at': now, 'expires_at': expires,
            'authorization_version': AUTHORIZATION_VERSION,
            'consumed': False, 'fielding_authorized': False,
            'scientific_approval': False}


def verify(engine, *, actor_id, authorization_id, assessment_id,
           source_fingerprint, context_id, context_packet_hash, objective_id,
           objective_admission_id, measurement_id, measurement_version,
           prompt_version, prompt_sha256, now: datetime | None = None) -> dict:
    """Verify every binding before dispatch. Raises a specific hold on failure.

    Ordered so the operator learns the most actionable fact first: absence, then
    expiry, then consumption, then a binding mismatch.
    """
    if actor_id is None:
        raise WorkflowHeld('QG_AUTHORIZATION_OWNER_REQUIRED')
    now = now or datetime.now(timezone.utc)
    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT * FROM public.m2_qg_authorizations
            WHERE authorization_id = :id
        """), {'id': str(authorization_id)}).mappings().one_or_none()
    if row is None:
        raise WorkflowHeld('QG_AUTHORIZATION_NOT_FOUND')
    if str(row['issued_by']) != str(actor_id):
        # RLS already hides a foreign row; this is the explicit second check.
        raise WorkflowHeld('QG_AUTHORIZATION_NOT_FOUND')
    if row['consumed_at'] is not None:
        raise WorkflowHeld('QG_AUTHORIZATION_CONSUMED')
    expires = row['expires_at']
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    if expires <= now:
        raise WorkflowHeld('QG_AUTHORIZATION_EXPIRED')

    expected = {
        'assessment_id': str(assessment_id),
        'source_fingerprint': str(source_fingerprint),
        'context_id': str(context_id),
        'context_packet_hash': str(context_packet_hash),
        'objective_id': str(objective_id),
        'objective_admission_id': str(objective_admission_id),
        'measurement_id': str(measurement_id),
        'measurement_version': str(measurement_version),
        'prompt_version': str(prompt_version),
        'prompt_sha256': str(prompt_sha256),
    }
    mismatched = [name for name, value in expected.items()
                  if str(row[name]) != value]
    if mismatched:
        raise WorkflowHeld('QG_AUTHORIZATION_BINDING_MISMATCH')

    return {name: (str(row[name]) if name != 'assessment_revision'
                   else row[name]) for name in _BINDING_FIELDS} | {
        'authorization_id': str(row['authorization_id']),
        'expires_at': row['expires_at'],
        'authorization_version': AUTHORIZATION_VERSION,
        'consumed': False,
    }


def consume(engine, *, actor_id, authorization_id, candidate_id) -> dict:
    """Spend the authorization exactly once, naming the candidate it produced."""
    with engine.begin() as conn:
        _bind(conn, actor_id)
        updated = conn.execute(text("""
            UPDATE public.m2_qg_authorizations
            SET consumed_at = now(), consumed_candidate_id = :candidate
            WHERE authorization_id = :id AND consumed_at IS NULL
        """), {'id': str(authorization_id),
               'candidate': str(candidate_id)}).rowcount
        if updated != 1:
            raise WorkflowHeld('QG_AUTHORIZATION_CONSUMED')
    return {'authorization_id': str(authorization_id),
            'consumed_candidate_id': str(candidate_id), 'consumed': True}


def read(engine, *, actor_id, authorization_id) -> dict | None:
    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT authorization_id, assessment_id, confirmation_id,
                   assessment_revision, source_fingerprint, context_id,
                   context_packet_hash, objective_id, objective_admission_id,
                   measurement_id, measurement_version, prompt_version,
                   prompt_sha256, issued_at, expires_at, consumed_at,
                   consumed_candidate_id
            FROM public.m2_qg_authorizations WHERE authorization_id = :id
        """), {'id': str(authorization_id)}).mappings().one_or_none()
    return dict(row) if row else None


__all__ = ['AUTHORIZATION_VERSION', 'DEFAULT_TTL', 'consume', 'issue', 'read',
           'verify']
