"""Independent CP13 verifier. No migrations, seeding, deletion or QJ dispatch."""
from __future__ import annotations
import argparse
from copy import deepcopy
from datetime import datetime, timezone
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from uuid import UUID
from urllib.parse import urlsplit

import bootstrap
from bootstrap import BACKEND, ROOT, PACKAGE

PROTECTED = {'ad723b3f-5937-44f3-bb94-3d0f3048c034','b28cd847-89f6-4994-adad-f79846f77c2e',
    'ffa8c0a3-fcd9-4e12-afa1-b7ce6392cc1b','7a2f0b5c-6e75-4aa0-934b-a529681b20ac',
    'b438c959-dbb4-4f99-8322-0f841dbba755'}
SECRETS=[]

def sanitize(value):
    """Never serialize headers, credentials or personal information into evidence."""
    if isinstance(value,dict):
        return {k:('[REDACTED]' if re.fullmatch(r'(?:.*_)?(?:password|secret|api_key|access_token|refresh_token|email)|authorization|authorization_header|proxy-authorization',k,re.I)
                   else sanitize(v)) for k,v in value.items()}
    if isinstance(value,(list,tuple)): return [sanitize(v) for v in value]
    if isinstance(value,str):
        for secret in SECRETS:
            if secret: value=value.replace(secret,'[REDACTED]')
        value=re.sub(r'(?i)(postgres(?:ql)?(?:\+\w+)?://)[^\s/@]+:[^\s/@]+@',r'\1[REDACTED]@',value)
        value=re.sub(r'(?i)Bearer\s+[^\s"\']+','Bearer [REDACTED]',value)
        return re.sub(r'[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}','[REDACTED_EMAIL]',value)
    return value

def save(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(sanitize(value),indent=2,ensure_ascii=False,default=str)+'\n',encoding='utf-8')

def assertion(name,expected,actual):
    return dict(name=name,expected=expected,actual=actual,status='PASS' if actual==expected else 'FAIL')

def controlled(case,module):
    from harness import CASES,fixture,run_bdj,attach_findings,run_bcb,run_qg
    f=fixture(case); original=deepcopy(f); spec=CASES[case]
    result=dict(mode='MOCKED',scope='Actual engines with test-only source/confirmation/policy/transport ports. No DB or cloud.',
        case=case,synthetic=True,input=deepcopy(f),modules={},assertions=[],database=dict(status='NOT_EXECUTED'))
    packet=None
    if case in {'confirmed-objective','clarify-objective','separate-concern'}:
        from objective_fixture import objective_actions
        try:
            result['objective_action']=objective_actions(case,spec)
            result['assertions'].append(assertion('existing ConfirmationService action','PASS',result['objective_action']['status']))
        except Exception as exc:
            result['objective_action']=dict(status='FAIL',error_type=type(exc).__name__,reason=str(exc))
            result['assertions'].append(assertion('existing ConfirmationService action','PASS','FAIL'))
    # BCB and QG standalone requests construct the prerequisite test context;
    # they never imply that an actual confirmation was created in PostgreSQL.
    for stage in ('bdj','bcb','direct-qg'):
        if module!='all' and stage!=module and stage!='bcb': continue
        if module=='bdj' and stage!='bdj': continue
        calls=[]; output=None
        try:
            if stage=='bdj':
                output,calls=run_bdj(f,spec)
                observed=output['outcome']
                attach_findings(f,output)
            elif stage=='bcb':
                packet=run_bcb(f); output=packet; observed='BUILT'
            else:
                if packet is None: observed='UPSTREAM_BCB_BLOCKED'
                else:
                    output,calls=run_qg(packet,spec); observed=output['status']
        except Exception as exc:
            observed=getattr(exc,'code',None) or str(exc)
            calls=getattr(exc,'cp13_calls',calls)
            output=dict(error_type=type(exc).__name__,code=observed)
        expected=spec['expected'][stage]
        check=assertion(stage+' expected outcome',expected,observed)
        result['assertions'].append(check)
        result['modules'][stage]=dict(mode='MOCKED',status=check['status'],observed=observed,
            input_revision=f['assessment']['revision'],output=output,provider_calls=calls,
            cloud_dispatch_count=0,token_usage=None,estimated_cost=None,
            note='BCB is deterministic. All provider replies and confirmation records in controlled mode are test fixtures.')
    result['assertions'].append(assertion('canonical source remains unchanged',original,fixture(case)))
    result['status']='FAIL' if any(x['status']=='FAIL' for x in result['assertions']) else 'PASS'
    return result

SOURCE_FILES = [
    'api/v1/project1_workflow.py','api/v1/m2.py','api/v1/m2_business_context.py','api/v1/qg_candidate.py',
    'services/bdj_service.py','services/confirmation_service.py','services/persisted_business_context_service.py',
    'services/business_context_v1.py','services/qg_candidate_service.py',
    'project1/model_assisted.py','project1/direct_qg_service.py','project1/provider.py',
    'project1/prompts.py','project1/bdj.py','project1/qg_contract.py','project1/qg_live.py',
    'repositories/m2_context_bindings.py','db/models/m2_schema.py','db/models/business_context_schema.py']

def inspect(settings,base):
    import httpx
    from sqlalchemy.engine import make_url
    from sitewise.project1.provider import MODEL,ENDPOINT
    from sitewise.project1.prompts import PROMPTS
    result=dict(mode='LIVE',scope='Read-only current configuration/source and running OpenAPI; no model call',
        status='PASS',git={},provider=dict(endpoint=ENDPOINT,model=MODEL,
            enabled=settings.tokenharbor_enabled,key_configured=bool(settings.tokenharbor_api_key.get_secret_value()),
            structured_mode=settings.tokenharbor_structured_mode,timeout_seconds=settings.tokenharbor_timeout_seconds,
            max_output_tokens=4000,max_auto_retries=0,token_usage=None,estimated_cost=None),
        prompts={k:dict(version=PROMPTS[k].version,sha256=PROMPTS[k].fingerprint) for k in ('BDJ','QG_PROPOSAL')},
        flags={k:getattr(settings,k) for k in ('m2_upstream_enabled','m2_bcb_persistence_enabled',
            'project1_workflow_enabled','tokenharbor_model_identity_exception','project1_rules_version',
            'project1_bcb_confirmation_validity_days')},
        rules_adoption_receipt_present=bool(settings.project1_rules_adoption_receipt),
        databases={},source_files={},cloud_dispatch_count=0,blockers=[])
    import subprocess
    for key,cmd in [('branch',['git','branch','--show-current']),('head',['git','rev-parse','HEAD'])]:
        result['git'][key]=subprocess.check_output(cmd,cwd=ROOT,text=True).strip()
    for field in ('database_url','m2_database_url','project1_runtime_database_url'):
        raw=getattr(settings,field);raw=raw.get_secret_value() if hasattr(raw,'get_secret_value') else raw
        if raw:
            url=make_url(raw)
            result['databases'][field]=dict(driver=url.drivername,host=url.host,port=url.port,database=url.database,
                role=url.username,password_configured=bool(url.password))
    for name in SOURCE_FILES:
        path=BACKEND/'src/sitewise'/name
        result['source_files'][name]=dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),path=str(path))
    try:
        with httpx.Client(timeout=15,follow_redirects=False,trust_env=False) as client:
            response=client.get(base+'/openapi.json')
            result['openapi_http_status']=response.status_code
            response.raise_for_status()
            api=response.json()
            result['registered_routes']={p:{m:dict(operation_id=v.get('operationId'),
                request_body=v.get('requestBody'),responses=v.get('responses')) for m,v in methods.items()
                if m in {'get','post','put','delete'}} for p,methods in api['paths'].items()
                if ('/m2/' in p or '/project1-workflow/' in p) and '/qj-' not in p}
            result['schemas']={k:v for k,v in api.get('components',{}).get('schemas',{}).items()
                if any(x in k for x in ('Context','Candidate','Revision','Objective','Confirm','ReviewRequest'))}
            result['read_only_probes']=[]
            for path in ('/health','/api/v1/m2/instruments','/api/v1/project1-workflow/setup'):
                r=client.get(base+path)
                try:body=r.json()
                except ValueError:body={'body_sha256':hashlib.sha256(r.content).hexdigest(),'content_type':r.headers.get('content-type')}
                result['read_only_probes'].append(dict(method='GET',path=path,status=r.status_code,body=body))
    except Exception:
        result['openapi_status']='BLOCKED: running API unavailable or OpenAPI not readable'
    if not settings.tokenharbor_enabled: result['blockers'].append('PROVIDER_NOT_CONFIGURED: TOKENHARBOR_ENABLED=false')
    if not settings.project1_workflow_enabled: result['blockers'].append('Cloud BDJ router not mounted: PROJECT1_WORKFLOW_ENABLED=false')
    if not result['rules_adoption_receipt_present'] or not settings.project1_rules_version:
        result['blockers'].append('BDJ_RULE_ADOPTION_REQUIRED')
    if settings.project1_bcb_confirmation_validity_days is None:
        result['blockers'].append('VALIDITY_BASIS_UNAUTHORIZED: no BCB confirmation validity policy configured')
    result['implementation_gate_probes']={}
    if not settings.project1_workflow_enabled:
        from sitewise.api.v1.project1_workflow import configuration_gate
        try:configuration_gate(None)
        except Exception as exc:
            result['implementation_gate_probes']['cloud_bdj']=dict(status_code=getattr(exc,'status_code',None),detail=getattr(exc,'detail',type(exc).__name__))
    if not settings.tokenharbor_enabled:
        from sitewise.project1.provider import configured_runner
        from sitewise.project1.contracts import BDJOutput
        try:configured_runner(None,None,PROMPTS).provider.complete([],BDJOutput)
        except Exception as exc:result['implementation_gate_probes']['provider']=dict(code=str(exc),dispatched=False)
    if settings.project1_bcb_confirmation_validity_days is None:
        from sitewise.repositories.m2_context_bindings import confirmation_horizon
        try:confirmation_horizon({},None)
        except Exception as exc:result['implementation_gate_probes']['bcb_validity']=dict(code=str(exc))
    from sitewise.api.v1 import project1_workflow as workflow_api
    result['source_routing']=dict(dedicated_m2_owner_session=hasattr(workflow_api,'get_workflow_source_db'),
        running_activation='Not demonstrated; workflow router is currently disabled')
    result['blockers'].extend([
        'Normal M2 source projection does not supply synthetic disclosure markers; cloud-BDJ must refuse it.',
        'Direct-QG live runner additionally requires its exact source-bound server authorization and persisted current objective/context.'])
    return result

def database_readback(settings):
    """Actual local databases, READ ONLY. Emit hashes, counts and target metadata only."""
    import psycopg2
    from psycopg2 import sql
    from sqlalchemy.engine import make_url
    u=make_url(settings.database_url)
    result=dict(mode='LIVE',readonly=True,databases={})
    for database in ('Dss','Final_Location_Analysis'):
        info=dict(tables={},status='PASS')
        try:
            conn=psycopg2.connect(host=u.host,port=u.port or 5432,user=u.username,password=u.password,
                dbname=database,connect_timeout=5,options='-c default_transaction_read_only=on -c statement_timeout=30000')
            try:
                conn.set_session(readonly=True,isolation_level='REPEATABLE READ')
                with conn.cursor() as q:
                    q.execute('SELECT current_database(),current_user, current_setting(\'transaction_read_only\')')
                    info['identity']=q.fetchone()
                    q.execute("SELECT table_schema,table_name FROM information_schema.tables WHERE table_type='BASE TABLE' AND (table_schema='project1_ai' OR (table_schema='public' AND (table_name LIKE 'm2_%' OR table_name='assessment'))) ORDER BY 1,2")
                    for schema,table in q.fetchall():
                        # Server computes hashes; no answer text or owner identities are exported.
                        q.execute(sql.SQL('SELECT md5(to_jsonb(r)::text) FROM {}.{} r ORDER BY 1').format(sql.Identifier(schema),sql.Identifier(table)))
                        hashes=[r[0] for r in q.fetchall()]
                        info['tables'][schema+'.'+table]=dict(count=len(hashes),
                            sha256=hashlib.sha256('\n'.join(hashes).encode()).hexdigest())
                    if database=='Dss':
                        q.execute('SELECT id::text,revision,confirmed_revision,(SELECT count(*) FROM public.m2_answer_revisions r WHERE r.assessment_id=a.id) FROM public.m2_assessments a WHERE id=%s',('b28cd847-89f6-4994-adad-f79846f77c2e',))
                        info['protected_blank_fiesta']=q.fetchone()
                        q.execute('SELECT marketplace_assessment_id::text,m2_assessment_id::text,revoked_at IS NULL FROM public.m2_assessment_links WHERE marketplace_assessment_id=%s',('ad723b3f-5937-44f3-bb94-3d0f3048c034',))
                        info['protected_blank_link']=q.fetchall()
                    q.execute("SELECT tc.table_name,kcu.column_name,ccu.table_name,ccu.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu USING(constraint_catalog,constraint_schema,constraint_name) JOIN information_schema.constraint_column_usage ccu USING(constraint_catalog,constraint_schema,constraint_name) WHERE tc.constraint_type='FOREIGN KEY' AND tc.table_schema='public' AND tc.table_name LIKE 'm2_%' ORDER BY 1,2")
                    info['m2_foreign_keys']=q.fetchall()
            finally: conn.rollback();conn.close()
        except Exception as exc:
            info['status']='BLOCKED';info['error_type']=type(exc).__name__
        result['databases'][database]=info
    result['status']='PASS' if all(x['status']=='PASS' for x in result['databases'].values()) else 'BLOCKED'
    return result

def live(args,settings,inventory):
    """Use existing authenticated routes only; never substitutes a fixture model."""
    import httpx
    result=dict(mode='BLOCKED',requested_mode='LIVE',status='BLOCKED',modules={},http=[],cloud_dispatch_count=0,
        token_usage=None,estimated_cost=None,blockers=[],database=dict(status='NOT_EXECUTED'),case=args.case)
    if inventory.get('git',{}).get('branch')!='merge_main_jed':
        result['blockers'].append('Live writer requires the verified merge_main_jed checkout')
    for name in ('assessment_id','confirmation_id','objective_id','context_id'):
        value=getattr(args,name,None)
        if value:
            try: UUID(value)
            except ValueError:
                result['blockers'].append(name+' must be a UUID')
            if value in PROTECTED: result['blockers'].append('Protected record refused: '+name)
    if not args.allow_test_writes: result['blockers'].append('Live route execution requires --allow-test-writes and a prepared isolated test record.')
    if not args.assessment_id: result['blockers'].append('--assessment-id required; the blank Fiesta record is forbidden')
    if args.revision is None: result['blockers'].append('--revision required')
    if args.module in {'bdj','all'}:
        if not settings.project1_workflow_enabled: result['blockers'].append('Cloud BDJ router disabled')
        if not settings.project1_rules_version or not settings.project1_rules_adoption_receipt:
            result['blockers'].append('BDJ_RULE_ADOPTION_REQUIRED')
    if args.module in {'bdj','direct-qg','all'} and not settings.tokenharbor_enabled:
        result['blockers'].append('PROVIDER_NOT_CONFIGURED')
    if args.module in {'bcb','all'} and not args.confirmation_id: result['blockers'].append('--confirmation-id required: human confirmation is not fabricated')
    if args.module in {'direct-qg','all'} and not args.objective_id: result['blockers'].append('--objective-id required: confirmed objective is not fabricated')
    if args.module=='direct-qg' and not args.context_id: result['blockers'].append('--context-id required')
    if urlsplit(args.api_base).port==8090:
        result['blockers'].append('Port 8090 is the original application; live writes in this package require a separately configured test API port.')
    if args.module in {'direct-qg','all'}:
        try:
            from sitewise.project1.qg_live import load_authorization
            auth=load_authorization(BACKEND/'var/qg_synthetic_authorization.json')
            if auth['assessment_id']!=args.assessment_id or auth['max_attempts']!=1:
                result['blockers'].append('QG server authorization must bind the test assessment with max_attempts=1')
        except Exception as exc:result['blockers'].append(str(exc))
    url=os.environ.get('CP13_TEST_DATABASE_URL','')
    from sqlalchemy.engine import make_url
    try:
        db=make_url(url)
        if db.database not in {'project1_cp13_test','project1_workflow_tests','project1_m2_bcb_test'} or db.get_backend_name()!='postgresql':
            raise ValueError('isolated database required')
        result['database']['name']=db.database
    except Exception: result['blockers'].append('CP13_TEST_DATABASE_URL must name an allowed isolated PostgreSQL test database')
    if result['blockers']: return result
    token=os.environ.get('CP13_BEARER_TOKEN') or (getpass.getpass('Test-account bearer token (hidden): ') if args.prompt_token else '')
    if not token:
        result['blockers'].append('CP13_BEARER_TOKEN required; no authentication bypass');return result
    SECRETS.append(token)
    # Readonly DB fingerprint must agree with authenticated HTTP source projection
    # before any POST, and connection must be to the explicit isolated DB.
    import psycopg2
    try:
        conn=psycopg2.connect(host=db.host,port=db.port or 5432,dbname=db.database,user=db.username,password=db.password,
            connect_timeout=5,options='-c default_transaction_read_only=on -c statement_timeout=10000')
        with conn:
            with conn.cursor() as q:
                q.execute('SELECT id::text,owner_user_id::text,revision FROM public.m2_assessments WHERE id=%s',(args.assessment_id,))
                identity=q.fetchone()
        conn.close()
        if not identity or identity[2]!=args.revision: raise ValueError('source mismatch')
        # A clone of a real record is not an isolated new test identity. Ensure
        # this UUID is absent from original Dss before contacting a write route.
        original=make_url(settings.m2_database_url.get_secret_value())
        if original.database!='Dss':raise ValueError('original Dss identity unavailable')
        conn=psycopg2.connect(host=original.host,port=original.port or 5432,dbname=original.database,
            user=original.username,password=original.password,connect_timeout=5,
            options='-c default_transaction_read_only=on -c statement_timeout=10000')
        try:
            with conn.cursor() as q:
                q.execute("SELECT set_config('project1.actor_id',%s,true)",(identity[1],))
                q.execute('SELECT count(*) FROM public.m2_assessments WHERE id=%s',(args.assessment_id,))
                if q.fetchone()[0]!=0:raise ValueError('record exists in original Dss')
        finally:conn.rollback();conn.close()
    except Exception:
        result['blockers'].append('Isolated source ownership/revision readback unavailable');return result
    with httpx.Client(base_url=args.api_base,headers={'Authorization':'Bearer '+token},timeout=65,follow_redirects=False,trust_env=False) as client:
        def request(method,path,body=None):
            start=time.monotonic()
            r=client.request(method,path,json=body)
            try: output=r.json()
            except ValueError: output={'code':'NON_JSON_RESPONSE','body_sha256':hashlib.sha256(r.content).hexdigest()}
            result['http'].append(dict(method=method,path=path,request=body,status=r.status_code,
                seconds=round(time.monotonic()-start,3),response=output))
            return r.status_code,output
        try:
            status,source=request('GET',f'/api/v1/m2/assessments/{args.assessment_id}/source-projection?expected_revision={args.revision}')
            from sitewise.project1.contracts import digest
            if status!=200 or source.get('assessment_id')!=identity[0] or source.get('assessment_revision')!=identity[2]:
                result['blockers'].append('Authenticated source projection does not match isolated database');return result
            # Recompute through the existing DB projection under the same owner.
            from sqlalchemy import create_engine
            from sqlmodel import Session
            from sitewise.repositories.m2_repository import SqlModelM2Repository
            from sitewise.project1.projection import M2SourceProjection
            engine=create_engine(url,hide_parameters=True,connect_args={'options':'-c default_transaction_read_only=on'})
            try:
                with Session(engine) as session:
                    local=M2SourceProjection(SqlModelM2Repository(session)).read(UUID(identity[0]),UUID(identity[1]),identity[2])
            finally: engine.dispose()
            if local!=source:
                result['blockers'].append('HTTP and isolated PostgreSQL source fingerprints differ');return result
            result['input']=source
            context_id=args.context_id
            for stage in ('bdj','bcb','direct-qg'):
                if args.module not in {'all',stage}:continue
                if stage=='bdj': path=f'/api/v1/project1-workflow/assessments/{args.assessment_id}/business-understanding/model-assisted';payload={'expected_revision':args.revision}
                elif stage=='bcb': path=f'/api/v1/m2/assessments/{args.assessment_id}/business-context';payload=dict(confirmation_id=args.confirmation_id,expected_revision=args.revision)
                else: path=f'/api/v1/m2/research-objectives/{args.objective_id}/qg-candidate';payload=dict(expected_revision=args.revision,context_id=context_id)
                result['cloud_dispatch_count']='NOT_OBSERVED: reconcile server receipts'
                status,body=request('POST',path,payload)
                valid=status in {200,201}
                if stage=='bdj': valid=valid and body.get('review_outcome')=='reviewed' and body.get('result_id') is not None
                if stage=='direct-qg': valid=valid and body.get('status') in {'VALIDATED_OUTPUT','VALID_ABSTENTION'}
                result['modules'][stage]=dict(mode='LIVE',status='PASS' if valid else 'BLOCKED',http_status=status,output=body)
                if not valid:
                    result['blockers'].append(stage+' did not produce a validated successful result');break
                if stage=='bcb':context_id=body['context_id']
            # Actual persisted readback, including audit rows, without exporting private raw payloads.
            conn=psycopg2.connect(host=db.host,port=db.port or 5432,dbname=db.database,user=db.username,password=db.password,
                options='-c default_transaction_read_only=on -c statement_timeout=10000')
            try:
                with conn.cursor() as q:
                    result['database']['rows']={}
                    for table in ('m2_assessments','m2_answer_revisions','m2_bdj_findings','m2_confirmation_snapshots','m2_business_contexts'):
                        column='id' if table=='m2_assessments' else 'assessment_id'
                        from psycopg2 import sql
                        q.execute(sql.SQL('SELECT to_jsonb(r) FROM public.{} r WHERE {}=%s').format(sql.Identifier(table),sql.Identifier(column)),(args.assessment_id,))
                        result['database']['rows'][table]=[r[0] for r in q.fetchall()]
                    q.execute('SELECT to_jsonb(r) FROM project1_ai.runs r WHERE assessment_id=%s',(args.assessment_id,))
                    result['database']['runs']=[r[0] for r in q.fetchall()]
                    q.execute('SELECT a.stage,a.prompt_version,a.prompt_hash,a.request_hash,a.attempt_no FROM project1_ai.attempts a JOIN project1_ai.runs r ON r.id=a.run_id WHERE r.assessment_id=%s',(args.assessment_id,))
                    result['database']['attempts']=q.fetchall()
                    q.execute('SELECT to_jsonb(a) FROM project1_ai.attempt_receipts a JOIN project1_ai.runs r ON r.id=a.run_id WHERE r.assessment_id=%s',(args.assessment_id,))
                    result['database']['receipts']=[r[0] for r in q.fetchall()]
                    q.execute('SELECT result_id::text,assessment_revision,source_fingerprint,prompt_version,model_requested,model_returned,validation_status,review_outcome FROM project1_ai.bdj_results WHERE assessment_id=%s',(args.assessment_id,))
                    result['database']['bdj_results']=q.fetchall()
                    q.execute('SELECT q.id::text,q.objective_id::text,q.source_receipt,q.question,q.options FROM public.m2_review_question_versions q JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id WHERE c.assessment_id=%s',(args.assessment_id,))
                    result['database']['candidates']=q.fetchall()
                    result['database']['status']='PASS'
            finally:conn.rollback();conn.close()
        except httpx.TransportError:
            result['blockers'].append('HTTP_TIMEOUT_OUTCOME_UNKNOWN: no automatic repeat POST')
        except Exception as exc:
            result['blockers'].append('Verification stopped: '+type(exc).__name__)
    result['mode']='LIVE' if result['modules'] else 'BLOCKED'
    result['assertions']=verify_live_evidence(result,args)
    if any(x['status']=='FAIL' for x in result['assertions']):
        result['blockers'].append('Live evidence is incomplete or inconsistent; see expected-versus-actual assertions')
    result['status']='BLOCKED' if result['blockers'] else 'PASS'
    return result

def verify_live_evidence(result,args):
    """Require persisted source, result, provenance and receipts, not only HTTP 2xx."""
    from sitewise.project1.contracts import digest
    from sitewise.project1.provider import MODEL
    checks=[];database=result.get('database',{});rows=database.get('rows',{})
    for stage,module in result['modules'].items():
        if module['status']!='PASS':continue
        body=module['output']
        if stage=='bcb':
            stored=[x for x in rows.get('m2_business_contexts',[]) if str(x['context_id'])==body['context_id']]
            checks.append(assertion('BCB immutable row matches HTTP packet',True,
                len(stored)==1 and stored[0]['packet_json']==body['packet']))
            packet=body['packet']
            checks.append(assertion('BCB packet fingerprint',packet.get('packet_hash'),
                digest({k:v for k,v in packet.items() if k!='packet_hash'})))
        elif stage=='bdj':
            stored=[x for x in database.get('bdj_results',[]) if x[0]==body['result_id']]
            checks.append(assertion('BDJ persisted result, exact requested/returned model and revision',True,
                len(stored)==1 and stored[0][1]==args.revision and stored[0][2]==result['input']['source_fingerprint']
                and stored[0][4]==stored[0][5]==MODEL and stored[0][7]=='reviewed'))
            checks.append(assertion('BDJ returned attempt receipt',True,
                any(x.get('outcome')=='returned' for x in database.get('receipts',[]))))
        else:
            candidates=[x for x in database.get('candidates',[]) if x[0]==body.get('version')]
            checks.append(assertion('Direct-QG candidate saved for exact confirmed objective',True,
                body.get('status')=='VALIDATED_OUTPUT' and len(candidates)==1 and candidates[0][1]==args.objective_id
                and candidates[0][3]==body['candidate']['question']))
            # The existing candidate API does not guarantee model identity metadata.
            # Refuse to guess it from the configured/requested name.
            identity=body.get('provider_execution') or {}
            checks.append(assertion('Direct-QG actual returned model independently recorded',MODEL,identity.get('model_returned')))
            checks.append(assertion('Direct-QG identity and receipt verified',True,
                identity.get('identity_verified') is True and identity.get('receipt_recorded') is True))
            if candidates:
                saved=candidates[0][2]
                if isinstance(saved,str):saved=json.loads(saved)
                checks.append(assertion('Direct-QG execution metadata persisted with candidate',identity,
                    (saved.get('evaluation') or {}).get('provider_execution')))
            checks.append(assertion('Direct-QG returned attempt receipt',True,
                any(x.get('outcome')=='returned' for x in database.get('receipts',[]))))
    return checks

def parser():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mode',choices=['inspect','controlled','live'],default='inspect')
    p.add_argument('--module',choices=['bdj','bcb','direct-qg','all'],default='all')
    p.add_argument('--case',default='complete')
    p.add_argument('--all-cases',action='store_true')
    p.add_argument('--menu',action='store_true')
    p.add_argument('--api-base',default=os.environ.get('CP13_API_BASE','http://127.0.0.1:8090'))
    for key in ('assessment-id','confirmation-id','objective-id','context-id'):p.add_argument('--'+key)
    p.add_argument('--revision',type=int)
    p.add_argument('--allow-test-writes',action='store_true')
    p.add_argument('--prompt-token',action='store_true')
    p.add_argument('--database-readback',action='store_true')
    p.add_argument('--output',type=Path)
    p.add_argument('--quiet',action='store_true',help='Print result summaries; full sanitized inputs/outputs remain in JSON')
    return p

def main(argv=None):
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    p=parser();args=p.parse_args(argv)
    from harness import CASES
    if args.menu or (argv is None and len(sys.argv)==1):
        print('CP13: 1 Inspect | 2 BDJ | 3 BCB | 4 Direct-QG | 5 Full workflow')
        choice=input('Select [1]: ').strip() or '1'
        args.module={'2':'bdj','3':'bcb','4':'direct-qg','5':'all'}.get(choice,'all')
        args.mode='inspect' if choice=='1' else (input('Mode controlled/live [controlled]: ').strip() or 'controlled')
        if args.mode not in {'inspect','controlled','live'}:p.error('invalid mode')
        if args.mode!='inspect':
            print('Cases: '+', '.join(CASES));args.case=input('Case [complete]: ').strip() or 'complete'
        if args.mode=='live':
            print('Live mode needs prepared isolated records. Use CLI arguments shown by --help; no record will be created.')
    if args.case not in CASES:p.error('Unknown case; choose '+', '.join(CASES))
    if args.mode=='live' and (args.all_cases or CASES[args.case].get('fault')):
        p.error('Live batch/failure injection prohibited; run one bounded positive case or controlled failures')
    uri=urlsplit(args.api_base)
    if uri.scheme not in {'http','https'} or uri.hostname not in {'127.0.0.1','localhost','::1'} or uri.username or uri.password or uri.query or uri.fragment:
        p.error('Only an explicit credential-free local FastAPI origin is supported')
    args.api_base=args.api_base.rstrip('/')
    settings=bootstrap.configure()
    SECRETS.append(settings.tokenharbor_api_key.get_secret_value())
    out=args.output or PACKAGE/'results'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=out.resolve();out.mkdir(parents=True,exist_ok=True)
    inventory=inspect(settings,args.api_base);save(out/'implementation_inventory.json',inventory)
    before=database_readback(settings) if args.database_readback else None
    if before:save(out/'database_before.json',before)
    if args.mode=='inspect':runs=[inventory]
    elif args.mode=='controlled':runs=[controlled(c,args.module) for c in (CASES if args.all_cases else [args.case])]
    else:runs=[live(args,settings,inventory)]
    for n,result in enumerate(runs):
        save(out/f'run_{n+1:02d}_{result.get("case",args.mode)}.json',result)
        if not args.quiet:print(json.dumps(sanitize(result),indent=2,ensure_ascii=False,default=str))
        else:print(json.dumps(dict(case=result.get('case'),mode=result['mode'],status=result['status'],
            modules={k:v.get('observed',v.get('status')) for k,v in result.get('modules',{}).items()},blockers=result.get('blockers',[]))))
    if before:
        after=database_readback(settings);save(out/'database_after.json',after)
        integrity=dict(status='PASS' if before==after and before['status']=='PASS' else 'BLOCKED',
            assertion='Observed read-only table hashes before/after are identical',before_equals_after=before==after,
            caveat='Concurrent external writes may change hashes; this is not a historical CP12 integrity re-audit.')
        save(out/'database_integrity.json',integrity)
        if integrity['status']!='PASS':runs.append(integrity)
    verdict='FAIL' if any(r['status']=='FAIL' for r in runs) else ('BLOCKED' if any(r['status']=='BLOCKED' for r in runs) else 'PASS')
    save(out/'summary.json',dict(status=verdict,mode=args.mode,runs=len(runs),cloud_acceptance='NOT_ESTABLISHED',
        note='Controlled passes are not live acceptance. QJ is excluded. No fielding/report authority.',output=str(out)))
    print(f'{verdict}: evidence saved to {out}')
    return {'PASS':0,'FAIL':1,'BLOCKED':2}[verdict]

if __name__=='__main__':raise SystemExit(main())
