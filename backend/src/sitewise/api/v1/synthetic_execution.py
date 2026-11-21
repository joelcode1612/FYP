"""Developer-only nonhuman session operations; ordinary routes remain held."""
from uuid import UUID
from fastapi import APIRouter,Depends,HTTPException,Response
from sitewise.core.config import settings
from sitewise.api.v1.synthetic_inspection import Actor,get_inspector,respond
from sitewise.api.v1.customer_questionnaire import Consent,Exposure,Present,Answer,Submit,Rendered

router=APIRouter()


def get_execution():
    if not settings.cq_synthetic_interactive_enabled:
        raise HTTPException(404,detail={'code':'SYNTHETIC_EXECUTION_DISABLED'})
    from sitewise.services.synthetic_execution_service import SyntheticExecutionService
    return SyntheticExecutionService(get_inspector().engine)


def call(response,service,user,run_id,session_id,operation,body=None,**extra):
    values={} if body is None else {'revision':body.expected_revision,'manifest_hash':body.manifest_hash}
    return respond(response,lambda:service.execute(user.user_id,run_id,session_id,operation,**values,**extra))


@router.get('/developer-imports/{run_id}/cases')
def cases(run_id:UUID,user:Actor,response:Response,service=Depends(get_execution)):
    return respond(response,lambda:service.cases(user.user_id,run_id))


@router.get('/developer-imports/{run_id}/sessions/{session_id}')
def read(run_id:UUID,session_id:UUID,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'read')


@router.get('/developer-imports/{run_id}/sessions/{session_id}/history')
def history(run_id:UUID,session_id:UUID,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'history')


@router.post('/developer-imports/{run_id}/sessions/{session_id}/consent')
def acknowledge(run_id:UUID,session_id:UUID,body:Consent,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'consent',body,request_id=body.request_id,consented=body.consented,version=body.consent_version)


@router.post('/developer-imports/{run_id}/sessions/{session_id}/stimuli')
def expose(run_id:UUID,session_id:UUID,body:Exposure,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'expose',body,kind=body.kind)


@router.post('/developer-imports/{run_id}/sessions/{session_id}/presentations')
def present(run_id:UUID,session_id:UUID,body:Present,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'present',body,edit_slot_id=body.edit_slot_id)


@router.post('/developer-imports/{run_id}/sessions/{session_id}/answers')
def answer(run_id:UUID,session_id:UUID,body:Answer,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'answer',body,request_id=body.request_id,display_id=body.display_id,slot_id=body.slot_id,value=body.value)


@router.post('/developer-imports/{run_id}/sessions/{session_id}/submit')
def submit(run_id:UUID,session_id:UUID,body:Submit,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'submit',body,request_id=body.request_id)


@router.post('/developer-imports/{run_id}/sessions/{session_id}/pause')
def pause(run_id:UUID,session_id:UUID,body:Submit,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'pause',body,request_id=body.request_id)


@router.post('/developer-imports/{run_id}/sessions/{session_id}/resume')
def resume(run_id:UUID,session_id:UUID,body:Submit,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'resume',body,request_id=body.request_id)


@router.post('/developer-imports/{run_id}/sessions/{session_id}/rendered')
def rendered(run_id:UUID,session_id:UUID,body:Rendered,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'rendered',body,display_id=body.display_id)


@router.post('/developer-imports/{run_id}/sessions/{session_id}/withdraw')
def withdraw(run_id:UUID,session_id:UUID,body:Submit,user:Actor,response:Response,service=Depends(get_execution)):
    return call(response,service,user,run_id,session_id,'withdraw',body,request_id=body.request_id)
