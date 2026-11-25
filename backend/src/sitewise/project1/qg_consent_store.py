"""Persisted QG processing permission: grant, read, consume, revoke.

Why this module exists
----------------------
``ai_processing_consent`` owns the *terms* of the QG permission and can build,
verify and disclose a block. It never stored one, and the only place
``qg_authorization.consent_block()`` looked was
``m2_confirmation_snapshots.snapshot_json -> 'ai_processing_qg'`` — a key no
snapshot carries and no route can write. QG generation therefore refused every
assessment with ``AI_PROCESSING_QG_CONSENT_ABSENT`` (DD-044).

The owner's decision was Option B: a separate, append-only, revision-bound
consent record. Appending a key to ``snapshot_json`` would mean writing a new
confirmation snapshot, which means a new M2 revision, and a permission to
process data must not invalidate an already approved research objective. So
consent lives in ``m2_qg_consent_grants`` (migration 20261124_06), bound to one
confirmed revision and one owner-approved objective, and touching no business
declaration.

What this module is responsible for
-----------------------------------
* Turning an explicit owner decision into a stored grant, with every term
  re-derived by ``build_qg_consent`` rather than taken from the request.
* Reading the current grant for a confirmation, distinguishing "granted" from
  "expired", "revoked" and "never granted" — four facts an operator needs to
  tell apart.
* Reserving the single attempt a grant authorises, atomically, before any
  external dispatch.

What it deliberately does not do
--------------------------------
* It does not decide whether the objective may be generated from. That is
  ``derive_objective_authority``; this module only records that the owner also
  permitted the *processing*.
* It does not grant scientific approval, publication or fielding.
* It never fabricates a grant. A declined request stores nothing.

Two codes are duplicated from ``qg_authorization`` on purpose: importing them
would create a cycle, since ``qg_authorization`` reads this module. A test
asserts the values still agree.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from sitewise.project1 import ai_processing_consent as consent
from sitewise.project1.contracts import WorkflowHeld

#: The authorised act and disclosure scope. Must equal
#: ``qg_authorization.QG_PURPOSE`` / ``QG_SCOPE``; mirrored by the table's CHECK
#: constraints as well, so a drift fails in three places rather than one.
PURPOSE = 'SYNTHETIC_QG_RESEARCH_EVALUATION'
SCOPE = 'QG_FIXED_OPTION_CANDIDATE'

#: A grant is a permission to run one attempt soon, not a standing licence. The
#: default horizon matches the confirmation validity window, because a grant
#: that outlives the facts it describes would authorise processing of data the
#: owner has since changed.
DEFAULT_TTL = timedelta(days=30)

GRANTED = 'GRANTED'
EXPIRED = 'EXPIRED'
REVOKED = 'REVOKED'
CONSUMED = 'CONSUMED'
ABSENT = 'ABSENT'

_COLUMNS = """
    consent_id, assessment_id, assessment_revision, confirmation_id, bcb_digest,
    objective_decision_id, objective_kind, objective_id, owner_user_id,
    purpose, scope, disclosure_purpose, disclosure_scope,
    entire_context_packet, contract_version, provider, model, endpoint,
    prompt_version, prompt_sha256, max_attempts, expires_at, granted_at,
    request_id, consent_digest, consent_block, revoked_at, revoked_reason
"""


def _bind(conn, actor_id):
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused
    try:
        bind_restricted_principal(conn, actor_id)
    except ContextRefused as exc:
        raise WorkflowHeld(exc.code) from None


def _sqlstate(exc: DBAPIError) -> str:
    orig = getattr(exc, 'orig', None)
    return str(getattr(orig, 'pgcode', '') or '')


def _now(now: datetime | None) -> datetime:
    return now or datetime.now(timezone.utc)


def _row(row) -> dict:
    data = dict(row)
    block = data.get('consent_block')
    if isinstance(block, str):
        try:
            data['consent_block'] = json.loads(block)
        except (ValueError, TypeError):
            data['consent_block'] = None
    for key in ('consent_id', 'assessment_id', 'confirmation_id',
                'objective_decision_id', 'owner_user_id'):
        if data.get(key) is not None:
            data[key] = str(data[key])
    return data


def _state(data: dict, now: datetime) -> str:
    if data.get('revoked_at') is not None:
        return REVOKED
    if data.get('consumed_at') is not None:
        return CONSUMED
    expires = data.get('expires_at')
    if expires is not None and expires <= now:
        return EXPIRED
    return GRANTED


# ---------------------------------------------------------------------------
# Grant
# ---------------------------------------------------------------------------
def grant(engine, *, actor_id, assessment_id, confirmation_id, revision,
          objective_decision_id, objective_kind, objective_id,
          request, request_id, endpoint, model, prompt_version, prompt_sha256,
          purpose: str = PURPOSE, scope: str = SCOPE,
          ttl: timedelta = DEFAULT_TTL, now: datetime | None = None) -> dict:
    """Store the owner's explicit QG permission for one objective.

    ``request`` is only the echo of what the interface showed; every stored term
    comes from :func:`ai_processing_consent.build_qg_consent`. A declined request
    returns ``{'granted': False}`` and writes nothing — a refusal is not a record.

    The revision and the BCB digest are read from the confirmation itself rather
    than trusted from the caller, then cross-checked against the revision the
    caller believes it is consenting to. That is what makes the stored grant
    describe *the facts the owner saw* instead of the facts the request claimed.
    """
    if not str(request_id or '').strip():
        raise WorkflowHeld('QG_CONSENT_REQUEST_ID_REQUIRED')

    block = consent.build_qg_consent(request=request, endpoint=endpoint,
                                     model=model, owner_id=actor_id)
    if block.get('decision') != consent.GRANTED:
        return {'granted': False, 'state': ABSENT, 'reason': 'DECLINED',
                'consent_id': None}

    moment = _now(now)
    with engine.begin() as conn:
        _bind(conn, actor_id)

        snapshot = conn.execute(text("""
            SELECT assessment_id, assessment_revision, actor_user_id, snapshot_digest
              FROM public.m2_confirmation_snapshots
             WHERE id = :cid
        """), {'cid': str(confirmation_id)}).mappings().one_or_none()
        if snapshot is None:
            raise WorkflowHeld('QG_CONSENT_CONFIRMATION_NOT_FOUND')
        if str(snapshot['assessment_id']) != str(assessment_id):
            raise WorkflowHeld('QG_CONSENT_CONFIRMATION_ASSESSMENT_MISMATCH')
        if int(snapshot['assessment_revision']) != int(revision):
            raise WorkflowHeld('QG_CONSENT_REVISION_MISMATCH')
        if str(snapshot['actor_user_id']) != str(actor_id):
            # Consent belongs to the owner who gave it. Another actor cannot
            # grant permission over someone else's declarations.
            raise WorkflowHeld('QG_CONSENT_OWNER_MISMATCH')

        decision = conn.execute(text("""
            SELECT decision, decided_by, confirmation_id
              FROM public.m2_bdj_objective_decisions
             WHERE decision_id = :did
        """), {'did': str(objective_decision_id)}).mappings().one_or_none()
        if decision is None:
            raise WorkflowHeld('QG_CONSENT_AUTHORITY_NOT_FOUND')
        if str(decision['confirmation_id']) != str(confirmation_id):
            raise WorkflowHeld('QG_CONSENT_AUTHORITY_NOT_CURRENT')
        if str(decision['decision']) != 'APPROVED':
            raise WorkflowHeld('QG_CONSENT_AUTHORITY_NOT_APPROVED')
        if str(decision['decided_by']) != str(actor_id):
            raise WorkflowHeld('QG_CONSENT_AUTHORITY_OTHER_OWNER')

        # A replay of the *same request* is a duplicate request, not a redundant
        # permission, and it is refused before the reuse rule below can answer it
        # with the first grant. Order matters: the unique key on ``request_id``
        # exists to make a replayed request fail loudly, and answering it with a
        # success would hide a double submit rather than prevent it.
        replay = conn.execute(text("""
            SELECT consent_id FROM public.m2_qg_consent_grants
             WHERE assessment_id = :assessment AND request_id = :request_id
             LIMIT 1
        """), {'assessment': str(assessment_id),
               'request_id': str(request_id)}).first()
        if replay is not None:
            raise WorkflowHeld('QG_CONSENT_REQUEST_DUPLICATE')

        # Issuance is idempotent *per binding*. Without this, a second click
        # (or a second verification run) mints a second permission for the same
        # act: the table's only unique key is ``request_id``, and each request
        # carries a fresh one. The owner would then hold three permissions for
        # one decision while having granted only one — the record would no
        # longer describe what the owner actually did.
        #
        # Only a *live* grant is reused. A spent, revoked or expired grant is
        # not a permission any more, so a fresh POST after one of those is a
        # genuine new act of consent and must be recorded as such rather than
        # silently answered with a dead row.
        live = conn.execute(text("""
            SELECT {cols}
              FROM public.m2_qg_consent_grants g
             WHERE g.assessment_id = :assessment
               AND g.assessment_revision = :revision
               AND g.confirmation_id = :confirmation
               AND g.objective_decision_id = :decision
               AND g.objective_id = :objective
               AND g.owner_user_id = :owner
               AND g.purpose = :purpose AND g.scope = :scope
               AND g.provider = :provider AND g.model = :model
               AND g.endpoint = :endpoint
               AND g.prompt_version = :prompt_version
               AND g.prompt_sha256 = :prompt_sha
               AND g.consent_digest = :digest
               AND g.revoked_at IS NULL
               AND g.expires_at > :now
               AND NOT EXISTS (SELECT 1 FROM public.m2_qg_consent_consumptions c
                                WHERE c.consent_id = g.consent_id)
             ORDER BY g.granted_at DESC
             LIMIT 1
        """.replace('{cols}', _COLUMNS)), {
            'assessment': str(assessment_id),
            'revision': int(revision),
            'confirmation': str(confirmation_id),
            'decision': str(objective_decision_id),
            'objective': str(objective_id),
            'owner': str(actor_id),
            'purpose': purpose,
            'scope': scope,
            'provider': block['provider'],
            'model': block['model'],
            'endpoint': block['endpoint'],
            'prompt_version': str(prompt_version),
            'prompt_sha': str(prompt_sha256),
            'digest': block['consent_digest'],
            'now': moment,
        }).mappings().one_or_none()

        if live is not None:
            existing = _row(live)
            existing['granted'] = True
            existing['state'] = GRANTED
            existing['reused'] = True
            return existing

        try:
            inserted = conn.execute(text(f"""
                INSERT INTO public.m2_qg_consent_grants
                  (assessment_id, assessment_revision, confirmation_id, bcb_digest,
                   objective_decision_id, objective_kind, objective_id,
                   owner_user_id, purpose, scope, disclosure_purpose,
                   disclosure_scope, entire_context_packet, contract_version,
                   provider, model, endpoint, prompt_version, prompt_sha256,
                   max_attempts, expires_at, granted_at, request_id,
                   consent_digest, consent_block)
                VALUES
                  (:assessment, :revision, :confirmation, :bcb,
                   :decision, :kind, :objective,
                   :owner, :purpose, :scope, :disclosure_purpose,
                   CAST(:disclosure_scope AS jsonb), :entire_packet, :contract,
                   :provider, :model, :endpoint, :prompt_version, :prompt_sha,
                   :attempts, :expires, :granted_at, :request_id,
                   :digest, CAST(:block AS jsonb))
                RETURNING {_COLUMNS}
            """), {
                'assessment': str(assessment_id),
                'revision': int(revision),
                'confirmation': str(confirmation_id),
                'bcb': str(snapshot['snapshot_digest']),
                'decision': str(objective_decision_id),
                'kind': str(objective_kind),
                'objective': str(objective_id),
                'owner': str(actor_id),
                'purpose': purpose,
                'scope': scope,
                'disclosure_purpose': block['purpose'],
                'disclosure_scope': json.dumps(block['data_shared']),
                'entire_packet': bool(block['entire_context_packet']),
                'contract': block['contract_version'],
                'provider': block['provider'],
                'model': block['model'],
                'endpoint': block['endpoint'],
                'prompt_version': str(prompt_version),
                'prompt_sha': str(prompt_sha256),
                'attempts': int(block['max_attempts']),
                'expires': moment + ttl,
                'granted_at': moment,
                'request_id': str(request_id),
                'digest': block['consent_digest'],
                'block': json.dumps(block, sort_keys=True),
            }).mappings().one()
        except DBAPIError as exc:
            state = _sqlstate(exc)
            if state == '23505':
                # The same request arrived twice. The database decided, not a
                # race in the route.
                raise WorkflowHeld('QG_CONSENT_REQUEST_DUPLICATE') from None
            if state == '23503':
                raise WorkflowHeld('QG_CONSENT_AUTHORITY_NOT_FOUND') from None
            if state == '23514':
                raise WorkflowHeld('QG_CONSENT_AUTHORITY_NOT_APPROVED') from None
            if state == '42501':
                raise WorkflowHeld('QG_CONSENT_OWNER_MISMATCH') from None
            raise

    data = _row(inserted)
    data['granted'] = True
    data['state'] = GRANTED
    data['reused'] = False
    return data


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------
def status(engine, *, actor_id, assessment_id, confirmation_id, revision,
           objective_decision_id=None, consent_id=None,
           now: datetime | None = None) -> dict:
    """The most recent grant for this confirmation, with its state.

    Returns ``{'state': ABSENT, 'grant': None}`` when nothing was ever granted,
    which is a different fact from a grant that expired or was revoked. The
    caller needs all three to explain itself.

    ``consent_id`` narrows the read to one recorded grant. The application asks
    for the current permission and leaves it unset; a reader that must report on
    a specific grant — an audit, or a test that creates several — names it rather
    than relying on "the newest one is mine".
    """
    moment = _now(now)
    clauses = ['g.assessment_id = :assessment',
               'g.confirmation_id = :confirmation',
               'g.assessment_revision = :revision']
    params = {'assessment': str(assessment_id),
              'confirmation': str(confirmation_id),
              'revision': int(revision)}
    if objective_decision_id is not None:
        clauses.append('g.objective_decision_id = :decision')
        params['decision'] = str(objective_decision_id)
    if consent_id is not None:
        clauses.append('g.consent_id = :consent')
        params['consent'] = str(consent_id)

    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text(f"""
            SELECT {', '.join('g.' + c.strip() for c in _COLUMNS.split(','))},
                   c.consumed_at, c.authorization_id, c.candidate_id
              FROM public.m2_qg_consent_grants g
              LEFT JOIN public.m2_qg_consent_consumptions c
                     ON c.consent_id = g.consent_id
             WHERE {' AND '.join(clauses)}
             ORDER BY g.granted_at DESC
             LIMIT 1
        """), params).mappings().one_or_none()

    if row is None:
        return {'state': ABSENT, 'grant': None}
    data = _row(row)
    for key in ('authorization_id', 'candidate_id'):
        if data.get(key) is not None:
            data[key] = str(data[key])
    data['state'] = _state(data, moment)
    return {'state': data['state'], 'grant': data}


def block(engine, *, actor_id, assessment_id, confirmation_id, revision,
          objective_decision_id=None, consent_id=None,
          now: datetime | None = None) -> dict | None:
    """The stored consent block, only when the grant is currently valid.

    A revoked or expired grant is not returned at all: a lapsed permission must
    not be readable as one. The block is re-verified by the caller, so a row
    whose ``consent_block`` was altered is refused rather than trusted.
    """
    found = status(engine, actor_id=actor_id, assessment_id=assessment_id,
                   confirmation_id=confirmation_id, revision=revision,
                   objective_decision_id=objective_decision_id,
                   consent_id=consent_id, now=now)
    if found['state'] != GRANTED:
        return None
    data = found['grant']
    stored = data.get('consent_block')
    if not isinstance(stored, dict):
        return None
    if stored.get('consent_digest') != data.get('consent_digest'):
        # The stored block and the stored digest disagree, so the row cannot
        # describe the terms it claims. Refusing is the only safe reading.
        return None
    return stored


def find_by_request(engine, *, actor_id, assessment_id, request_id) -> dict | None:
    """The grant already stored for this request, if any.

    ``m2_qg_consent_grants_request_key`` makes (assessment_id, request_id)
    unique, so a retried POST answers with the existing grant instead of
    surfacing a unique violation as a server error.
    """
    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text(f"""
            SELECT {_COLUMNS}
              FROM public.m2_qg_consent_grants
             WHERE assessment_id = :assessment AND request_id = :request_id
        """), {'assessment': str(assessment_id),
               'request_id': str(request_id)}).mappings().one_or_none()
    if row is None:
        return None
    data = _row(row)
    data['granted'] = True
    data['state'] = _state(data, _now(None))
    return data


# ---------------------------------------------------------------------------
# Consume
# ---------------------------------------------------------------------------
def consume(engine, *, actor_id, consent_id, assessment_id, authorization_id,
            candidate_id=None) -> dict:
    """Reserve the single attempt this grant authorises.

    ``m2_qg_consent_consumptions.consent_id`` is the primary key, so this INSERT
    either wins or loses against any concurrent dispatch. The reservation is
    made *before* the provider is called: a grant cannot be spent twice because
    a first attempt failed, and an attempt cannot be dispatched against a grant
    that was already spent.
    """
    with engine.begin() as conn:
        _bind(conn, actor_id)
        try:
            conn.execute(text("""
                INSERT INTO public.m2_qg_consent_consumptions
                  (consent_id, owner_user_id, assessment_id, authorization_id,
                   candidate_id)
                VALUES
                  (:consent, :owner, :assessment, :authorization, :candidate)
            """), {
                'consent': str(consent_id),
                'owner': str(actor_id),
                'assessment': str(assessment_id),
                'authorization': str(authorization_id),
                'candidate': None if candidate_id is None else str(candidate_id),
            })
        except DBAPIError as exc:
            state = _sqlstate(exc)
            if state == '23505':
                raise WorkflowHeld('QG_CONSENT_ALREADY_CONSUMED') from None
            if state == '23503':
                raise WorkflowHeld('QG_CONSENT_NOT_FOUND') from None
            if state == '42501':
                raise WorkflowHeld('QG_CONSENT_OWNER_MISMATCH') from None
            raise
    return {'consent_id': str(consent_id),
            'authorization_id': str(authorization_id),
            'consumed': True}


def consumption(engine, *, actor_id, consent_id) -> dict | None:
    """The attempt already reserved against a grant, if any."""
    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT consent_id, owner_user_id, assessment_id, authorization_id,
                   candidate_id, consumed_at
              FROM public.m2_qg_consent_consumptions
             WHERE consent_id = :consent
        """), {'consent': str(consent_id)}).mappings().one_or_none()
    if row is None:
        return None
    data = dict(row)
    for key in ('consent_id', 'owner_user_id', 'assessment_id',
                'authorization_id', 'candidate_id'):
        if data.get(key) is not None:
            data[key] = str(data[key])
    return data


# ---------------------------------------------------------------------------
# Revoke
# ---------------------------------------------------------------------------
def revoke(engine, *, actor_id, consent_id, reason: str) -> dict:
    """Withdraw a grant. The row survives; the permission does not."""
    if not str(reason or '').strip():
        raise WorkflowHeld('QG_CONSENT_REVOCATION_REASON_REQUIRED')
    with engine.begin() as conn:
        _bind(conn, actor_id)
        try:
            updated = conn.execute(text("""
                UPDATE public.m2_qg_consent_grants
                   SET revoked_at = now(), revoked_reason = :reason
                 WHERE consent_id = :consent AND revoked_at IS NULL
            """), {'consent': str(consent_id),
                   'reason': str(reason)[:200]}).rowcount
        except DBAPIError as exc:
            if _sqlstate(exc) == '55000':
                raise WorkflowHeld('QG_CONSENT_ALREADY_REVOKED') from None
            raise
    if updated != 1:
        raise WorkflowHeld('QG_CONSENT_ALREADY_REVOKED')
    return {'consent_id': str(consent_id), 'revoked': True}


__all__ = [
    'ABSENT', 'CONSUMED', 'DEFAULT_TTL', 'EXPIRED', 'GRANTED', 'PURPOSE',
    'REVOKED', 'SCOPE', 'block', 'consume', 'consumption', 'find_by_request',
    'grant', 'revoke', 'status',
]
