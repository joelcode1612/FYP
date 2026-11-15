"""Exercise the one-bank operator on fresh PostgreSQL 16, never live data."""
from pathlib import Path
import argparse,importlib.util,json,os,secrets,socket,subprocess,sys,tempfile
from copy import deepcopy
import psycopg2


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    backend=Path(__file__).resolve().parents[2]
    if out==backend or backend in out.parents:raise ValueError('Evidence must be outside backend')
    bins=Path(r'C:\Program Files\PostgreSQL\16\bin')
    with socket.socket() as probe:probe.bind(('127.0.0.1',55445))
    private=Path(tempfile.mkdtemp(prefix='project1_cq_source_bank16_'));password=secrets.token_urlsafe(32)
    pw=private/'init_password';pw.write_text(password,encoding='ascii')
    env=os.environ.copy();env.update(PGHOST='127.0.0.1',PGPORT='55445',PGUSER='postgres',PGPASSWORD=password,PGDATABASE='postgres')
    started=False;checks=[]
    def record(name,condition):
        assert condition,name
        checks.append({'check':name,'result':'PASS'})
    try:
        with (out/'private_cluster_setup.log').open('w',encoding='utf-8') as log:
            def run(command):subprocess.run(command,env=env,stdout=log,stderr=log,check=True)
            run([str(bins/'initdb.exe'),'-D',str(private/'data'),'-U','postgres','--encoding=UTF8','--locale=C','-A','scram-sha-256','--pwfile='+str(pw)])
            pw.unlink()
            run([str(bins/'pg_ctl.exe'),'-D',str(private/'data'),'-l',str(private/'postgres.log'),'-o','-h 127.0.0.1 -p 55445','-w','start']);started=True
            run([str(bins/'psql.exe'),'-v','ON_ERROR_STOP=1','-c','CREATE DATABASE project1_cq_source_bank_test'])
        os.environ['CQ_BANK_PRIVATE_CLUSTER']=str(private)
        spec=importlib.util.spec_from_file_location('source_bank_operator',backend/'scripts/register_cq_source_bank.py')
        operator=importlib.util.module_from_spec(spec);spec.loader.exec_module(operator)
        target='project1_cq_source_bank_test';url=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:55445/{target}'
        receipt={'record_kind':'PRIVATE_TEST_STORAGE_SCOPE_RECEIPT','target_database':target,
            'scope':operator.SCOPE,'source_sha256':operator.SOURCE_SHA,'fielding_authorized':False}
        plan=operator.register(url,target)
        record('read_only_plan_creates_no_table',not plan['registered'] and not plan['created_table'])
        for name,kwargs in [('missing_scope_receipt',{}),('wrong_target',{'expected':'Dss'})]:
            try:operator.register(url,kwargs.get('expected',target),apply=True,authorization=None if name=='missing_scope_receipt' else {**receipt,'target_database':'Dss'})
            except ValueError:record(name+'_refused',True)
            else:raise AssertionError(name)
        def fail_before_commit(_):raise RuntimeError('Explicit private rollback test')
        try:operator.register(url,target,True,receipt,before_commit=fail_before_commit)
        except RuntimeError:pass
        else:raise AssertionError('Rollback injection did not fail')
        record('DDL_and_insert_roll_back_atomically',not operator.register(url,target)['table_existed_before'])
        applied=operator.register(url,target,True,receipt)
        record('PostgreSQL16_exact_13_source_records_written',applied['question_count']==13 and applied['independent_readback']['exact_original_records_match'])
        repeated=operator.register(url,target,True,receipt)
        record('repeat_is_idempotent',not repeated['inserted_bank'] and not repeated['created_table'] and repeated['independent_readback']['created_at']==applied['independent_readback']['created_at'])
        original=operator.source_bank
        def collision():
            bank=deepcopy(original());bank['questions'][0]['stem']+=' TEST TAMPER';bank['content_hash']=operator.digest(bank['questions']);return bank
        operator.source_bank=collision
        try:
            try:operator.register(url,target,True,receipt)
            except ValueError:record('immutable_version_conflict_refused',True)
            else:raise AssertionError('Immutable source version overwritten')
        finally:operator.source_bank=original
        for statement in ('UPDATE public.cq_bank_versions SET content_hash=repeat(\'0\',64)','DELETE FROM public.cq_bank_versions'):
            conn=operator.connect(url,False)
            try:
                with conn.cursor() as q:q.execute(statement)
            except psycopg2.Error as exc:record(('update' if statement.startswith('UPDATE') else 'delete')+'_blocked_by_immutable_trigger',exc.pgcode=='55000')
            else:raise AssertionError('Immutable operation succeeded')
            finally:conn.rollback();conn.close()
        conn=operator.connect(url,False)
        try:
            with conn.cursor() as q:
                q.execute('CREATE ROLE cq_source_bank_test_reader NOLOGIN')
                q.execute('GRANT SELECT ON public.cq_bank_versions TO cq_source_bank_test_reader')
                q.execute('SET LOCAL ROLE cq_source_bank_test_reader')
                q.execute('SELECT count(*) FROM public.cq_bank_versions');record('default_deny_RLS_for_non_owner',q.fetchone()[0]==0)
        finally:conn.rollback();conn.close()
        conn=operator.connect(url,True)
        try:
            with conn.cursor() as q:
                q.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")
                record('only_existing_bank_entity_created_no_releases_campaigns_or_responses',q.fetchall()==[('cq_bank_versions',)])
        finally:conn.rollback();conn.close()
        verified=operator.register(url,target)
        record('final_independent_exact_readback',verified['question_count']==13 and not verified['fielding_authorized'])
        (out/'RESULTS.json').write_text(json.dumps({'result':'PASS','checks':checks,'count':len(checks),
            'server_version':applied['server_version'],'scope':'NEW_PRIVATE_POSTGRESQL16_ONLY','live_database_writes':False,
            'registration':applied,'idempotent_repeat':repeated},indent=2),encoding='utf-8')
        print(json.dumps({'result':'PASS','checks':len(checks),'server_version':applied['server_version'],'live_database_writes':False}))
    finally:
        if pw.exists():pw.unlink()
        if started:subprocess.run([str(bins/'pg_ctl.exe'),'-D',str(private/'data'),'-m','fast','-w','stop'],env=env,capture_output=True,check=True)
        print('Private PostgreSQL16 source-bank cluster stopped.')


if __name__=='__main__':main()
