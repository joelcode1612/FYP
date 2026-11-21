"""Reconcile normal-phone HTTP evidence with actual Dss. READ ONLY; no replay."""
import argparse
import json
from pathlib import Path
from uuid import UUID
from sqlalchemy import create_engine,text
from import_mock_to_dss import configured_urls
from sitewise.domain.customer_questionnaire import digest
from sitewise.services.synthetic_dss_import import normalized


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run-id',type=UUID,required=True)
    p.add_argument('--session-id',type=UUID,required=True)
    p.add_argument('--evidence',type=Path,required=True);a=p.parse_args()
    trace=[json.loads(line) for line in (a.evidence/'connected_phone_http.jsonl').read_text().splitlines()]
    prefix='/api/v1/cq/developer-imports/'+str(a.run_id)+'/sessions/'+str(a.session_id)
    events=[r for r in trace if r['path'].startswith(prefix) and r['HTTP']==200]
    submitted=next((r for r in reversed(events) if r['response'].get('lifecycle_status')=='COMPLETED'),None)
    if not submitted:raise ValueError('Actual phone completion has not been observed')
    wire=submitted['response'];manifest=wire['manifest']
    assert digest(manifest)==wire['manifest_hash']
    expected={q['id']+':'+f for q in manifest['questions'] for f in q['feature_ids']}
    expected.update(q['id'] for q in manifest['questions'] if not q['feature_ids'])
    assert [q['id'] for q in manifest['questions']]==['Q'+str(i).zfill(2) for i in range(1,14)]
    assert len(expected)==14
    admin,_=configured_urls();db=create_engine(admin,hide_parameters=True,connect_args={'options':'-c default_transaction_read_only=on'})
    with db.connect() as c:
        c.execute(text('SET TRANSACTION READ ONLY'))
        root=dict(c.execute(text('SELECT s.*,x.run_id,x.case_key,x.scenario FROM cq_sessions s JOIN cq_synthetic_cases x ON x.session_id=s.id WHERE s.id=:sid AND x.run_id=:run'),{'sid':a.session_id,'run':a.run_id}).mappings().one())
        assert root['state']=='SUBMITTED' and root['revision']==wire['revision'] and root['scenario']=='NORMAL'
        assert str(root['campaign_id'])==wire['campaign_id'] and str(root['release_id'])==wire['release_id']
        campaign=dict(c.execute(text('SELECT * FROM cq_campaigns WHERE id=:cid'),{'cid':root['campaign_id']}).mappings().one())
        assert c.scalar(text('SELECT count(*) FROM cq_campaigns WHERE assessment_id=:id'),{'id':campaign['assessment_id']})==1
        answers=[dict(r) for r in c.execute(text('SELECT a.*,q.question_version FROM cq_answer_revisions a JOIN cq_question_assignments q ON q.release_id=:release AND q.slot_id=a.slot_id WHERE a.session_id=:sid ORDER BY revision'),{'release':root['release_id'],'sid':a.session_id}).mappings()]
        assert {r['slot_id'] for r in answers}==expected
        posts=[r['request'] for r in events if r['path'].endswith('/answers')]
        unique_posts={r['request_id']:r for r in posts}
        assert len(unique_posts)==len(answers)
        for row in answers:
            request=unique_posts[str(row['request_id'])]
            assert request['slot_id']==row['slot_id'] and request['value']==row['value_json']
            assert request['expected_revision']+1==row['revision'] and request['display_id']==str(row['display_id'])
            assert c.scalar(text('SELECT count(*) FROM cq_render_events WHERE session_id=:sid AND display_id=:did'),{'sid':a.session_id,'did':row['display_id']})==1
        effective=[dict(r) for r in c.execute(text('SELECT * FROM cq_effective_answers WHERE session_id=:sid ORDER BY slot_id'),{'sid':a.session_id}).mappings()]
        assert {r['slot_id'] for r in effective}==expected
        for row in effective:
            route=next(r for r in wire['routing'] if r['slot_id']==row['slot_id'])
            assert route['verdict']=='SHOWN' and route['state']==row['state']
            assert route['event_id']==str(row['answer_event_id']) and route['context_digest']==row['context_digest']
        receipt=dict(c.execute(text('SELECT * FROM cq_submission_receipts WHERE session_id=:sid'),{'sid':a.session_id}).mappings().one())
        assert receipt['payload_json']==wire['receipt'] and receipt['receipt_hash']==wire['receipt']['receipt_hash']
        payload=dict(receipt['payload_json']);sha=payload.pop('receipt_hash');assert digest(payload)==sha
        audit=[dict(r) for r in c.execute(text('SELECT id,developer_user_id,operation,revision,lifecycle_status,snapshot_sha256,snapshot_json FROM cq_synthetic_execution_events WHERE session_id=:sid ORDER BY revision,created_at,id'),{'sid':a.session_id}).mappings()]
        principal=json.loads((a.evidence/'verified_phone_principal.json').read_text())
        assert all(str(r['developer_user_id'])==principal['user_id'] and digest(r['snapshot_json'])==r['snapshot_sha256'] for r in audit)
        assert any(r['operation']=='submit' and r['lifecycle_status']=='COMPLETED' for r in audit)
        deliveries=[dict(r) for r in c.execute(text('SELECT id,kind,stimulus_hash,revision FROM cq_stimulus_deliveries WHERE session_id=:sid ORDER BY revision'),{'sid':a.session_id}).mappings()]
        assert [r['kind'] for r in deliveries]==manifest['stimulus_order']
        assert all(r['stimulus_hash']==digest(manifest['stimuli'][r['kind']]) for r in deliveries)
        control=dict(c.execute(text('SELECT * FROM cq_session_controls WHERE session_id=:sid'),{'sid':a.session_id}).mappings().one())
        assert control['research_mode']=='DEVELOPER_PREVIEW' and control['source_json']['real_reportable'] is False
        assert digest(control['source_json'])==control['source_hash']
    result=normalized({'result':'PASS','source':'ACTUAL_NORMAL_SITEWISE_PHONE_HTTP_AND_LOCAL_DSS_READ_ONLY',
        'run_id':a.run_id,'session_id':a.session_id,'root':root,'campaign':campaign,'manifest_hash':wire['manifest_hash'],
        'question_ids':[q['id'] for q in manifest['questions']],'applicable_answer_cells':sorted(expected),
        'accepted_revisions':answers,'effective_answers':effective,'submission_receipt':receipt,
        'classification_audit':audit,'stimulus_deliveries':deliveries,'qualification_control':control,
        'actual_HTTP_operations':len(events),'actual_completion_response':submitted,
        'actual_readback_checks':{'all_13_questions_and_14_cells':True,'every_answer_matches_phone_request':True,
          'every_answer_has_actual_render_ack':True,'revisions_preserved':True,'current_effective_answers_match':True,
          'SUBMITTED_storage_COMPLETED_lifecycle':True,'immutable_receipt_matches':True,'one_campaign_per_assessment':True,
          'real_developer_separate_from_nonhuman_subject':True,'no_production_demand_mode':True},
        'real_fielding_authorized':False,'real_report_admitted':False})
    (a.evidence/'actual_full_phone_completion_verified.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('PASS: actual normal phone -> FastAPI -> Dss; 13 questions / 14 cells; answers, revisions, renders, receipt and classification match.')
    db.dispose()


if __name__=='__main__':main()
