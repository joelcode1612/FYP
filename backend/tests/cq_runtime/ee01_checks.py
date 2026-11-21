"""Actual CQ HTTP writes -> restricted PostgreSQL EE01 snapshots, no fielding."""
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError

from test_postgres_api import TestOnlyAuthority, release, version, session, post, respond
from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest
from sitewise.services.ee01_service import Ee01Service
from sitewise.services.ports.cq_store_port import CqGrant


def test_EE01_persisted_cutoff_reference_security_and_held_report(lab):
    from sitewise.api.v1 import customer_questionnaire as api
    from sitewise.db.models.user import User
    from sitewise.db.models.m2_schema import assessments
    contexts = {}

    class Authority(TestOnlyAuthority):
        def authorize(self, unit, release, actor_id, operation):
            super().authorize(unit, release, actor_id, operation)
            return CqGrant('ISOLATED_TEST', 'SYNTHETIC-EE01-ONLY', False, contexts.get(str(actor_id)))

    lab['app'].dependency_overrides[api.get_cq_authority] = lambda: Authority()
    engine = create_engine(os.environ['EE01_DATABASE_URL'], hide_parameters=True)
    service = Ee01Service(engine)
    rid, manifest = release(lab, 'C1')
    aid = uuid4()
    with lab['db'].begin() as c:
        c.execute(assessments.insert().values(id=aid, owner_user_id=lab['owner'], instrument_id=lab['iid'], revision=0))
    campaign = lab['request']('POST', f'/assessments/{aid}/campaign', uid=lab['owner'], json={'release_id': rid})
    cid = UUID(campaign['id'])
    sessions = []

    def action(s, uid, name, data=None, expected=200):
        return lab['request']('POST', '/sessions/'+s['session_id']+'/'+name, expected, uid=uid,
                              json={**version(s), **(data or {})})

    def shown(s, uid, edit=None):
        p = action(s, uid, 'presentations', {'edit_slot_id': edit})
        return action(p, uid, 'rendered', {'display_id': p['presentation']['display_id']})

    def answer(p, uid, value, expected=200):
        return action(p, uid, 'answers', {'request_id': str(uuid4()), 'display_id': p['presentation']['display_id'],
                                         'slot_id': p['presentation']['slot_id'], 'value': value}, expected)

    def new_unit(index, mode='CUSTOMER_DEMAND_SURVEY'):
        uid = uuid4()
        contexts[str(uid)] = {'source_class': 'SYNTHETIC_FIXTURE', 'research_mode': mode,
                              'eligibility': 'ELIGIBLE' if index < 8 else 'INELIGIBLE',
                              'qualification_version': 'SYNTHETIC-INDEPENDENT-QUALIFICATION-1', 'receipt': 'TEST-ONLY-NOT-SCIENCE'}
        with lab['db'].begin() as c:
            c.execute(User.__table__.insert().values(user_id=uid, email=f'{uid}@test.invalid', role='customer', account_status='active', email_verified=True))
        lab['request']('POST', f'/campaigns/{cid}/participants', uid=lab['owner'], json={'respondent_id': str(uid)})
        s = lab['request']('POST', '/sessions', uid=uid, json={'campaign_id': str(cid), 'manifest_hash': digest(manifest), 'locale': 'EN'})
        s = action(s, uid, 'consent', {'request_id': str(uuid4()), 'consented': True, 'consent_version': manifest['consent_version']})
        # ZERO/NONE are real substantive answers, never qualification predicates.
        while s['next_slot_id'] != 'Q05':
            while s['next_stimulus_kind']:
                s = action(s, uid, 'stimuli', {'kind': s['next_stimulus_kind']})
            p = shown(s, uid)
            q = p['presentation']['question_id']
            item = next(qi for qi in manifest['questions'] if qi['id'] == q)
            code = {'Q01': 'LIVE', 'Q02': 'NONE', 'Q04': 'ZERO'}.get(q, item['validation']['substantive_codes'][0])
            s = answer(p, uid, [code] if item['type'].startswith('multi_select') else code)
        while s['next_stimulus_kind']:
            s = action(s, uid, 'stimuli', {'kind': s['next_stimulus_kind']})
        return uid, s

    try:
        for i in range(10):
            uid, s = new_unit(i)
            if i < 7:
                p = shown(s, uid)
                if i == 5:
                    answer(p, uid, 'INVALID_TEST_CODE', 422)
                    s = p
                else:
                    s = answer(p, uid, ['PROB_YES', 'DEF_YES', 'PROB_YES', 'UNSURE', 'DEF_NO', None, 'PREFER_NOT_TO_ANSWER'][i])
            elif i == 7:
                # Preparing a presentation is deliberately not a render.
                action(s, uid, 'presentations')
            sessions.append((uid, s))
        cutoff = datetime.now(timezone.utc)
        current = service.build_diagnostic(lab['owner'], aid, cid, 'Q05', cutoff, 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        accepted = service.build_diagnostic(lab['owner'], aid, cid, 'Q05', cutoff, 'ACCEPTED_EFFECTIVE_DIAGNOSTIC')
        assert (current['q'], current['s'], current['a'], current['v']) == (8, 7, 7, 5)
        assert (accepted['q'], accepted['s'], accepted['a'], accepted['v']) == (8, 7, 6, 5)
        top = next(c for c in current['cells'] if c['code'] == 'TOP_TWO_STATED_INTEREST')
        assert top['x'] == 3 and float(top['diagnostic_percentage']) == 60 and top['percentage'] is None
        assert current['counts_json']['INVALID'] == 1 and current['counts_json']['REFUSED'] == 1
        assert current['counts_json']['not_shown'] == 1 and current['counts_json']['excluded'] == 2
        repeated = service.build_diagnostic(lab['owner'], aid, cid, 'Q05', cutoff, 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        assert repeated == current
        assert service.build_diagnostic(lab['owner'], aid, cid, 'Q05', cutoff.astimezone(), 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC') == current
        with service.connection(lab['owner']) as c:
            # Independent raw-source oracle; no Python aggregation function used.
            raw = list(c.execute(text('SELECT u.source_json,r.id AS rendered,a.state,a.value_json,i.id AS invalid '
                'FROM ee01_source_units u LEFT JOIN cq_render_events r ON r.id=u.render_id '
                'LEFT JOIN cq_answer_revisions a ON a.id=u.answer_id LEFT JOIN cq_rejected_answer_events i ON i.id=u.rejected_id '
                'WHERE u.snapshot_id=:id'), {'id': current['id']}).mappings())
            eligible = [r for r in raw if r['source_json']['qualified']]
            valid = [r for r in eligible if r['rendered'] and r['state'] == 'ANSWERED_SUBSTANTIVE' and not r['invalid']]
            assert len(eligible) == 8 and len(valid) == 5
            assert sum(r['value_json'] in ['DEF_YES', 'PROB_YES'] for r in valid)*100/len(valid) == 60
        held = service.report_readback(lab['owner'], aid, cid, UUID(current['id']))
        assert held['findings'] == [] and held['status'] == 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'
        prefix = f'/assessments/{aid}/campaigns/{cid}/measurements/{current["id"]}'
        assert lab['request']('GET', prefix, uid=lab['owner']) == current
        assert lab['request']('GET', prefix+'/report-readback', uid=lab['owner']) == held
        lab['request']('GET', prefix, 404, uid=lab['other'])
        lab['request']('GET', prefix.replace(str(aid), str(uuid4())), 404, uid=lab['owner'])
        with pytest.raises(CqRefused):
            Ee01Service(lab['db']).read(lab['owner'], aid, cid, UUID(current['id']))
        # Prove no privileged application connection and no cross-owner read.
        with service.connection(lab['other']) as c:
            assert c.scalar(text('SELECT count(*) FROM ee01_measurement_snapshots')) == 0
        with pytest.raises(DBAPIError):
            with service.connection(lab['owner']) as c:
                c.execute(text('UPDATE ee01_category_cells SET x=0 WHERE snapshot_id=:id'), {'id': current['id']})
        # Invalid -> valid changes the new cutoff; previous evidence remains intact.
        uid, p = sessions[5]
        answer(p, uid, 'DEF_YES')
        after = service.build_diagnostic(lab['owner'], aid, cid, 'Q05', datetime.now(timezone.utc), 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        assert after['id'] != current['id'] and after['v'] == 6
        assert service.read(lab['owner'], aid, cid, UUID(current['id'])) == current
        # Valid -> invalid at a new cutoff counts current invalid exactly once.
        uid, s = sessions[0]
        p = shown(s, uid, 'Q05'); answer(p, uid, 'INVALID_TEST_CODE', 422)
        invalid = service.build_diagnostic(lab['owner'], aid, cid, 'Q05', datetime.now(timezone.utc), 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        assert invalid['v'] == 5 and invalid['counts_json']['INVALID'] == 1
        # Same underlying database, cognitive/previews cannot enter demand Q.
        for mode in ('COGNITIVE_PRETEST', 'DEVELOPER_PREVIEW'):
            uid, s = new_unit(0, mode)
            p = shown(s, uid); answer(p, uid, 'DEF_YES')
        mixed = service.build_diagnostic(lab['owner'], aid, cid, 'Q05', datetime.now(timezone.utc), 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        assert mixed['q'] == 8 and mixed['counts_json']['excluded'] == 4
        # Explicit withdrawal is reconstructed from immutable consent at cutoff.
        uid, s = sessions[1]
        action(s, uid, 'withdraw', {'request_id': str(uuid4())})
        withdrawn = service.build_diagnostic(lab['owner'], aid, cid, 'Q05', datetime.now(timezone.utc), 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        assert withdrawn['q'] == 7
        empty = service.build_diagnostic(lab['owner'], aid, cid, 'Q13', cutoff, 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        assert empty['v'] == 0 and all(c['percentage'] is None and c['diagnostic_percentage'] is None for c in empty['cells'])
        # Execute delivered read-only SQL as the actual restricted login role.
        url = make_url(os.environ['EE01_DATABASE_URL'])
        env = {**os.environ, 'PGHOST': url.host, 'PGPORT': str(url.port), 'PGUSER': url.username,
               'PGPASSWORD': url.password, 'PGDATABASE': url.database}
        out = Path(os.environ['CQ_EVIDENCE'])
        for name in ('VERIFY_EE01_SCHEMA', 'VERIFY_EE01_AGGREGATES', 'VERIFY_CQ_TO_REPORT_LINEAGE'):
            command = [r'C:\Program Files\PostgreSQL\18\bin\psql.exe', '-X', '-v', 'ON_ERROR_STOP=1',
                       '-v', 'actor_id='+str(lab['owner']), '-v', 'assessment_id='+str(aid), '-v', 'campaign_id='+str(cid),
                       '-v', 'snapshot_id='+current['id'], '-f', str(Path(__file__).parent/(name+'.sql'))]
            result = subprocess.run(command, env=env, capture_output=True, text=True, encoding='utf-8')
            (out/(name+'.log')).write_text(result.stdout+result.stderr, encoding='utf-8')
            assert result.returncode == 0, result.stderr
        (out/'ee01_readback.json').write_text(json.dumps({'current': current, 'alternate': accepted, 'after_revision': after,
            'report': held, 'production_adoption': False, 'sql_role': url.username}, indent=2), encoding='utf-8')
        lab['readbacks'].append({'test': 'EE01', 'snapshot_id': current['id'], 'Q': 8, 'S': 7, 'A': 7, 'V': 5,
                                 'top_two': '3/5 = 60% DIAGNOSTIC ONLY', 'report_findings': []})
    finally:
        lab['app'].dependency_overrides[api.get_cq_authority] = lambda: TestOnlyAuthority()
        engine.dispose()


def test_EE02_zero_denominator_and_snapshot_transaction_rollback(lab, monkeypatch):
    from sitewise.api.v1 import customer_questionnaire as api
    context = {'source_class': 'SYNTHETIC_FIXTURE', 'research_mode': 'CUSTOMER_DEMAND_SURVEY',
               'eligibility': 'ELIGIBLE', 'qualification_version': 'TEST-ONLY-ELIGIBILITY', 'receipt': 'TEST-ONLY'}
    class Authority(TestOnlyAuthority):
        def authorize(self, unit, release, actor_id, operation):
            super().authorize(unit, release, actor_id, operation)
            return CqGrant('ISOLATED_TEST','SYNTHETIC-ONLY',False,context)
    lab['app'].dependency_overrides[api.get_cq_authority] = lambda: Authority()
    engine = create_engine(os.environ['EE01_DATABASE_URL'],hide_parameters=True)
    service = Ee01Service(engine)
    try:
        s = respond(lab,session(lab,'C0'),['LIVE'])
        p = post(lab,s,'presentations')
        p = post(lab,p,'rendered',{'display_id':p['presentation']['display_id']})
        s = post(lab,p,'answers',{'request_id':str(uuid4()),'display_id':p['presentation']['display_id'],
                               'slot_id':'Q02','value':'PREFER_NOT_TO_ANSWER'})
        with lab['db'].connect() as c:
            campaign = c.execute(text('SELECT * FROM cq_campaigns WHERE id=:id'),{'id':s['campaign_id']}).mappings().one()
        args = (lab['owner'],campaign['assessment_id'],campaign['id'],'Q02')
        row = service.build_diagnostic(*args,datetime.now(timezone.utc),'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        assert (row['q'],row['s'],row['a'],row['v']) == (1,1,1,0)
        assert row['status']=='NOT_ESTIMABLE' and all(c['percentage'] is None and c['diagnostic_percentage'] is None for c in row['cells'])
        with service.connection(lab['owner']) as c:
            before = c.scalar(text('SELECT count(*) FROM ee01_measurement_snapshots'))
        def fail(c,row): raise RuntimeError('Synthetic post-write failure')
        monkeypatch.setattr(service,'_store_held_context',fail)
        with pytest.raises(RuntimeError):
            service.build_diagnostic(*args,datetime.now(timezone.utc),'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
        with service.connection(lab['owner']) as c:
            assert c.scalar(text('SELECT count(*) FROM ee01_measurement_snapshots')) == before
    finally:
        lab['app'].dependency_overrides[api.get_cq_authority] = lambda: TestOnlyAuthority()
        engine.dispose()


def test_EE03_multiselect_distinct_units_and_feature_denominators(lab):
    from sitewise.api.v1 import customer_questionnaire as api
    from sitewise.db.models.user import User
    from sitewise.db.models.m2_schema import assessments
    context = {'source_class':'SYNTHETIC_FIXTURE','research_mode':'CUSTOMER_DEMAND_SURVEY',
               'eligibility':'ELIGIBLE','qualification_version':'TEST-ONLY','receipt':'SYNTHETIC-NOT-APPROVAL'}
    class Authority(TestOnlyAuthority):
        def authorize(self, unit, release, actor_id, operation):
            super().authorize(unit,release,actor_id,operation)
            return CqGrant('ISOLATED_TEST','SYNTHETIC',False,context)
    lab['app'].dependency_overrides[api.get_cq_authority]=lambda:Authority()
    engine=create_engine(os.environ['EE01_DATABASE_URL'],hide_parameters=True)
    service=Ee01Service(engine)
    try:
        rid,m=release(lab,'C1');aid=uuid4()
        with lab['db'].begin() as c:
            c.execute(assessments.insert().values(id=aid,owner_user_id=lab['owner'],instrument_id=lab['iid'],revision=0))
        campaign=lab['request']('POST',f'/assessments/{aid}/campaign',uid=lab['owner'],json={'release_id':rid})
        cid=UUID(campaign['id'])
        for index in range(2):
            uid=uuid4()
            with lab['db'].begin() as c:
                c.execute(User.__table__.insert().values(user_id=uid,email=f'{uid}@test.invalid',role='customer',account_status='active',email_verified=True))
            lab['request']('POST',f'/campaigns/{cid}/participants',uid=lab['owner'],json={'respondent_id':str(uid)})
            s=lab['request']('POST','/sessions',uid=uid,json={'campaign_id':str(cid),'manifest_hash':digest(m),'locale':'EN'})
            def act(s,name,data=None):
                return lab['request']('POST',f'/sessions/{s["session_id"]}/{name}',uid=uid,json={**version(s),**(data or {})})
            s=act(s,'consent',{'request_id':str(uuid4()),'consented':True,'consent_version':m['consent_version']})
            for _ in range(40):
                while s['next_stimulus_kind']:s=act(s,'stimuli',{'kind':s['next_stimulus_kind']})
                if s['can_submit']:break
                p=act(s,'presentations');p=act(p,'rendered',{'display_id':p['presentation']['display_id']})
                slot=p['presentation']['slot_id'];q=next(q for q in m['questions'] if q['id']==slot.split(':')[0])
                codes=q['validation']['substantive_codes']
                value=['LIVE'] if q['id']=='Q01' else 'ONE' if q['id']=='Q04' else codes[:2] if q['type'].startswith('multi_select') else codes[0]
                if index==1 and slot=='Q10:SYN-F2':value='PREFER_NOT_TO_ANSWER'
                s=act(p,'answers',{'request_id':str(uuid4()),'display_id':p['presentation']['display_id'],'slot_id':slot,'value':value})
            assert s['can_submit']
        cutoff=datetime.now(timezone.utc);results={}
        for slot in ('Q06','Q08','Q09','Q10:SYN-F1','Q10:SYN-F2','Q07'):
            row=service.build_diagnostic(lab['owner'],aid,cid,slot,cutoff,'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
            results[slot]=row
            assert row['q']==2 and row['s']==2 and row['a']==2
            assert row['v']==(1 if slot=='Q10:SYN-F2' else 2)
            assert all(c['percentage'] is None and c['x']<=row['v'] for c in row['cells'])
            if slot in ('Q06','Q08','Q09'):
                nonzero=[c for c in row['cells'] if c['x']]
                assert len(nonzero)==2 and all(c['x']==2 for c in nonzero)
                assert sum(c['x'] for c in nonzero)==4  # multi-select totals may exceed V
        assert results['Q10:SYN-F2']['counts_json']['REFUSED']==1
        with service.connection(lab['owner']) as c:
            refs=list(c.execute(text('SELECT source_json FROM ee01_source_units WHERE snapshot_id=:id'),{'id':results['Q07']['id']}).scalars())
            offer_hash=digest(m['stimuli']['offer'])
            assert all(any(e['kind']=='offer' and e['stimulus_hash']==offer_hash for e in u['exposures']) for u in refs)
        (Path(os.environ['CQ_EVIDENCE'])/'ee01_multiselect_readback.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    finally:
        lab['app'].dependency_overrides[api.get_cq_authority]=lambda:TestOnlyAuthority()
        engine.dispose()
