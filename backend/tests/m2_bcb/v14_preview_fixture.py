"""Isolated placement experiment. Imported only from the disposable PostgreSQL suite."""
import json
import os
import subprocess
from pathlib import Path
from uuid import UUID, uuid4
from sqlalchemy import text
from sitewise.api.v1 import customer_questionnaire as api
from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest
from sitewise.repositories.cq_repository import PostgresCqStore
from sitewise.services.customer_questionnaire_service import CustomerQuestionnaireService


def reviewed_current_source(session,assessment,candidate,revision):
    return session.scalar(text("""SELECT EXISTS(SELECT FROM m2_candidate_owner_reviews review
        JOIN m2_review_question_versions q ON q.id=review.candidate_id
        JOIN m2_confirmed_uncertainties u ON u.id=q.objective_id
        JOIN m2_confirmation_snapshots c ON c.id=u.confirmation_id
        JOIN m2_assessments a ON a.id=c.assessment_id
        WHERE review.candidate_id=:id AND review.decision='APPROVE_FOR_REVIEW'
        AND a.id=:aid AND a.confirmed_revision=a.revision AND c.assessment_revision=a.revision
        AND a.revision=:revision AND NOT EXISTS(SELECT FROM m2_review_question_versions WHERE supersedes=q.id))"""),
        dict(aid=assessment,id=candidate,revision=revision))


def exercise(lab, helpers, cq, aid, candidate, revision):
    out = Path(os.environ['M2_BCB_EVIDENCE'])
    actor, respondent = lab['actor'], lab['other']
    with lab['db'].connect() as conn:
        row = conn.execute(text("""SELECT q.question,q.options,q.source_receipt,q.objective_id,
            c.snapshot_digest,c.id confirmation FROM m2_review_question_versions q
            JOIN m2_confirmed_uncertainties u ON u.id=q.objective_id
            JOIN m2_confirmation_snapshots c ON c.id=u.confirmation_id
            WHERE q.id=:id AND c.assessment_id=:aid AND c.assessment_revision=:rev"""),
            dict(id=candidate,aid=aid,rev=revision)).mappings().one()
    evidence=json.loads(row['source_receipt'])
    stimulus=evidence['evaluation']['qj']['measurement']['stimulus']
    codes=[o['code'] for o in row['options']]
    item_source=dict(id='Q14',type='single_select',codes=codes,substantive_codes=['I'],
        exclusive_codes=[],option_to_state_map={'I':'ANSWERED_SUBSTANTIVE','U':'ANSWERED_NON_SUBSTANTIVE'})
    item=dict(id='Q14',version=str(candidate),type='single_select',codes=codes,validation=item_source,
        wording={'EN':row['question']},labels={'EN':{o['code']:o['label'] for o in row['options']}},
        option_version=digest([[o['code'],o['label']] for o in row['options']]),
        stimulus_text=stimulus,required_for_presentation=True,required_for_answer=False,
        dependencies=['Q01'],stimulus_dependencies=[],feature_ids=[])
    def append(m,p):
        if not item['stimulus_text'].strip() or any(q['wording']['EN']==row['question'] for q in m['questions']):
            raise CqRefused('TEST_STIMULUS_OR_EQUIVALENCE_HOLD')
        m.update(locales=['EN'],test_placement='isolated-last/1')
        m['questions'].append(item)
        m['authorized_question_ids'].append('Q14')
        p['item_show_gate']['Q14']='Q01_ELIGIBLE'
        m['policy_hash']=digest(p)
    import pytest
    baseline, policy=helpers.fixture_manifest(mode='C0')
    baseline['questions'][0]['wording']['EN']=row['question']
    with pytest.raises(CqRefused):
        append(baseline,policy)
    baseline,policy=helpers.fixture_manifest(mode='C0')
    item['stimulus_text']=''
    with pytest.raises(CqRefused):
        append(baseline,policy)
    item['stimulus_text']=stimulus
    release_id = uuid4()
    with lab['db'].begin() as conn:
        assert Path(conn.scalar(text('SHOW data_directory'))).resolve()==(Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'data').resolve()
        assert conn.scalar(text('SELECT current_database()'))=='project1_m2_bcb_test'
        conn.execute(text("ALTER TABLE cq_question_assignments DROP CONSTRAINT cq_question_assignments_question_id_check"))
        conn.execute(text(f"""ALTER TABLE cq_question_assignments ADD CONSTRAINT cq_question_assignments_question_id_check
            CHECK(question_id ~ '^Q(0[1-9]|1[0-3])$' OR (question_id='Q14' AND slot_id='Q14'
            AND release_id='{release_id}' AND question_version='{UUID(str(candidate))}' AND content_hash='{digest(item)}'))"""))
    rid,m=helpers.release(lab,mode='C0',mutate=append,release_id=release_id)
    authority=helpers.TestOnlyAuthority('project1_m2_bcb_test','M2_BCB_PRIVATE_CLUSTER')
    gates={'scientific':True,'publication':True,'fielding':True}
    class FixtureService(CustomerQuestionnaireService):
        def _release(self,unit,target,principal,operation):
            if str(target)!=rid:
                raise CqRefused('TEST_RELEASE_SCOPE_MISMATCH',403)
            grant=authority.authorize(unit,unit.release(target),principal,operation)
            if unit.release(target)['source_class']!='SYNTHETIC_FIXTURE' or grant.scope!='ISOLATED_TEST' or not all(gates.values()) or principal not in (actor,respondent):
                raise CqRefused('TEST_EXACT_RELEASE_GRANT_REQUIRED',403)
            ok=reviewed_current_source(unit.session,aid,candidate,revision)
            if not ok or unit.release(target)['manifest_hash']!=digest(m):
                raise CqRefused('TEST_SOURCE_VERSION_HOLD')
            return super()._release(unit,target,principal,operation)
        def create_campaign(self,assessment,target,principal):
            if str(target)==rid and str(assessment)!=str(aid):
                raise CqRefused('TEST_ASSESSMENT_MISMATCH',403)
            return super().create_campaign(assessment,target,principal)
    def service():
        obj=FixtureService(PostgresCqStore(lab['db']),authority)
        obj.contract={**obj.contract,'items':[*obj.contract['items'],item_source]}
        return obj
    lab['app'].dependency_overrides[api.get_cq_service]=service
    try:
        import httpx
        url=lab['base']+'/api/v1/cq'
        owner_headers={'Authorization':'Bearer '+lab['token'](actor)}
        wrong=httpx.post(url+f'/assessments/{uuid4()}/campaign',headers=owner_headers,json={'release_id':rid})
        assert wrong.status_code==403
        for gate in gates:
            gates[gate]=False
            resp=httpx.get(lab['base']+'/api/v1/cq/manifests/'+rid,headers={'Authorization':'Bearer '+lab['token'](respondent)})
            assert resp.status_code==403
            gates[gate]=True
        campaign=cq('POST',f'/assessments/{aid}/campaign',actor,json={'release_id':rid})
        cq('POST',f"/campaigns/{campaign['id']}/participants",actor,json={'respondent_id':str(respondent)})
        sess=cq('POST','/sessions',respondent,json={'campaign_id':campaign['id'],'manifest_hash':digest(m),'locale':'EN'})
        got=cq('GET','/manifests/'+rid,respondent)
        assert not any(key in json.dumps(got) for key in ('desired_option','owner_decision','Synthetic scope limitation retained'))
        assert got['manifest']['questions'][-1]==item and not got['production_fielding_authorized']
        root=Path(__file__).resolve().parents[3]
        import shutil
        screen_dir=Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'widget-captures'
        screen_dir.mkdir(exist_ok=True)
        env=dict(os.environ,CQ_TEST_BASE=lab['base'],CQ_TEST_SESSION=sess['session_id'],
            CQ_TEST_TOKEN=lab['token'](respondent),CQ_PREVIEW_EVIDENCE=str(screen_dir),
            CQ_PREVIEW_FONT=str(Path(os.environ['WINDIR'])/'Fonts/segoeui.ttf'))
        with (out/'flutter-preview.log').open('w',encoding='utf8') as stream:
            result=subprocess.run([str(root/'.fvm/flutter_sdk/bin/flutter.bat'),'--no-version-check','test','--no-pub',
                '--reporter','expanded','test/cq_runtime/cq_api_widget_test.dart','--plain-name',
                'exact server manifest, answers, next decision, revision, resume and receipt'],
                cwd=root/'fyp_mobile_app',env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=400)
        assert result.returncode==0,(out/'flutter-preview.log').read_text(encoding='utf8',errors='replace')[-2500:]
        for name in ('before-extra','last-question','final-review','receipt'):
            shutil.copyfile(screen_dir/(name+'.png'),out/(name+'.png'))
        saved=cq('GET','/sessions/'+sess['session_id'],respondent)
        assert saved['receipt']['effective_answers'][-1]['value']=='I'
        with lab['db'].connect() as conn:
            assert conn.scalar(text("SELECT count(*) FROM cq_submission_receipts WHERE session_id=:id AND receipt_hash=:h"),
                dict(id=sess['session_id'],h=saved['receipt']['receipt_hash']))==1
        with lab['db'].connect() as conn:
            trace=conn.execute(text('''SELECT b.context_id,b.packet_hash,s.provenance,v.decision,
                    c.assessment_revision FROM m2_review_question_versions q
                    JOIN m2_research_objective_sources s ON s.objective_id=q.objective_id
                    JOIN m2_confirmed_uncertainties u ON u.id=q.objective_id
                    JOIN m2_confirmation_snapshots c ON c.id=u.confirmation_id
                    JOIN m2_business_contexts b ON b.confirmation_id=c.id
                    JOIN m2_candidate_owner_reviews v ON v.candidate_id=q.id
                    WHERE q.id=:id AND c.assessment_id=:aid'''),dict(id=candidate,aid=aid)).mappings().one()
            assert trace['packet_hash']==evidence['evaluation']['source_fingerprint']
        default_status=None
        from sitewise.repositories.cq_repository import UnverifiedCqAuthority
        ordinary=CustomerQuestionnaireService(PostgresCqStore(lab['db']),UnverifiedCqAuthority())
        with pytest.raises(CqRefused) as production:
            ordinary.manifest(UUID(rid),respondent)
        default_status=production.value.code
        with lab['db'].connect() as conn:
            assignment=conn.execute(text("SELECT slot_id,question_id,question_version,content_hash FROM cq_question_assignments WHERE release_id=:id AND slot_id='Q14'"),dict(id=rid)).mappings().one()
            assert assignment['question_version']==str(candidate) and assignment['content_hash']==digest(item)
            versions=conn.execute(text("SELECT state,value_json FROM cq_answer_revisions WHERE session_id=:id AND slot_id='Q14'"),dict(id=sess['session_id'])).mappings().all()
            assert any(v['value_json']=='I' for v in versions)
        if trace['provenance']['origin']=='ENTREPRENEUR':
            lab['request']('PUT',f'/assessments/{aid}/answers/M2V1-03',json=dict(expected_revision=revision,answer_state='ANSWERED',value=['BAKED_GOODS']))
            stale=httpx.get(url+'/manifests/'+rid,headers={'Authorization':'Bearer '+lab['token'](respondent)})
            assert stale.status_code==409 and stale.json()['detail']['code']=='TEST_SOURCE_VERSION_HOLD'
        (out/'release-binding.json').write_text(json.dumps(dict(assessment=str(aid),revision=revision,trace=dict(trace),assignment=dict(assignment),answer_versions=[dict(v) for v in versions],default_refusal=default_status,measurement=evidence['evaluation']['qj'],
            objective=str(row['objective_id']),confirmation=str(row['confirmation']),snapshot_digest=row['snapshot_digest'],
            candidate=str(candidate),source=evidence['candidate']['source_version'],release=rid,manifest_hash=digest(m),
            campaign=campaign['id'],session=sess['session_id'],question=item,receipt=saved['receipt'],missing_gate_tests=list(gates)),indent=2,default=str))
    finally:
        lab['app'].dependency_overrides.pop(api.get_cq_service,None)
