"""Normal signed FastAPI HTTP and real restricted SQL; MOCK provider only.

Run exclusively through run_isolated.py --suite bdj-connected. Admin is used
for disposable schema/authority fixture provisioning and independent readback.
No dependency override for source, authentication, repository or result store.
"""
import hashlib
import json
import os
import secrets
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4

import httpx
import pytest
from pydantic import SecretStr
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from test_postgres_api import lab, case_name, answer


def test_g1_normal_bdj_endpoints_inventory_persistence_and_guards(lab, monkeypatch):
    from scripts.register_m2_v1 import register
    from sitewise.api.v1 import project1_workflow as api
    from sitewise.core.config import settings
    from sitewise.db import m2_session
    from sitewise.project1.bdj import BDJEngine, SYNTHETIC_M2V1_RULESET_SHA256
    from sitewise.project1.bdj_discovery_candidate import DiscoveryOutputCandidate
    from sitewise.project1.contracts import digest, WorkflowHeld
    from sitewise.project1.prompts import Prompt
    from sitewise.project1.provider import ModelRunner, TokenHarbor, ENDPOINT, MODEL
    from sitewise.services.bdj_synthetic_execution import prepare_registered_trial

    root = Path(__file__).resolve().parents[2]
    dburl = make_url(os.environ['DATABASE_URL'])
    assert dburl.database == 'project1_m2_bcb_test'
    assert dburl.port == int(os.environ['M2_BCB_PRIVATE_PORT']) and dburl.port != 5432
    key, password = secrets.token_bytes(32), secrets.token_hex(24)
    # Test-only identity translation of the existing SQL's allowed clone name.
    # The original migrations and live databases are never changed.
    migrations = ['20261111_01_candidate_ledger.sql', '20261117_01_execution_principal.sql',
                  '20261117_02_finding_provenance.sql', '20261117_03_bdj_result_persistence.sql']
    raw = lab['db'].raw_connection()
    try:
        cur = raw.cursor()
        cur.execute("SET project1.migration_target='project1_m2_bcb_test'; SET project1.migration_receipt='MOCK-G1-PRIVATE-ONLY'")
        for name in migrations:
            sql = (root/'migrations/project1_ai'/name).read_text(encoding='utf-8')
            cur.execute(sql.replace("'project1_workflow_tests'", "'project1_m2_bcb_test'"))
        cur.execute("SET project1.identity_test_receipt='PRIVATE-SYNTHETIC-ONLY'")
        cur.execute((root/'migrations/m2/20261121_01_protected_identity_private_rehearsal.sql').read_text(encoding='utf-8'))
        raw.commit()
    finally:
        raw.close()
    with lab['db'].begin() as c:
        c.execute(text('INSERT INTO project1_identity.private_key VALUES (1,:key)'), {'key':key})
        c.exec_driver_sql((Path(__file__).parent/'protected_review_private_policies.sql').read_text(encoding='utf-8'))
        c.exec_driver_sql("ALTER ROLE p1_m2_runtime PASSWORD '"+password+"'")
        c.exec_driver_sql("ALTER ROLE p1ai_engine PASSWORD '"+password+"'")
        c.exec_driver_sql('GRANT USAGE ON SCHEMA project1_identity TO p1ai_runtime')
        c.exec_driver_sql('GRANT EXECUTE ON FUNCTION project1_identity.verified_actor() TO p1ai_runtime')
        rows = c.execute(text("SELECT tablename FROM pg_policies WHERE schemaname='project1_ai' AND policyname='owner_scope'")).scalars().all()
        for table in rows:
            assert table.replace('_','').isalnum()
            c.exec_driver_sql(f'ALTER POLICY owner_scope ON project1_ai.{table} USING '
                '(owner_user_id=project1_identity.verified_actor()) WITH CHECK '
                '(owner_user_id=project1_identity.verified_actor())')
        c.exec_driver_sql('CREATE TABLE project1_ai.synthetic_trial_authority '
            '(run_id uuid PRIMARY KEY REFERENCES project1_ai.runs(id), owner_user_id uuid NOT NULL, authorization_json jsonb NOT NULL)')
        c.exec_driver_sql('REVOKE ALL ON project1_ai.synthetic_trial_authority FROM PUBLIC')
        c.exec_driver_sql('GRANT SELECT ON project1_ai.synthetic_trial_authority TO p1ai_runtime')
        c.exec_driver_sql('ALTER TABLE project1_ai.synthetic_trial_authority ENABLE ROW LEVEL SECURITY')
        c.exec_driver_sql('CREATE POLICY owner_scope ON project1_ai.synthetic_trial_authority '
            'FOR SELECT USING (owner_user_id=project1_identity.verified_actor())')

    source_url = dburl.set(username='p1_m2_runtime', password=password)
    runtime_url = dburl.set(username='p1ai_engine', password=password)
    runtime = create_engine(runtime_url, hide_parameters=True)
    monkeypatch.setattr(settings, 'm2_database_url', SecretStr(source_url.render_as_string(hide_password=False)))
    monkeypatch.setattr(settings, 'project1_runtime_database_url', SecretStr(runtime_url.render_as_string(hide_password=False)))
    monkeypatch.setattr(settings, 'm2_protected_identity_enabled', True)
    monkeypatch.setattr(settings, 'm2_identity_assertion_key', SecretStr(key.hex()))
    monkeypatch.setattr(settings, 'project1_isolated_database_name', dburl.database)
    monkeypatch.setattr(settings, 'project1_isolated_database_port', dburl.port)
    monkeypatch.setattr(settings, 'project1_synthetic_bdj_trial_enabled', True)
    monkeypatch.setattr(settings, 'tokenharbor_enabled', True)
    monkeypatch.setattr(settings, 'project1_key_custody_dir', str(Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'keys'))
    prompt_path = root.parent/'artifacts/stage34_integration_20261119/bdj_synthetic_trial_v1_0_1_prompt.txt'
    monkeypatch.setattr(settings, 'project1_synthetic_bdj_prompt_path', str(prompt_path))
    monkeypatch.setattr(settings, 'project1_synthetic_bdj_prompt_sha256', hashlib.sha256(prompt_path.read_bytes()).hexdigest())
    prompt = Prompt('BDJ-M2V1-INFO-GAP-TEST-1.0.1', 'You are a bounded business declaration reviewer.', prompt_path.read_bytes().decode('utf-8'))
    hits, outputs = [], []
    def transport(request):
        hits.append(request.content)
        return httpx.Response(200, json={'model':MODEL, 'choices':[{'finish_reason':'stop',
            'message':{'role':'assistant','content':json.dumps(outputs[-1])}}]})
    def runner_factory(ledger, disclosure, prompts):
        return ModelRunner(TokenHarbor(SecretStr('mock-not-a-credential'), enabled=True,
            transport=httpx.MockTransport(transport)), ledger, prompts, disclosure=disclosure)
    monkeypatch.setattr(api, 'configured_runner', runner_factory)
    lab['app'].dependency_overrides[api.get_runner_factory] = lambda: runner_factory
    iid = register(lab['db'], apply=True, expected_database=dburl.database)['instrument_id']
    evidence = []
    try:
        for finding_case in (True, False):
            mid = lab['request']('POST','/assessments',201,json={'instrument_version_id':iid}).json()['id']
            values = {'M2V1-01':'UNDECIDED','M2V1-02':'HYBRID','M2V1-03':['COFFEE'],
                'M2V1-04':['STUDENTS','OFFICE_WORKERS'],'M2V1-05':'STUDENTS','M2V1-06':'QUALITY',
                'M2V1-07':'STUDY_WORK','M2V1-08':['NONE'],'M2V1-09':['CONCEPT_INTEREST','PRICE_ACCEPTABILITY'],
                'M2V1-10':'CONCEPT_INTEREST','M2V1-11':'EXPLORE'}
            for rev,(item,value) in enumerate(values.items()): answer(lab,mid,item,value,rev)
            lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',409,json={'expected_revision':11})
            lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':11})
            confirmation = lab['request']('POST',f'/assessments/{mid}/confirm',
                json={'expected_revision':11,'acknowledged_issue_ids':[]}).json()
            uid=SimpleNamespace(user_id=lab['actor'])
            with m2_session.m2_session_for(lab['actor']) as s:
                envelope=api.source(s,uid,UUID(mid),11,include_inventory=True)
            packet=envelope['projection']; run_id=uuid4()
            record={'run_id':str(run_id),'owner_id':str(lab['actor']),'assessment_id':mid,'revision':11,
                'confirmation_id':confirmation['id'],'source_fingerprint':packet['source_fingerprint'],
                'endpoint':ENDPOINT,'model':MODEL,'rules_sha256':SYNTHETIC_M2V1_RULESET_SHA256,
                'prompt_fingerprint':prompt.fingerprint,'request_sha256':'0'*64,
                'approval_receipt':'MOCK-G1-NONHUMAN-NO-NETWORK-ONLY','data_class':'SYNTHETIC_NONHUMAN',
                'decision':'APPROVED','max_attempts':1,
                'output_schema_sha256':digest(DiscoveryOutputCandidate.model_json_schema()),
                'inventory_fingerprint':envelope['item_inventory']['inventory_fingerprint']}
            # No registry record: refuse before reserving or contacting transport.
            lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',409,json={'expected_revision':11})
            with lab['db'].begin() as c:
                c.execute(text('INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,'
                    'source_fingerprint,policy_fingerprint,work_identity) VALUES (:r,:o,:a,11,:f,:p,:w)'),
                    {'r':run_id,'o':lab['actor'],'a':UUID(mid),'f':packet['source_fingerprint'],'p':'d'*64,'w':hashlib.sha256(run_id.bytes).hexdigest()})
                c.execute(text('INSERT INTO project1_ai.synthetic_trial_authority VALUES (:r,:o,CAST(:v AS jsonb))'),
                    {'r':run_id,'o':lab['actor'],'v':json.dumps(record)})
            with m2_session.m2_session_for(lab['actor']) as s:
                prepared=prepare_registered_trial(session=s,user=uid,assessment_id=UUID(mid),revision=11,
                    packet_source=api.source,runtime=runtime,runner_factory=runner_factory)
                model_packet,_=BDJEngine(prepared['rules']).prepare_discovery_trial(packet,
                    item_definitions=prepared['item_definitions'],recheck_current=prepared['current_fingerprint'],
                    inventory_envelope=envelope,registered_disclosure=prepared['runner'].disclosure)
                messages=prompt.messages(model_packet,DiscoveryOutputCandidate.model_json_schema())
                body=httpx.Request('POST',ENDPOINT,json=prepared['runner'].provider.prepare_payload(messages,DiscoveryOutputCandidate)).content
            record['request_sha256']=hashlib.sha256(body).hexdigest()
            with lab['db'].begin() as c:
                c.execute(text('UPDATE project1_ai.synthetic_trial_authority SET authorization_json=CAST(:v AS jsonb) WHERE run_id=:r'),
                    {'r':run_id,'v':json.dumps(record)})
            d=next(d for d in packet['declarations'] if d['item_key']=='M2V1-01')
            issue={'rule_id':'M2V1_EXPLICIT_PLANNING_UNDECIDED','kind':'INFORMATION_GAP',
                'discovery_signal':'EXPLICIT_UNCERTAINTY','source_refs':[{k:d[k] for k in ('item_key','item_version_id','answer_revision_id')} | {'quote':'UNDECIDED'}],
                'observed_condition':'The synthetic source declares UNDECIDED.',
                'counterargument':'A valid undecided answer is not a business defect.',
                'justification':'Literal confirmed source only.', 'next_action':'Optionally clarify the intended area.'}
            outputs.append({'contract_version':'bdj-discovery-output/1-candidate',
                'issues':[issue] if finding_case else [],'overall_note':'MOCKED synthetic response; not a live model result.'})
            # Guard failures must not dispatch or consume a reserved attempt.
            previous_hits=len(hits)
            with monkeypatch.context() as bad:
                bad.setattr(settings,'project1_isolated_database_port',dburl.port+1)
                lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',(409,503),json={'expected_revision':11})
            with monkeypatch.context() as bad:
                bad.setattr(settings,'project1_isolated_database_name','')
                bad.setattr(settings,'project1_isolated_database_port',0)
                lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',(409,503),json={'expected_revision':11})
            lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',409,json={'expected_revision':10})
            lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',409,uid=lab['other'],json={'expected_revision':11})
            lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',401,uid=None,json={'expected_revision':11})
            assert len(hits)==previous_hits
            if finding_case:
                result=lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',200,json={'expected_revision':11}).json()
            else:
                r=httpx.post(lab['base']+f'/api/v1/project1-workflow/assessments/{mid}/business-understanding/model-assisted',
                    headers={'Authorization':'Bearer '+lab['token'](lab['actor'])},json={'expected_revision':11},timeout=30)
                assert r.status_code==200,r.text
                result=r.json()
                lab['traces'].append({'method':'POST','path':str(r.url),'actual_http':r.status_code,'output':result,'auth':'signed-test-principal'})
            assert hits[-1]==body and len(hits)==previous_hits+1
            assert result['validation_status']=='valid' and len(result['findings'])==int(finding_case)
            read=lab['request']('GET',f'/assessments/{mid}/bdj/current',params={'confirmation_id':confirmation['id'],'expected_revision':11}).json()
            assert read['status']==('COMPLETED_WITH_FINDINGS' if finding_case else 'COMPLETED_ZERO_FINDINGS')
            assert read['result']['result_id']==result['result_id']
            if finding_case:
                # A result payload finding does not yet have a durable individual
                # m2_bdj_findings ID or a post-confirmation review receipt. Do
                # not let an arbitrary ID become an approved objective.
                held=lab['request']('POST',f"/confirmations/{confirmation['id']}/research-objectives",409,
                    json={'expected_revision':11,'origin':'BDJ','finding_id':str(uuid4()),
                          'objective':'SYNTHETIC pending objective'}).json()
                assert held['detail']['code']=='M2_UNCERTAINTY_LINK_REQUIRED'
                assert 'not available yet' in held['detail']['message']
                with lab['db'].connect() as c:
                    assert c.scalar(text('SELECT count(*) FROM m2_confirmed_uncertainties WHERE confirmation_id=:id'),
                                    {'id':UUID(confirmation['id'])}) == 0
                    # The existing unique key cannot represent two distinct
                    # sources for the same rule. Prove this only in a rolled
                    # back transaction on the disposable database.
                    from sqlalchemy.exc import IntegrityError
                    tx = c.begin_nested()
                    try:
                        insert = text('INSERT INTO m2_bdj_findings '
                            '(id,assessment_id,assessment_revision,rule_id,rule_version,source_answer_ids,'
                            'issue_type,explanation,not_proven,next_action,review_state) '
                            "VALUES (:id,:assessment,11,'M2V1_EXPLICIT_PLANNING_UNDECIDED',"
                            "'BDJ-M2V1-IG-0.1-PROP',CAST(:sources AS json),'INFORMATION_GAP',"
                            "'synthetic','synthetic','synthetic','PENDING')")
                        refs=[x['answer_revision_id'] for x in packet['declarations'][:2]]
                        c.execute(insert,{'id':uuid4(),'assessment':UUID(mid),'sources':json.dumps(refs[:1])})
                        with pytest.raises(IntegrityError) as collision:
                            c.execute(insert,{'id':uuid4(),'assessment':UUID(mid),'sources':json.dumps(refs[1:])})
                        assert collision.value.orig.pgcode == '23505'
                    finally:
                        tx.rollback()
            lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',409,json={'expected_revision':11})
            assert len(hits)==previous_hits+1
            with lab['db'].connect() as c:
                stored=dict(c.execute(text('SELECT result_id,owner_user_id,assessment_id,assessment_revision,source_fingerprint,'
                    'finding_count,validation_status,result_schema_version,result_payload FROM project1_ai.bdj_results WHERE run_id=:r'),{'r':run_id}).mappings().one())
                assert stored['owner_user_id']==lab['actor'] and str(stored['assessment_id'])==mid
                assert stored['assessment_revision']==11 and stored['source_fingerprint']==packet['source_fingerprint']
                assert stored['finding_count']==int(finding_case) and '__payload_envelope__' in stored['result_payload']
                stored.pop('result_payload')
                assert c.scalar(text('SELECT count(*) FROM project1_ai.attempts WHERE run_id=:r'),{'r':run_id})==1
                assert c.scalar(text('SELECT count(*) FROM project1_ai.bdj_result_sources WHERE result_id=:r'),{'r':UUID(result['result_id'])})==11
            evidence.append({'provider':'MOCKED_NO_NETWORK','input':packet,'request':json.loads(body),
                'request_sha256':record['request_sha256'],'api_result':result,'readback':read,'database':stored})
            answer(lab,mid,'M2V1-11','UNSURE',11)
            lab['request']('GET',f'/assessments/{mid}/bdj/current',409,
                params={'confirmation_id':confirmation['id'],'expected_revision':11})
        with runtime.begin() as c:
            c.exec_driver_sql('SET LOCAL ROLE p1ai_runtime')
            c.execute(text("SELECT set_config('project1.actor_id',:owner,true)"),{'owner':str(lab['actor'])})
            assert c.scalar(text('SELECT count(*) FROM project1_ai.bdj_results'))==0
            assert not c.scalar(text("SELECT has_table_privilege(current_user,'project1_ai.synthetic_trial_authority','INSERT,UPDATE,DELETE,TRUNCATE')"))
    finally:
        (Path(os.environ['M2_BCB_EVIDENCE'])/'g1_connected_evidence.json').write_text(json.dumps(evidence,indent=2,default=str),encoding='utf-8')
        lab['app'].dependency_overrides.pop(api.get_runner_factory,None)
        runtime.dispose()

