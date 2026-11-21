"""Backup/clone rehearsal, actual-route tests, then optional bounded Dss setup.

Only --apply prepares pristine nonhuman cases in Dss. All answer submissions
in this runner go to the private clone, never to the original database.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from types import SimpleNamespace
from uuid import UUID,uuid4

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'));sys.path.insert(0,str(ROOT/'scripts'))
import import_mock_to_dss as op
from sqlalchemy import create_engine,text
from sqlalchemy.engine import URL
from sitewise.services.synthetic_case_setup import prepare_cases
from sitewise.services.synthetic_execution_service import SyntheticExecutionService
from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization
from sitewise.services.ee01_service import Ee01Service
from sitewise.services.synthetic_dss_import import normalized


def migrate(c,name):
    p=ROOT/'migrations/cq'/name;sha=hashlib.sha256(p.read_bytes()).hexdigest()
    c.execute(text("SELECT set_config('project1.cq_migration_target',current_database(),true),set_config('project1.cq_migration_receipt','OWNER_NONHUMAN_INTERACTIVE_REHEARSAL',true),set_config('project1.cq_migration_sha256',:sha,true)"),{'sha':sha})
    with c.connection.driver_connection.cursor() as cursor:cursor.execute(p.read_text().replace('BEGIN;','',1).rsplit('COMMIT;',1)[0])
    return sha


def exercise(admin,runtime,developer,run_id,out):
    from fastapi import FastAPI,Header
    from fastapi.testclient import TestClient
    from sitewise.api.v1 import synthetic_execution as api
    from sitewise.dependencies import get_active_user
    app=FastAPI();app.include_router(api.router,prefix='/api/v1/cq')
    # Explicit private auth fixture; NOT evidence of real Supabase login.
    def actor(x_private_test_actor:str|None=Header(default=None)):
        return SimpleNamespace(user_id=UUID(x_private_test_actor) if x_private_test_actor else developer)
    app.dependency_overrides[get_active_user]=actor
    service=SyntheticExecutionService(runtime)
    app.dependency_overrides[api.get_execution]=lambda:service
    client=TestClient(app);base='/api/v1/cq/developer-imports/'+str(run_id)
    traces=[];checks={}
    def request(method,path,body=None,status=200,other=False):
        response=client.request(method,base+path,json=body,headers={'x-private-test-actor':str(uuid4())} if other else {})
        traces.append({'source':'private clone actual FastAPI routes; explicit auth fixture','method':method,'path':base+path,'request':body,'HTTP':response.status_code,'response':response.json()})
        with (out/'clone_interactive_http_events.jsonl').open('a',encoding='utf-8') as log:
            log.write(json.dumps(traces[-1])+'\n')
        assert response.status_code==status,(path,response.status_code,response.text)
        return response.json()
    cases=request('GET','/cases')['cases'];assert len(cases)==6
    for k in cases:request('GET','/sessions/'+k['session_id'],status=404,other=True)
    checks['cross_account_denied']=True
    def read(sid):return request('GET','/sessions/'+str(sid))
    def post(s,action,**values):
        return request('POST','/sessions/'+s['session_id']+'/'+action,{'expected_revision':s['revision'],'manifest_hash':s['manifest_hash'],**values})
    def ack(s):return post(s,'consent',request_id=str(uuid4()),consented=True,consent_version=s['manifest']['consent_version'])
    def answer(s,value=None,edit=None):
        s=post(s,'presentations',**({'edit_slot_id':edit} if edit else {}));p=s['presentation']
        s=post(s,'rendered',display_id=p['display_id'])
        q=next(q for q in s['manifest']['questions'] if q['id']==p['question_id'])
        if value is None:
            code='ONE' if q['id']=='Q04' else 'PROB_YES' if q['id']=='Q05' else q['validation']['substantive_codes'][0]
            value=[code] if q['type'] in ('multi_select','multi_select_with_exclusive_terminals') else code
        return post(s,'answers',request_id=str(uuid4()),display_id=p['display_id'],slot_id=p['slot_id'],value=value)
    normal=next(x for x in cases if x['case_key']=='01-normal-completion')
    s=ack(read(normal['session_id']))
    s=answer(s,['NEVER']);assert s['lifecycle_status']=='IN_PROGRESS'
    # Area/no-connection value itself never screens out a NORMAL fixture.
    s=answer(s,['LIVE'],edit='Q01');assert s['lifecycle_status']=='IN_PROGRESS'
    checks['geography_does_not_automatically_screen_out']=True
    s=post(s,'pause',request_id=str(uuid4()));assert s['status']=='PAUSED'
    restored=read(s['session_id']);assert restored['revision']==s['revision'] and restored['lifecycle_status']=='PAUSED'
    s=post(restored,'resume',request_id=str(uuid4()));assert s['status']=='ACTIVE'
    checks['pause_readback_resume']=True
    for _ in range(45):
        if s['next_stimulus_kind'] is not None:s=post(s,'stimuli',kind=s['next_stimulus_kind'])
        elif s['next_slot_id'] is not None:s=answer(s)
        else:break
    assert s['can_submit']
    rid=str(uuid4());before=s;s=post(s,'submit',request_id=rid)
    assert s['status']=='SUBMITTED' and s['lifecycle_status']=='COMPLETED'
    retry=post(before,'submit',request_id=rid);assert retry['receipt']['receipt_hash']==s['receipt']['receipt_hash']
    history=request('GET','/sessions/'+s['session_id']+'/history')['answers']
    assert len(history)>=15 and len([a for a in history if a['slot_id']=='Q01'])==2
    assert len({a['slot_id'] for a in history})==14
    checks['all_applicable_Q01_Q13_and_revisions']=True
    checks['submitted_preserved_completed_lifecycle']=True
    checks['completion_retry_idempotent']=True
    hypo=next(x for x in cases if x['scenario']=='HYPOTHETICAL_SCREENOUT')
    h=answer(ack(read(hypo['session_id'])),['LIVE'])
    assert h['lifecycle_status']=='SCREENED_OUT' and h['status']=='ACTIVE' and not h['can_submit']
    request('POST','/sessions/'+h['session_id']+'/submit',{'expected_revision':h['revision'],'manifest_hash':h['manifest_hash'],'request_id':str(uuid4())},status=409)
    checks['hypothetical_screenout_distinct_no_completion']=True
    recovery=next(x for x in cases if x['case_key']=='03-pause-recovery')
    p=answer(ack(read(recovery['session_id'])),['LIVE']);p=post(p,'pause',request_id=str(uuid4()))
    assert read(p['session_id'])['lifecycle_status']=='PAUSED'
    unresolved=next(x for x in cases if x['scenario']=='UNRESOLVED')
    u=read(unresolved['session_id']);assert u['lifecycle_status']=='UNRESOLVED' and not u['can_submit']
    checks['paused_and_unresolved_not_completed']=True
    with admin.connect() as c:
        receipt_count=c.scalar(text('SELECT count(*) FROM cq_submission_receipts WHERE session_id=:sid'),{'sid':hypo['session_id']})
        assert receipt_count==0
        rows=c.execute(text('SELECT * FROM cq_synthetic_execution_events ORDER BY created_at,id')).mappings().all()
        assert rows and all(v['developer_user_id']==developer and not v['real_reportable'] and op.digest(v['snapshot_json'])==v['snapshot_sha256'] for v in rows)
        (out/'clone_interactive_events.json').write_text(json.dumps(normalized([dict(v) for v in rows]),indent=2))
        campaign=c.execute(text('SELECT c.* FROM cq_campaigns c JOIN cq_sessions s ON s.campaign_id=c.id WHERE s.id=:sid'),{'sid':s['session_id']}).mappings().one()
        assert c.scalar(text("SELECT count(*) FROM cq_session_controls ctl JOIN cq_synthetic_cases x ON x.session_id=ctl.session_id WHERE ctl.research_mode='CUSTOMER_DEMAND_SURVEY'"))==0
    checks['transactional_actor_and_classification_audit']=True
    cutoff=datetime.now(timezone.utc)
    calc=Ee01Service(runtime,SyntheticPreviewAuthorization(run_id))
    measurement=calc.build_diagnostic(campaign['owner_user_id'],campaign['assessment_id'],campaign['id'],'Q05',cutoff,'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
    (out/'clone_interactive_measurement.json').write_text(json.dumps(measurement,indent=2))
    assert (measurement['q'],measurement['s'],measurement['a'],measurement['v'])==(3,2,2,2)
    assert all(v['percentage'] is None for v in measurement['cells'])
    top=next(v for v in measurement['cells'] if v['code']=='TOP_TWO_STATED_INTEREST')
    # Frozen original complete fixture selected DEF_NO; this new scripted
    # completion selected PROB_YES. Expected top-two is exactly 1/2, not 2/2.
    assert top['x']==1 and top['diagnostic_percentage']=='50.000000'
    with admin.connect() as c:
        assert c.scalar(text('SELECT count(DISTINCT s.respondent_user_id) FROM ee01_source_units u JOIN cq_sessions s ON s.id=u.session_id WHERE u.snapshot_id=:sid'),{'sid':measurement['id']})==7
        # Original completed subject plus six new nonhuman cases; only three
        # have the test-only eligibility + acknowledgment needed to qualify.
        sql=(ROOT/'tests/cq_runtime/VERIFY_EE01_FROM_CQ.sql').read_text()
        sql=sql[sql.index('WITH bound AS'):sql.index('COMMIT;')].replace("'CUSTOMER_DEMAND_SURVEY'","'DEVELOPER_PREVIEW'")
        for k,v in {'actor_id':campaign['owner_user_id'],'assessment_id':campaign['assessment_id'],'campaign_id':campaign['id'],'snapshot_id':measurement['id']}.items():
            sql=sql.replace(":"+"'"+k+"'", "'"+str(v)+"'")
        oracle=c.execute(text(sql)).scalar_one()
        assert oracle['matches_saved_counts'] and oracle['from_raw_CQ']=={'Q':3,'S':2,'A':2,'V':2,'top_two_x':1}
        assert oracle['diagnostic_percentage']==50
        (out/'independent_interactive_CQ_oracle.json').write_text(json.dumps(oracle,indent=2))
    checks['synthetic_EE01_Q3_S2_A2_V2']=True
    developer_reader=Ee01Service(runtime,SyntheticPreviewAuthorization(run_id,developer_user_id=developer))
    assert developer_reader.read(developer,campaign['assessment_id'],campaign['id'],UUID(measurement['id']))['fingerprint']==measurement['fingerprint']
    try:Ee01Service(runtime).read(campaign['owner_user_id'],campaign['assessment_id'],campaign['id'],UUID(measurement['id']))
    except Exception as exc:assert exc.code=='SYNTHETIC_DATA_NOT_REPORTABLE'
    else:raise AssertionError('Generated snapshot escaped boundary')
    checks['generated_diagnostic_not_real_reportable']=True
    (out/'clone_interactive_measurement.json').write_text(json.dumps(measurement,indent=2))
    (out/'clone_interactive_http.json').write_text(json.dumps(traces,indent=2))
    return checks


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--evidence',type=Path,required=True)
    p.add_argument('--prior',type=Path,required=True);p.add_argument('--run-id',type=UUID,required=True)
    p.add_argument('--developer',type=UUID,required=True);p.add_argument('--apply',action='store_true')
    p.add_argument('--prepare-only',action='store_true',help='Rehearse only additive case setup without replaying already-used cases')
    p.add_argument('--source-backup',type=Path,help='Replay a verified pristine private backup on a clone only')
    p.add_argument('--source-backup-sha256')
    p.add_argument('--fresh-case',default='05-full-questionnaire-retry')
    a=p.parse_args();out=a.evidence;out.mkdir(parents=True,exist_ok=True)
    source,app_url=op.configured_urls();pg=Path(r'C:\Program Files\PostgreSQL\16\bin')
    backup=out/'private_Dss_before_interactive.dump'
    env={**os.environ,'PGHOST':source.host,'PGPORT':str(source.port or 5432),'PGUSER':source.username,'PGPASSWORD':source.password,'PGDATABASE':'Dss'}
    if a.source_backup:
        if a.apply:raise ValueError('Saved backup replay cannot authorize changes to Dss')
        backup=a.source_backup.resolve()
        if hashlib.sha256(backup.read_bytes()).hexdigest()!=a.source_backup_sha256:raise ValueError('Pristine backup hash mismatch')
    with (out/'interactive_backup.log').open('w') as log:
        if not a.source_backup:
            subprocess.run([str(pg/'pg_dump.exe'),'-Fc','--file='+str(backup)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        subprocess.run([str(pg/'pg_restore.exe'),'--list',str(backup)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    backup_sha=hashlib.sha256(backup.read_bytes()).hexdigest()
    cfg=json.loads((a.prior/'private_cq_connection.json').read_text());runtime_cfg=json.loads((a.prior/'private_pg_connection.json').read_text())
    assert cfg['host']=='127.0.0.1' and cfg['port']==55443
    cluster=Path(cfg['cluster']);control=[str(pg/'pg_ctl.exe'),'-D',str(cluster/'data')]
    started=subprocess.run([*control,'status'],capture_output=True).returncode==3
    if started:
        with socket.socket() as s:s.bind(('127.0.0.1',55443))
        with (out/'interactive_cluster.log').open('a') as log:
            subprocess.run([*control,'-l',str(cluster/'interactive.log'),'-o','-h 127.0.0.1 -p 55443 -c shared_buffers=16MB -c work_mem=1MB -c maintenance_work_mem=16MB -c max_connections=12 -c max_worker_processes=0 -c autovacuum=off','-w','start'],stdout=log,stderr=subprocess.STDOUT,check=True)
    url=URL.create('postgresql+psycopg2',username='postgres',password=cfg['password'],host='127.0.0.1',port=55443,database='postgres')
    clone_name='project1_interactive_'+uuid4().hex[:10];engine=None;runtime=None
    try:
        admin=create_engine(url,isolation_level='AUTOCOMMIT')
        with admin.connect() as c:
            if not c.scalar(text("SELECT count(*) FROM pg_roles WHERE rolname='p1_ee01_runtime'")):
                from psycopg2 import sql
                with c.connection.driver_connection.cursor() as cursor:
                    cursor.execute(sql.SQL('CREATE ROLE p1_ee01_runtime LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD {}').format(sql.Literal(runtime_cfg['password'])))
            c.exec_driver_sql('CREATE DATABASE '+clone_name)
        admin.dispose()
        private_env={**env,'PGHOST':'127.0.0.1','PGPORT':'55443','PGUSER':'postgres','PGPASSWORD':cfg['password']}
        with (out/'interactive_restore.log').open('w') as log:
            subprocess.run([str(pg/'pg_restore.exe'),'--exit-on-error','--no-owner','--no-privileges','-d',clone_name,str(backup)],env=private_env,stdout=log,stderr=subprocess.STDOUT,check=True)
        engine=create_engine(url.set(database=clone_name),hide_parameters=True)
        with engine.begin() as c:
            c.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
            before=op.footprint(c)
            migrate(c,'20261116_02_ee01_snapshots.sql');migrate(c,'20261116_03_synthetic_import_boundary.sql')
            sha=migrate(c,'20261116_04_synthetic_interactive.sql')
            cases=prepare_cases(c,a.run_id,a.developer,'OWNER_NONHUMAN_INTERACTIVE_20261116')
            assert op.preserved(before,op.footprint(c))
        runtime=create_engine(url.set(database=clone_name,username='p1_ee01_runtime',password=runtime_cfg['password']),hide_parameters=True)
        if a.prepare_only:
            svc=SyntheticExecutionService(runtime)
            fresh=next(k for k in cases if k['case_key']==a.fresh_case)
            row=svc.execute(a.developer,a.run_id,UUID(fresh['session_id']),'read')
            assert row['revision']==0 and row['lifecycle_status']=='IN_PROGRESS' and not row['consented']
            with engine.begin() as c:
                before_retry=op.footprint(c)
                assert prepare_cases(c,a.run_id,a.developer,'OWNER_NONHUMAN_ADDITIONAL_CASE')==cases
                assert before_retry==op.footprint(c)
            try:svc.execute(uuid4(),a.run_id,UUID(fresh['session_id']),'read')
            except Exception as exc:assert exc.code=='SYNTHETIC_SESSION_NOT_FOUND'
            else:raise AssertionError('Additional case leaked')
            checks={'additive_case_is_pristine':True,'idempotent_case_setup':True,'other_account_denied':True}
        else:
            checks=exercise(engine,runtime,a.developer,a.run_id,out)
        checks['backup_restore_and_original_rows_preserved']=True
        result={'all_checks_passed':all(checks.values()),'checks':checks,'database':clone_name,'port':55443,
            'migration_sha256':sha,'backup_sha256':backup_sha,'cases':cases,'real_collection_enabled':False,
            'auth_fixture':'private API regression only; actual phone login remains separately required',
            'test_scope':'ADDITIVE_CASE_PREPARATION_ONLY' if a.prepare_only else 'FULL_INTERACTIVE_API_REHEARSAL'}
        (out/'interactive_clone_receipt.json').write_text(json.dumps(result,indent=2))
        assert result['all_checks_passed']
        if a.apply:
            # Every rehearsal submission was confined to the clone. Actual
            # Dss receives four pristine cases, no participant answers.
            actual=create_engine(source,hide_parameters=True)
            with actual.begin() as c:
                c.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
                before=op.footprint(c)
                assert migrate(c,'20261116_04_synthetic_interactive.sql')==sha
                actual_cases=prepare_cases(c,a.run_id,a.developer,'OWNER_NONHUMAN_INTERACTIVE_20261116')
                assert op.preserved(before,op.footprint(c))
            (out/'interactive_Dss_setup_receipt.json').write_text(json.dumps({'database':'Dss','migration_sha256':sha,'backup_sha256':backup_sha,'original_rows_preserved':True,'cases':actual_cases,'answers_seeded_into_Dss':False},indent=2))
            actual.dispose()
        print(json.dumps(result,indent=2))
    finally:
        if runtime:runtime.dispose()
        if engine:engine.dispose()
        if started:
            with (out/'interactive_cluster.log').open('a') as log:subprocess.run([*control,'-m','fast','-w','stop'],stdout=log,stderr=subprocess.STDOUT,check=True)


if __name__=='__main__':main()
