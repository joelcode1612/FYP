"""Authenticated CQ application API; production fielding is default-held."""
import logging
from datetime import datetime
from typing import Annotated, Literal
from functools import lru_cache
from uuid import UUID

from fastapi import APIRouter,Depends,HTTPException,Response
from pydantic import BaseModel,ConfigDict,Field,model_validator

from sitewise.core.config import settings
from sitewise.dependencies import AuthenticatedUser,get_active_user,require_entrepreneur
from sitewise.domain.cq_runtime import CqRefused

logger = logging.getLogger(__name__)

router=APIRouter()
Actor=Annotated[AuthenticatedUser,Depends(get_active_user)]
Owner=Annotated[AuthenticatedUser,Depends(require_entrepreneur)]


def get_cq_authority():
    from sitewise.repositories.cq_repository import UnverifiedCqAuthority
    return UnverifiedCqAuthority()


def get_cq_service(authority=Depends(get_cq_authority)):
    if not settings.cq_runtime_enabled:
        raise HTTPException(503,detail={'code':'PRODUCTION_FIELDING_HOLD','message':'Customer questionnaires are not activated.'})
    from sitewise.repositories.cq_repository import PostgresCqStore,get_cq_engine
    from sitewise.services.customer_questionnaire_service import CustomerQuestionnaireService
    # The CQ write principal, not the M2 read-only login. See DD-CQ-11.
    return CustomerQuestionnaireService(PostgresCqStore(get_cq_engine()),authority)


Service=Annotated[object,Depends(get_cq_service)]


def get_cq_withdrawal_service():
    # Withholding new participation must not trap a respondent's consent.
    from sitewise.repositories.cq_repository import PostgresCqStore,UnverifiedCqAuthority,get_cq_engine
    from sitewise.services.customer_questionnaire_service import CustomerQuestionnaireService
    return CustomerQuestionnaireService(PostgresCqStore(get_cq_engine()),UnverifiedCqAuthority())


WithdrawalService=Annotated[object,Depends(get_cq_withdrawal_service)]


def get_ee01_service():
    from sqlalchemy.engine import make_url
    from sitewise.services.ee01_service import Ee01Service
    raw=settings.ee01_database_url.get_secret_value()
    if not raw:
        raise HTTPException(503,detail={'code':'EE01_DATABASE_TARGET_UNVERIFIED'})
    url=make_url(raw)
    if url.drivername!='postgresql+psycopg2' or url.database!=settings.ee01_expected_database or url.username!='p1_ee01_runtime':
        raise HTTPException(503,detail={'code':'EE01_DATABASE_TARGET_UNVERIFIED'})
    return Ee01Service(_ee01_engine(raw))


@lru_cache(maxsize=2)
def _ee01_engine(raw):
    from sqlalchemy import create_engine
    return create_engine(raw,hide_parameters=True,pool_pre_ping=True)


Ee01=Annotated[object,Depends(get_ee01_service)]


def get_publication_service():
    """Publication, deliberately independent of ``cq_runtime_enabled``.

    The respondent route is held by ``CQ_RUNTIME_ENABLED`` because customer
    fielding is not authorised. Publication is a different operation with a
    different principal: it writes the instrument, it does not field it. Gating
    it on the respondent switch is what made the Publish Questionnaire button
    permanently dead (DD-096). The real gate is
    ``get_publication_engine()``, which refuses unless the DSN names
    ``p1_cq_publisher`` and the declared database, so a deployment without the
    principal fails closed with ``CQ_PUBLICATION_TARGET_UNVERIFIED``.
    """
    from sitewise.repositories.cq_repository import PostgresCqStore,get_publication_engine
    from sitewise.services.cq_publication_service import PublicationService
    return PublicationService(PostgresCqStore(get_publication_engine()))


def get_collection_state_service():
    """Respondent target and collection lifecycle (DD-097).

    Runs as ``p1_ee01_runtime`` — the CQ *write* principal — not the publisher
    and not the M2 read-only login. Publishing starts a collection; configuring
    and ending one is a different act with a different principal, which is why
    the migration grants the publisher SELECT only.
    """
    from sqlalchemy.engine import make_url
    from sitewise.services.cq_collection_state_service import CollectionStateService
    raw=settings.ee01_database_url.get_secret_value()
    if not raw:
        raise HTTPException(503,detail={'code':'CQ_COLLECTION_STATE_TARGET_UNVERIFIED'})
    url=make_url(raw)
    if (url.drivername!='postgresql+psycopg2'
            or url.database!=settings.ee01_expected_database
            or url.username!='p1_ee01_runtime'):
        raise HTTPException(503,detail={'code':'CQ_COLLECTION_STATE_TARGET_UNVERIFIED'})
    return CollectionStateService(_ee01_engine(raw))


Collection=Annotated[object,Depends(get_collection_state_service)]


Publication=Annotated[object,Depends(get_publication_service)]


class PublicationRequest(BaseModel):
    """No option is accepted from the client except none.

    ``optional_context``, ``mode`` and ``q02_policy`` are the builder's
    fail-closed defaults and the owner has not decided them, so the request
    body carries no way to set them. A client that wants a different instrument
    is asking for a different publication decision, not a different parameter.
    """
    model_config=ConfigDict(extra='forbid')


@router.get('/publication/{assessment_id}')
def publication_preview(assessment_id:UUID,user:Owner,service:Publication,response:Response):
    """What publishing would do. Read-only; writes no row."""
    return call(response,lambda:service.preview(str(assessment_id),user.user_id))


@router.post('/publication/{assessment_id}')
def publication_publish(assessment_id:UUID,user:Owner,service:Publication,response:Response,
                        body:PublicationRequest|None=None):
    """Publish the questionnaire for an assessment the caller owns.

    Idempotent by content: republishing an unchanged questionnaire returns
    ``ALREADY_PUBLISHED`` with the same release id and writes nothing.
    """
    return call(response,lambda:service.publish(str(assessment_id),user.user_id))


def _synthetic_preview(user):
    """The developer-preview capability for this caller, resolved per record.

    The snapshot id is in the path but the synthetic run id is only in the
    snapshot's metadata, so the run cannot be named before the record is read.
    ``for_record`` therefore carries the developer identity and lets the boundary
    resolve the run — and still require a ``cq_synthetic_preview_grants`` row for
    it. Without a grant the read fails exactly as before. DD-126.
    """
    from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization
    return SyntheticPreviewAuthorization.for_record(developer_user_id=user.user_id)


@router.get('/assessments/{assessment_id}/campaigns/{campaign_id}/measurements/{snapshot_id}')
def measurement_readback(assessment_id:UUID,campaign_id:UUID,snapshot_id:UUID,user:Owner,service:Ee01,response:Response):
    return call(response,lambda:service.read(user.user_id,assessment_id,campaign_id,snapshot_id,
                                             synthetic_preview=_synthetic_preview(user)))


@router.get('/assessments/{assessment_id}/campaigns/{campaign_id}/measurements/{snapshot_id}/report-readback')
def measurement_report_readback(assessment_id:UUID,campaign_id:UUID,snapshot_id:UUID,user:Owner,service:Ee01,response:Response):
    return call(response,lambda:service.report_readback(user.user_id,assessment_id,campaign_id,snapshot_id,
                                                        synthetic_preview=_synthetic_preview(user)))


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
class CollectionTarget(Strict):
    request_id:UUID
    respondent_target:int=Field(ge=1,le=9999)
class CollectionEnd(Strict):
    request_id:UUID
    #: A label, not a governed vocabulary. Which reasons are legitimate is a
    #: policy decision (DD-097) and is not pre-empted here.
    #:
    #: REQUIRED when ``completion_policy`` is ``OWNER_DISCRETION``: the owner
    #: adopted below-target closure with a mandatory recorded reason on
    #: 2026-11-25. Optional under ``TARGET_REACHED_ONLY``, where the policy is
    #: itself the statement.
    reason:str|None=Field(default=None,max_length=200)
    #: Required, with no default. Closing below target and closing with sessions
    #: still in progress are exactly the two rules DD-097 leaves open, so the
    #: caller must state the decision instead of inheriting one from code.
    completion_policy:Literal['TARGET_REACHED_ONLY','OWNER_DISCRETION']
    in_progress_disposition:Literal['LEAVE_OPEN']
    #: Defaults to the closure instant. An earlier cutoff may be stated when the
    #: last admissible response predates the closure.
    evidence_cutoff:datetime|None=None

    @model_validator(mode='after')
    def _reason_required_below_target(self):
        """Reject a below-target closure that does not say why.

        Validated at the boundary so the 422 names the field, rather than
        surfacing later as a database CHECK violation. The CHECK still exists as
        the backstop; this is the readable front door.
        """
        if self.completion_policy == 'OWNER_DISCRETION' and not (self.reason or '').strip():
            raise ValueError('reason is required when completion_policy is OWNER_DISCRETION')
        return self


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
        # `state` and `code` are unchanged so existing consumers keep working.
        # `reason` is the additive field that separates "the feature is switched
        # off" from "this respondent is not authorized": both used to report
        # PRODUCTION_FIELDING_HOLD, which made them indistinguishable.
        return {'contract_version':'cq-invitations/1','state':'held',
            'code':'PRODUCTION_FIELDING_HOLD','reason':'CQ_RUNTIME_DISABLED',
            'invitations':[]}
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


# --- collection state (respondent target + lifecycle, DD-097) ---------------
# Declared after the request models so the annotations resolve.

@router.get('/assessments/{assessment_id}/collection')
def collection_state(assessment_id:UUID,user:Owner,service:Collection,response:Response):
    """The respondent target and the collection lifecycle for this assessment.

    Deliberately independent of ``cq_runtime_enabled``: reading one's own target
    is not customer fielding, and gating it on the respondent switch is what made
    the Publish button dead (DD-096).
    """
    return call(response,lambda:service.read(user.user_id,assessment_id))


@router.get('/assessments/{assessment_id}/collection/report-eligibility')
def collection_report_eligibility(assessment_id:UUID,user:Owner,
                                  service:Collection,response:Response):
    """The six report concepts, each with its own reason.

    Kept server-side and separate from button enablement: a direct API call must
    get the same answer as the rendered page, and the report readback endpoint
    enforces the same rule independently of this response.
    """
    return call(response,lambda:service.report_eligibility(user.user_id,assessment_id))


@router.put('/assessments/{assessment_id}/collection/target')
def collection_set_target(assessment_id:UUID,body:CollectionTarget,user:Owner,
                          service:Collection,response:Response):
    """Set the planning figure. Idempotent per ``request_id``."""
    return call(response,lambda:service.set_target(
        user.user_id,assessment_id,body.respondent_target,body.request_id))


@router.post('/assessments/{assessment_id}/collection/end')
def collection_end(assessment_id:UUID,body:CollectionEnd,user:Owner,
                   service:Collection,response:Response):
    """Explicit End Collection. Atomic, idempotent, and deletes nothing."""
    return call(response,lambda:service.end_collection(
        user.user_id,assessment_id,body.request_id,body.reason,
        completion_policy=body.completion_policy,
        in_progress_disposition=body.in_progress_disposition,
        evidence_cutoff=body.evidence_cutoff))


# --- Synthetic chart preview (Round 24 / Gate 5) ---------------------------
#
# A developer diagnostic, not a report finding. Three independent controls sit
# between a request and a count:
#
# 1. ``cq_synthetic_preview_enabled`` — a module switch that is false in every
#    production configuration. Disabled means 503, not an empty list.
# 2. The per-run developer grant. ``Ee01Service`` is constructed with a
#    ``SyntheticPreviewAuthorization`` resolved against the *caller*, so the
#    boundary refuses (403) a caller with no grant for the run the snapshot
#    belongs to. The service is never built without it on this path.
# 3. The instrument gate. A slot whose frozen contract requires an approved
#    stimulus keeps ``UNAVAILABLE_MISSING_APPROVED_STIMULUS`` even in preview:
#    a preview may disclose a count, never manufacture an authorization.
#
# The response is marked ``synthetic`` and ``reportable: false`` so a client
# cannot present it as a finding, and nothing here writes an admission row.

#: Gate 3 — how one snapshot per slot is chosen when a campaign holds several.
#:
#: A *total* order, so the same stored evidence always selects the same
#: snapshot regardless of the order the binding happens to list them in:
#: latest ``cutoff`` first, ties broken by ``snapshot_id``. Ordering by cutoff
#: alone left ties resolved by iteration order, which is not a policy.
#:
#: What this policy cannot do: it selects, it does not *pin*. A report revision
#: that rendered the 18:00 snapshot and is re-rendered after a 19:00 snapshot
#: lands will show the 19:00 evidence, because no row binds a revision to the
#: snapshot it was assembled from. Persisting that binding is a schema change
#: and is recorded as an open Owner decision (DD-R24-3), not quietly assumed
#: away here. The per-slot ``candidates`` count and ``selection`` label are
#: published so a reader can at least see that a choice was made.
SELECTION_POLICY = 'LATEST_CUTOFF_PER_SLOT_THEN_SNAPSHOT_ID/1'


def _snapshot_order(entry: dict) -> tuple[str, str]:
    """Total order over one slot's snapshots: ``(cutoff, snapshot_id)``."""
    return (str(entry.get('cutoff') or ''), str(entry.get('snapshot_id') or ''))


#: Refusals that describe the *caller*, not the slot.
#:
#: These come from the synthetic-preview boundary and mean "this principal may
#: not read synthetic evidence at all". They must abort the whole request with
#: the boundary's own status, not be collected into a per-slot ineligibility:
#: a 200 whose every slot says "refused" is not an authorization decision, and a
#: client could mistake it for a preview with nothing eligible in it.
_AUTHORIZATION_REFUSALS = frozenset({
    'SYNTHETIC_PREVIEW_NOT_AUTHORIZED',
    'SYNTHETIC_DATA_NOT_REPORTABLE',
    'EE01_RESTRICTED_ROLE_REQUIRED',
})


def get_ee01_preview_service(user: Actor):
    """EE-01 bound to the caller's own synthetic-preview grant.

    Deliberately a different dependency from ``get_ee01_service``: the ordinary
    service carries no authorization and is therefore refused by the boundary on
    any synthetic record. This one names the caller so the per-run grant can be
    checked, and it is only reachable from the preview route below.
    """
    from sqlalchemy.engine import make_url
    from sitewise.services.ee01_service import Ee01Service
    from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization
    raw = settings.ee01_database_url.get_secret_value()
    if not raw:
        raise HTTPException(503, detail={'code': 'EE01_DATABASE_TARGET_UNVERIFIED'})
    url = make_url(raw)
    if (url.drivername != 'postgresql+psycopg2'
            or url.database != settings.ee01_expected_database
            or url.username != 'p1_ee01_runtime'):
        raise HTTPException(503, detail={'code': 'EE01_DATABASE_TARGET_UNVERIFIED'})
    return Ee01Service(
        _ee01_engine(raw),
        synthetic_preview=SyntheticPreviewAuthorization.for_record(
            developer_user_id=user.user_id),
    )


PreviewEe01 = Annotated[object, Depends(get_ee01_preview_service)]


@router.get('/assessments/{assessment_id}/campaigns/{campaign_id}/chart-previews')
def chart_previews(assessment_id: UUID, campaign_id: UUID, user: Owner,
                   service: PreviewEe01, response: Response):
    """Eligible frozen-snapshot charts for one campaign, for a developer session.

    One request answers for every measured slot, because eligibility is decided
    per slot by the frozen contract and a client that asked slot by slot would
    have to re-implement that decision.
    """
    if not settings.cq_synthetic_preview_enabled:
        raise HTTPException(503, detail={
            'code': 'SYNTHETIC_PREVIEW_DISABLED',
            'message': 'Synthetic chart preview is not enabled on this server.',
        })
    return call(response, lambda: _chart_previews(
        service, user.user_id, assessment_id, campaign_id))


def _chart_previews(service, actor, assessment_id, campaign_id) -> dict:
    from sitewise.project1 import chart_question_source as cqs
    from sitewise.project1.chart_spec import ChartRefused, from_ee01

    binding = service.explanation_binding(actor, assessment_id)
    if str(binding.get('campaign_id') or '') != str(campaign_id):
        # The campaign in the path is not the campaign this assessment owns.
        raise CqRefused('CAMPAIGN_ASSESSMENT_MISMATCH', 404)

    latest: dict[str, dict] = {}
    competing: dict[str, int] = {}
    for entry in binding.get('snapshots') or []:
        slot = entry.get('slot_id')
        if not slot:
            continue
        competing[slot] = competing.get(slot, 0) + 1
        current = latest.get(slot)
        if current is None or _snapshot_order(entry) > _snapshot_order(current):
            latest[slot] = entry

    slots = []
    for slot in sorted(latest):
        frozen = latest[slot]
        record = {
            'slot_id': slot,
            'snapshot_id': frozen.get('snapshot_id'),
            'cutoff': frozen.get('cutoff'),
            'question_version': frozen.get('question_version'),
            # Gate 3: say how the choice was made and whether more than one
            # revision existed, so a reader can see that this evidence was
            # selected rather than assume it was the only one.
            'candidates': competing.get(slot, 1),
            'selection': SELECTION_POLICY,
        }
        try:
            source = cqs.source_for(slot)
        except ChartRefused as exc:
            slots.append({**record, 'eligible': False, 'code': exc.code})
            continue
        try:
            snapshot = service.read(actor, assessment_id, campaign_id,
                                    frozen['snapshot_id'])
            readback = service.report_readback(actor, assessment_id, campaign_id,
                                               frozen['snapshot_id'])
            # A gate that requires an approved stimulus keeps its restriction;
            # everything else may be inspected as a preview — except a slot that
            # was never shown. NOT_SHOWN has no distribution to preview (V=0),
            # and a preview percentage over a zero denominator is not a number
            # the contract will accept. It stays NOT_SHOWN.
            if source.render_state_override:
                override = source.render_state_override
            elif str(snapshot.get('status')) == 'NOT_SHOWN':
                override = None
            else:
                override = 'SYNTHETIC_PREVIEW_ONLY'
            spec = from_ee01(
                snapshot, readback, dict(source.question,
                                         report_sections=list(source.report_sections)),
                title=f'{slot} · {source.question.get("construct") or "diagnostic"}',
                labels=source.labels,
                render_state_override=override,
            )
        except ChartRefused as exc:
            slots.append({**record, 'eligible': False, 'code': exc.code})
            continue
        except CqRefused as exc:
            if exc.code in _AUTHORIZATION_REFUSALS:
                # The caller may not read synthetic evidence at all. Refuse the
                # request rather than reporting seven per-slot refusals.
                raise
            slots.append({**record, 'eligible': False, 'code': exc.code})
            continue
        except ValueError as exc:
            # A chart-spec validation refusal is a per-slot outcome, not a
            # failure of the whole preview: the other slots are still readable.
            # The reason is logged, because a bare code here hides *which* rule
            # refused the slot — and a slot that should have been described as
            # withheld would otherwise look merely unconvertible.
            logger.warning('chart preview slot %s refused: %s: %s',
                           slot, type(exc).__name__, str(exc)[:400])
            slots.append({**record, 'eligible': False,
                          'code': getattr(exc, 'code', 'CHART_SPEC_INVALID')})
            continue
        slots.append({
            **record,
            'eligible': True,
            'spec': spec.model_dump(mode='json'),
            'provenance': source.describe(),
            'funnel': {'q': snapshot.get('q'), 's': snapshot.get('s'),
                       'a': snapshot.get('a'), 'v': snapshot.get('v')},
        })

    return {
        'contract_version': 'chart-preview/1',
        'assessment_id': str(assessment_id),
        'campaign_id': str(campaign_id),
        'selection_policy': SELECTION_POLICY,
        'synthetic': True,
        'reportable': False,
        'admission': {'status': 'HELD', 'real_reportable': False},
        'slots': slots,
    }
