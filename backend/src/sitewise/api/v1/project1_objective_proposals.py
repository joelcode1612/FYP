"""Governed HTTP surface for owner-bound BDJ objective proposals.

Composition
-----------
Execution here **dispatches to TokenHarbour**, the adopted cloud provider. This
module composes the unchanged governed machinery around the real adapter:

* ``TokenHarbor`` performs the dispatch. The credential comes from
  ``settings.tokenharbor_api_key`` and is not caller-selectable;
* ``ObjectiveSimulationDisclosure.for_tokenharbour`` fails closed on any stage,
  model, endpoint, schema version, source fingerprint or context binding other
  than the exact cloud composition built for this one execution;
* ``PostgresAttemptLedger`` still reserves the attempt *before* the call and
  writes an append-only receipt after it, so a failed or unknown-outcome
  dispatch is recorded rather than hidden;
* ``validate_objective_proposal`` and ``bind_to_business_context`` still run
  unchanged, so a model answer cannot bypass the candidate contract;
* rows are persisted with ``execution_mode='LIVE'`` together with the requested
  and returned model, so no later reader can mistake them for a fixture.

Owner decision (2026-11-23)
---------------------------
This route previously composed an in-process simulator that never opened a
socket, on the grounds that neither the ``SyntheticBdjDisclosure`` packet
authorisation nor the real-data authorisation row authorised disclosing this
source to a cloud model. The repository owner has since directed that the
objective route use TokenHarbour outright; that direction is recorded here
rather than silently encoded. The simulator is retained in
``objective_simulation`` for offline verification and the test suite, but it is
no longer reachable from this route. Consequence: with
``tokenharbor_enabled`` false or no key configured, the route fails closed with
``PROVIDER_NOT_CONFIGURED`` rather than falling back to the simulator.

Two database principals, two engines
------------------------------------
Proposal/decision rows live in ``public`` beside the other ``m2_*`` tables and
are granted to ``p1_m2_runtime``; the append-only attempt ledger lives in
``project1_ai`` and executes as ``p1ai_runtime``. They are deliberately not the
same login, so this module takes one engine per concern and guards each.

Approval is not admission
-------------------------
``POST …/{proposal_id}/decision`` records the entrepreneur's own decision. An
APPROVED decision is preserved verbatim, but it does **not** authorise QJ or QG:
``confirm_objective(origin='BDJ')`` still refuses with
``M2_UNCERTAINTY_LINK_REQUIRED``. That is reported as a distinct ``HELD``
admission state — never as an admission, and never by inventing an uncertainty
link.

Target scope
------------
The storage and ledger guards are pinned to the disposable cluster authorised
for this checkpoint. A production cutover is a separate, owner-approved change;
it is not obtained by loosening these constants here.
"""
from typing import Annotated, Callable, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from sqlalchemy import text
from sqlalchemy.engine import make_url

from sitewise.core.config import (
    provider_timeout_seconds, selected_bdj_contract, settings)
from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.dependencies import (
    AuthenticatedUser, get_persisted_business_context_service, require_entrepreneur)
from sitewise.db.m2_session import get_bcb_engine, m2_session_for
from sitewise.project1.contracts import WorkflowHeld, no_authority
from sitewise.project1 import proposal_target_policy
#: Captured at import time on purpose. The cloud-dispatch requirement is bound
#: to the *real* adapter class; if this were resolved lazily, a substituted
#: adapter (the offline test double) would redefine the very symbol the check
#: depends on and could switch the requirement off.
from sitewise.project1.provider import TokenHarbor as CloudTokenHarbor
from sitewise.services.persisted_business_context_service import ContextOperationHeld
from sitewise.services.ports.business_context_store_port import ContextActor
from sitewise.domain import rbac

router = APIRouter()
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]

#: Approved isolated targets and the principals allowed there.
#:
#: DD-006 was a single literal ``(database, port)`` pair, so the checkpoint could
#: not run against the PG18 cluster the rest of the application uses. The
#: allowlist lives in ``proposal_target_policy`` and is imported — never copied —
#: so the route guard and the persistence adapter cannot drift apart again, and
#: no environment variable can widen it.
APPROVED_TARGETS = proposal_target_policy.APPROVED_TARGETS
TARGET_HOSTS = proposal_target_policy.TARGET_HOSTS
#: Never allowlisted, and checked *before* the allowlist so that a later edit
#: which adds one of these names fails loudly instead of silently authorising it.
PROTECTED_DATABASES = proposal_target_policy.PROTECTED_DATABASES
#: The restricted principal that owns the proposal/decision grants.
PROPOSAL_PRINCIPAL = proposal_target_policy.PROPOSAL_PRINCIPAL
#: Adapter label persisted in ``m2_bdj_objective_proposals.model_provider``. It
#: names the adapter, not the model; the model ids are stored in their own
#: columns so a reader can tell which model was requested from which answered.
PROVIDER_NAME = 'tokenharbor'


class ProposalRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    expected_revision: int = Field(ge=0, strict=True)
    context_id: UUID


class DecisionRequest(ProposalRequest):
    decision: Literal['APPROVED', 'REJECTED']
    note: str | None = Field(default=None, max_length=500)


class AdmissionRequest(ProposalRequest):
    """Admission asks one question the decision does not.

    ``objective_id`` is optional because the policy can usually derive the fixed
    objective from the cited declarations. When the owner names it explicitly,
    the policy must agree — a contradiction is refused, never overridden.
    """
    objective_id: Literal['O1', 'O2', 'O3', 'O4', 'O5', 'O6'] | None = None


def get_objective_source_db(user: Owner):
    """Owner-bound source session; RLS actor binding is transaction-local."""
    with m2_session_for(user.user_id) as session:
        yield session


SourceDatabase = Annotated[object, Depends(get_objective_source_db)]


def get_workflow_packet_source() -> Callable:
    """Resolve the shared source projector lazily to avoid a router import cycle."""
    from sitewise.api.v1.project1_workflow import source
    return source


PacketSource = Annotated[Callable, Depends(get_workflow_packet_source)]


def get_objective_context_service(
        service: Annotated[object, Depends(get_persisted_business_context_service)]):
    """Require a verified persisted business context.

    The service MUST be injected, not constructed here: its own
    ``resolver_factory`` parameter defaults to a ``Depends`` marker, so calling
    ``get_persisted_business_context_service()`` directly leaves that marker in
    place and every read fails with "'Depends' object is not callable" (observed
    as BDJ_OBJECTIVE_CONTEXT_UNAVAILABLE on the first live request).
    """
    if not settings.m2_bcb_persistence_enabled:
        raise HTTPException(503, detail={
            'code': 'BCB_PERSISTENCE_NOT_CONFIGURED',
            'message': 'A verified persisted business context is required.'},
            headers={'Cache-Control': 'no-store'})
    return service


ContextService = Annotated[object, Depends(get_objective_context_service)]


def get_proposal_storage_engine():
    """Proposal rows are ``public.m2_*`` rows: they need the M2 principal.

    Deliberately not the ``project1_ai`` runtime engine — that login executes as
    ``p1ai_runtime``, which is refused on these tables (proved in Gate A).
    """
    try:
        return get_bcb_engine()
    except Exception:
        raise _refused('PROPOSAL_STORAGE_NOT_CONFIGURED', 503,
                       'Proposal storage is not configured.') from None


ProposalStorageEngine = Annotated[object, Depends(get_proposal_storage_engine)]


def get_ledger_engine():
    """The append-only attempt ledger engine (``p1ai_engine`` → ``p1ai_runtime``)."""
    from sitewise.api.v1.project1_workflow import get_runtime_engine
    return get_runtime_engine()


LedgerEngine = Annotated[object, Depends(get_ledger_engine)]


def get_authorized_proposal_storage_engine(
        engine: ProposalStorageEngine) -> object:
    assert_proposal_storage_target(engine)
    return engine


AuthorizedProposalStorageEngine = Annotated[
    object, Depends(get_authorized_proposal_storage_engine)]


def get_authorized_ledger_engine(engine: LedgerEngine) -> object:
    assert_ledger_target(engine)
    return engine


AuthorizedLedgerEngine = Annotated[object, Depends(get_authorized_ledger_engine)]


def _refused(code: str, status_code: int = 409,
             message: str = 'The objective proposal could not be verified.',
             **extra) -> HTTPException:
    detail = {'code': code, 'message': message}
    detail.update(extra)
    return HTTPException(status_code, detail=detail,
                         headers={'Cache-Control': 'no-store'})


def _require_objective_contract() -> None:
    try:
        selected = selected_bdj_contract()
    except ValueError:
        raise _refused('BDJ_CONTRACT_CONFIGURATION_INVALID', 503) from None
    if selected != 'objective':
        raise _refused('BDJ_OBJECTIVE_CONTRACT_NOT_SELECTED', 503,
                       'Objective proposals are not enabled for this workflow.')


def _current_inputs(*, assessment_id: UUID, payload: ProposalRequest,
                    user: AuthenticatedUser, session, packet_source: Callable,
                    context_service):
    try:
        packet = packet_source(session, user, assessment_id,
                              payload.expected_revision)
    except HTTPException:
        raise
    except NotFoundError:
        # The owner-scoped projection cannot see another owner's assessment.
        raise _refused('BDJ_OBJECTIVE_ASSESSMENT_NOT_FOUND', 404) from None
    except ConflictError:
        # No current confirmation, a superseded revision, or an assessment the
        # caller does not own. All three are the same refusal on purpose: the
        # response must not confirm that a foreign assessment exists.
        raise _refused('BDJ_OBJECTIVE_SOURCE_NOT_CURRENT', 409) from None
    except Exception:
        raise _refused('BDJ_OBJECTIVE_SOURCE_UNAVAILABLE', 503) from None

    confirmation = packet.get('confirmation') or {}
    source_fingerprint = packet.get('source_fingerprint')
    # The schema string is the only discriminator between the two M2 source
    # families. An unrecognised one is refused here rather than guessed, so a
    # caller cannot pass an arbitrary dict off as a confirmed projection.
    from sitewise.project1.m2v2_projection import resolve_source_contract
    try:
        resolve_source_contract(packet.get('schema_version'))
    except ConflictError:
        raise _refused('BDJ_OBJECTIVE_SOURCE_NOT_CURRENT') from None
    if (str(packet.get('assessment_id')) != str(assessment_id) or
            packet.get('assessment_revision') != payload.expected_revision or
            packet.get('confirmed') is not True or
            not isinstance(source_fingerprint, str) or
            len(source_fingerprint) != 64 or
            not confirmation.get('confirmation_id') or
            not confirmation.get('snapshot_digest')):
        raise _refused('BDJ_OBJECTIVE_SOURCE_NOT_CURRENT')

    actor = ContextActor(user.user_id, rbac.canonical_role(user.role))
    try:
        stored = context_service.retrieve(assessment_id, payload.context_id, actor)
    except ContextOperationHeld as exc:
        raise _refused(exc.code, exc.status_code) from None
    except NotFoundError:
        raise _refused('BDJ_OBJECTIVE_CONTEXT_NOT_FOUND', 404) from None
    except ConflictError:
        raise _refused('BDJ_OBJECTIVE_CONTEXT_NOT_CURRENT', 409) from None
    except Exception:
        raise _refused('BDJ_OBJECTIVE_CONTEXT_UNAVAILABLE', 503) from None

    context_packet = stored.get('packet') if isinstance(stored, dict) else None
    if not isinstance(context_packet, dict):
        raise _refused('BDJ_OBJECTIVE_CONTEXT_INVALID')

    from sitewise.services.business_context_v1 import source_hash
    packet_body = {k: v for k, v in context_packet.items() if k != 'packet_hash'}
    context_confirmation = context_packet.get('confirmation') or {}
    identity = context_packet.get('identity') or {}
    stored_confirmation = str(confirmation.get('confirmation_id'))
    stored_digest = str(confirmation.get('snapshot_digest'))

    context_packet_hash = context_packet.get('packet_hash')
    if (not isinstance(context_packet_hash, str) or
            source_hash(packet_body) != context_packet_hash or
            stored.get('contract_version') != 'persisted-business-context/1' or
            str(stored.get('context_id')) != str(payload.context_id) or
            str(stored.get('assessment_id')) != str(assessment_id) or
            str(stored.get('confirmation_id')) != stored_confirmation or
            stored.get('assessment_revision') != payload.expected_revision or
            stored.get('lifecycle_status') != 'PERSISTED' or
            stored.get('qj_execution_authorized') is not False or
            stored.get('qg_execution_authorized') is not False or
            str(identity.get('assessment_id')) != str(assessment_id) or
            str(identity.get('owner_id')) != str(user.user_id) or
            str(context_confirmation.get('id')) != stored_confirmation or
            context_confirmation.get('revision') != payload.expected_revision or
            context_confirmation.get('digest') != stored_digest or
            context_confirmation.get('status') != 'CURRENT_CONFIRMED'):
        raise _refused('BDJ_OBJECTIVE_CONTEXT_SOURCE_MISMATCH')

    return packet, stored, context_packet


def assert_proposal_storage_target(engine) -> None:
    """Refuse storage outside the approved disposable proposal database.

    Stricter than the adapter's name allowlist: this also proves the *server*
    identity and that the connection really is the restricted M2 principal. A
    superuser or BYPASSRLS login would make the ``owner_scope`` policies inert,
    so it is refused rather than silently trusted.
    """
    try:
        url = make_url(str(engine.url))
        if url.get_backend_name() != 'postgresql' or url.host not in TARGET_HOSTS:
            raise ValueError
        # Protected names are refused before the allowlist is consulted, so the
        # allowlist can never become a way to reach one of them.
        permitted = proposal_target_policy.approved_principals(
            url.database, url.port)
        if permitted is None:
            raise ValueError
        with engine.connect() as connection:
            database, server_port, current_user, privileged = connection.execute(text(
                'SELECT current_database(), inet_server_port(), current_user,'
                ' (SELECT rolsuper OR rolbypassrls FROM pg_roles'
                '  WHERE rolname = current_user)')).one()
        # The server's answer must agree with the URL we were handed, and must
        # itself not be a protected database.
        if (database, server_port) != (url.database, url.port):
            raise ValueError
        if database in PROTECTED_DATABASES:
            raise ValueError
        if current_user not in permitted or privileged is not False:
            raise ValueError
    except Exception:
        raise _refused('PROPOSAL_DB_TARGET_REFUSED', 503,
                       'Proposal storage is not on the approved disposable target.') from None


def assert_ledger_target(engine) -> None:
    """The append-only attempt ledger must be the same disposable cluster.

    ``restricted_scope`` already refuses a privileged principal at use time;
    this guard stops a misconfigured runtime URL from writing attempts (and
    therefore run identity) to the protected databases in the first place.
    """
    try:
        url = make_url(str(engine.url))
        if url.get_backend_name() != 'postgresql' or url.host not in TARGET_HOSTS:
            raise ValueError
        if url.database in PROTECTED_DATABASES:
            raise ValueError
        if not proposal_target_policy.is_approved(url.database, url.port):
            raise ValueError
        with engine.connect() as connection:
            database, server_port = connection.execute(text(
                'SELECT current_database(), inet_server_port()')).one()
        if (database, server_port) != (url.database, url.port):
            raise ValueError
        if database in PROTECTED_DATABASES:
            raise ValueError
    except Exception:
        raise _refused('LEDGER_DB_TARGET_REFUSED', 503,
                       'The attempt ledger is not on the approved disposable target.') from None


# --------------------------------------------------------------------------
# Execution / decision error mapping
# --------------------------------------------------------------------------
_EXECUTION_HELD = {
    'RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED': (503, 'LEDGER_PRINCIPAL_REFUSED'),
    'WORKFLOW_STORAGE_UNAVAILABLE': (503, 'LEDGER_STORAGE_UNAVAILABLE'),
    'WORKFLOW_RUN_NOT_FOUND': (503, 'LEDGER_STORAGE_UNAVAILABLE'),
    'WORKFLOW_RUN_REVISION_INVALID': (422, 'BDJ_OBJECTIVE_REVISION_INVALID'),
    'WORKFLOW_RUN_FINGERPRINT_INVALID': (422, 'BDJ_OBJECTIVE_SOURCE_INVALID'),
    'WORKFLOW_RUN_REVISION_MISMATCH': (409, 'BDJ_OBJECTIVE_RUN_REVISION_MISMATCH'),
    'WORKFLOW_RUN_BINDING_MISMATCH': (409, 'BDJ_OBJECTIVE_RUN_BINDING_MISMATCH'),
    'WORKFLOW_LEDGER_VERSION_UNSUPPORTED': (503, 'LEDGER_VERSION_UNSUPPORTED'),
    'MODEL_STAGE_ALREADY_RESERVED': (409, 'BDJ_OBJECTIVE_ALREADY_ATTEMPTED'),
    'MODEL_ATTEMPT_BUDGET_EXHAUSTED': (409, 'BDJ_OBJECTIVE_ATTEMPT_BUDGET_EXHAUSTED'),
    'MODEL_RECEIPT_OUTCOME_INVALID': (503, 'LEDGER_STORAGE_UNAVAILABLE'),
    'DISCLOSURE_STAGE_NOT_AUTHORIZED': (503, 'BDJ_OBJECTIVE_DISCLOSURE_REFUSED'),
    'DISCLOSURE_MODEL_MISMATCH': (503, 'BDJ_OBJECTIVE_DISCLOSURE_REFUSED'),
    'DISCLOSURE_ENDPOINT_MISMATCH': (503, 'BDJ_OBJECTIVE_DISCLOSURE_REFUSED'),
    'DISCLOSURE_SOURCE_CLASS_INVALID': (409, 'BDJ_OBJECTIVE_DISCLOSURE_SOURCE_INVALID'),
    'DISCLOSURE_SOURCE_MISMATCH': (409, 'BDJ_OBJECTIVE_SOURCE_STALE'),
    'DISCLOSURE_ASSESSMENT_BINDING_MISMATCH': (409, 'BDJ_OBJECTIVE_SOURCE_STALE'),
    'PROPOSAL_DB_TARGET_REFUSED': (503, 'PROPOSAL_DB_TARGET_REFUSED'),
    'PROPOSAL_SOURCE_FINGERPRINT_INVALID': (422, 'BDJ_OBJECTIVE_SOURCE_INVALID'),
    'PROPOSAL_NOT_BOUND_TO_CONTEXT': (409, 'BDJ_OBJECTIVE_CONTEXT_SOURCE_MISMATCH'),
    'PROPOSAL_EXECUTION_MODE_INVALID': (503, 'PROPOSAL_EXECUTION_MODE_INVALID'),
    'PROPOSAL_PROBLEM_TYPE_MISMATCH': (422, 'BDJ_OBJECTIVE_PROBLEM_TYPE_MISMATCH'),
    'PROPOSAL_SOURCE_REQUIRED': (422, 'BDJ_OBJECTIVE_SOURCE_REQUIRED'),
    'PROPOSAL_PROBLEM_REQUIRED': (422, 'BDJ_OBJECTIVE_PROBLEM_REQUIRED'),
    'PROPOSAL_SOURCE_NOT_ALLOWED': (422, 'BDJ_OBJECTIVE_SOURCE_NOT_ALLOWED'),
    'PROPOSAL_PROBLEM_NOT_ALLOWED': (422, 'BDJ_OBJECTIVE_PROBLEM_NOT_ALLOWED'),
    'RESTRICTED_PRINCIPAL_REQUIRED': (503, 'PROPOSAL_PRINCIPAL_REFUSED'),
}

_DECISION_HELD = {
    # A foreign owner is indistinguishable from a missing row on purpose: the
    # owner-scoped policy makes it invisible, and the API must not confirm that
    # another entrepreneur's proposal exists.
    'PROPOSAL_NOT_FOUND': (404, 'BDJ_OBJECTIVE_PROPOSAL_NOT_FOUND'),
    'PROPOSAL_DECISION_FORBIDDEN': (404, 'BDJ_OBJECTIVE_PROPOSAL_NOT_FOUND'),
    'PROPOSAL_DECISION_STALE': (409, 'BDJ_OBJECTIVE_PROPOSAL_STALE'),
    'PROPOSAL_ALREADY_DECIDED': (409, 'BDJ_OBJECTIVE_ALREADY_DECIDED'),
    'PROPOSAL_DECISION_INVALID': (422, 'BDJ_OBJECTIVE_DECISION_INVALID'),
    'PROPOSAL_OWNER_REQUIRED': (403, 'BDJ_OBJECTIVE_OWNER_REQUIRED'),
    'PROPOSAL_DB_TARGET_REFUSED': (503, 'PROPOSAL_DB_TARGET_REFUSED'),
    'RESTRICTED_PRINCIPAL_REQUIRED': (503, 'PROPOSAL_PRINCIPAL_REFUSED'),
}

_ADMISSION_HELD = {
    # Approval and admission are different decisions. "You have not approved it"
    # and "you approved it but have not admitted it" must not look alike.
    'PROPOSAL_NOT_APPROVED': (409, 'BDJ_OBJECTIVE_NOT_APPROVED'),
    'PROPOSAL_SOURCE_STALE': (409, 'BDJ_OBJECTIVE_SOURCE_STALE'),
    'PROPOSAL_NOT_FOUND': (404, 'BDJ_OBJECTIVE_PROPOSAL_NOT_FOUND'),
    'PROPOSAL_OWNER_REQUIRED': (403, 'BDJ_OBJECTIVE_OWNER_REQUIRED'),
    'PROPOSAL_DB_TARGET_REFUSED': (503, 'PROPOSAL_DB_TARGET_REFUSED'),
    'RESTRICTED_PRINCIPAL_REQUIRED': (503, 'PROPOSAL_PRINCIPAL_REFUSED'),
    'RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED': (503, 'PROPOSAL_PRINCIPAL_REFUSED'),
    # Policy refusals. Each names the disposition that decided it, because
    # "a survey cannot answer this" and "clarify first" need different actions.
    'ADMISSION_NOT_RESEARCH_SUITABLE_BUSINESS_DECISION_REQUIRED':
        (409, 'BDJ_ADMISSION_NOT_RESEARCH_SUITABLE'),
    'ADMISSION_NOT_RESEARCH_SUITABLE_HOLD_REVIEW':
        (409, 'BDJ_ADMISSION_NOT_RESEARCH_SUITABLE'),
    'ADMISSION_NOT_RESEARCH_SUITABLE_NO_ACTION':
        (409, 'BDJ_ADMISSION_NOT_RESEARCH_SUITABLE'),
    'ADMISSION_OBJECTIVE_AMBIGUOUS': (409, 'BDJ_ADMISSION_OBJECTIVE_AMBIGUOUS'),
    'ADMISSION_OBJECTIVE_CONFLICT': (409, 'BDJ_ADMISSION_OBJECTIVE_CONFLICT'),
    'ADMISSION_ALREADY_BOUND_TO_OTHER_OBJECTIVE':
        (409, 'BDJ_ADMISSION_OBJECTIVE_CONFLICT'),
}


def _held(exc: WorkflowHeld, table: dict, fallback_status: int,
          fallback_code: str) -> HTTPException:
    code = str(exc)
    status, external = table.get(code, (fallback_status, fallback_code))
    # Held codes are fixed identifiers by contract (see project1/bdj.py); they
    # never carry source content, so echoing them is safe and diagnosable.
    return _refused(external, status, reason=code)


def _checkpoint_reason(result: dict, checkpoint: int):
    for event in result.get('checkpoints') or []:
        if event.get('checkpoint') == checkpoint and event.get('reason'):
            return str(event['reason'])
    return None


def _current_rows(engine, *, assessment_id, user, revision, context_id,
                  source_fingerprint, context_packet_hash) -> list[dict]:
    """Owner-scoped readback filtered to this exact source and context."""
    from sitewise.project1 import objective_adapter
    try:
        rows = objective_adapter.read_for_assessment(
            engine, assessment_id, user.user_id, revision, 100)
    except WorkflowHeld as exc:
        raise _held(exc, _EXECUTION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None

    return [row for row in rows
            if row.get('source_fingerprint') == source_fingerprint
            and str(row.get('context_id')) == str(context_id)
            and row.get('context_packet_hash') == context_packet_hash]


def _require_current_proposal(engine, proposal_id, user, assessment_id,
                              payload: ProposalRequest, packet,
                              context_packet) -> dict:
    """Owner-scoped read plus the exact currentness checks the readback applies."""
    from sitewise.project1 import objective_adapter
    try:
        row = objective_adapter.read(engine, proposal_id, user.user_id)
    except WorkflowHeld as exc:
        raise _held(exc, _EXECUTION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None
    if row is None:
        raise _refused('BDJ_OBJECTIVE_PROPOSAL_NOT_FOUND', 404)

    confirmation = packet['confirmation']
    if (str(row.get('assessment_id')) != str(assessment_id) or
            str(row.get('confirmation_id')) != str(confirmation.get('confirmation_id')) or
            row.get('confirmation_revision') != payload.expected_revision or
            row.get('source_fingerprint') != packet.get('source_fingerprint') or
            str(row.get('context_id')) != str(payload.context_id) or
            row.get('context_packet_hash') != context_packet.get('packet_hash')):
        raise _refused('BDJ_OBJECTIVE_PROPOSAL_STALE')
    return row


def _recommendation(row: dict) -> dict:
    return {
        'recommendation_status': row['recommendation_status'],
        'problem_type': row['problem_type'],
        'problem': row['problem'],
        'research_objective': row['research_objective'],
        'reason': row['reason'],
        'source_refs': row['source_refs'],
    }


# --------------------------------------------------------------------------
# Evaluate
# --------------------------------------------------------------------------
@router.post('/assessments/{assessment_id}/objective-proposals/evaluate')
@router.post('/assessments/{assessment_id}/objective-proposals')
def evaluate_objective_proposals(
        assessment_id: UUID, payload: ProposalRequest, user: Owner,
        session: SourceDatabase, packet_source: PacketSource,
        context_service: ContextService, engine: AuthorizedProposalStorageEngine,
        ledger_engine: AuthorizedLedgerEngine, response: Response):
    """Run one governed simulated objective evaluation, persist, read back.

    Exactly one attempt is dispatched per (source revision, context, policy):
    the run identity is deterministic, and the append-only ledger refuses a
    second ``BDJ`` attempt on the same run. A repeat call therefore returns the
    already-persisted set with ``execution.reused = true`` rather than
    dispatching again.
    """
    response.headers['Cache-Control'] = 'no-store'
    _require_objective_contract()
    packet, _, context_packet = _current_inputs(
        assessment_id=assessment_id, payload=payload, user=user, session=session,
        packet_source=packet_source, context_service=context_service)

    from sitewise.project1.m2v2_projection import resolve_source_contract
    contract = resolve_source_contract(packet['schema_version'])

    from sitewise.project1 import objective_adapter
    from sitewise.project1.bdj import BDJEngine
    from sitewise.project1.ledger import PostgresAttemptLedger
    from sitewise.project1.objective_proposal import (
        bind_to_business_context, validate_objective_proposal)
    from sitewise.project1.objective_simulation import ObjectiveSimulationDisclosure
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import ModelRunner, TokenHarbor
    from sitewise.project1.runs import (
        attempt_count, ensure_objective_run, latest_receipt)

    source_fingerprint = packet['source_fingerprint']
    context_packet_hash = context_packet['packet_hash']
    confirmation = packet['confirmation']
    revision = payload.expected_revision

    try:
        run_id = ensure_objective_run(
            ledger_engine, user.user_id, assessment_id, revision,
            source_fingerprint, context_packet_hash,
            prompt_key=contract.objective_prompt_key,
            # Versioned policy identity: a real cloud execution never shares a
            # run with a historical simulated one, so it can neither reuse the
            # simulator's attempt slot nor redispatch across a policy change.
            provider=PROVIDER_NAME)
        prior_attempts = attempt_count(ledger_engine, user.user_id, run_id)
    except WorkflowHeld as exc:
        raise _held(exc, _EXECUTION_HELD, 503, 'LEDGER_STORAGE_UNAVAILABLE') from None

    if prior_attempts:
        # No second dispatch. Report the persisted set and the existing receipt.
        rows = _current_rows(
            engine, assessment_id=assessment_id, user=user, revision=revision,
            context_id=payload.context_id,
            source_fingerprint=source_fingerprint,
            context_packet_hash=context_packet_hash)
        receipt = latest_receipt(ledger_engine, user.user_id, run_id)
        if not rows:
            raise _refused(
                'BDJ_OBJECTIVE_ALREADY_ATTEMPTED', 409,
                'This source revision already used its objective attempt and '
                'persisted no proposal.',
                execution={'run_id': str(run_id), 'reused': True,
                           'receipt_outcome': receipt[1] if receipt else None})
        return _evaluation_envelope(
            packet=packet, payload=payload, rows=rows, created={},
            execution=_execution_block(
                runner=None, run_id=run_id, ledger_engine=ledger_engine,
                actor_id=user.user_id, reused=True,
                context_packet_hash=context_packet_hash,
                prompt_key=contract.objective_prompt_key,
                model_provider=PROVIDER_NAME),
            checkpoints=[])

    # The adopted cloud adapter. The credential is read from settings and is not
    # caller-selectable; ``enabled`` and the key together decide whether a
    # dispatch can happen at all. With either missing the adapter raises
    # ``PROVIDER_NOT_CONFIGURED``, which surfaces below as a 503 hold — the route
    # does not fall back to the offline simulator.
    provider = TokenHarbor(
        settings.tokenharbor_api_key,
        enabled=settings.tokenharbor_enabled,
        structured_mode=settings.tokenharbor_structured_mode,
        timeout=provider_timeout_seconds(),
        identity_exception=settings.tokenharbor_model_identity_exception)
    # Bound to the model actually configured on the adapter, so a substituted or
    # downgraded model is refused rather than inheriting this authorisation.
    source_disclosure = ObjectiveSimulationDisclosure.for_tokenharbour(
        model=provider.model,
        assessment_id=assessment_id, revision=revision,
        confirmation_id=str(confirmation['confirmation_id']),
        source_fingerprint=source_fingerprint,
        context_packet_hash=context_packet_hash,
        expected_schema_version=contract.schema_version)
    disclosure = _compose_disclosure(
        source_disclosure, ledger_engine=ledger_engine,
        user=user, assessment_id=assessment_id, revision=revision,
        confirmation=confirmation, source_fingerprint=source_fingerprint,
        context_packet_hash=context_packet_hash,
        prompt=PROMPTS[contract.objective_prompt_key],
        provider=provider, packet_source=packet_source, session=session)
    ledger = PostgresAttemptLedger(ledger_engine, user.user_id, run_id)
    runner = ModelRunner(provider, ledger, PROMPTS, disclosure=disclosure)
    # ``rules=None`` is deliberate and truthful: the deterministic detector does
    # not author objective proposals, and ``bdj-objective-proposal/1`` has no
    # rule_id field, so there is no rule vocabulary to police here. Loading the
    # BDJ findings ruleset would only add an unrelated configuration dependency.
    engine_bdj = BDJEngine(rules=None, model_runner=runner)

    try:
        result = engine_bdj.propose_objectives(
            packet,
            recheck_current=lambda: packet_source(
                session, user, assessment_id, revision)['source_fingerprint'],
            context_packet=context_packet, context_id=str(payload.context_id))
    except WorkflowHeld as exc:
        raise _held(exc, _EXECUTION_HELD, 503, 'BDJ_OBJECTIVE_EXECUTION_HELD') from None

    execution = _execution_block(
        runner=runner, run_id=run_id, ledger_engine=ledger_engine,
        actor_id=user.user_id, reused=False,
        context_packet_hash=context_packet_hash,
        prompt_key=contract.objective_prompt_key,
        model_provider=PROVIDER_NAME)

    outcome = result.get('outcome')
    if outcome == 'stale':
        raise _refused('BDJ_OBJECTIVE_SOURCE_STALE', 409,
                       'The confirmed M2 source changed during evaluation.',
                       execution=execution)
    if outcome == 'held':
        code = _checkpoint_reason(result, 2) or 'BDJ_OBJECTIVE_MODEL_REQUIRED'
        raise _refused('BDJ_OBJECTIVE_EXECUTION_HELD', 503, reason=code,
                       execution=execution)
    if outcome != 'reviewed':
        code = _checkpoint_reason(result, 4) or 'CANDIDATE_VALIDATION_FAILED'
        raise _refused('BDJ_OBJECTIVE_CANDIDATE_REJECTED', 422, reason=code,
                       execution=execution)

    # The engine already validated and bound its own output; re-proving both at
    # the persistence boundary keeps a caller from persisting an unbound set.
    try:
        proposal = validate_objective_proposal(
            {'contract_version': result['contract_version'],
             'recommendations': result['proposals']}, packet)
        bound = bind_to_business_context(
            proposal, context_packet=context_packet,
            context_id=str(payload.context_id))
    except ValidationError:
        raise _refused('BDJ_OBJECTIVE_CANDIDATE_REJECTED', 422,
                       reason='CANDIDATE_VALIDATION_FAILED') from None
    except WorkflowHeld as exc:
        raise _refused('BDJ_OBJECTIVE_BINDING_REFUSED', 409, reason=str(exc)) from None

    if (bound.context_packet_hash != context_packet_hash or
            str(result.get('context_packet_hash')) != context_packet_hash or
            str(result.get('context_id')) != str(payload.context_id)):
        raise _refused('BDJ_OBJECTIVE_CONTEXT_SOURCE_MISMATCH', 409)

    # Truthful provenance. A real dispatch is recorded as LIVE, with the model the
    # adapter requested and — when the provider envelope reported one — the model
    # it returned. ``model_provider`` names the adapter, not the model.
    identity = provider.last_identity or {}
    dispatch_record = provider.last_execution or {}
    try:
        written = objective_adapter.persist(
            engine, bound, owner_user_id=user.user_id,
            evaluation_id=uuid4(), assessment_id=assessment_id,
            confirmation_revision=revision,
            confirmation_id=str(confirmation['confirmation_id']),
            source_fingerprint=source_fingerprint,
            prompt_version=PROMPTS[contract.objective_prompt_key].version,
            execution_mode='LIVE', model_provider=PROVIDER_NAME,
            model_requested=dispatch_record.get('model_requested') or provider.model,
            model_returned=identity.get('returned_model'))
    except WorkflowHeld as exc:
        raise _held(exc, _EXECUTION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None

    created = {row['proposal_id']: bool(row['created']) for row in written}
    rows = _current_rows(
        engine, assessment_id=assessment_id, user=user, revision=revision,
        context_id=payload.context_id,
        source_fingerprint=source_fingerprint,
        context_packet_hash=context_packet_hash)

    return _evaluation_envelope(
        packet=packet, payload=payload, rows=rows, created=created,
        execution=execution, checkpoints=result.get('checkpoints') or [])


class _BothGates:
    """Runs every supplied disclosure gate. All of them must pass.

    Neither gate replaces the other: the source-binding gate proves the packet
    matches what was authorised, and the registered gate proves an owner
    decision covers this exact source leaving the boundary.
    """

    def __init__(self, *gates):
        self.gates = gates

    def require_current(self, stage, packet, endpoint, model):
        for gate in self.gates:
            gate.require_current(stage, packet, endpoint, model)

    def require_request(self, provider, prompt, messages, output_type):
        for gate in self.gates:
            if hasattr(gate, 'require_request'):
                gate.require_request(provider, prompt, messages, output_type)


def _compose_disclosure(source_disclosure, *, ledger_engine, user,
                        assessment_id, revision, confirmation,
                        source_fingerprint, context_packet_hash, prompt,
                        provider, packet_source, session):
    """Compose every disclosure gate a dispatch must satisfy.

    **There is no switch that removes the assessment-bound requirement.** A real
    cloud dispatch happens only through the ``TokenHarbor`` adapter, so the
    requirement is bound to that adapter rather than to a flag: if the composed
    provider is a ``TokenHarbor`` instance, ``RegisteredObjectiveDisclosure`` is
    always added. Provider-enabled but authorisation-absent therefore holds
    closed instead of dispatching.

    A substituted adapter (the offline test double) is not a cloud dispatch and
    is returned with the source-binding gate alone, which is what keeps the test
    suite network-free without weakening the production path. The route builds
    its own provider, so this is not a caller-selectable escape.
    """
    if not isinstance(provider, CloudTokenHarbor):
        return source_disclosure

    from sitewise.project1.consent_authorization import ConsentAuthorization
    from sitewise.project1.database_identity import verify_workflow_database
    from sitewise.project1.disclosure import RegisteredObjectiveDisclosure
    from sitewise.project1.provider import ENDPOINT
    from sitewise.project1.synthetic_trial_registry import (
        PrivateSyntheticTrialRegistry,
    )

    registry = PrivateSyntheticTrialRegistry(
        ledger_engine, user.user_id,
        verify_private_instance=lambda s: verify_workflow_database(
            s, private_only=True))

    def current_source():
        projection = packet_source(session, user, assessment_id, revision)
        return {
            'owner_id': str(user.user_id),
            'assessment_id': str(projection['assessment_id']),
            'revision': projection['assessment_revision'],
            'confirmation_id': str(
                projection['confirmation']['confirmation_id']),
            'source_fingerprint': projection['source_fingerprint'],
        }

    def read_confirmation_snapshot():
        """The owner's recorded decision, read from their own confirmation."""
        from sitewise.repositories.m2_repository import SqlModelM2Repository
        row = SqlModelM2Repository(session).get_confirmation(
            UUID(str(confirmation['confirmation_id'])), user.user_id)
        return (row or {}).get('snapshot_json') if row else None

    # The operator no longer composes terms by hand: they are derived from the
    # permission the owner recorded when confirming. Deriving writes nothing,
    # so this route can observe a grant but never create one.
    consent = ConsentAuthorization(
        read_confirmation=read_confirmation_snapshot,
        current_source=current_source,
        owner_id=user.user_id, assessment_id=assessment_id, revision=revision,
        confirmation_id=str(confirmation['confirmation_id']),
        source_fingerprint=source_fingerprint,
        context_packet_hash=context_packet_hash,
        prompt=prompt, endpoint=ENDPOINT, model=provider.model)

    return _BothGates(
        source_disclosure,
        RegisteredObjectiveDisclosure(
            registry=registry, current_source=current_source,
            owner_id=user.user_id, assessment_id=assessment_id,
            revision=revision,
            confirmation_id=str(confirmation['confirmation_id']),
            source_fingerprint=source_fingerprint,
            context_packet_hash=context_packet_hash,
            prompt=prompt, endpoint=ENDPOINT, model=provider.model,
            consent=consent))


def _execution_block(*, runner, run_id, ledger_engine, actor_id,
                     reused: bool, context_packet_hash: str,
                     prompt_key: str = 'BDJ_OBJECTIVE',
                     model_provider: str | None = None) -> dict:
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.runs import latest_receipt

    receipt = None
    try:
        receipt = latest_receipt(ledger_engine, actor_id, run_id)
    except WorkflowHeld:
        receipt = None
    last = (runner.last_execution if runner is not None else None) or {}
    attempt_no, receipt_outcome, output_digest = receipt or (
        last.get('attempt_no'), last.get('receipt_outcome'),
        last.get('output_sha256'))

    # Provenance is reported from what the adapter actually did, not assumed. A
    # real POST sets ``dispatched``; nothing on this route sets it otherwise.
    # The persisted vocabulary (LIVE / SIMULATED / DETERMINISTIC) is mirrored
    # here so the response and the row cannot disagree.
    #
    # The last-resort label is the *adopted provider name*, not the simulator's
    # model name: a reused run read back from the ledger without a runner still
    # names the provider this route actually composes. ``model_provider`` is a
    # provider identity, so a model name never belonged in this field.
    dispatched = bool(last.get('dispatched', False))
    return {
        'execution_mode': (last.get('execution_mode')
                           or ('LIVE' if dispatched else 'SIMULATED')),
        'model_provider': (model_provider or last.get('model_provider')
                           or last.get('provider') or PROVIDER_NAME),
        'model_requested': last.get('model_requested'),
        'model_returned': last.get('model_returned'),
        'dispatched': dispatched,
        'run_id': str(run_id),
        'attempt_no': attempt_no,
        'prompt_version': last.get('prompt_version',
                                   PROMPTS[prompt_key].version),
        'prompt_sha256': last.get('prompt_sha256'),
        'request_sha256': last.get('request_sha256'),
        'output_sha256': output_digest or last.get('output_sha256'),
        'receipt_outcome': receipt_outcome,
        'reused': reused,
        'context_packet_hash': context_packet_hash,
    }


def _evaluation_envelope(*, packet, payload: ProposalRequest, rows, created,
                         execution, checkpoints) -> dict:
    confirmation = packet['confirmation']
    context_packet_hash = execution.get('context_packet_hash')
    proposals = []
    for row in rows:
        entry = {'proposal_id': str(row['proposal_id']),
                 'created': created.get(str(row['proposal_id']))}
        entry.update(_recommendation(row))
        entry['review_state'] = row['review_state']
        proposals.append(entry)
    return {
        'contract_version': 'bdj-objective-proposal/1',
        'assessment_id': str(packet['assessment_id']),
        'confirmation_id': str(confirmation.get('confirmation_id')),
        'confirmation_revision': payload.expected_revision,
        'context_id': str(payload.context_id),
        'context_packet_hash': context_packet_hash,
        'source_fingerprint': packet['source_fingerprint'],
        'outcome': 'reviewed',
        'proposal_count': len(proposals),
        'proposals': proposals,
        'execution': execution,
        'checkpoints': checkpoints,
        'finding_authority': 'CANDIDATE_ONLY',
        'status_contract': 'UNRECONCILED_PROPOSAL',
        'qj_execution': False,
        'qg_execution': False,
        **no_authority(),
    }


# --------------------------------------------------------------------------
# Readback
# --------------------------------------------------------------------------
@router.get('/assessments/{assessment_id}/objective-proposals/{proposal_id}')
def read_objective_proposal(
        assessment_id: UUID, proposal_id: UUID,
        expected_revision: Annotated[int, Query(ge=0)],
        context_id: UUID, user: Owner, session: SourceDatabase,
        packet_source: PacketSource, context_service: ContextService,
        engine: AuthorizedProposalStorageEngine, response: Response):
    """Owner-scoped authenticated readback, only while M2 and BCB are current."""
    response.headers['Cache-Control'] = 'no-store'
    _require_objective_contract()
    payload = ProposalRequest(expected_revision=expected_revision,
                              context_id=context_id)
    packet, _, context_packet = _current_inputs(
        assessment_id=assessment_id, payload=payload, user=user, session=session,
        packet_source=packet_source, context_service=context_service)
    row = _require_current_proposal(
        engine, proposal_id, user, assessment_id, payload, packet, context_packet)

    return {
        'contract_version': row['contract_version'],
        'proposal_id': str(row['proposal_id']),
        'assessment_id': str(row['assessment_id']),
        'confirmation_id': str(row['confirmation_id']),
        'confirmation_revision': row['confirmation_revision'],
        'context_id': str(row['context_id']),
        'context_packet_hash': row['context_packet_hash'],
        'source_fingerprint': row['source_fingerprint'],
        'recommendation': _recommendation(row),
        'execution_mode': row['execution_mode'],
        'validation_status': row['validation_status'],
        # Persisted execution provenance for this exact row. Additive: these
        # columns were already stored, and the list route is unchanged. They let
        # a reader report which model produced the text it is displaying instead
        # of inferring it from the surrounding page.
        'execution': {
            'execution_mode': row['execution_mode'],
            'model_provider': row.get('model_provider'),
            'model_requested': row.get('model_requested'),
            'model_returned': row.get('model_returned'),
            'prompt_version': row.get('prompt_version'),
            'validation_status': row['validation_status'],
        },
        'review_state': row['review_state'],
        'finding_authority': 'CANDIDATE_ONLY',
        'status_contract': 'UNRECONCILED_PROPOSAL',
        'qj_execution': False,
        'qg_execution': False,
        **no_authority(),
    }


@router.get('/assessments/{assessment_id}/objective-proposals')
def list_objective_proposals(
        assessment_id: UUID,
        expected_revision: Annotated[int, Query(ge=0)],
        context_id: UUID, user: Owner, session: SourceDatabase,
        packet_source: PacketSource, context_service: ContextService,
        engine: AuthorizedProposalStorageEngine, response: Response,
        limit: Annotated[int, Query(ge=1, le=100)] = 50):
    """Read current owner proposals via individually guarded adapter reads."""
    response.headers['Cache-Control'] = 'no-store'
    _require_objective_contract()
    payload = ProposalRequest(expected_revision=expected_revision,
                              context_id=context_id)
    packet, _, context_packet = _current_inputs(
        assessment_id=assessment_id, payload=payload, user=user, session=session,
        packet_source=packet_source, context_service=context_service)

    from sitewise.project1 import objective_adapter
    try:
        rows = objective_adapter.read_for_assessment(
            engine, assessment_id, user.user_id, expected_revision, limit)
    except AttributeError:
        raise _refused('PROPOSAL_READBACK_NOT_AVAILABLE', 503) from None
    except WorkflowHeld as exc:
        raise _held(exc, _EXECUTION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None

    current = []
    for row in rows:
        if (row.get('source_fingerprint') != packet.get('source_fingerprint') or
                str(row.get('context_id')) != str(context_id) or
                row.get('context_packet_hash') != context_packet.get('packet_hash')):
            continue
        entry = {'proposal_id': str(row['proposal_id'])}
        entry.update(_recommendation(row))
        entry['review_state'] = row['review_state']
        current.append(entry)
    return {
        'assessment_id': str(assessment_id),
        'context_id': str(context_id),
        'proposal_count': len(current),
        'proposals': current,
        'finding_authority': 'CANDIDATE_ONLY',
        'status_contract': 'UNRECONCILED_PROPOSAL',
        'qj_execution': False,
        'qg_execution': False,
        **no_authority(),
    }


# --------------------------------------------------------------------------
# Decision (approval) and admission
# --------------------------------------------------------------------------
@router.post('/assessments/{assessment_id}/objective-proposals/{proposal_id}/decision')
def decide_objective_proposal(
        assessment_id: UUID, proposal_id: UUID, payload: DecisionRequest,
        user: Owner, session: SourceDatabase, packet_source: PacketSource,
        context_service: ContextService, engine: AuthorizedProposalStorageEngine,
        response: Response):
    """Record the entrepreneur's APPROVED/REJECTED decision.

    Append-only and one decision per proposal: repeating the same decision is
    idempotent, a conflicting decision is refused. Approval is *not* admission —
    the ``admission`` block is computed separately and reports ``HELD`` while
    the uncertainty-link contract is incomplete.
    """
    response.headers['Cache-Control'] = 'no-store'
    _require_objective_contract()
    packet, _, context_packet = _current_inputs(
        assessment_id=assessment_id, payload=payload, user=user, session=session,
        packet_source=packet_source, context_service=context_service)
    _require_current_proposal(
        engine, proposal_id, user, assessment_id, payload, packet, context_packet)

    from sitewise.project1 import objective_adapter
    try:
        decided = objective_adapter.decide(
            engine, proposal_id, actor_id=user.user_id, decision=payload.decision,
            source_fingerprint=packet['source_fingerprint'],
            context_packet_hash=context_packet['packet_hash'], note=payload.note)
    except WorkflowHeld as exc:
        raise _held(exc, _DECISION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None

    return _decision_envelope(
        engine, proposal_id, user, assessment_id, payload, packet,
        context_packet, decided=decided)


@router.get('/assessments/{assessment_id}/objective-proposals/{proposal_id}/decision')
def read_objective_decision(
        assessment_id: UUID, proposal_id: UUID,
        expected_revision: Annotated[int, Query(ge=0)],
        context_id: UUID, user: Owner, session: SourceDatabase,
        packet_source: PacketSource, context_service: ContextService,
        engine: AuthorizedProposalStorageEngine, response: Response):
    """Owner-scoped decision readback with the current admission state."""
    response.headers['Cache-Control'] = 'no-store'
    _require_objective_contract()
    payload = ProposalRequest(expected_revision=expected_revision,
                              context_id=context_id)
    packet, _, context_packet = _current_inputs(
        assessment_id=assessment_id, payload=payload, user=user, session=session,
        packet_source=packet_source, context_service=context_service)
    row = _require_current_proposal(
        engine, proposal_id, user, assessment_id, payload, packet, context_packet)

    from sitewise.project1 import objective_adapter
    try:
        record = objective_adapter.read_decision(engine, proposal_id, user.user_id)
    except WorkflowHeld as exc:
        raise _held(exc, _DECISION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None
    if record is None:
        raise _refused('BDJ_OBJECTIVE_DECISION_NOT_FOUND', 404)

    return _decision_envelope(
        engine, proposal_id, user, assessment_id, payload, packet,
        context_packet, decided=None, record=record, review_state=row['review_state'])


@router.post(
    '/assessments/{assessment_id}/objective-proposals/{proposal_id}/admission')
def admit_objective_proposal(
        assessment_id: UUID, proposal_id: UUID, payload: AdmissionRequest,
        user: Owner, session: SourceDatabase, packet_source: PacketSource,
        context_service: ContextService, engine: AuthorizedProposalStorageEngine,
        response: Response):
    """Record the owner's admission that this gap is worth researching.

    This is the second, separate decision. ``APPROVED`` says "this objective is
    one I want"; ``ADMITTED`` says "the gap it cites is worth spending research
    on". Only the second may reach a QG eligibility check, and neither
    authorises QG execution on its own.

    Idempotent per proposal: a repeat returns the existing record with
    ``created = false`` rather than writing a second admission. The row is
    append-only and bound to a SHA-256 of the proposal content at admission time,
    so a later reader can prove the decision was about *this* objective.
    """
    response.headers['Cache-Control'] = 'no-store'
    _require_objective_contract()
    packet, _, context_packet = _current_inputs(
        assessment_id=assessment_id, payload=payload, user=user, session=session,
        packet_source=packet_source, context_service=context_service)
    _require_current_proposal(
        engine, proposal_id, user, assessment_id, payload, packet, context_packet)

    from sitewise.project1 import objective_admission
    try:
        record = objective_admission.record_admission(
            engine, proposal_id, actor_id=user.user_id, request_id=uuid4(),
            source_fingerprint=packet['source_fingerprint'],
            objective_id=getattr(payload, 'objective_id', None))
    except WorkflowHeld as exc:
        raise _held(exc, _ADMISSION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None

    return _admission_envelope(
        engine, proposal_id, user, assessment_id, payload, packet,
        context_packet, record=record)


@router.get(
    '/assessments/{assessment_id}/objective-proposals/{proposal_id}/admission')
def read_objective_admission(
        assessment_id: UUID, proposal_id: UUID,
        expected_revision: Annotated[int, Query(ge=0)],
        context_id: UUID, user: Owner, session: SourceDatabase,
        packet_source: PacketSource, context_service: ContextService,
        engine: AuthorizedProposalStorageEngine, response: Response):
    """Current admission state, derived from the record rather than asserted."""
    response.headers['Cache-Control'] = 'no-store'
    _require_objective_contract()
    payload = ProposalRequest(expected_revision=expected_revision,
                              context_id=context_id)
    packet, _, context_packet = _current_inputs(
        assessment_id=assessment_id, payload=payload, user=user, session=session,
        packet_source=packet_source, context_service=context_service)
    _require_current_proposal(
        engine, proposal_id, user, assessment_id, payload, packet, context_packet)
    return _admission_envelope(
        engine, proposal_id, user, assessment_id, payload, packet,
        context_packet, record=None)


def _admission_envelope(engine, proposal_id, user, assessment_id,
                        payload: ProposalRequest, packet, context_packet, *,
                        record=None) -> dict:
    from sitewise.project1 import objective_adapter

    try:
        admission = objective_adapter.admission_status(
            engine, proposal_id,
            source_fingerprint=packet['source_fingerprint'],
            actor_id=user.user_id)
    except WorkflowHeld as exc:
        raise _held(exc, _ADMISSION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None

    confirmation = packet['confirmation']
    return {
        'contract_version': 'bdj-objective-admission/1',
        'proposal_id': str(proposal_id),
        'assessment_id': str(assessment_id),
        'confirmation_id': str(confirmation.get('confirmation_id')),
        'confirmation_revision': payload.expected_revision,
        'context_id': str(payload.context_id),
        'context_packet_hash': context_packet['packet_hash'],
        'source_fingerprint': packet['source_fingerprint'],
        'admission': admission,
        'admission_created': None if record is None else bool(record['created']),
        'admission_id': None if record is None else record['admission_id'],
        'approval_is_not_admission': True,
        'finding_authority': 'CANDIDATE_ONLY',
        'qj_execution': False,
        'qg_execution': False,
        **no_authority(),
    }


def _decision_envelope(engine, proposal_id, user, assessment_id,
                       payload: ProposalRequest, packet, context_packet, *,
                       decided=None, record=None, review_state=None) -> dict:
    from sitewise.project1 import objective_adapter

    if record is None:
        try:
            record = objective_adapter.read_decision(engine, proposal_id, user.user_id)
        except WorkflowHeld as exc:
            raise _held(exc, _DECISION_HELD, 503,
                        'PROPOSAL_STORAGE_UNAVAILABLE') from None
        except Exception:
            raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None
    if record is None:
        raise _refused('BDJ_OBJECTIVE_DECISION_NOT_FOUND', 404)

    if review_state is None:
        try:
            current = objective_adapter.read(engine, proposal_id, user.user_id)
        except Exception:
            current = None
        review_state = (current or {}).get('review_state')

    try:
        admission = objective_adapter.admission_status(
            engine, proposal_id,
            source_fingerprint=packet['source_fingerprint'],
            actor_id=user.user_id)
    except WorkflowHeld as exc:
        raise _held(exc, _DECISION_HELD, 503, 'PROPOSAL_STORAGE_UNAVAILABLE') from None
    except Exception:
        raise _refused('PROPOSAL_STORAGE_UNAVAILABLE', 503) from None

    confirmation = packet['confirmation']
    return {
        'contract_version': 'bdj-objective-proposal/1',
        'proposal_id': str(proposal_id),
        'assessment_id': str(assessment_id),
        'confirmation_id': str(confirmation.get('confirmation_id')),
        'confirmation_revision': payload.expected_revision,
        'context_id': str(payload.context_id),
        'context_packet_hash': context_packet['packet_hash'],
        'source_fingerprint': packet['source_fingerprint'],
        'decision': record['decision'],
        'decision_id': str(record['decision_id']),
        'decided_at': record.get('decided_at'),
        'note': record.get('note'),
        'decision_created': None if decided is None else bool(decided['created']),
        'review_state': review_state,
        'admission': admission,
        'finding_authority': 'CANDIDATE_ONLY',
        'status_contract': 'UNRECONCILED_PROPOSAL',
        'qj_execution': False,
        'qg_execution': False,
        **no_authority(),
    }


# ---------------------------------------------------------------------------
# N04-C Decision 1: versioned objective re-admission
# ---------------------------------------------------------------------------
class ReadmissionRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    confirmation_id: UUID


@router.post('/assessments/{assessment_id}/objective-admissions/{admission_id}/readmit')
def readmit_objective(assessment_id: UUID, admission_id: UUID,
                      payload: ReadmissionRequest, user: Owner, response: Response,
                      engine: AuthorizedProposalStorageEngine,
                      context_service: Annotated[object, Depends(
                          get_objective_context_service)]):
    """Bind an already-approved objective to the workflow's current context.

    This is the legitimate answer to "the snapshot moved". It creates a new
    admission row over the same approved proposal, with an explicit supersession
    edge; it never edits the historical admission and never authors a proposal.

    Only the owner may do it, and only against the context the business-context
    service currently calls current — not against whichever snapshot happens to
    make an admission lookup pass.
    """
    response.headers['Cache-Control'] = 'no-store'
    from sitewise.project1.objective_readmission import readmit

    actor = user.user_id
    # The business-context service takes a ContextActor, not a bare id: it needs
    # the role to scope the read as well as the owner.
    context_actor = ContextActor(user.user_id, rbac.canonical_role(user.role))
    try:
        status = context_service.status(assessment_id, payload.confirmation_id,
                                        context_actor)
    except ContextOperationHeld as exc:
        raise HTTPException(503, detail={'code': exc.code,
                                         'message': 'The business context could '
                                                    'not be verified.'}) from None
    if status.get('source_is_current') is not True:
        raise HTTPException(409, detail={
            'code': 'BCB_SOURCE_NOT_CURRENT',
            'message': 'The confirmation has no current, reproducible context.'})
    if status.get('context_compatible') is False:
        raise HTTPException(409, detail={
            'code': 'BCB_CONTEXT_NOT_REPRODUCIBLE',
            'message': 'The current context does not reproduce under this build.'})
    context_id = status.get('context_id')
    if not context_id:
        raise HTTPException(409, detail={
            'code': 'BCB_CONTEXT_NOT_PERSISTED',
            'message': 'No persisted business context exists to bind to.'})
    try:
        read = context_service.retrieve(assessment_id, context_id, context_actor)
    except ContextOperationHeld as exc:
        raise HTTPException(409, detail={'code': exc.code,
                                         'message': 'The current context could '
                                                    'not be read.'}) from None
    packet_hash = (read.get('packet') or {}).get('packet_hash')
    if not packet_hash:
        raise HTTPException(409, detail={
            'code': 'BCB_CONTEXT_HASH_UNAVAILABLE',
            'message': 'The current context carries no packet hash.'})

    try:
        result = readmit(engine, actor_id=actor, assessment_id=assessment_id,
                         admission_id=admission_id,
                         confirmation_id=payload.confirmation_id,
                         context_id=context_id,
                         context_packet_hash=packet_hash)
    except WorkflowHeld as exc:
        raise _held(exc, {}, 409, 'BDJ_OBJECTIVE_READMISSION_REFUSED') from None
    return {**result, 'confirmation_id': str(payload.confirmation_id),
            'qg_execution_authorized': False, 'fielding_authorized': False,
            'publication_authorized': False, 'scientifically_accepted': False}
