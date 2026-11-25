"""Authenticated candidate review surface. No model or approval HTTP endpoint."""
from typing import Annotated, Callable
from functools import lru_cache
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import text, create_engine
from sqlalchemy.engine import make_url
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.db.m2_session import get_m2_db, m2_session_for
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur, require_admin_mfa
from sitewise.project1.bdj import BDJEngine, load_rules
from sitewise.project1.ruleset_resolver import resolve_ruleset
from sitewise.project1.contracts import WorkflowHeld, no_authority
from sitewise.project1.model_assisted import run_model_assisted
from sitewise.project1.projection import M2SourceProjection
from sitewise.project1.provider import configured_runner
from sitewise.project1.key_custody import LocalKeyCustody
from sitewise.project1.result_store import results_for_assessment
from sitewise.repositories.m2_repository import SqlModelM2Repository
from sitewise.services.m2_service import M2Service
from sitewise.core.exceptions import ConflictError


def configuration_gate(session: Annotated[Session, Depends(get_m2_db)]):
    from sitewise.project1.database_identity import verify_workflow_database
    if not settings.project1_workflow_enabled:
        raise HTTPException(503, detail={'code': 'WORKFLOW_CONFIGURATION_REQUIRED'})
    try:
        verify_workflow_database(session)
    except WorkflowHeld:
        raise
    except (ValueError, SQLAlchemyError):
        raise HTTPException(503, detail={'code': 'SOURCE_STORAGE_UNAVAILABLE'}) from None
    finally:
        session.rollback()


router = APIRouter(dependencies=[Depends(configuration_gate)])
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
Admin = Annotated[AuthenticatedUser, Depends(require_admin_mfa)]


def get_workflow_source_db(user: Owner):
    # The same owner-bound, transaction-rebinding adapter used by existing M2
    # services. Projection reads roll back; subsequent revision rechecks must
    # retain the authenticated actor rather than silently lose RLS visibility.
    with m2_session_for(user.user_id) as session:
        yield session


Database = Annotated[Session, Depends(get_workflow_source_db)]


def model_assisted_gate():
    """Second gate: the model-assisted path needs its own configuration.

    ``configuration_gate`` already requires the workflow flag and the Dss
    principal. This one additionally requires an enabled provider and a
    non-empty adopted rules version/hash/receipt. A partial configuration is a
    hold, not a reason to dispatch under unknown terms.
    """
    if settings.project1_synthetic_bdj_trial_enabled:
        from sitewise.project1.database_identity import configured_target
        if (configured_target()[1] is None or not settings.m2_protected_identity_enabled
                or not settings.tokenharbor_enabled):
            raise HTTPException(503, detail={'code': 'BDJ_TRIAL_DISABLED'})
        return
    if not (settings.tokenharbor_enabled and _any_ruleset_adopted()):
        raise HTTPException(503, detail={
            'code': 'MODEL_ASSISTED_NOT_CONFIGURED',
            'message': 'Model-assisted review is waiting for its required setup.'})


def _any_ruleset_adopted() -> bool:
    """Is *some* instrument family fully adopted?

    The gate has no packet, so it cannot know which instrument is about to be
    reviewed. It therefore answers only the coarse question; the per-instrument
    decision is made later by ``resolve_ruleset``, which refuses an unadopted,
    unsupported or hash-mismatched family *before* the authorization lookup and
    before any dispatch. Requiring the global M2V1 trio here would refuse every
    M2V2 assessment on an environment that deliberately pins only M2V2, which is
    a configuration-shape assumption, not a safety property.
    """
    families = (
        (settings.project1_rules_version, settings.project1_rules_sha256,
         settings.project1_rules_adoption_receipt),
        (settings.project1_rules_m2v1_version, settings.project1_rules_m2v1_sha256,
         settings.project1_rules_m2v1_adoption_receipt),
        (settings.project1_rules_m2v2_version, settings.project1_rules_m2v2_sha256,
         settings.project1_rules_m2v2_adoption_receipt),
    )
    return any(all(part for part in family) for family in families)


def get_packet_source():
    """Indirection so a test can supply a synthetic packet without a Dss name."""
    return source


@lru_cache(maxsize=2)
def runtime_engine(secret):
    return create_engine(secret, hide_parameters=True, pool_pre_ping=True)


def get_runtime_engine():
    secret = settings.project1_runtime_database_url.get_secret_value()
    if not secret:
        raise HTTPException(503, detail={
            'code': 'MODEL_ASSISTED_NOT_CONFIGURED',
            'message': 'Model-assisted review is waiting for its required setup.'})
    return runtime_engine(secret)


def get_runner_factory():
    """Server composition only; a web caller cannot choose a provider or key."""
    return configured_runner


PacketSource = Annotated[Callable, Depends(get_packet_source)]
RuntimeEngine = Annotated[object, Depends(get_runtime_engine)]
RunnerFactory = Annotated[Callable, Depends(get_runner_factory)]


def source(session, user, assessment_id, revision, *, include_inventory=False):
    try:
        from sitewise.project1.database_identity import verify_workflow_database
        verify_workflow_database(session)
        # Explicit owner SQL checks remain necessary even if existing RLS grants deny.
        repo = SqlModelM2Repository(session)
        confirmation = repo.latest_confirmation(assessment_id, user.user_id)
        if confirmation is None:
            raise ConflictError('Confirm the current M2 declarations before BDJ evaluation.')
        with M2Service(repo).locked_confirmed_source(assessment_id, user.user_id,
                confirmation_id=confirmation['id'], expected_revision=revision) as confirmed:
            receipt = {k: str(confirmed[k]) for k in ('confirmation_id','snapshot_digest')}
        # The projector dispatches internally on the instrument version, so one
        # entry point serves both M2 source families without adding repository
        # calls here (and without changing this function's existing contract).
        projected = M2SourceProjection(repo).read(
            assessment_id, user.user_id, revision, include_inventory=include_inventory)
        # Keep the original envelope untouched for its fingerprint check.
        packet = dict(projected['projection']) if include_inventory else projected
        if not packet['confirmed']:
            raise ConflictError('The M2 confirmation changed before BDJ evaluation.')
        packet['confirmation'] = receipt
        from sitewise.project1.contracts import digest
        packet['source_fingerprint'] = digest({k:v for k,v in packet.items() if k != 'source_fingerprint'})
        if include_inventory:
            # Definitions are server-read, never a client-supplied codebook. The
            # versioned envelope does not alter the historical fingerprint.
            from sitewise.project1.projection import bind_bdj_inventory_to_confirmation
            definitions = repo.list_items(UUID(packet['instrument_id']))
            envelope = bind_bdj_inventory_to_confirmation(projected, packet, item_definitions=definitions)
            # Both the inventory and definition read happened after the first
            # confirmation lock was released. Refuse a concurrent source edit.
            if source(session, user, assessment_id, revision)['source_fingerprint'] != packet['source_fingerprint']:
                raise ConflictError('The confirmed M2 source changed while reading the item inventory.')
            return envelope
        return packet
    except SQLAlchemyError:
        session.rollback()
        raise HTTPException(503, detail={'code': 'SOURCE_STORAGE_UNAVAILABLE',
            'message': 'Your business details could not be loaded for review.'}) from None


@router.get('/assessments/{assessment_id}/source')
def read_source(assessment_id: UUID, expected_revision: Annotated[int, Query(ge=0)],
                user: Owner, session: Database, response: Response,
                include_inventory: bool = False):
    response.headers['Cache-Control'] = 'no-store'
    return source(session, user, assessment_id, expected_revision, include_inventory=include_inventory)


class ReviewRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    expected_revision: int = Field(ge=0)


@router.get('/setup')
def setup_status(user: Owner, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    return {'outcome': 'held', 'message':
            'Your questionnaire preview needs a saved M2 record before business review.',
            'workspace_m2_binding_available': False, **no_authority()}


@router.post('/assessments/{assessment_id}/business-understanding')
def business_understanding(assessment_id: UUID, payload: ReviewRequest,
                           user: Owner, session: Database, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    packet = source(session, user, assessment_id, payload.expected_revision)
    try:
        # Per instrument, not the global default: the deterministic review must
        # never evaluate an M2V2 packet against the M2V1 catalogue.
        rules = resolve_ruleset(packet.get('instrument_version', '')).module
    except WorkflowHeld:
        rules = None
    # Deliberately no cloud runner here until durable storage/disclosure adapters
    # and the shared status register have an adopted integration contract.
    result = BDJEngine(rules).review(packet, recheck_current=lambda:
        source(session, user, assessment_id, payload.expected_revision)['source_fingerprint'])
    result['message'] = {
        'held': 'Your business details are available. The consistency review is waiting for its required setup.',
        'reviewed': 'Your details have been checked. Please review any suggested clarifications.',
        'rejected': 'The suggested review could not be validated. Your answers are unchanged.',
        'stale': 'Your business details changed. Review the latest version first.',
    }[result['outcome']]
    return result


@router.post('/assessments/{assessment_id}/business-understanding/model-assisted',
             dependencies=[Depends(model_assisted_gate)])
def business_understanding_model_assisted(
        assessment_id: UUID, payload: ReviewRequest, user: Owner, session: Database,
        response: Response, packet_source: PacketSource, runtime: RuntimeEngine,
        runner_factory: RunnerFactory):
    """A second, explicitly labelled entry point; the deterministic one is untouched.

    Success is a candidate result, never authority: the response always carries
    ``finding_authority='CANDIDATE_ONLY'``, ``status_contract`` and the all-false
    ``no_authority()`` spread.
    """
    response.headers['Cache-Control'] = 'no-store'
    return execute_model_assisted_source(session=session, user=user,
        assessment_id=assessment_id, revision=payload.expected_revision,
        packet_source=packet_source, runtime=runtime, runner_factory=runner_factory)


def execute_model_assisted_source(*, session, user, assessment_id, revision,
                                  packet_source, runtime, runner_factory):
    """Shared by both existing BDJ routes; selection is server-only and default-off."""
    if settings.project1_synthetic_bdj_trial_enabled:
        from sitewise.services.bdj_synthetic_execution import execute_registered_trial
        return execute_registered_trial(session=session, user=user,
            assessment_id=assessment_id, revision=revision, packet_source=packet_source,
            runtime=runtime, runner_factory=runner_factory)
    packet = packet_source(session, user, assessment_id, revision)
    return run_model_assisted(packet=packet, actor_id=user.user_id,
        runtime_engine=runtime, runner_factory=runner_factory,
        current_fingerprint=lambda: packet_source(
            session, user, assessment_id, revision)['source_fingerprint'])


@router.get('/assessments/{assessment_id}/results')
def business_understanding_results(
        assessment_id: UUID, user: Owner, runtime: RuntimeEngine, response: Response,
        limit: Annotated[int, Query(ge=1, le=100)] = 50):
    """Activity History V1.1: the saved model-assisted results for one assessment.

    Additive to the V1 activity feed at ``/m2/assessments/{id}/activity``, which
    is untouched. This route reads *persisted* rows, so it is the only endpoint
    that can prove a result survived a restart.

    What it deliberately does not return: ``result_payload`` (an internal
    column whose quote spans are redacted at write, but which is still not part
    of the response contract), any ``source_refs``, and any
    ``bdj_raw_responses`` column. The projection allow-list is enforced in
    ``results_for_assessment``; the sentinel test is
    ``test_history_projection_excludes_the_quote_sentinel``.

    Every row carries ``finding_authority='candidate_only'`` and the response
    spreads ``no_authority()``, so a saved result can never read as approval.
    """
    response.headers['Cache-Control'] = 'no-store'
    rows = results_for_assessment(runtime, user.user_id, assessment_id, limit,
                                  payload_custody=LocalKeyCustody())
    return {
        'assessment_id': str(assessment_id),
        'result_count': len(rows),
        'results': [{**row, 'finding_authority': 'CANDIDATE_ONLY'} for row in rows],
        'status_contract': 'UNRECONCILED_PROPOSAL',
        **no_authority(),
    }


@router.get('/technical-audit')
def technical_audit(user: Admin, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    # Metadata only; no key presence, credentials, provider bodies or raw M2 text.
    return {'status_contract': 'UNRECONCILED_PROPOSAL',
            'source_contract': 'project1-m2-projection/1-candidate',
            'cloud_http_execution': False, 'automatic_migrations': False,
            'rules_configured': bool(settings.project1_rules_version),
            'unresolved': ['shared_status_adoption', 'BCB_live_authority_adapters',
                           'approved_bank_register', 'provider_disclosure',
                           'restricted_database_grants'], **no_authority()}


@lru_cache(maxsize=1)
def audit_engine(secret):
    return create_engine(secret, hide_parameters=True, pool_pre_ping=True)


@router.get('/technical-audit/runs/{run_id}')
def audit_run(run_id: UUID, user: Admin, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    # Separate read-only metadata principal. The model/runtime principal is not
    # reused for global staff audit and has no endpoint for issuing approvals.
    secret = settings.project1_audit_database_url.get_secret_value()
    try:
        url = make_url(secret)
        app_url = make_url(settings.database_url)
        if (url.get_backend_name() != 'postgresql' or url.username != 'p1ai_audit' or
                (url.host,url.port,url.database) != (app_url.host,app_url.port,app_url.database)):
            raise ValueError
        with Session(audit_engine(secret)) as session:
            identity = session.execute(text('SELECT current_user,rolsuper,rolbypassrls '
                'FROM pg_roles WHERE rolname=current_user')).one()
            if tuple(identity) != ('p1ai_audit',False,False):
                raise ValueError
            rows = session.execute(text('SELECT a.attempt_no,a.stage,a.prompt_version,'
                'a.prompt_hash,a.request_hash,a.reserved_at,r.outcome,r.output_digest,r.created_at '
                'FROM project1_ai.attempts a LEFT JOIN project1_ai.attempt_receipts r '
                'ON r.run_id=a.run_id AND r.attempt_no=a.attempt_no '
                'WHERE a.run_id=:id ORDER BY a.attempt_no'), {'id':run_id}).mappings().all()
            return {'run_id':run_id, 'attempts':[dict(row) for row in rows],
                    'missing_receipt_means':'unknown_outcome_do_not_redispatch', **no_authority()}
    except (ValueError, SQLAlchemyError):
        raise HTTPException(503,detail={'code':'AUDIT_STORAGE_UNAVAILABLE'}) from None


# BDJ objective proposals are additive and remain fail-closed until their
# objective-specific disclosure and attempt-ledger composition is approved.
from sitewise.api.v1.project1_objective_proposals import router as objective_proposals_router
router.include_router(objective_proposals_router)

# Stage 4 preview of the governed Q01-Q13 core questionnaire. Read-only and
# explicitly non-authoritative: it populates wording from the owner's own M2
# declarations and never claims an approval, a bank equivalence or fielding.
from sitewise.api.v1.project1_stage4_preview import router as stage4_preview_router
router.include_router(stage4_preview_router)

# Stage 5 composed questionnaire: the governed core plus every additional
# question that is already approved and eligible. Same composition service as
# the Stage 4 preview, so the two stages cannot describe different documents.
# Read-only; adds no approval verb and grants no authority.
from sitewise.api.v1.project1_stage5_composed import router as stage5_composed_router
router.include_router(stage5_composed_router)
