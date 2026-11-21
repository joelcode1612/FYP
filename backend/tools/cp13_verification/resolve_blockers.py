"""Read-only evidence for CP13 policy/configuration/schema gates. No dispatch."""
import hashlib
import json
from pathlib import Path
from datetime import datetime,timezone
import bootstrap
from cp13_manual_verify import inspect,save,SECRETS

def main():
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    from sqlalchemy.engine import make_url
    import psycopg2
    from sitewise.project1 import bdj,budget
    from sitewise.project1.provider import MODEL
    from sitewise.project1.qg_live import AUTHORIZATION_PATH,load_authorization
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.contracts import WorkflowHeld
    settings=bootstrap.configure();SECRETS.append(settings.tokenharbor_api_key.get_secret_value())
    out=args.output or bootstrap.ROOT/'artifacts/cp13_20261119/blocker_resolution'
    result=dict(observed_utc=datetime.now(timezone.utc).isoformat(),mode='LIVE_READ_ONLY',cloud_calls=0,
        configured_source=inspect(settings,'http://127.0.0.1:8090'),rules={},runtime_connections={},schema={},failures=[])
    for version,name in bdj.RULE_MODULES.items():
        from importlib import import_module
        module=import_module(name);path=Path(module.__file__)
        result['rules'][version]=dict(file=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            adoption_inferred=False,rule_catalogue=getattr(module,'RULE_CATALOGUE',None))
    for version in ('BDJ-M2V1-0.1-CAND','BDJ-RULESET-0.3-M2V1-CAND'):
        try:bdj.load_rules(version,'0'*64,'CP13-NEGATIVE-TEST-NOT-APPROVAL')
        except WorkflowHeld as exc:result['rules'][version]=dict(code=str(exc),registered=False,negative_test=True)
    decision=bootstrap.ROOT/'docs/cp00_integration/PROJECT1_D02_RULESET_RETIREMENT_DECISION_20261117.md'
    result['retirement_decision']=dict(path=str(decision),sha256=hashlib.sha256(decision.read_bytes()).hexdigest(),
        decision='D02: RETIRE; re-opening requires a new reviewed decision, not an invented receipt')
    flags=('TOKENHARBOR_ENABLED','PROJECT1_WORKFLOW_ENABLED','PROJECT1_RULES_VERSION','PROJECT1_RULES_SHA256',
           'PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS','TOKENHARBOR_STRUCTURED_MODE','TOKENHARBOR_TIMEOUT_SECONDS',
           'TOKENHARBOR_MODEL_IDENTITY_EXCEPTION')
    result['environment_file_flags']={}
    for path in (bootstrap.BACKEND/'.env',bootstrap.BACKEND/'.env.local'):
        if path.is_file():
            result['environment_file_flags'][str(path)]={}
            for line in path.read_text(encoding='utf-8-sig').splitlines():
                key,sep,value=line.partition('=')
                if sep and key.strip() in flags:result['environment_file_flags'][str(path)][key.strip()]=value.strip()
    result['budget']=budget.status()
    result['provider']=dict(configured_model=MODEL,identity_exception=settings.tokenharbor_model_identity_exception,
        key_present=bool(settings.tokenharbor_api_key.get_secret_value()),key_validity='NOT_VERIFIED: dispatch disabled',
        returned_model='NOT_OBSERVED_THIS_CP13',usage=None,actual_or_estimated_cost=None,
        caveat='Budget file cost ceiling is a policy value, not provider billing verification.')
    try:
        auth=load_authorization()
        result['qg_authorization']=dict(path=str(AUTHORIZATION_PATH),sha256=hashlib.sha256(AUTHORIZATION_PATH.read_bytes()).hexdigest(),
            assessment_id=auth['assessment_id'],source_fingerprint=auth['source_fingerprint'],
            actor_hash=hashlib.sha256(str(auth['actor_id']).encode()).hexdigest(),max_attempts=auth['max_attempts'],
            purpose=auth['purpose'],receipt_present=bool(auth['operator_receipt']),
            scope='Existing exact-source synthetic authorization, not authority for any newly selected assessment')
    except WorkflowHeld as exc:result['qg_authorization']=dict(code=str(exc))
    urls={'m2':settings.m2_database_url.get_secret_value(),'workflow':settings.project1_runtime_database_url.get_secret_value()}
    for name,url in urls.items():
        try:
            u=make_url(url)
            conn=psycopg2.connect(host=u.host,port=u.port or 5432,dbname=u.database,user=u.username,password=u.password,
                connect_timeout=5,options='-c default_transaction_read_only=on -c statement_timeout=10000')
            try:
                with conn.cursor() as q:
                    q.execute('SELECT current_database(),session_user,current_user,rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user')
                    result['runtime_connections'][name]=dict(status='PASS',identity=q.fetchone())
                    if name=='workflow':
                        q.execute('SET LOCAL ROLE p1ai_runtime')
                        q.execute('SELECT current_user,current_setting(\'transaction_read_only\')')
                        result['runtime_connections'][name]['restricted_role']=q.fetchone()
            finally:conn.rollback();conn.close()
        except Exception as exc:
            result['runtime_connections'][name]=dict(status='BLOCKED',error_type=type(exc).__name__)
    u=make_url(settings.database_url)
    conn=psycopg2.connect(host=u.host,port=u.port or 5432,dbname='Dss',user=u.username,password=u.password,
        options='-c default_transaction_read_only=on -c statement_timeout=10000')
    try:
        with conn.cursor() as q:
            q.execute("SELECT table_schema,table_name,column_name,data_type,is_nullable FROM information_schema.columns WHERE (table_schema='project1_ai' OR (table_schema='public' AND table_name LIKE 'm2_%')) ORDER BY 1,2,ordinal_position")
            result['schema']['columns']=q.fetchall()
            required={'public.m2_assessments','public.m2_answer_revisions','public.m2_confirmation_snapshots',
                'public.m2_business_contexts','public.m2_business_context_builds','public.m2_confirmed_uncertainties',
                'public.m2_research_objective_sources','public.m2_review_question_versions',
                'project1_ai.runs','project1_ai.attempts','project1_ai.attempt_receipts','project1_ai.bdj_results'}
            present={row[0]+'.'+row[1] for row in result['schema']['columns']}
            result['schema']['required_tables_missing']=sorted(required-present)
            q.execute("SELECT conrelid::regclass::text,conname,pg_get_constraintdef(oid) FROM pg_constraint WHERE contype='f' AND (connamespace='public'::regnamespace OR connamespace='project1_ai'::regnamespace) AND (conrelid::regclass::text LIKE 'm2_%' OR conrelid::regclass::text LIKE 'project1_ai.%') ORDER BY 1,2")
            result['schema']['foreign_keys']=q.fetchall()
            q.execute("SELECT has_table_privilege('p1_m2_runtime','public.m2_business_contexts','SELECT,INSERT'),has_table_privilege('p1_m2_runtime','public.m2_business_context_builds','SELECT,INSERT,UPDATE'),has_table_privilege('p1ai_runtime','project1_ai.attempts','SELECT,INSERT')")
            result['schema']['runtime_grants']=q.fetchone()
            q.execute('SELECT id::text,revision,confirmed_revision,created_at,(SELECT min(created_at) FROM public.m2_answer_revisions WHERE assessment_id=a.id),(SELECT max(created_at) FROM public.m2_answer_revisions WHERE assessment_id=a.id),(SELECT count(*) FROM public.m2_answer_revisions WHERE assessment_id=a.id) FROM public.m2_assessments a WHERE id=%s',('b28cd847-89f6-4994-adad-f79846f77c2e',))
            result['protected_fiesta_observation']=q.fetchone()
            queries={
                'contexts':'SELECT context_id::text,confirmation_id::text,assessment_revision,packet_hash,builder_version FROM public.m2_business_contexts WHERE assessment_id=%s',
                'build_status':'SELECT confirmation_id::text,status,last_code,context_id::text,attempt_count FROM public.m2_business_context_builds WHERE assessment_id=%s',
                'confirmations':'SELECT id::text,assessment_revision,snapshot_digest FROM public.m2_confirmation_snapshots WHERE assessment_id=%s'}
            result['protected_fiesta_context_readback']={}
            for name,statement in queries.items():
                q.execute(statement,('b28cd847-89f6-4994-adad-f79846f77c2e',))
                result['protected_fiesta_context_readback'][name]=dict(sql=statement,rows=q.fetchall())
    finally:conn.rollback();conn.close()
    save(out/'blocker_evidence.json',result)
    print(json.dumps(dict(evidence=str(out/'blocker_evidence.json'),runtime_connections=result['runtime_connections'],
        missing_tables=result['schema']['required_tables_missing'],runtime_grants=result['schema']['runtime_grants'],
        budget=result['budget'],cloud_calls=0),indent=2))
    return 0

if __name__=='__main__':raise SystemExit(main())
