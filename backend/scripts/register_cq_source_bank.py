"""Explicit, transactional Q01-Q13 SOURCE-ONLY registration; no fielding.

Default is read-only planning/verification. --apply requires the exact target
and a storage-scope receipt referring to the user's authorization. This does
not grant scientific, M2, campaign, release or respondent authorization.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import sys

import psycopg2
from psycopg2.extras import Json
from sqlalchemy.engine import make_url

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(BACKEND/'src'))
from sitewise.core.config import Settings
from sitewise.domain.customer_questionnaire import digest

SOURCE = BACKEND/'src/sitewise/customer_contracts/reference/CUST_RECOVERY_20261027/CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json'
SOURCE_SHA = 'ec2b5494ecf82447076e0d7a2bfb57599a24f049bbcc925a9ecbea6e833bce59'
MIGRATION = BACKEND/'migrations/cq/20261114_01_source_bank_only.sql'
SCOPE = 'Q01_Q13_SOURCE_BANK_STORAGE_ONLY'


def source_bank():
    raw=SOURCE.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=SOURCE_SHA:raise ValueError('Frozen source fingerprint changed')
    document=json.loads(raw.decode('utf-8'))
    questions=document['items']
    if [q['id'] for q in questions]!=[f'Q{i:02}' for i in range(1,14)]:raise ValueError('Exact original Q01-Q13 required')
    if not all(isinstance(q['stem'],str) and q['stem'] and isinstance(q['codes'],list) for q in questions):
        raise ValueError('Source wording/codebook unavailable')
    return {'version':'SOURCE_ONLY:'+document['spec_version']+':EN:'+SOURCE_SHA[:12],
        'content_hash':digest(questions),'questions':questions,'source_sha256':SOURCE_SHA,
        'source_version':document['spec_version'],'source_status':document['status']}


def connect(raw,readonly):
    u=make_url(raw)
    if u.drivername!='postgresql+psycopg2':raise ValueError('Existing psycopg2 driver required')
    conn=psycopg2.connect(host=u.host,port=u.port or 5432,dbname=u.database,user=u.username,password=u.password,
        connect_timeout=5,options='-c statement_timeout=30000 -c lock_timeout=5000')
    conn.set_session(readonly=readonly)
    return conn


def check_target(conn,raw,expected):
    u=make_url(raw)
    with conn.cursor() as q:
        q.execute('SELECT current_database(),current_setting(\'data_directory\'),current_setting(\'server_version\')')
        database,directory,server=q.fetchone()
    if database!=expected or u.database!=expected:raise ValueError('Database target mismatch')
    if database=='Dss':
        pass  # The exact separate live write is explicitly authorized by the user.
    elif database.startswith('project1_cq_source_bank_test'):
        private=os.environ.get('CQ_BANK_PRIVATE_CLUSTER')
        if (not private or u.host!='127.0.0.1' or u.port!=55445
                or Path(directory).resolve()!=(Path(private)/'data').resolve()):
            raise ValueError('Fresh private PostgreSQL target required')
    else:raise ValueError('Only Dss or the verified private source-bank lab is permitted')
    return {'database':database,'server_version':server,'driver':u.drivername}


def schema_state(q):
    q.execute("SELECT to_regclass('public.cq_bank_versions')")
    if q.fetchone()[0] is None:return False
    q.execute("SELECT column_name,data_type,character_maximum_length,is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='cq_bank_versions' ORDER BY ordinal_position")
    expected=[('version','character varying',100,'NO'),('content_hash','character varying',64,'NO'),
        ('questions_json','jsonb',None,'NO'),('created_at','timestamp with time zone',None,'NO')]
    if q.fetchall()!=expected:raise ValueError('Existing bank schema differs; no overwrite allowed')
    q.execute("SELECT relrowsecurity FROM pg_class WHERE oid='public.cq_bank_versions'::regclass")
    if q.fetchone()!= (True,):raise ValueError('Bank RLS must already be enabled')
    q.execute("SELECT count(*) FROM pg_trigger WHERE tgrelid='public.cq_bank_versions'::regclass AND NOT tgisinternal AND tgname IN ('cq_source_bank_append_only','cq_append_only')")
    if q.fetchone()[0]!=1:raise ValueError('Existing immutable bank protection differs')
    return True


def register(raw,expected,apply=False,authorization=None,before_commit=None):
    bank=source_bank()
    if apply:
        if (not authorization or authorization.get('target_database')!=expected
            or authorization.get('scope')!=SCOPE or authorization.get('source_sha256')!=SOURCE_SHA
            or authorization.get('fielding_authorized') is not False):
            raise ValueError('Exact storage-only authorization receipt required')
    conn=connect(raw,readonly=not apply)
    result={'operation':'CQ_SOURCE_BANK_ONLY','apply_requested':apply,'fielding_authorized':False,
        'release_created':False,'campaign_created':False,'version':bank['version'],
        'content_hash':bank['content_hash'],'source_sha256':SOURCE_SHA,'source_status':bank['source_status'],
        'created_table':False,'inserted_bank':False,'committed':False}
    try:
        result.update(check_target(conn,raw,expected))
        if expected=='Dss' and before_commit is not None:raise ValueError('Test hooks cannot target live Dss')
        with conn.cursor() as q:
            if apply:q.execute("SELECT pg_advisory_xact_lock(hashtextextended('PROJECT1_CQ_SOURCE_BANK_ONLY',0))")
            exists=schema_state(q)
            result['table_existed_before']=exists
            if not exists and apply:
                q.execute("SELECT to_regprocedure('public.cq_source_bank_immutable_record()')")
                if q.fetchone()[0] is not None:raise ValueError('Unexpected existing source-bank function')
                q.execute("SELECT set_config('project1.cq_source_bank_target',%s,true),set_config('project1.cq_source_bank_receipt',%s,true)",
                    (expected,authorization.get('record_kind','USER_STORAGE_SCOPE_RECEIPT')))
                q.execute(MIGRATION.read_text(encoding='utf-8'))
                result['created_table']=True;exists=schema_state(q)
            stored=None
            if exists:
                q.execute('SELECT content_hash,questions_json FROM public.cq_bank_versions WHERE version=%s',(bank['version'],))
                stored=q.fetchone()
            if stored and (stored[0]!=bank['content_hash'] or stored[1]!=bank['questions']):
                raise ValueError('Immutable version conflict; no overwrite allowed')
            if not stored and apply:
                q.execute('INSERT INTO public.cq_bank_versions(version,content_hash,questions_json) VALUES(%s,%s,%s)',
                    (bank['version'],bank['content_hash'],Json(bank['questions'])))
                result['inserted_bank']=True;stored=(bank['content_hash'],bank['questions'])
            result['registered']=stored is not None
            result['question_count']=len(stored[1]) if stored else 0
            result['question_ids']=[x['id'] for x in stored[1]] if stored else []
            if before_commit:before_commit(conn)
        if apply:conn.commit();result['committed']=True
        else:conn.rollback()
    except Exception:
        conn.rollback();raise
    finally:conn.close()
    if result['registered']:
        # Independent connection, read-only; verify exact JSON, not only counts.
        verify=connect(raw,readonly=True)
        try:
            check_target(verify,raw,expected)
            with verify.cursor() as q:
                q.execute('SELECT content_hash,questions_json,created_at FROM public.cq_bank_versions WHERE version=%s',(bank['version'],))
                row=q.fetchone()
                if row is None or row[0]!=bank['content_hash'] or row[1]!=bank['questions'] or digest(row[1])!=row[0]:
                    raise ValueError('Independent source-bank readback mismatch')
                result['independent_readback']={'content_hash':row[0],'question_count':len(row[1]),
                    'question_ids':[v['id'] for v in row[1]],'created_at':row[2].isoformat(),
                    'exact_original_records_match':True,'read_only':True}
        finally:verify.rollback();verify.close()
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-database',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--authorization-record',type=Path)
    parser.add_argument('--private-test-url-env')
    args=parser.parse_args()
    if args.private_test_url_env:
        if not args.expected_database.startswith('project1_cq_source_bank_test'):raise ValueError('Private test target required')
        raw=os.environ[args.private_test_url_env]
    else:
        if args.expected_database!='Dss':raise ValueError('Dedicated Dss target required')
        s=Settings(_env_file=str(BACKEND/'.env'))
        raw=s.m2_database_url.get_secret_value() or s.database_url
    authorization=json.loads(args.authorization_record.read_text(encoding='utf-8')) if args.authorization_record else None
    result=register(raw,args.expected_database,args.apply,authorization)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
