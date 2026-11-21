"""Authenticated CQ application API; production fielding is default-held."""
from typing import Annotated
from functools import lru_cache
from uuid import UUID

from fastapi import APIRouter,Depends,HTTPException,Response
from pydantic import BaseModel,ConfigDict,Field

from sitewise.core.config import settings
from sitewise.dependencies import AuthenticatedUser,get_active_user,require_entrepreneur
from sitewise.domain.cq_runtime import CqRefused

router=APIRouter()
Actor=Annotated[AuthenticatedUser,Depends(get_active_user)]
Owner=Annotated[AuthenticatedUser,Depends(require_entrepreneur)]


def get_cq_authority():
    from sitewise.repositories.cq_repository import UnverifiedCqAuthority
    return UnverifiedCqAuthority()


def get_cq_service(authority=Depends(get_cq_authority)):
    if not settings.cq_runtime_enabled:
        raise HTTPException(503,detail={'code':'PRODUCTION_FIELDING_HOLD','message':'Customer questionnaires are not activated.'})
    from sitewise.db.m2_session import get_m2_engine
    from sitewise.repositories.cq_repository import PostgresCqStore
    from sitewise.services.customer_questionnaire_service import CustomerQuestionnaireService
    return CustomerQuestionnaireService(PostgresCqStore(get_m2_engine()),authority)


Service=Annotated[object,Depends(get_cq_service)]


def get_cq_withdrawal_service():
    # Withholding new participation must not trap a respondent's consent.
    from sitewise.db.m2_session import get_m2_engine
    from sitewise.repositories.cq_repository import PostgresCqStore,UnverifiedCqAuthority
    from sitewise.services.customer_questionnaire_service import CustomerQuestionnaireService
    return CustomerQuestionnaireService(PostgresCqStore(get_m2_engine()),UnverifiedCqAuthority())


WithdrawalService=Annotated[object,Depends(get_cq_withdrawal_service)]


def get_ee01_service():
    from sqlalchemy.engine import make_url
    from sitewise.services.ee01_service import Ee01Service
    raw=settings.ee01_database_url.get_secret_value()
    if not raw:
        raise HTTPException(503,detail={'code':'EE01_DATABASE_TARGET_UNVERIFIED'})
    url=make_url(raw)
    if url.drivername!='postgresql+psycopg2' or url.database!=settings.m2_expected_database or url.username!='p1_ee01_runtime':
        raise HTTPException(503,detail={'code':'EE01_DATABASE_TARGET_UNVERIFIED'})
    return Ee01Service(_ee01_engine(raw))


@lru_cache(maxsize=2)
def _ee01_engine(raw):
    from sqlalchemy import create_engine
    return create_engine(raw,hide_parameters=True,pool_pre_ping=True)


Ee01=Annotated[object,Depends(get_ee01_service)]


@router.get('/assessments/{assessment_id}/campaigns/{campaign_id}/measurements/{snapshot_id}')
def measurement_readback(assessment_id:UUID,campaign_id:UUID,snapshot_id:UUID,user:Owner,service:Ee01,response:Response):
    return call(response,lambda:service.read(user.user_id,assessment_id,campaign_id,snapshot_id))


@router.get('/assessments/{assessment_id}/campaigns/{campaign_id}/measurements/{snapshot_id}/report-readback')
def measurement_report_readback(assessment_id:UUID,campaign_id:UUID,snapshot_id:UUID,user:Owner,service:Ee01,response:Response):
    return call(response,lambda:service.report_readback(user.user_id,assessment_id,campaign_id,snapshot_id))


def call(response,operation):
    response.headers['Cache-Control']='no-store'
    try: return operation()
    except CqRefused as exc:
        raise HTTPException(exc.status,detail={'code':exc.code,'message':'The questionnaire operation could not be authorized or completed.'},headers={'Cache-Control':'no-store'}) from exc
    except (KeyError,TypeError,ValueError) as exc:
        raise HTTPException(503,detail={'code':'CQ_CONTRACT_UNAVAILABLE','message':'The versioned questionnaire contract is unavailable.'},headers={'Cache-Control':'no-store'}) from exc


class Strict(BaseModel): model_config=ConfigDict(extra='forbid')
class Campaign(Strict): release_id:UUID
class Participant(Strict): respondent_id:UUID
class Start(Strict):
    campaign_id:UUID
    manifest_hash:str=Field(pattern=r'^[0-9a-f]{64}$')
    locale:str=Field(pattern=r'^(EN|BM)$')
class Version(Strict):
    expected_revision:int=Field(ge=0,strict=True)
    manifest_hash:str=Field(pattern=r'^[0-9a-f]{64}$')
class Consent(Version):
    request_id:UUID
    consented:bool=Field(strict=True)
    consent_version:str=Field(min_length=1,max_length=100)
class Exposure(Version): kind:str=Field(max_length=20)
class Present(Version): edit_slot_id:str|None=Field(default=None,max_length=100)
class Answer(Version):
    request_id:UUID
    display_id:UUID
    slot_id:str=Field(max_length=100)
    value:str|list[str]|None
class Submit(Version): request_id:UUID
class Rendered(Version): display_id:UUID


@router.get('/availability')
def availability(user:Actor,response:Response):
    response.headers['Cache-Control']='no-store'
    return {'contract_version':'cq-availability/1','state':'held','code':'PRODUCTION_FIELDING_HOLD',
        'message':'Customer participation requires an approved instrument, bank, scientific policy, consent and fielding authorization.',
        'production_fielding_authorized':False}


@router.get('/invitations')
def invitations(user:Actor,response:Response,authority=Depends(get_cq_authority)):
    if not settings.cq_runtime_enabled:
        response.headers['Cache-Control']='no-store'
        return {'contract_version':'cq-invitations/1','state':'held','code':'PRODUCTION_FIELDING_HOLD','invitations':[]}
    return call(response,lambda:get_cq_service(authority).invitations(user.user_id))


@router.get('/manifests/{release_id}')
def manifest(release_id:UUID,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.manifest(release_id,user.user_id))


@router.post('/assessments/{assessment_id}/campaign')
def campaign(assessment_id:UUID,body:Campaign,user:Owner,service:Service,response:Response):
    return call(response,lambda:service.create_campaign(assessment_id,body.release_id,user.user_id))


@router.post('/campaigns/{campaign_id}/participants')
def participant(campaign_id:UUID,body:Participant,user:Owner,service:Service,response:Response):
    return call(response,lambda:service.invite(campaign_id,body.respondent_id,user.user_id))


@router.post('/sessions')
def start(body:Start,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.start(body.campaign_id,body.manifest_hash,body.locale,user.user_id))


@router.get('/sessions/{session_id}')
def read(session_id:UUID,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.read(session_id,user.user_id))


@router.post('/sessions/{session_id}/consent')
def consent(session_id:UUID,body:Consent,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.consent(session_id,user.user_id,revision=body.expected_revision,
        manifest_hash=body.manifest_hash,request_id=body.request_id,consented=body.consented,version=body.consent_version))


@router.post('/sessions/{session_id}/stimuli')
def expose(session_id:UUID,body:Exposure,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.expose(session_id,user.user_id,revision=body.expected_revision,
        manifest_hash=body.manifest_hash,kind=body.kind))


@router.post('/sessions/{session_id}/presentations')
def present(session_id:UUID,body:Present,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.present(session_id,user.user_id,revision=body.expected_revision,
        manifest_hash=body.manifest_hash,edit_slot_id=body.edit_slot_id))


@router.post('/sessions/{session_id}/answers')
def answer(session_id:UUID,body:Answer,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.answer(session_id,user.user_id,revision=body.expected_revision,
        manifest_hash=body.manifest_hash,request_id=body.request_id,display_id=body.display_id,slot_id=body.slot_id,value=body.value))


@router.post('/sessions/{session_id}/submit')
def submit(session_id:UUID,body:Submit,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.submit(session_id,user.user_id,revision=body.expected_revision,
        manifest_hash=body.manifest_hash,request_id=body.request_id))


@router.post('/sessions/{session_id}/pause')
def pause(session_id:UUID,body:Submit,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.lifecycle(session_id,user.user_id,action='PAUSE',
        revision=body.expected_revision,manifest_hash=body.manifest_hash,request_id=body.request_id))


@router.post('/sessions/{session_id}/resume')
def resume(session_id:UUID,body:Submit,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.lifecycle(session_id,user.user_id,action='RESUME',
        revision=body.expected_revision,manifest_hash=body.manifest_hash,request_id=body.request_id))


@router.post('/sessions/{session_id}/rendered')
def rendered(session_id:UUID,body:Rendered,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.rendered(session_id,user.user_id,revision=body.expected_revision,
        manifest_hash=body.manifest_hash,display_id=body.display_id))


@router.get('/sessions/{session_id}/history')
def history(session_id:UUID,user:Actor,service:Service,response:Response):
    return call(response,lambda:service.history(session_id,user.user_id))


@router.post('/sessions/{session_id}/withdraw')
def withdraw(session_id:UUID,body:Submit,user:Actor,service:WithdrawalService,response:Response):
    return call(response,lambda:service.withdraw(session_id,user.user_id,revision=body.expected_revision,
        manifest_hash=body.manifest_hash,request_id=body.request_id))
