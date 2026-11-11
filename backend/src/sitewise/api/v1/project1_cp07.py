"""Default-off staging bridge. No BCB, QJ, QG, LLM or fielding activation."""
from functools import lru_cache
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import create_engine
from sqlalchemy.engine import make_url
from sqlalchemy.exc import ArgumentError, DBAPIError
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.db.session import engine, get_db
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.repositories.m2_repository import SqlModelM2Repository
from sitewise.repositories.uc_decision_gateway import UcDecisionGateway
from sitewise.repositories.uc_history_repository import UcHistoryRepository
from sitewise.services.m2_service import M2Service


# Additional read-only verification target. The existing decision gateway's
# allowed targets are unchanged and it rejects this private test port.
READ_STAGE_TARGETS = UcDecisionGateway.ALLOWED_STAGE_TARGETS | {
    ("project1_cp07_tests", 55437, 18),
}


def require_stage_configuration() -> None:
    """Check before auth can provision a profile or open an application session."""
    try:
        url = make_url(settings.database_url)
    except (ArgumentError, ValueError):
        raise HTTPException(503, detail={"code": "CP07_STAGE_CONFIGURATION_REQUIRED"}) from None
    if (not settings.project1_cp07_enabled or
            url.get_backend_name() != "postgresql" or
            url.host not in {"127.0.0.1", "localhost", "::1"} or
            (url.database, url.port) not in {(db, port) for db, port, _ in READ_STAGE_TARGETS}):
        raise HTTPException(503, detail={"code": "CP07_STAGE_CONFIGURATION_REQUIRED"})


router = APIRouter(dependencies=[Depends(require_stage_configuration)])
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
Database = Annotated[Session, Depends(get_db)]


def verify_stage_database(session: Session) -> None:
    row = session.execute(UcDecisionGateway.IDENTITY_SQL).mappings().one()
    identity = (row["db_name"], int(row["server_port"]), int(row["version_num"]) // 10000)
    if identity not in READ_STAGE_TARGETS:
        raise HTTPException(503, detail={"code": "CP07_STAGE_DATABASE_REQUIRED"})


@router.get("/assessments/{assessment_id}/confirmed-source")
def confirmed_source(assessment_id: UUID, confirmation_id: UUID,
                     expected_revision: Annotated[int, Query(ge=0)],
                     user: Owner, session: Database, response: Response):
    response.headers["Cache-Control"] = "no-store"
    try:
        verify_stage_database(session)
        return M2Service(SqlModelM2Repository(session)).read_confirmed_source(
            assessment_id, user.user_id, confirmation_id=confirmation_id,
            expected_revision=expected_revision,
        )
    except DBAPIError as exc:
        raise HTTPException(503, detail={"code": "CP07_SOURCE_STORAGE_UNAVAILABLE"}) from exc
    finally:
        session.rollback()


@router.get("/uncertainties/{version_id}/history")
def uncertainty_history(version_id: UUID, user: Owner, session: Database, response: Response,
                        after_event_no: Annotated[int, Query(ge=0)] = 0):
    response.headers["Cache-Control"] = "no-store"
    try:
        verify_stage_database(session)
        return UcHistoryRepository(session).read_version(
            version_id, user.user_id, after_event_no=after_event_no)
    except DBAPIError as exc:
        raise HTTPException(503, detail={"code": "CP07_UC_READ_UNAVAILABLE"}) from exc
    finally:
        session.rollback()


class DecisionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    event_id: UUID
    candidate_version_id: UUID
    action: Literal["CONFIRMED", "REJECTED", "DEFERRED", "WITHDRAWN"]
    receipt: str = Field(min_length=1, max_length=2000, pattern=r"\S")


@lru_cache(maxsize=1)
def _decision_engine(url: str):
    return create_engine(url, pool_pre_ping=True, hide_parameters=True)


def decision_session():
    require_stage_configuration()
    secret = settings.project1_cp07_uc_database_url.get_secret_value()
    if not secret:
        raise HTTPException(503, detail={"code": "CP07_RESTRICTED_UC_CONNECTION_REQUIRED"})
    try:
        url, app_url = make_url(secret), engine.url
    except (ArgumentError, ValueError):
        raise HTTPException(503, detail={"code": "CP07_RESTRICTED_UC_CONNECTION_REQUIRED"}) from None
    if (url.get_backend_name() != "postgresql" or
            url.username != UcDecisionGateway.REQUIRED_DB_ROLE or
            (url.host, url.port, url.database) !=
            (app_url.host, app_url.port, app_url.database)):
        raise HTTPException(503, detail={"code": "CP07_RESTRICTED_UC_CONNECTION_REQUIRED"})
    with Session(_decision_engine(secret)) as session:
        yield session


@router.post("/uncertainty-decisions")
def record_decision(payload: DecisionRequest, user: Owner,
                    session: Annotated[Session, Depends(decision_session)], response: Response):
    response.headers["Cache-Control"] = "no-store"
    try:
        uncertainty_id = UcDecisionGateway(session).record_decision(
            verified_actor_user_id=user.user_id, event_id=payload.event_id,
            candidate_version_id=payload.candidate_version_id,
            action=payload.action, receipt=payload.receipt,
        )
        return {"event_id": payload.event_id, "action": payload.action,
                "confirmed_uncertainty_id": uncertainty_id,
                "qj_handoff_authorized": False}
    except DBAPIError as exc:
        # Do not echo SQL, receipt, source text or database credentials.
        session.rollback()
        code = getattr(exc.orig, "pgcode", None)
        status = 403 if code == "42501" else 409 if code == "P0001" else 503
        raise HTTPException(status, detail={"code": "UC_DECISION_DENIED"}) from exc
    except (PermissionError, RuntimeError) as exc:
        raise HTTPException(503, detail={"code": "CP07_UC_IDENTITY_DENIED"}) from exc
