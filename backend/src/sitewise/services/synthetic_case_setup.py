"""Operator-only, transactional preparation of nonhuman interactive cases."""
import json
from uuid import UUID,uuid5,NAMESPACE_URL
from sqlalchemy import text
from sitewise.db.models.user import User
from sitewise.db.models import cq_runtime_schema as db
from sitewise.domain.customer_questionnaire import digest


def prepare_cases(c,run_id,developer,receipt,*,campaign_id=None):
    """Prepare the six nonhuman interactive cases for one run's campaign.

    ``campaign_id`` selects the campaign explicitly. When it is omitted the
    campaign is resolved from the run's own record of what it published
    (``manifest_json->>'release_id'``), never from a literal assessment id: the
    previous hard-coded ``6a59045c-…`` meant this function could only ever
    prepare one assessment, so every other campaign failed with
    ``NoResultFound`` before any check ran (DD-105).

    The provenance checks are unchanged and still refuse: the run must not be
    ``real_reportable``, must not be retired, must have a verified developer
    preview grant, and the campaign must be one of the records in that run's
    package.
    """
    run=c.execute(text('SELECT * FROM cq_synthetic_import_runs WHERE run_id=:id'),{'id':run_id}).mappings().one()
    if run['real_reportable'] or c.scalar(text('SELECT count(*) FROM cq_synthetic_import_retirements WHERE run_id=:id'),{'id':run_id}):raise ValueError('Run is unavailable')
    if not c.scalar(text('SELECT count(*) FROM cq_synthetic_preview_grants WHERE run_id=:id AND developer_user_id=:dev'),{'id':run_id,'dev':developer}):raise ValueError('Existing verified developer grant required')
    if campaign_id is not None:
        campaign=c.execute(text('SELECT c.*,r.manifest_json,r.manifest_hash FROM cq_campaigns c JOIN cq_manifest_releases r ON r.id=c.release_id WHERE c.owner_user_id=:owner AND c.id=:cid'),{'owner':run['owner_user_id'],'cid':str(campaign_id)}).mappings().one()
    else:
        published_release=(run['manifest_json'] or {}).get('release_id')
        if not published_release:raise ValueError('Run does not record a published release; pass campaign_id')
        campaign=c.execute(text('SELECT c.*,r.manifest_json,r.manifest_hash FROM cq_campaigns c JOIN cq_manifest_releases r ON r.id=c.release_id WHERE c.owner_user_id=:owner AND c.release_id=:rid'),{'owner':run['owner_user_id'],'rid':str(published_release)}).mappings().one()
    # Exact campaign is one of the verified input package's two mappings.
    if not c.scalar(text("SELECT count(*) FROM cq_synthetic_import_records WHERE run_id=:run AND table_name='cq_campaigns' AND record_key->>'id'=:cid"),{'run':run_id,'cid':str(campaign['id'])}):raise ValueError('Campaign is outside this verified package')
    m=campaign['manifest_json']
    # The instrument must be complete, but completeness is a property of the
    # manifest, not of the authorization decision: requiring all thirteen ids in
    # `authorized_question_ids` refused every assessment that withholds a
    # question by policy (DD-104, DD-105). What a respondent is shown is decided
    # by `route()`, not here.
    if [q['id'] for q in m['questions']]!=['Q'+str(i).zfill(2) for i in range(1,14)]:raise ValueError('Exact full questionnaire required')
    c.execute(text('INSERT INTO cq_synthetic_execution_grants(run_id,developer_user_id,operator_receipt) VALUES(:run,:dev,:receipt) ON CONFLICT DO NOTHING'),{'run':run_id,'dev':developer,'receipt':receipt})
    cases=[]
    for key,scenario in [('01-normal-completion','NORMAL'),('02-hypothetical-screenout','HYPOTHETICAL_SCREENOUT'),('03-pause-recovery','NORMAL'),('04-unresolved-eligibility','UNRESOLVED'),('05-full-questionnaire-retry','NORMAL'),('06-single-continue-check','NORMAL')]:
        uid=uuid5(NAMESPACE_URL,str(run_id)+':nonhuman-profile:'+key);sid=uuid5(NAMESPACE_URL,str(run_id)+':interactive-session:'+key)
        existing=c.execute(text('SELECT * FROM cq_synthetic_cases WHERE session_id=:sid'),{'sid':sid}).mappings().first()
        if existing:
            if existing['run_id']!=run_id or existing['case_key']!=key:raise ValueError('Case ID collision')
            cases.append({'session_id':str(sid),'case_key':key,'scenario':scenario});continue
        if c.scalar(text('SELECT count(*) FROM users WHERE user_id=:uid'),{'uid':uid}) or c.scalar(text('SELECT count(*) FROM cq_sessions WHERE id=:sid'),{'sid':sid}):raise ValueError('Preexisting unowned case identity; no overwrite')
        c.execute(User.__table__.insert().values(user_id=uid,email='nonhuman-'+str(uid)+'@test.invalid',role='customer',account_status='suspended',email_verified=False))
        c.execute(db.participants.insert().values(campaign_id=campaign['id'],respondent_user_id=uid))
        c.execute(db.sessions.insert().values(id=sid,campaign_id=campaign['id'],release_id=campaign['release_id'],respondent_user_id=uid,locale='EN',revision=0,state='ACTIVE',consented=False,consent_version=None))
        source={'run_id':str(run_id),'case_key':key,'scenario':scenario,'predicate_version':'HYPOTHETICAL_NONHUMAN_FIXTURE_1',
                'hypothetical_ineligible':scenario=='HYPOTHETICAL_SCREENOUT','not_a_human_eligibility_policy':True,
                'no_geography_days_preference_predicate':True,'manifest_hash':campaign['manifest_hash'],
                'release_id':str(campaign['release_id']),'consent_semantics':'SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT',
                'operator_receipt':receipt,'origin':'SYNTHETIC_TEST','real_reportable':False}
        c.execute(text('INSERT INTO cq_synthetic_cases(session_id,run_id,case_key,scenario,source_json,source_sha256) VALUES(:sid,:run,:key,:scenario,CAST(:source AS jsonb),:sha)'),
            {'sid':sid,'run':run_id,'key':key,'scenario':scenario,'source':json.dumps(source),'sha':digest(source)})
        context={'source_class':'SYNTHETIC_FIXTURE','research_mode':'DEVELOPER_PREVIEW','eligibility':
            'INELIGIBLE' if scenario=='HYPOTHETICAL_SCREENOUT' else 'UNRESOLVED' if scenario=='UNRESOLVED' else 'ELIGIBLE',
            'qualification_version':'HYPOTHETICAL_NONHUMAN_FIXTURE_1','receipt':receipt,'session_id':str(sid),
            'assessment_id':str(campaign['assessment_id']),'campaign_id':str(campaign['id']),
            'owner_user_id':str(campaign['owner_user_id']),'respondent_user_id':str(uid),
            'manifest_hash':campaign['manifest_hash'],'instrument_version':m['version'],'bank_version':m['bank_version'],
            'routing_version':m['policy_version'],'consent_version':m['consent_version'],
            'consent_hash':digest(m['consent_text']['EN']),'synthetic_run_id':str(run_id),
            'consent_semantics':'SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT','origin':'SYNTHETIC_TEST','real_reportable':False,
            'synthetic_case_source_sha256':digest(source)}
        c.execute(db.controls.insert().values(session_id=sid,research_mode='DEVELOPER_PREVIEW',eligibility=context['eligibility'],qualification_version=context['qualification_version'],source_json=context,source_hash=digest(context)))
        cases.append({'session_id':str(sid),'case_key':key,'scenario':scenario})
    return cases
