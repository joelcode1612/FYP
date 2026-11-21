"""CP12 integration on NEW databases in the existing private PG16 lab only.

Never mutates a port-5432 database. Source exports contain schema only.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import uuid4

from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL, make_url

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'backend/src'))
from sitewise.core.config import Settings
from sitewise.services.assessment_discard_service import AssessmentDiscardService
from sitewise.core.exceptions import AssessmentError

OUT = ROOT / 'artifacts/cp12_20261118'
LAB = json.loads((ROOT / 'artifacts/cp11_20261118/private_cluster.json').read_text())
assert LAB['port'] == 55447 and LAB['host'] == '127.0.0.1'
BIN = Path('C:/Program Files/PostgreSQL/16/bin')
PREFIX = 'cp12_' + uuid4().hex[:8]
DBS = [PREFIX + '_market', PREFIX + '_dss']
results = []


def url(db, role='postgres'):
    return URL.create('postgresql+psycopg2', username=role,
                      password=LAB['password'] if role == 'postgres' else LAB['runtime_password'],
                      host='127.0.0.1', port=55447, database=db)


def sql(engine, statement, **params):
    with engine.begin() as c:
        r = c.execute(text(statement), params)
        return r.scalar() if r.returns_rows else None


def script(db, path, suffix=""):
    env = {**os.environ, 'PGHOST': '127.0.0.1', 'PGPORT': '55447',
           'PGUSER': 'postgres', 'PGPASSWORD': LAB['password'], 'PGDATABASE': db}
    with (OUT / (db + '_' + path.stem + suffix + '.log')).open('w', encoding='utf-8') as log:
        subprocess.run([str(BIN/'psql.exe'), '-X', '-v', 'ON_ERROR_STOP=1', '-c', f"SET project1.cp12_migration_target='{db}'; SET project1.cp12_migration_receipt='CP12-SYNTHETIC-CLONE-ONLY';", '-f', str(path)],
                       env=env, stdout=log, stderr=log, check=True)


def check(name, fn):
    try:
        fn()
        results.append({'test': name, 'status': 'PASS'})
    except Exception as exc:
        results.append({'test': name, 'status': 'FAIL', 'type': type(exc).__name__, 'message': str(exc)[:300]})
        raise


def main():
    OUT.mkdir(exist_ok=True)
    admin = create_engine(url('postgres'), isolation_level='AUTOCOMMIT')
    with admin.connect() as c:
        for db in DBS:
            c.exec_driver_sql('CREATE DATABASE "' + db + '"')
    admin.dispose()
    source = make_url(Settings(_env_file=(ROOT/'backend/.env', ROOT/'backend/.env.local')).database_url)
    assert source.database == 'Final_Location_Analysis' and source.host in ('localhost','127.0.0.1')
    env = {**os.environ, 'PGHOST': source.host, 'PGPORT': str(source.port or 5432),
           'PGUSER': source.username, 'PGPASSWORD': source.password, 'PGDATABASE': source.database,
           'PGOPTIONS': '-c default_transaction_read_only=on'}
    dump = OUT/'marketplace_schema.sql'
    with (OUT/'marketplace_export.log').open('w') as log:
        subprocess.run([str(BIN/'pg_dump.exe'), '--schema-only', '--no-owner', '--no-acl',
                        '-f', str(dump)],
                       env=env, stdout=log, stderr=log, check=True)
    script(DBS[0], dump)
    script(DBS[1], ROOT/'artifacts/cp11_20261118/current_Dss_schema_with_acl.sql')
    script(DBS[0], ROOT/'backend/migrations/cp12/marketplace_up.sql')
    script(DBS[1], ROOT/'backend/migrations/cp12/dss_up.sql')
    # Empty-journal rollback restores the original append-only function, then
    # the same migrations can be applied again without touching source DBs.
    before=create_engine(url(DBS[1]))
    old=sql(before,'SELECT body FROM cp12.original_definition')
    script(DBS[1], ROOT/'backend/migrations/cp12/dss_down.sql')
    assert sql(before,"SELECT pg_get_functiondef('public.m2_bcb_reject_mutation()'::regprocedure)")==old
    before.dispose()
    script(DBS[0], ROOT/'backend/migrations/cp12/marketplace_down.sql')
    script(DBS[0], ROOT/'backend/migrations/cp12/marketplace_up.sql')
    script(DBS[1], ROOT/'backend/migrations/cp12/dss_up.sql')
    results.append({'test':'empty_journal_migration_rollback_and_reapply','status':'PASS'})

    market, dss = [create_engine(url(db), hide_parameters=True) for db in DBS]
    runtime = create_engine(url(DBS[1], 'p1_m2_runtime'), hide_parameters=True)
    service = AssessmentDiscardService(market, runtime)
    import secrets
    secret=secrets.token_bytes(32)
    for e in (market,dss):
        sql(e,'INSERT INTO cp12.handoff_key(secret) VALUES(:key)',key=secret)
    # Explicit synthetic retention/external-reference authority on disposable DBs.
    for engine in (market, dss):
        sql(engine, "UPDATE cp12.policy SET approved=true,receipt='SYNTHETIC-TEST-ONLY'")
    sql(dss, 'UPDATE cp12.policy SET external_references_verified=true')
    owner, other = uuid4(), uuid4()
    for engine in (market, dss):
        for uid in (owner, other):
            sql(engine, "INSERT INTO users(user_id,email,role,account_status,email_verified,created_at,updated_at) VALUES(:id,:email,'entrepreneur','active',true,now(),now())", id=uid, email=str(uid)+'@example.test')
    ins, item = uuid4(), uuid4()
    sql(dss, "INSERT INTO m2_instrument_versions(id,code,version_tag,approval_state,schema_digest) VALUES(:id,'CP12','SYNTHETIC','AUTHORIZED',:hash)", id=ins, hash='a'*64)
    sql(dss, "INSERT INTO m2_item_versions(id,instrument_id,item_key,question_text,requiredness,answer_kind,option_values,allowed_states,lifecycle,sort_order) VALUES(:id,:ins,'CP12-Q','Synthetic fixture','REQUIRED','SINGLE','{}','[\"ANSWERED\"]','ACTIVE',1)", id=item, ins=ins)

    def world(who=owner, property_id=None):
        aid, mid = uuid4(), uuid4()
        sql(market, "INSERT INTO assessment(assessment_id,user_id,property_id,status,created_at,updated_at) VALUES(:id,:owner,:prop,'in_progress',now(),now())", id=aid, owner=who, prop=property_id or 'CP12-'+str(aid))
        sql(dss, 'INSERT INTO m2_assessments(id,owner_user_id,instrument_id,revision) VALUES(:id,:owner,:ins,1)', id=mid, owner=who, ins=ins)
        sql(dss, 'INSERT INTO m2_assessment_links(m2_assessment_id,marketplace_assessment_id,user_id,created_by) VALUES(:mid,:aid,:owner,:owner)', mid=mid, aid=aid, owner=who)
        sql(dss, "INSERT INTO m2_answer_revisions(id,assessment_id,item_version_id,assessment_revision,answer_state,value_json) VALUES(:id,:mid,:item,1,'ANSWERED','\"TEST\"')", id=uuid4(), mid=mid, item=item)
        for e in (market,dss):
            sql(e,"INSERT INTO cp12.target_reviews VALUES(:id,:owner,'SYNTHETIC-RETENTION-ONLY','SYNTHETIC-NO-EXTERNAL-REFS')",id=aid,owner=who)
        return aid, mid

    sentinel = world()
    def sentinel_hashes():
        aid,mid=sentinel
        return {'marketplace':sql(market,'SELECT md5(to_jsonb(a)::text) FROM assessment a WHERE assessment_id=:id',id=aid),
                'm2':sql(dss,'SELECT md5(to_jsonb(a)::text) FROM m2_assessments a WHERE id=:id',id=mid),
                'answers':sql(dss,"SELECT md5(string_agg(to_jsonb(a)::text,',' ORDER BY id)) FROM m2_answer_revisions a WHERE assessment_id=:id",id=mid),
                'link':sql(dss,'SELECT md5(to_jsonb(a)::text) FROM m2_assessment_links a WHERE m2_assessment_id=:id',id=mid)}
    sentinel_before=sentinel_hashes()
    def counts(pair):
        aid, mid = pair
        return [sql(market,'SELECT count(*) FROM assessment WHERE assessment_id=:id',id=aid),
                sql(dss,'SELECT count(*) FROM m2_assessments WHERE id=:id',id=mid),
                sql(dss,'SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id',id=mid)]
    def expect_refusal(aid, actor):
        try:
            service.discard(aid, actor)
        except AssessmentError:
            return
        raise AssertionError('Expected refusal')
    def eligible():
        p=world(); service.discard(p[0],owner); assert counts(p)==[0,0,0]
        service.discard(p[0],owner); assert counts(p)==[0,0,0]
    check('eligible_full_graph_and_idempotent_retry',eligible)
    def unauthorized():
        p=world(); expect_refusal(p[0],other); assert counts(p)==[1,1,1]
    check('different_owner_no_deletion',unauthorized)
    def protected():
        p=world(); sql(dss,'UPDATE m2_assessments SET confirmed_revision=1 WHERE id=:id',id=p[1]); expect_refusal(p[0],owner); assert counts(p)==[1,1,1]
    check('confirmed_refused',protected)
    def downstream():
        p=world()
        sql(dss,"INSERT INTO m2_bdj_evaluations(id,assessment_id,assessment_revision,evaluator_version) VALUES(:id,:mid,1,'SYNTHETIC')",id=uuid4(),mid=p[1])
        expect_refusal(p[0],owner); assert counts(p)==[1,1,1]
        assert sql(market,'SELECT count(*) FROM cp12.operations WHERE assessment_id=:id',id=p[0])==0
    check('protected_bdj_refused_without_intent_write',downstream)
    def cq_ee_protected():
        p=world(); release=uuid4(); campaign=uuid4(); snap=uuid4()
        sql(dss,"INSERT INTO cq_bank_versions(version,content_hash,questions_json) VALUES('SYNTHETIC-ONLY',:hash,'{}')",hash='d'*64)
        sql(dss,"INSERT INTO cq_manifest_releases(id,manifest_hash,policy_hash,manifest_json,policy_json,source_class) VALUES(:id,:hash,:hash,'{}','{}','SYNTHETIC_FIXTURE')",id=release,hash='b'*64)
        sql(dss,'INSERT INTO cq_campaigns(id,assessment_id,owner_user_id,release_id) VALUES(:id,:mid,:owner,:rel)',id=campaign,mid=p[1],owner=owner,rel=release)
        sql(dss,"INSERT INTO cq_question_assignments(release_id,slot_id,question_id,question_version,bank_version,content_hash) VALUES(:rel,'CP12-SYNTHETIC','Q01','CP12','SYNTHETIC-ONLY',:hash)",rel=release,hash='d'*64)
        sql(dss,"INSERT INTO ee01_measurement_snapshots(id,owner_user_id,assessment_id,campaign_id,release_id,slot_id,question_version,cutoff,fingerprint,rules_hash,source_hash,scope,status,q,s,a,v,metadata_json,counts_json) VALUES(:id,:owner,:mid,:campaign,:rel,'CP12-SYNTHETIC','CP12',now(),:hash,:hash,:hash,'ISOLATED_TEST','WITHHELD_NOT_AUTHORIZED',0,0,0,0,'{}','{}')",id=snap,owner=owner,mid=p[1],campaign=campaign,rel=release,hash='c'*64)
        expect_refusal(p[0],owner); assert counts(p)==[1,1,1]
        assert sql(dss,'SELECT count(*) FROM cq_campaigns WHERE id=:id',id=campaign)==1
        assert sql(dss,'SELECT count(*) FROM ee01_measurement_snapshots WHERE id=:id',id=snap)==1
    check('cq_and_ee01_protected_records_preserved',cq_ee_protected)

    def handoff():
        p=world()
        try:
            service._call(runtime,'SELECT cp12.remove_draft(:key,:aid,:proof)',owner,key=str(uuid4()),aid=str(p[0]),proof='forged')
        except AssessmentError as e: assert e.code=='DISCARD_HANDOFF_INVALID'
        else: raise AssertionError('Forged handoff accepted')
        assert counts(p)==[1,1,1]
    check('forged_cross_database_handoff_refused',handoff)
    def missing_authority():
        p=world(); sql(dss,'DELETE FROM cp12.target_reviews WHERE assessment_id=:id',id=p[0])
        expect_refusal(p[0],owner); assert counts(p)==[1,1,1]
    check('target_retention_authority_missing_refused',missing_authority)

    def unknown():
        p=world(); sql(dss,'CREATE TABLE cp12_unknown_reference(payload jsonb)'); sql(dss,"INSERT INTO cp12_unknown_reference VALUES(CAST(:payload AS jsonb))", payload=json.dumps({'source':str(p[1])})); expect_refusal(p[0],owner); assert counts(p)==[1,1,1]; sql(dss,'DROP TABLE cp12_unknown_reference')
    check('unknown_semantic_reference_refused',unknown)
    def failure():
        p=world(); original=service._call
        def fail(engine,function,actor,**params):
            if 'cp12.finish' in function: raise RuntimeError('SYNTHETIC_CRASH_AFTER_DSS_COMMIT')
            return original(engine,function,actor,**params)
        service._call=fail
        try:
            try: service.discard(p[0],owner)
            except RuntimeError: pass
            assert counts(p)==[1,0,0]
            try: service.assert_available(p[0],owner)
            except AssessmentError as exc: assert exc.code=='DISCARD_IN_PROGRESS'
            else: raise AssertionError('Resume did not respect pending discard')
            try:
                sql(market,"UPDATE assessment SET updated_at=now() WHERE assessment_id=:id",id=p[0])
            except Exception: pass
            else: raise AssertionError('Pending marketplace write was accepted')
        finally: service._call=original
        service.discard(p[0],owner); assert counts(p)==[0,0,0]
    check('partial_failure_durable_retry',failure)
    def concurrency():
        from concurrent.futures import ThreadPoolExecutor
        import time
        p=world()
        c=dss.connect(); tx=c.begin()
        c.execute(text('UPDATE m2_assessments SET revision=revision WHERE id=:id'),{'id':p[1]})
        with ThreadPoolExecutor(max_workers=1) as pool:
            future=pool.submit(service.discard,p[0],owner)
            time.sleep(0.15)
            assert not future.done(), 'Discard raced past active writer lock'
            tx.commit(); c.close()
            future.result(timeout=25)
        assert counts(p)==[0,0,0]
    check('concurrent_m2_write_serializes_before_discard',concurrency)
    def reserved_crash():
        p=world(); original=service._call
        def interrupt(db,function,actor,**params):
            if 'cp12.remove_draft' in function: raise RuntimeError('SYNTHETIC_BEFORE_DSS_REMOVAL')
            return original(db,function,actor,**params)
        service._call=interrupt
        try:
            try: service.discard(p[0],owner)
            except RuntimeError: pass
            assert counts(p)==[1,1,1]
            try: sql(dss,'UPDATE m2_assessments SET revision=revision+1 WHERE id=:id',id=p[1])
            except Exception: pass
            else: raise AssertionError('Pending Dss save was allowed')
        finally: service._call=original
        service.discard(p[0],owner); assert counts(p)==[0,0,0]
    check('crash_before_removal_blocks_m2_save_and_recovers',reserved_crash)
    def permission_error():
        p=world()
        sql(dss,'REVOKE EXECUTE ON FUNCTION cp12.inspect(uuid) FROM p1_m2_runtime')
        try:
            try: service.discard(p[0],owner)
            except AssessmentError as e: assert e.code=='DISCARD_NOT_PROVISIONED' and e.status_code==503
            else: raise AssertionError('Missing read privilege treated as zero dependencies')
            assert counts(p)==[1,1,1]
        finally: sql(dss,'GRANT EXECUTE ON FUNCTION cp12.inspect(uuid) TO p1_m2_runtime')
    check('missing_privilege_refuses_503_without_deletion',permission_error)
    def unlinked():
        aid=uuid4()
        sql(market,"INSERT INTO assessment(assessment_id,user_id,property_id,status,created_at,updated_at) VALUES(:id,:owner,:prop,'in_progress',now(),now())",id=aid,owner=owner,prop='UNLINKED-'+str(aid))
        for e in (market,dss): sql(e,"INSERT INTO cp12.target_reviews VALUES(:id,:owner,'SYNTHETIC-RETENTION','SYNTHETIC-EXTERNAL')",id=aid,owner=owner)
        service.discard(aid,owner)
        assert sql(market,'SELECT count(*) FROM assessment WHERE assessment_id=:id',id=aid)==0
    check('unlinked_eligible_assessment_discard',unlinked)
    def market_protected():
        p=world(); sql(market,"UPDATE assessment SET status='completed' WHERE assessment_id=:id",id=p[0])
        expect_refusal(p[0],owner); assert counts(p)==[1,1,1]
    check('completed_marketplace_assessment_refused',market_protected)

    def raw_delete():
        p=world()
        try: sql(market,'DELETE FROM assessment WHERE assessment_id=:id',id=p[0])
        except Exception: pass
        else: raise AssertionError('Legacy direct delete bypassed coordinator')
        assert counts(p)==[1,1,1]
    check('legacy_marketplace_only_delete_refused',raw_delete)
    def raw_append_only():
        p=world()
        try: sql(dss,'DELETE FROM m2_answer_revisions WHERE assessment_id=:id',id=p[1])
        except Exception: pass
        else: raise AssertionError('Append-only delete bypass accepted')
        assert counts(p)==[1,1,1]
    check('append_only_guard_still_refuses_direct_delete',raw_append_only)
    def api():
        eligible=world(); failed=world(); protected=world()
        shared='CP12-SHARED-'+str(uuid4()); pair_a=world(owner,shared); pair_b=world(other,shared)
        sql(dss,"INSERT INTO m2_bdj_evaluations(id,assessment_id,assessment_revision,evaluator_version) VALUES(:id,:mid,1,'SYNTHETIC')",id=uuid4(),mid=protected[1])
        def pair_hash(p):
            aid,mid=p
            return {'assessment':sql(market,'SELECT md5(to_jsonb(t)::text) FROM assessment t WHERE assessment_id=:id',id=aid),
                    'm2':sql(dss,'SELECT md5(to_jsonb(t)::text) FROM m2_assessments t WHERE id=:id',id=mid),
                    'link':sql(dss,'SELECT md5(to_jsonb(t)::text) FROM m2_assessment_links t WHERE m2_assessment_id=:id',id=mid),
                    'answers':sql(dss,"SELECT md5(string_agg(to_jsonb(t)::text,',' ORDER BY id)) FROM m2_answer_revisions t WHERE assessment_id=:id",id=mid)}
        pair_b_before=pair_hash(pair_b)
        cases={'owner':str(owner),'other':str(other),'eligible':str(eligible[0]),'failure':str(failed[0]),'protected':str(protected[0]),'sentinel':str(sentinel[0]),'pair_a':list(map(str,pair_a)),'pair_b':list(map(str,pair_b))}
        path=OUT/'api_cases.json'; path.write_text(json.dumps(cases))
        env={**os.environ,'DATABASE_URL':url(DBS[0]).render_as_string(hide_password=False),
             'ANALYTICS_DATABASE_URL':url(DBS[0]).render_as_string(hide_password=False),
             'M2_DATABASE_URL':url(DBS[1],'p1_m2_runtime').render_as_string(hide_password=False),
             'M2_EXPECTED_DATABASE':DBS[1],'M2_UPSTREAM_ENABLED':'true','DB_AUTO_CREATE':'false',
             'TOKENHARBOR_ENABLED':'false','TOKENHARBOR_API_KEY':'','PROJECT1_WORKFLOW_ENABLED':'false',
             'SUPABASE_URL':'https://cp12.example.test','SUPABASE_JWKS_URL':'https://cp12.example.test/auth/v1/.well-known/jwks.json',
             'SUPABASE_JWT_AUDIENCES':'authenticated',
             'CP12_API_CASES':str(path),'CP12_API_OUTPUT':str(OUT/'api_exchanges.json')}
        with (OUT/'api_run.log').open('w',encoding='utf-8') as log:
            subprocess.run([sys.executable,str(ROOT/'backend/tests/cp12/api_checks.py')],env=env,cwd=ROOT/'backend',stdout=log,stderr=log,check=True)
        assert counts(eligible)==[0,0,0] and counts(failed)==[0,0,0] and counts(protected)==[1,1,1]
        assert counts(pair_a)==[0,0,0] and counts(pair_b)==[1,1,1]
        pair_b_after=pair_hash(pair_b); assert pair_b_before==pair_b_after
        (OUT/'multiuser_b_hashes.json').write_text(json.dumps({'before':pair_b_before,'after':pair_b_after,'unchanged':True},indent=2))
    check('actual_fastapi_jwt_route_and_recovery',api)
    def reused_key():
        from uuid import uuid5, NAMESPACE_URL
        p=world(); q=world(); key=uuid5(NAMESPACE_URL,f'project1:discard:{owner}:{p[0]}')
        service.discard(p[0],owner)
        try: service._call(market,'SELECT cp12.prepare(:key,:aid)',owner,key=str(key),aid=str(q[0]))
        except AssessmentError as e: assert e.code=='DISCARD_OWNER_OR_KEY_MISMATCH'
        else: raise AssertionError('Reused operation key accepted another assessment')
        assert counts(q)==[1,1,1]
    check('same_idempotency_key_other_record_refused',reused_key)
    def rollback_refused():
        for db,e,name in ((DBS[0],market,'marketplace_down.sql'),(DBS[1],dss,'dss_down.sql')):
            before=sql(e,'SELECT count(*) FROM cp12.operations')
            try: script(db,ROOT/'backend/migrations/cp12'/name,'_populated_refusal')
            except subprocess.CalledProcessError: pass
            else: raise AssertionError('Rollback erased journal evidence')
            assert sql(e,'SELECT count(*) FROM cp12.operations')==before
    check('populated_journal_rollback_refused',rollback_refused)


    check('unrelated_assessment_preserved',lambda: None if counts(sentinel)==[1,1,1] else (_ for _ in ()).throw(AssertionError('Sentinel changed')))
    sentinel_after=sentinel_hashes()
    assert sentinel_before==sentinel_after
    (OUT/'sentinel_hashes.json').write_text(json.dumps({'scope':'SYNTHETIC_UNRELATED_SENTINEL','before':sentinel_before,'after':sentinel_after,'unchanged':True},indent=2))
    for engine in (runtime,market,dss): engine.dispose()
    print(json.dumps({'tests':results,'databases':DBS,'port':55447},indent=2))


if __name__=='__main__':
    try:
        main()
    finally:
        (OUT/'postgres_results.json').write_text(json.dumps({'tests':results,'databases':DBS,'port':55447},indent=2)+'\n')
