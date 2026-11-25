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
AUTHORIZATION_VERSION = 'P1-QG-AUTHORIZATION-1.1'

#: Default validity horizon. Deliberately short: an authorization is a
#: decision to run one attempt soon, not a standing permission.
DEFAULT_TTL = timedelta(hours=24)

#: The act this row authorises. A closed vocabulary, mirrored by
#: ``m2_qg_authorizations_purpose_check``: a value outside it is a contract
#: change, not a request parameter. Kept identical to
#: ``disclosure.QG_PURPOSE`` so the row and the disclosure cannot drift.
QG_PURPOSE = 'SYNTHETIC_QG_RESEARCH_EVALUATION'

#: The disclosure scope the grant was read under. Mirrored by
#: ``m2_qg_authorizations_scope_check``.
QG_SCOPE = 'QG_FIXED_OPTION_CANDIDATE'

#: ``purpose`` and ``scope`` are part of the binding, not metadata: a row issued
#: for one act must not be readable as authority for another.
_BINDING_FIELDS = ('assessment_id', 'confirmation_id', 'assessment_revision',
                   'source_fingerprint', 'context_id', 'context_packet_hash',
                   'objective_id', 'objective_admission_id', 'measurement_id',
                   'measurement_version', 'prompt_version', 'prompt_sha256',
                   'purpose', 'scope',
                   # Contract 2.1. Carried in the returned binding set so a
                   # reader can see which authority the row was issued against
                   # instead of inferring it from the absence of an admission.
                   'objective_decision_id', 'objective_kind', 'measurement_basis')

#: The two ways an objective can be authorised. An admission is the legacy
#: manual step; a decision is the owner's own approval, which contract 2.1
#: treats as sufficient. Exactly one must be present.
AUTHORITY_ADMISSION = 'OBJECTIVE_ADMISSION'
AUTHORITY_DECISION = 'OWNER_APPROVED_PROPOSAL'

#: Objective kinds, mirrored by the ``*_objective_kind_check`` constraints.
KIND_MANDATORY = 'MANDATORY_REGISTRY_OBJECTIVE'
KIND_ADDITIONAL = 'ADDITIONAL_ASSESSMENT_OBJECTIVE'
OBJECTIVE_KINDS = (KIND_MANDATORY, KIND_ADDITIONAL)

#: Measurement bases, mirrored by ``*_measurement_basis_check``. The proposed
#: basis is what makes generation possible without a scientific approval; it
#: never means the measurement *is* approved.
BASIS_APPROVED = 'APPROVED_SPECIFICATION'
BASIS_PROPOSED = 'PROPOSED_NOT_CONFIRMED'
MEASUREMENT_BASES = (BASIS_APPROVED, BASIS_PROPOSED)


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


def _resolve_decision_authority(conn, *, actor_id, decision_id, assessment_id,
                                confirmation_id, assessment_revision,
                                source_fingerprint,
                                context_packet_hash) -> dict:
    """Prove the owner's approval still describes *this* request.

    Contract 2.1 replaces the manual admission with the approval the owner
    already gave. That is only sound if the approval is still about the same
    revision, source and context, so every one of those is compared here rather
    than assumed from the fact that a decision row exists.
    """
    row = conn.execute(text("""
        SELECT d.decision_id, d.decision, d.decided_by, d.confirmation_id,
               d.source_fingerprint, d.context_packet_hash,
               p.assessment_id, p.confirmation_revision
          FROM public.m2_bdj_objective_decisions d
          JOIN public.m2_bdj_objective_proposals p
            ON p.proposal_id = d.proposal_id
         WHERE d.decision_id = :did
    """), {'did': str(decision_id)}).mappings().one_or_none()
    # "No such decision" and "another owner's decision" share one code on
    # purpose: a caller must not be able to probe for the existence of somebody
    # else's approval.
    if row is None or str(row['decided_by']) != str(actor_id):
        raise WorkflowHeld('QG_AUTHORIZATION_DECISION_NOT_FOUND')
    if str(row['decision']) != 'APPROVED':
        raise WorkflowHeld('QG_AUTHORIZATION_DECISION_NOT_APPROVED')
    if (str(row['assessment_id']) != str(assessment_id)
            or str(row['confirmation_id']) != str(confirmation_id)
            or int(row['confirmation_revision']) != int(assessment_revision)
            or str(row['source_fingerprint']) != str(source_fingerprint)
            or str(row['context_packet_hash']) != str(context_packet_hash)):
        raise WorkflowHeld('QG_AUTHORIZATION_DECISION_STALE')
    return dict(row)


#: Namespace for the deterministic recovery request identity. Fixed forever: a
#: changed namespace would silently make an existing recovery look new.
_RECOVERY_NAMESPACE = uuid.UUID('6f1c5b2e-0d3a-5a4e-9c77-2b8f4d6e1a03')


def recovery_request_id(prior_authorization_id) -> uuid.UUID:
    """The one request identity a recovery of ``prior`` can ever have.

    Deterministic on purpose. ``uq_qg_auth_request`` is unique on
    ``(assessment_id, request_id)``, so deriving the id from the prior
    authorization makes "at most one recovery per spent attempt" a database
    fact rather than a rule the caller has to remember, and makes a repeated
    recovery request idempotent instead of a second attempt.
    """
    return uuid.uuid5(_RECOVERY_NAMESPACE, f'recovery:{prior_authorization_id}')


def _is_recovery_row(conn, *, assessment_id, prior) -> bool:
    """True when ``prior`` is itself a recovery.

    A recovery's ``request_id`` is ``uuid5(namespace, 'recovery:<prior id>')``, so
    it can be recognised without a column: it equals the derived identity of some
    *other* authorization for the same assessment.

    Refusing to recover a recovery is what bounds this mechanism at **one** extra
    attempt. Without it the rule would be defeated by repetition rather than
    bypassed: each recovery is a fresh spent row, so each one would be a lawful
    prior for the next, and "one attempt per act" would become unbounded. The
    check is a scan of one assessment's authorizations, which is a handful of rows
    — not a reason to add a column.
    """
    siblings = conn.execute(text("""
        SELECT authorization_id, request_id
          FROM public.m2_qg_authorizations
         WHERE assessment_id = :assessment
    """), {'assessment': str(assessment_id)}).mappings().all()
    target = str(prior['request_id'])
    for sibling in siblings:
        if str(sibling['authorization_id']) == str(prior['authorization_id']):
            continue
        if str(recovery_request_id(sibling['authorization_id'])) == target:
            return True
    return False


def _require_recoverable(conn, *, recovery_of, assessment_id, confirmation_id,
                         assessment_revision, objective_id,
                         objective_decision_id, prompt_version, prompt_sha256,
                         consent_digest) -> dict:
    """A recovery may only follow the *same act*, after it was actually spent.

    Every binding column is compared, not just the ids: a recovery that could be
    re-pointed at a different revision, objective, prompt or grant would be a
    second attempt dressed as a first one. The original row is never read for
    mutation and never updated — the recovery is an additional row beside it.

    A recovery is also refused when the row it names is itself a recovery, so the
    chain has length one. See ``_is_recovery_row``.
    """
    prior = conn.execute(text("""
        SELECT authorization_id, request_id, assessment_id, confirmation_id,
               assessment_revision, objective_id, objective_decision_id,
               prompt_version, prompt_sha256, consent_digest, consumed_at
          FROM public.m2_qg_authorizations
         WHERE authorization_id = :aid
    """), {'aid': str(recovery_of)}).mappings().one_or_none()
    if prior is None:
        raise WorkflowHeld('QG_RECOVERY_PRIOR_NOT_FOUND')
    if prior['consumed_at'] is None:
        # Recovering an unspent attempt would hand out a second budget for an
        # act that has not used its first.
        raise WorkflowHeld('QG_RECOVERY_PRIOR_NOT_SPENT')
    same = (
        str(prior['assessment_id']) == str(assessment_id)
        and str(prior['confirmation_id']) == str(confirmation_id)
        and int(prior['assessment_revision']) == int(assessment_revision)
        and str(prior['objective_id']) == str(objective_id)
        and str(prior['objective_decision_id']) == str(objective_decision_id)
        and str(prior['prompt_version']) == str(prompt_version)
        and str(prior['prompt_sha256']) == str(prompt_sha256)
        and (prior['consent_digest'] or None) == (consent_digest or None)
    )
    if not same:
        raise WorkflowHeld('QG_RECOVERY_BINDING_MISMATCH')
    if _is_recovery_row(conn, assessment_id=assessment_id, prior=prior):
        # The named attempt was already a recovery. One extra attempt is the
        # remedy; a second recovery would be a retry loop with extra steps.
        raise WorkflowHeld('QG_RECOVERY_CHAIN_REFUSED')
    return dict(prior)


def issue(engine, *, actor_id, assessment_id, confirmation_id,
          assessment_revision, source_fingerprint, context_id,
          context_packet_hash, objective_id,
          objective_admission_id=None, objective_decision_id=None,
          objective_kind=None, measurement_basis=None,
          measurement_id=None, measurement_version=None,
          prompt_version, prompt_sha256,
          request_id=None, ttl: timedelta = DEFAULT_TTL,
          recovery_of=None,
          purpose: str = QG_PURPOSE, scope: str = QG_SCOPE,
          consent_version: str | None = None,
          consent_digest: str | None = None) -> dict:
    """Create one exact-bound authorization.

    The caller must already hold an authorised objective, in one of two forms:

    ``objective_admission_id``
        The legacy manual admission. Kept because historical rows and the
        operator script still use it.
    ``objective_decision_id``
        Contract 2.1: the owner's own approval of the research objective. This
        is the form the live route uses, because it needs no separate manual
        step. When this form is used ``objective_kind`` and
        ``measurement_basis`` are mandatory — a reader must be able to tell an
        approved measurement from a proposed one without consulting another
        table.

    Exactly one authority is accepted. Supplying both is refused rather than
    resolved by precedence: two authorities that disagree is a fact the caller
    has to settle, not one this function should silently pick between.

    ``consent_version`` and ``consent_digest`` name the grant this row relies
    on. They travel together or not at all (a CHECK enforces it): a digest with
    no contract version cannot be verified against the terms it claims to cover.
    A row issued without them is *legacy* — usable only because its purpose and
    scope defaults are a backfill of what it implicitly was, and it is visibly
    distinguishable from a row issued under the QG consent contract.
    """
    if actor_id is None:
        raise WorkflowHeld('QG_AUTHORIZATION_OWNER_REQUIRED')
    if purpose != QG_PURPOSE:
        raise WorkflowHeld('QG_AUTHORIZATION_PURPOSE_NOT_SUPPORTED')
    if scope != QG_SCOPE:
        raise WorkflowHeld('QG_AUTHORIZATION_SCOPE_NOT_SUPPORTED')
    if (consent_version is None) != (consent_digest is None):
        raise WorkflowHeld('QG_AUTHORIZATION_CONSENT_PAIR_REQUIRED')

    has_admission = objective_admission_id is not None
    has_decision = objective_decision_id is not None
    if not has_admission and not has_decision:
        raise WorkflowHeld('QG_AUTHORIZATION_AUTHORITY_REQUIRED')
    if has_admission and has_decision:
        raise WorkflowHeld('QG_AUTHORIZATION_AUTHORITY_AMBIGUOUS')

    if has_decision:
        if objective_kind not in OBJECTIVE_KINDS:
            raise WorkflowHeld('QG_AUTHORIZATION_OBJECTIVE_KIND_REQUIRED')
        if measurement_basis not in MEASUREMENT_BASES:
            raise WorkflowHeld('QG_AUTHORIZATION_MEASUREMENT_BASIS_REQUIRED')
        if measurement_basis == BASIS_PROPOSED:
            # A proposed basis is a statement that no approved specification
            # exists. Carrying an id beside it would let the row claim one.
            if measurement_id is not None or measurement_version is not None:
                raise WorkflowHeld(
                    'QG_AUTHORIZATION_MEASUREMENT_BASIS_INCONSISTENT')
        elif measurement_id is None or measurement_version is None:
            raise WorkflowHeld('QG_AUTHORIZATION_MEASUREMENT_REQUIRED')
    else:
        # The legacy form records neither kind nor basis, because the contract
        # that would have recorded them did not exist when those rows were
        # written. Accepting values here would fabricate that history.
        if objective_kind is not None or measurement_basis is not None:
            raise WorkflowHeld('QG_AUTHORIZATION_AUTHORITY_FIELDS_NOT_SUPPORTED')
        if measurement_id is None or measurement_version is None:
            raise WorkflowHeld('QG_AUTHORIZATION_MEASUREMENT_REQUIRED')

    source_fingerprint = _sha(source_fingerprint, 'SOURCE_FINGERPRINT')
    context_packet_hash = _sha(context_packet_hash, 'CONTEXT_HASH')
    prompt_sha256 = _sha(prompt_sha256, 'PROMPT_HASH')
    if consent_digest is not None:
        consent_digest = _sha(consent_digest, 'CONSENT_DIGEST')
    request_id = request_id or uuid.uuid4()
    if recovery_of is not None:
        # A recovery is addressed by its own deterministic identity, so at most
        # one can exist per spent authorization and asking twice is idempotent
        # rather than additive. The unique index on (assessment_id, request_id)
        # is what enforces that, so no extra table or column is needed (DD-054).
        request_id = recovery_request_id(recovery_of)
    authorization_id = uuid.uuid4()
    now = datetime.now(timezone.utc)
    expires = now + ttl

    with engine.begin() as conn:
        _bind(conn, actor_id)
        if recovery_of is not None:
            _require_recoverable(
                conn, recovery_of=recovery_of, assessment_id=assessment_id,
                confirmation_id=confirmation_id,
                assessment_revision=assessment_revision,
                objective_id=objective_id,
                objective_decision_id=objective_decision_id,
                prompt_version=prompt_version, prompt_sha256=prompt_sha256,
                consent_digest=consent_digest)
        if has_admission:
            # The admission must exist, belong to this owner and still describe
            # the same source. An authorization over a stale admission is
            # worthless.
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
        else:
            _resolve_decision_authority(
                conn, actor_id=actor_id, decision_id=objective_decision_id,
                assessment_id=assessment_id, confirmation_id=confirmation_id,
                assessment_revision=assessment_revision,
                source_fingerprint=source_fingerprint,
                context_packet_hash=context_packet_hash)

        # Idempotent per binding, not per request id (DD-046). A caller that
        # retries — a double click, a replayed POST, a second tab — asks for the
        # *same act*, and the same act must not acquire two independent attempt
        # budgets. Reuse is only allowed when every binding field matches,
        # including the consent digest: a different grant is a different
        # permission and must be issued as a new row.
        #
        # Only a live row is reusable. A consumed or expired one is not
        # permission, so it is never handed back as if it were.
        existing = conn.execute(text("""
            SELECT authorization_id, issued_at, expires_at, consumed_at
              FROM public.m2_qg_authorizations
             WHERE assessment_id = :assessment
               AND confirmation_id = :confirmation
               AND assessment_revision = :revision
               AND purpose = :purpose
               AND scope = :scope
               AND objective_id = :objective
               AND source_fingerprint = :source
               AND context_id IS NOT DISTINCT FROM :context
               AND context_packet_hash = :context_hash
               AND prompt_version = :prompt_version
               AND prompt_sha256 = :prompt_sha
               AND consent_digest IS NOT DISTINCT FROM :consent_digest
               AND objective_decision_id IS NOT DISTINCT FROM :decision
               AND objective_admission_id IS NOT DISTINCT FROM :admission
               AND measurement_id IS NOT DISTINCT FROM :measurement
               AND measurement_version IS NOT DISTINCT FROM :version
               -- A recovery addresses its own row and must not see the spent
               -- original it is recovering from; ordinary issuance passes NULL
               -- and keeps the original "one attempt per binding" behaviour.
               -- CAST(...) rather than ``::uuid``: a bind parameter immediately
               -- followed by the ``::`` cast operator does not parse.
               AND (CAST(:request_filter AS uuid) IS NULL
                    OR request_id = CAST(:request_filter AS uuid))
             ORDER BY (consumed_at IS NOT NULL) DESC, issued_at DESC
             LIMIT 1
        """), {
            'request_filter': (str(request_id) if recovery_of is not None
                               else None),
            'assessment': str(assessment_id),
            'confirmation': str(confirmation_id),
            'revision': int(assessment_revision),
            'purpose': purpose, 'scope': scope, 'objective': str(objective_id),
            'source': source_fingerprint, 'context': (str(context_id)
                                                      if context_id is not None
                                                      else None),
            'context_hash': context_packet_hash,
            'prompt_version': str(prompt_version),
            'prompt_sha': prompt_sha256,
            'consent_digest': consent_digest,
            'decision': (str(objective_decision_id) if has_decision else None),
            'admission': (str(objective_admission_id) if has_admission else None),
            'measurement': (str(measurement_id)
                            if measurement_id is not None else None),
            'version': (str(measurement_version)
                        if measurement_version is not None else None),
        }).mappings().one_or_none()

        if existing is not None and existing['consumed_at'] is not None:
            # The one attempt this binding is allowed has already been taken.
            # Re-issuing would hand out a second attempt for the same act, which
            # is exactly what "once per revision, purpose and objective" forbids.
            raise WorkflowHeld('QG_AUTHORIZATION_ALREADY_SPENT')

        if existing is not None and existing['expires_at'] > now:
            return {'authorization_id': str(existing['authorization_id']),
                    'issued_at': existing['issued_at'],
                    'expires_at': existing['expires_at'],
                    'authorization_version': AUTHORIZATION_VERSION,
                    'authority_basis': (AUTHORITY_DECISION if has_decision
                                        else AUTHORITY_ADMISSION),
                    'objective_decision_id': (str(objective_decision_id)
                                              if has_decision else None),
                    'objective_kind': objective_kind if has_decision else None,
                    'measurement_basis': (measurement_basis
                                          if has_decision else None),
                    'purpose': purpose, 'scope': scope,
                    'consent_version': consent_version,
                    'consent_digest': consent_digest,
                    'consumed': False, 'fielding_authorized': False,
                    'scientific_approval': False,
                    'reused': True}

        conn.execute(text("""
            INSERT INTO public.m2_qg_authorizations (
                authorization_id, assessment_id, confirmation_id,
                assessment_revision, source_fingerprint, context_id,
                context_packet_hash, objective_id, objective_admission_id,
                measurement_id, measurement_version, prompt_version,
                prompt_sha256, issued_by, issued_at, expires_at, request_id,
                purpose, scope, consent_version, consent_digest,
                objective_decision_id, objective_kind, measurement_basis)
            VALUES (
                :id, :assessment, :confirmation, :revision, :source, :context,
                :context_hash, :objective, :admission, :measurement, :version,
                :prompt_version, :prompt_sha, :actor, :issued, :expires, :request,
                :purpose, :scope, :consent_version, :consent_digest,
                :decision, :kind, :basis)
        """), {
            'id': str(authorization_id), 'assessment': str(assessment_id),
            'confirmation': str(confirmation_id),
            'revision': int(assessment_revision),
            'source': source_fingerprint, 'context': str(context_id),
            'context_hash': context_packet_hash, 'objective': str(objective_id),
            'admission': (str(objective_admission_id) if has_admission else None),
            'measurement': (str(measurement_id) if measurement_id is not None else None),
            'version': (str(measurement_version)
                        if measurement_version is not None else None),
            'prompt_version': str(prompt_version),
            'prompt_sha': prompt_sha256, 'actor': str(actor_id),
            'issued': now, 'expires': expires, 'request': str(request_id),
            'purpose': purpose, 'scope': scope,
            'consent_version': consent_version,
            'consent_digest': consent_digest,
            'decision': (str(objective_decision_id) if has_decision else None),
            'kind': objective_kind if has_decision else None,
            'basis': measurement_basis if has_decision else None,
        })

    return {'authorization_id': str(authorization_id),
            'issued_at': now, 'expires_at': expires,
            'authorization_version': AUTHORIZATION_VERSION,
            'authority_basis': (AUTHORITY_DECISION if has_decision
                                else AUTHORITY_ADMISSION),
            'objective_decision_id': (str(objective_decision_id)
                                      if has_decision else None),
            'objective_kind': objective_kind if has_decision else None,
            'measurement_basis': measurement_basis if has_decision else None,
            'purpose': purpose, 'scope': scope,
            'consent_version': consent_version,
            'consent_digest': consent_digest,
            'consumed': False, 'fielding_authorized': False,
            'scientific_approval': False,
            'reused': False}


def _norm(value):
    """Compare-ready rendering of a binding value.

    ``str(None)`` is ``'None'``, which would compare equal to a literal string
    'None' and unequal to a genuine NULL. Contract 2.1 made three binding
    columns nullable, so the difference matters: a decision-backed row has no
    admission id, and that must compare equal to the caller's ``None``.
    """
    return None if value is None else str(value)


def verify(engine, *, actor_id, authorization_id, assessment_id,
           source_fingerprint, context_id, context_packet_hash, objective_id,
           objective_admission_id=None, measurement_id=None,
           measurement_version=None, prompt_version, prompt_sha256,
           objective_decision_id=None, objective_kind=None,
           measurement_basis=None,
           now: datetime | None = None,
           purpose: str = QG_PURPOSE, scope: str = QG_SCOPE) -> dict:
    """Verify every binding before dispatch. Raises a specific hold on failure.

    Ordered so the operator learns the most actionable fact first: absence, then
    expiry, then consumption, then a binding mismatch.

    ``purpose`` and ``scope`` default to the only values this release supports,
    so a caller cannot omit them and thereby skip the check. A row issued for a
    different act fails as a binding mismatch.

    The authority columns are compared too. A row issued against one approval
    must not verify against another: without that, an authorization could be
    spent on an objective the owner never approved.
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
        'assessment_id': _norm(assessment_id),
        'source_fingerprint': _norm(source_fingerprint),
        'context_id': _norm(context_id),
        'context_packet_hash': _norm(context_packet_hash),
        'objective_id': _norm(objective_id),
        'objective_admission_id': _norm(objective_admission_id),
        'measurement_id': _norm(measurement_id),
        'measurement_version': _norm(measurement_version),
        'prompt_version': _norm(prompt_version),
        'prompt_sha256': _norm(prompt_sha256),
        'purpose': _norm(purpose),
        'scope': _norm(scope),
        'objective_decision_id': _norm(objective_decision_id),
        'objective_kind': _norm(objective_kind),
        'measurement_basis': _norm(measurement_basis),
    }
    mismatched = [name for name, value in expected.items()
                  if _norm(row[name]) != value]
    if mismatched:
        # Named separately from a generic mismatch when the act itself differs:
        # "this row authorises something else" is a different fact from "the
        # source moved", and an operator must not have to guess which.
        if 'purpose' in mismatched:
            raise WorkflowHeld('QG_AUTHORIZATION_PURPOSE_MISMATCH')
        if 'scope' in mismatched:
            raise WorkflowHeld('QG_AUTHORIZATION_SCOPE_MISMATCH')
        raise WorkflowHeld('QG_AUTHORIZATION_BINDING_MISMATCH')

    return {name: (row[name] if name == 'assessment_revision'
                   else _norm(row[name])) for name in _BINDING_FIELDS} | {
        'authorization_id': str(row['authorization_id']),
        'expires_at': row['expires_at'],
        'authorization_version': AUTHORIZATION_VERSION,
        'consent_version': row['consent_version'],
        'consent_digest': row['consent_digest'],
        'consumed': False,
    }


# ``consume()`` used to live here: an UPDATE setting ``consumed_at`` and
# ``consumed_candidate_id`` after the candidate had been persisted. It has been
# removed rather than kept as an unused alternative, because spending an attempt
# after the model has answered is the defect ``qg_attempt.reserve`` fixes — a
# successful call whose write failed left the row looking unspent and replayable.
# The single permitted transition is now made before dispatch, in the same
# transaction as the consent reservation, and ``consumed_candidate_id`` stays
# NULL because the candidate does not exist yet. The reverse link is
# ``m2_qg_candidates.authorization_id``.


def read(engine, *, actor_id, authorization_id) -> dict | None:
    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT authorization_id, assessment_id, confirmation_id,
                   assessment_revision, source_fingerprint, context_id,
                   context_packet_hash, objective_id, objective_admission_id,
                   measurement_id, measurement_version, prompt_version,
                   prompt_sha256, issued_at, expires_at, consumed_at,
                   consumed_candidate_id, purpose, scope, consent_version,
                   consent_digest, objective_decision_id, objective_kind,
                   measurement_basis
            FROM public.m2_qg_authorizations WHERE authorization_id = :id
        """), {'id': str(authorization_id)}).mappings().one_or_none()
    return dict(row) if row else None


def find_by_request(engine, *, actor_id, assessment_id, request_id) -> dict | None:
    """The row already issued for this request, if any.

    ``uq_qg_auth_request`` makes (assessment_id, request_id) unique at the
    database level, so a second insert would fail rather than duplicate. This
    read exists so the API can answer with the existing row — "you already
    authorised this attempt" — instead of surfacing a unique-violation as a
    server error. It is what makes a retried POST safe.
    """
    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT authorization_id, assessment_id, confirmation_id,
                   assessment_revision, source_fingerprint, context_id,
                   context_packet_hash, objective_id, objective_admission_id,
                   measurement_id, measurement_version, prompt_version,
                   prompt_sha256, issued_at, expires_at, consumed_at,
                   consumed_candidate_id, purpose, scope, consent_version,
                   consent_digest, objective_decision_id, objective_kind,
                   measurement_basis, request_id
            FROM public.m2_qg_authorizations
            WHERE assessment_id = :a AND request_id = :r
        """), {'a': str(assessment_id),
               'r': str(request_id)}).mappings().one_or_none()
    return dict(row) if row else None


def consent_block(engine, *, actor_id, assessment_id, confirmation_id,
                  revision: int, objective_decision_id=None) -> dict | None:
    """The persisted QG consent block for one confirmation revision.

    Read from ``m2_qg_consent_grants`` first (migration 20261124_06, DD-044).
    That store is where a grant can actually be recorded: it is append-only,
    bound to the confirmed revision and the owner-approved objective, and it does
    not touch ``snapshot_json`` — granting permission to process data must not
    write a new M2 revision or invalidate an approved objective.

    The snapshot key ``ai_processing_qg`` is still consulted when the store has
    nothing, and only then. No snapshot carries that key today, so this is
    historical compatibility rather than a live path: a legacy grant, were one
    ever written, is never shadowed by the newer mechanism.

    Returns ``None`` when neither location holds a currently valid grant.
    ``ai_processing_consent.verify_qg_consent`` then reports which kind of
    absence it was, because "the owner declined", "the grant lapsed" and "this
    confirmation predates the contract" need different responses.

    Read through the restricted M2 principal so the owner policy applies: a
    foreign assessment yields ``None`` rather than another owner's grant.
    """
    from sitewise.project1 import qg_consent_store

    stored = qg_consent_store.block(
        engine, actor_id=actor_id, assessment_id=assessment_id,
        confirmation_id=confirmation_id, revision=revision,
        objective_decision_id=objective_decision_id)
    if stored is not None:
        return stored

    with engine.connect() as conn:
        _bind(conn, actor_id)
        row = conn.execute(text("""
            SELECT snapshot_json -> 'ai_processing_qg' AS block
              FROM public.m2_confirmation_snapshots
             WHERE assessment_id = :assessment
               AND id = :confirmation
               AND assessment_revision = :revision
        """), {'assessment': str(assessment_id),
               'confirmation': str(confirmation_id),
               'revision': int(revision)}).mappings().one_or_none()
    if row is None:
        return None
    block = row['block']
    if isinstance(block, str):
        import json as _json
        try:
            block = _json.loads(block)
        except (ValueError, TypeError):
            return None
    return block if isinstance(block, dict) else None


def runner_authority(engine, *, actor_id, authorization_id, consent_lookup,
                     provider: str, model: str, endpoint: str,
                     packet_source_fingerprint: str,
                     required_purpose: str = QG_PURPOSE,
                     required_scope: str = QG_SCOPE,
                     max_attempts: int = 1, now: datetime | None = None,
                     attempt_reserved: bool = False) -> dict:
    """Build the runner's authority from the **persisted** row and grant.

    Why this exists
    ---------------
    ``QgLiveRunner`` used to receive a dict the HTTP route assembled in process,
    and then checked ``payload['purpose'] == QG_PURPOSE`` against it. The check
    compared a value the caller had just written, so it could never fail. This
    function is the missing authority: it reads the row, reads the consent block
    the row names, and only then produces the dict.

    Refusals, each distinct because they mean different things to an operator:

    ``QG_AUTHORIZATION_PURPOSE_MISMATCH``   the row authorises a different act
    ``QG_AUTHORIZATION_SCOPE_MISMATCH``     the row was read under other terms
    ``QG_AUTHORIZATION_CONSENT_MISMATCH``   the grant changed since issue
    ``QG_AUTHORIZATION_CONSENT_NOT_RECORDED`` the grant was never named

    A row with no ``consent_digest`` is refused here. That is deliberate: the
    legacy rows predate the QG consent contract, and "the purpose was assumed"
    is exactly the state this function exists to end.
    """
    from sitewise.project1.ai_processing_consent import verify_qg_consent

    now = now or datetime.now(timezone.utc)
    row = read(engine, actor_id=actor_id, authorization_id=authorization_id)
    if row is None:
        raise WorkflowHeld('QG_AUTHORIZATION_NOT_FOUND')
    if str(row['purpose']) != required_purpose:
        raise WorkflowHeld('QG_AUTHORIZATION_PURPOSE_MISMATCH')
    if str(row['scope']) != required_scope:
        raise WorkflowHeld('QG_AUTHORIZATION_SCOPE_MISMATCH')
    if row['consumed_at'] is not None and not attempt_reserved:
        # ``attempt_reserved`` is passed only by a caller that has already spent
        # this attempt in ``qg_attempt.reserve`` — the same transaction that
        # records the consent consumption. It does not widen what the row
        # authorises; it acknowledges that the row is consumed *by the attempt
        # now being dispatched*. Every other caller still gets the refusal, so a
        # spent authorization cannot be replayed through this path.
        raise WorkflowHeld('QG_AUTHORIZATION_CONSUMED')
    expires = row['expires_at']
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    if expires <= now:
        raise WorkflowHeld('QG_AUTHORIZATION_EXPIRED')
    if row['consent_digest'] is None:
        raise WorkflowHeld('QG_AUTHORIZATION_CONSENT_NOT_RECORDED')

    block = verify_qg_consent(consent_lookup(), endpoint=endpoint, model=model,
                              owner_id=actor_id)
    if str(block['consent_digest']) != str(row['consent_digest']):
        raise WorkflowHeld('QG_AUTHORIZATION_CONSENT_MISMATCH')
    if str(block['contract_version']) != str(row['consent_version']):
        raise WorkflowHeld('QG_AUTHORIZATION_CONSENT_MISMATCH')
    if str(block['provider']) != provider:
        raise WorkflowHeld('AI_PROCESSING_QG_CONSENT_PROVIDER_MISMATCH')

    return {
        'purpose': str(row['purpose']),
        'scope': str(row['scope']),
        # The QG packet carries the *confirmed-facts* fingerprint, which is a
        # different identifier from the row's proposal source fingerprint. The
        # runner compares the packet against this value before provisioning a
        # run; passing the row's value refused every dispatch with
        # DISCLOSURE_SOURCE_MISMATCH before a socket was opened. The row's own
        # fingerprint is still checked, by ``verify``, immediately before this.
        'source_fingerprint': str(packet_source_fingerprint),
        'assessment_id': str(row['assessment_id']),
        'confirmation_id': str(row['confirmation_id']),
        'actor_id': str(actor_id),
        # One grant, one attempt. Read from the grant rather than assumed, so a
        # widened consent contract cannot silently widen the run.
        'max_attempts': int(block['max_attempts']),
        'operator_receipt': f'QG-AUTHORIZATION-{row["authorization_id"]}',
        'evaluation_id': str(row['authorization_id']),
        'prompt_version': str(row['prompt_version']),
        'prompt_sha256': str(row['prompt_sha256']),
        'consent_version': str(row['consent_version']),
        'consent_digest': str(row['consent_digest']),
        'authorization_version': AUTHORIZATION_VERSION,
        # Which authority this row was issued against. Carried so the attempt
        # record can state it rather than leave a reader to infer it from a
        # NULL admission id.
        'authority_basis': (AUTHORITY_DECISION if row['objective_decision_id']
                            is not None else AUTHORITY_ADMISSION),
        'objective_decision_id': _norm(row['objective_decision_id']),
        'measurement_basis': _norm(row['measurement_basis']),
    }


def recovery_state(engine, *, actor_id, assessment_id, confirmation_id,
                   assessment_revision, objective_decision_id,
                   objective_id=None) -> dict:
    """What a recovery of this act would consist of, read and not granted.

    DD-054 in one sentence: the authorization is single-use and the consent
    grant is single-use, so a *technical* failure consumes both and the owner is
    left holding a revision that can never be generated again. The approved
    remedy is a separately authorised recovery attempt — never an automatic
    retry, never a second attempt smuggled through the first row.

    This function exists so the recovery can be *presented* before it is
    requested: which attempt was spent, whether a recovery already exists for it,
    and whether the owner still holds a grant that could fund one. It writes
    nothing, so calling it cannot consume an allowance or create consent.

    ``can_request`` is true only when every precondition is already satisfied.
    ``blocked_by`` names the first missing one, in the order the dispatch would
    meet it, so a caller is never told "yes" about a recovery that the next step
    would refuse.
    """
    with engine.connect() as conn:
        _bind(conn, actor_id)
        spent = conn.execute(text("""
            SELECT authorization_id, issued_at, consumed_at, expires_at,
                   prompt_version, consent_digest, request_id
              FROM public.m2_qg_authorizations
             WHERE assessment_id = :assessment
               AND confirmation_id = :confirmation
               AND assessment_revision = :revision
               AND objective_decision_id = :decision
               AND purpose = :purpose
               AND scope = :scope
               AND consumed_at IS NOT NULL
             ORDER BY consumed_at DESC
             LIMIT 1
        """), {'assessment': str(assessment_id),
               'confirmation': str(confirmation_id),
               'revision': int(assessment_revision),
               'decision': str(objective_decision_id),
               'purpose': QG_PURPOSE, 'scope': QG_SCOPE}).mappings().one_or_none()

        if spent is None:
            # Nothing has been attempted, so there is nothing to recover from.
            # The ordinary issue path is the correct next step, not this one.
            return {'recovery_available': False, 'blocked_by': None,
                    'prior_authorization_id': None, 'recovery_authorization_id': None,
                    'recovery_already_issued': False, 'recovery_spent': False,
                    'consent_grant_available': False, 'can_request': False}

        recovery_id = recovery_request_id(spent['authorization_id'])
        issued = conn.execute(text("""
            SELECT authorization_id, consumed_at
              FROM public.m2_qg_authorizations
             WHERE assessment_id = :assessment AND request_id = :request
        """), {'assessment': str(assessment_id),
               'request': str(recovery_id)}).mappings().one_or_none()

        # An unspent grant is the allowance a recovery would spend. Read through
        # the same predicate ``qg_attempt.reserve`` uses, so "available" here and
        # "reservable" there cannot disagree.
        grant = conn.execute(text("""
            SELECT count(*) FROM public.m2_qg_consent_grants g
             WHERE g.assessment_id = :assessment
               AND g.confirmation_id = :confirmation
               AND g.assessment_revision = :revision
               AND g.objective_decision_id = :decision
               AND g.revoked_at IS NULL
               AND g.expires_at > now()
               AND NOT EXISTS (SELECT 1 FROM public.m2_qg_consent_consumptions c
                                WHERE c.consent_id = g.consent_id)
        """), {'assessment': str(assessment_id),
               'confirmation': str(confirmation_id),
               'revision': int(assessment_revision),
               'decision': str(objective_decision_id)}).scalar_one()

        # A recovery of a recovery is refused, so the interface must not offer
        # one. Read through the same helper ``_require_recoverable`` uses, so the
        # button and the dispatch cannot disagree about whether a chain is
        # allowed.
        prior_is_recovery = _is_recovery_row(
            conn, assessment_id=assessment_id, prior=spent)

    grant_available = int(grant or 0) > 0
    already_issued = issued is not None
    spent_already = bool(issued is not None and issued['consumed_at'] is not None)
    if spent_already:
        blocked_by = 'QG_RECOVERY_ALREADY_SPENT'
    elif prior_is_recovery:
        # The attempt that would be recovered is itself the one extra attempt
        # the policy allows. There is no second one.
        blocked_by = 'QG_RECOVERY_CHAIN_REFUSED'
    elif not grant_available:
        # The honest answer: a recovery is permitted, but the owner's single-use
        # grant was consumed by the failed attempt. A fresh grant is a new act of
        # consent, and this code says so rather than manufacturing one.
        blocked_by = 'QG_RECOVERY_CONSENT_REQUIRED'
    else:
        blocked_by = None
    return {
        'recovery_available': True,
        'blocked_by': blocked_by,
        'prior_authorization_id': str(spent['authorization_id']),
        'prior_consumed_at': spent['consumed_at'],
        'recovery_authorization_id': (str(issued['authorization_id'])
                                      if already_issued else None),
        'recovery_already_issued': already_issued,
        'recovery_spent': spent_already,
        'consent_grant_available': grant_available,
        # An already-issued, unspent recovery is *requestable* in the sense that
        # re-asking is idempotent and returns that row — but it grants no new
        # allowance, so ``can_request`` reports the fresh-request case only.
        # ``blocked_by`` is authoritative: whenever it names a reason, nothing may
        # be requested, so the verdict is derived from it rather than from the
        # allowance alone. Otherwise a chained recovery would be advertised as
        # available while the dispatch refused it.
        'can_request': blocked_by is None and not already_issued,
    }


__all__ = ['AUTHORIZATION_VERSION', 'AUTHORITY_ADMISSION', 'AUTHORITY_DECISION',
           'BASIS_APPROVED', 'BASIS_PROPOSED', 'DEFAULT_TTL', 'KIND_ADDITIONAL',
           'KIND_MANDATORY', 'MEASUREMENT_BASES', 'OBJECTIVE_KINDS', 'QG_PURPOSE',
           'QG_SCOPE', 'consent_block', 'find_by_request', 'issue',
           'read', 'recovery_request_id', 'recovery_state', 'runner_authority',
           'verify']
