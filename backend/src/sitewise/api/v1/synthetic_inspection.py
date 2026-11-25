"""No participation/consent/answer writes: local developer inspection only."""
from typing import Annotated
from uuid import UUID
from fastapi import APIRouter,Depends,HTTPException,Response
from sqlalchemy.engine import make_url
from sitewise.core.config import settings
from sitewise.dependencies import AuthenticatedUser,get_active_user
from sitewise.domain.cq_runtime import CqRefused

router=APIRouter()
Actor=Annotated[AuthenticatedUser,Depends(get_active_user)]


def get_inspector():
    if not settings.cq_synthetic_preview_enabled:
        raise HTTPException(404,detail={'code':'SYNTHETIC_PREVIEW_DISABLED'})
    raw=settings.ee01_database_url.get_secret_value();u=make_url(raw) if raw else None
    # The target check is kept in full -- loopback only, the restricted reporting
    # login only, psycopg2 only -- but the database is compared against the
    # *declared* EE-01 target rather than the literal 'Dss'. Pinning 'Dss' made
    # this route reject the very DSN that `customer_questionnaire.get_ee01_service`
    # accepts, so the same credential was authorised on one route and refused on
    # the other, and the whole synthetic surface was unreachable on any cluster
    # whose database is not named 'Dss' (DD-105).
    if (not u or u.host not in ('localhost','127.0.0.1','::1')
            or not settings.ee01_expected_database
            or u.database!=settings.ee01_expected_database
            or u.username!='p1_ee01_runtime' or u.drivername!='postgresql+psycopg2'):
        raise HTTPException(503,detail={'code':'SYNTHETIC_TARGET_UNVERIFIED'})
    from sitewise.api.v1.customer_questionnaire import _ee01_engine
    from sitewise.services.synthetic_inspection_service import SyntheticInspectionService
    return SyntheticInspectionService(_ee01_engine(raw))


def respond(response,operation):
    response.headers['Cache-Control']='no-store'
    try:return operation()
    except CqRefused as exc:
        raise HTTPException(exc.status,detail={'code':exc.code},headers={'Cache-Control':'no-store'}) from exc


@router.get('/developer-imports')
def runs(user:Actor,response:Response,service=Depends(get_inspector)):
    return respond(response,lambda:service.runs(user.user_id))


@router.get('/developer-imports/{run_id}')
def inspect_run(run_id:UUID,user:Actor,response:Response,service=Depends(get_inspector)):
    return respond(response,lambda:service.inspect(user.user_id,run_id))
