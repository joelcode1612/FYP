"""Explicit-migration-only CQ tables; no startup provisioning or fixture seeding."""
from sqlalchemy import Boolean, Column, DateTime, Integer, MetaData, String, Table, Uuid, func
from sqlalchemy.dialects.postgresql import JSONB

metadata=MetaData()
def table(name, fields, primary=('id',)):
    return Table(name,metadata,*[Column(key,kind,primary_key=key in primary) for key,kind in fields],
        Column('created_at',DateTime(timezone=True),server_default=func.now()))

banks=table('cq_bank_versions',[('version',String(100)),('content_hash',String(64)),('questions_json',JSONB)],('version',))
releases=table('cq_manifest_releases',[('id',Uuid),('manifest_hash',String(64)),('policy_hash',String(64)),
    ('manifest_json',JSONB),('policy_json',JSONB),('source_class',String(32))])
assignments=table('cq_question_assignments',[('release_id',Uuid),('slot_id',String(100)),
    ('question_id',String(3)),('question_version',String(100)),('bank_version',String(100)),
    ('content_hash',String(64))],('release_id','slot_id'))
campaigns=table('cq_campaigns',[('id',Uuid),('assessment_id',Uuid),('owner_user_id',Uuid),('release_id',Uuid)])
participants=table('cq_participants',[('campaign_id',Uuid),('respondent_user_id',Uuid)],('campaign_id','respondent_user_id'))
sessions=table('cq_sessions',[('id',Uuid),('campaign_id',Uuid),('release_id',Uuid),('respondent_user_id',Uuid),
    ('locale',String(2)),('revision',Integer),('state',String(24)),('consented',Boolean),('consent_version',String(100))])
consents=table('cq_consent_events',[('id',Uuid),('session_id',Uuid),('revision',Integer),('request_id',Uuid),
    ('request_hash',String(64)),('consented',Boolean),('version',String(100))])
exposures=table('cq_stimulus_deliveries',[('id',Uuid),('session_id',Uuid),('revision',Integer),('kind',String(20)),('stimulus_hash',String(64))])
decisions=table('cq_routing_decisions',[('id',Uuid),('session_id',Uuid),('revision',Integer),('decision_json',JSONB),('decision_hash',String(64))])
displays=table('cq_presentations',[('id',Uuid),('session_id',Uuid),('revision',Integer),('slot_id',String(100)),
    ('context_digest',String(64)),('decision_id',Uuid)])
answers=table('cq_answer_revisions',[('id',Uuid),('session_id',Uuid),('slot_id',String(100)),('revision',Integer),
    ('request_id',Uuid),('request_hash',String(64)),('display_id',Uuid),('state',String(32)),('value_json',JSONB),('context_digest',String(64))])
effective=table('cq_effective_answers',[('session_id',Uuid),('slot_id',String(100)),('answer_event_id',Uuid),
    ('state',String(32)),('context_digest',String(64)),('revision',Integer)],('session_id','slot_id'))
receipts=table('cq_submission_receipts',[('id',Uuid),('session_id',Uuid),('request_id',Uuid),('request_hash',String(64)),
    ('revision',Integer),('receipt_hash',String(64)),('payload_json',JSONB)])

lifecycle=table('cq_lifecycle_events',[('id',Uuid),('session_id',Uuid),('revision',Integer),
    ('request_id',Uuid),('request_hash',String(64)),('action',String(8))])
renders=table('cq_render_events',[('id',Uuid),('session_id',Uuid),('display_id',Uuid),('slot_id',String(100)),('revision',Integer)])
rejected=table('cq_rejected_answer_events',[('id',Uuid),('session_id',Uuid),('display_id',Uuid),('revision',Integer),
    ('request_id',Uuid),('request_hash',String(64)),('slot_id',String(100)),('raw_value',JSONB),('reason',String(100))])
controls=table('cq_session_controls',[('session_id',Uuid),('research_mode',String(32)),('eligibility',String(24)),
    ('qualification_version',String),('source_json',JSONB),('source_hash',String(64))],('session_id',))
