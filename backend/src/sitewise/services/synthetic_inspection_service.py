"""Authenticated inspection of explicitly granted local synthetic runs only."""
from uuid import UUID
from sqlalchemy import text
from sitewise.domain.cq_runtime import CqRefused
from sitewise.services.ee01_service import Ee01Service,plain
from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization,boundary_run


class SyntheticInspectionService:
    def __init__(self,engine):self.engine=engine

    def runs(self,actor):
        with Ee01Service(self.engine).connection(actor) as c:
            c.execute(text('SET TRANSACTION READ ONLY'))
            rows=c.execute(text('SELECT r.run_id,r.origin,r.created_at,r.package_sha256 FROM cq_synthetic_import_runs r '
                'JOIN cq_synthetic_preview_grants g ON g.run_id=r.run_id '
                'WHERE g.developer_user_id=:actor AND NOT EXISTS(SELECT 1 FROM cq_synthetic_import_retirements x WHERE x.run_id=r.run_id) '
                'ORDER BY r.created_at DESC LIMIT 20'),{'actor':actor}).mappings().all()
        return {'contract_version':'synthetic-inspection/1','runs':plain([dict(r) for r in rows]),
                'origin':'SYNTHETIC_TEST','real_reportable':False,'participant_collection_enabled':False}

    def inspect(self,actor,run_id):
        capability=SyntheticPreviewAuthorization(run_id,developer_user_id=actor)
        with Ee01Service(self.engine).connection(actor) as c:
            c.execute(text('SET TRANSACTION READ ONLY'))
            run=c.execute(text('SELECT r.* FROM cq_synthetic_import_runs r JOIN cq_synthetic_preview_grants g ON g.run_id=r.run_id '
                'WHERE r.run_id=:run AND g.developer_user_id=:actor'),{'run':run_id,'actor':actor}).mappings().first()
            if not run:raise CqRefused('SYNTHETIC_RUN_NOT_FOUND',404)
            campaigns=c.execute(text("SELECT c.* FROM cq_campaigns c JOIN cq_synthetic_import_records r ON r.table_name='cq_campaigns' AND r.record_key->>'id'=c.id::text WHERE r.run_id=:run"),{'run':run_id}).mappings().all()
            sessions=[];snapshot_keys=[];histories={};effective={};case_rows={}
            params={'campaigns':[x['id'] for x in campaigns]}
            if campaigns:
                for row in c.execute(text('SELECT a.* FROM cq_answer_revisions a JOIN cq_sessions s ON s.id=a.session_id WHERE s.campaign_id=ANY(CAST(:campaigns AS uuid[])) ORDER BY a.revision'),params).mappings():
                    value=dict(row);sid=value.pop('session_id')
                    histories.setdefault(sid,[]).append({k:value[k] for k in ('id','slot_id','revision','state','value_json','context_digest')})
                for row in c.execute(text('SELECT e.session_id,e.slot_id,e.state,e.revision,e.answer_event_id,a.value_json,a.revision AS answer_revision FROM cq_effective_answers e JOIN cq_sessions s ON s.id=e.session_id LEFT JOIN cq_answer_revisions a ON a.id=e.answer_event_id WHERE s.campaign_id=ANY(CAST(:campaigns AS uuid[])) ORDER BY e.slot_id'),params).mappings():
                    value=dict(row);sid=value.pop('session_id');effective.setdefault(sid,[]).append(value)
            if c.scalar(text("SELECT to_regclass('cq_synthetic_cases')")):
                for row in c.execute(text('SELECT x.session_id,x.case_key,x.scenario,e.lifecycle_status,e.operation,e.revision AS classified_revision FROM cq_synthetic_cases x LEFT JOIN LATERAL(SELECT lifecycle_status,operation,revision FROM cq_synthetic_execution_events WHERE session_id=x.session_id ORDER BY revision DESC,created_at DESC,id DESC LIMIT 1)e ON true WHERE x.run_id=:run'),{'run':run_id}).mappings():
                    value=dict(row);sid=value.pop('session_id');case_rows[sid]=value
            for campaign in campaigns:
                boundary_run(c,'cq_campaigns',{'id':str(campaign['id'])},capability)
                rows=c.execute(text('SELECT s.*,ctl.eligibility,ctl.qualification_version,ctl.research_mode,ctl.source_json,'
                    "(SELECT action FROM cq_lifecycle_events e WHERE e.session_id=s.id ORDER BY revision DESC LIMIT 1) AS latest_action,"
                    '(SELECT count(*) FROM cq_submission_receipts e WHERE e.session_id=s.id) AS receipt_count '
                    'FROM cq_sessions s JOIN cq_session_controls ctl ON ctl.session_id=s.id WHERE s.campaign_id=:cid ORDER BY s.id'),{'cid':campaign['id']}).mappings().all()
                for row in rows:
                    s=dict(row);sid=s['id']
                    s['status']='PAUSED' if s['state']=='ACTIVE' and s['latest_action']=='PAUSE' else s['state']
                    s['classification_reason']='SUBMISSION_RECEIPT' if s['receipt_count'] else 'NO_SUBMISSION_RECEIPT'
                    s['screened_out']='NOT_DEFINED_BY_ADOPTED_POLICY'
                    case=case_rows.get(sid)
                    if case:
                        s.update(case)
                        s['lifecycle_status']=case['lifecycle_status'] or ('UNRESOLVED' if case['scenario']=='UNRESOLVED' else 'IN_PROGRESS')
                        s['screened_out']='HYPOTHETICAL_FIXTURE_ONLY' if case['scenario']=='HYPOTHETICAL_SCREENOUT' else s['screened_out']
                    s['effective_answers']=effective.get(sid,[])
                    s['answer_history']=histories.get(sid,[])
                    # No names, contact fields or simulated notice text are sent.
                    s.pop('source_json',None);sessions.append(s)
                snapshot_keys.extend(dict(v) for v in c.execute(text('SELECT id,assessment_id,campaign_id FROM ee01_measurement_snapshots WHERE campaign_id=:cid ORDER BY created_at,id'),{'cid':campaign['id']}).mappings())
            reader=Ee01Service(self.engine,capability);snapshots=[]
            for k in snapshot_keys:
                # One authorized read-only snapshot replaces repeated pool
                # checkouts and duplicate integrity scans for this same bundle.
                boundary_run(c,'ee01_measurement_snapshots',{'id':str(k['id'])},capability)
                measurement=reader._read(c,k['id'],k['assessment_id'],k['campaign_id'])
                context=reader._report_context(c,k['id'])
                snapshots.append({'measurement':measurement,'explanation_context':context})
        return plain({'contract_version':'synthetic-inspection/1','run_id':run_id,'database':'Dss',
            'origin':'SYNTHETIC_TEST','real_reportable':False,'participant_collection_enabled':False,
            'consent_semantics':run['consent_semantics'],'package_sha256':run['package_sha256'],
            'campaigns':[dict(v) for v in campaigns],'sessions':sessions,'snapshots':snapshots,
            'write_state':'SEPARATE_SYNTHETIC_EXECUTION_GRANT_REQUIRED','real_report_admission':'HOLD'})
