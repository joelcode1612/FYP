"""Real restricted logins; run only through the new private-cluster runner."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import secrets
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.ledger import PostgresAttemptLedger

if not os.environ.get('PROJECT1_LAB_ROOT'):
    pytest.skip('Private PostgreSQL runner required',allow_module_level=True)


@pytest.fixture(scope='module')
def db():
    url=make_url(os.environ['PROJECT1_LAB_URL'])
    assert (url.host,url.port,url.database)==('127.0.0.1',55439,'project1_workflow_tests')
    admin=create_engine(url,hide_parameters=True)
    actor,aid,iid,rid=uuid4(),uuid4(),uuid4(),uuid4()
    password=secrets.token_urlsafe(32)
    with admin.begin() as conn:
        assert Path(conn.execute(text('SHOW data_directory')).scalar_one()).resolve()==(Path(os.environ['PROJECT1_LAB_ROOT'])/'data').resolve()
        from psycopg2 import sql
        with conn.connection.driver_connection.cursor() as cur:
            cur.execute(sql.SQL('ALTER ROLE p1ai_runtime LOGIN PASSWORD {}').format(sql.Literal(password)))
        conn.execute(text("INSERT INTO public.users(user_id,email,role,account_status,email_verified,created_at,updated_at) VALUES (:id,'synthetic@example.test','entrepreneur','active',true,now(),now())"),{'id':actor})
        conn.execute(text("INSERT INTO public.m2_instrument_versions(id,code,version_tag,approval_state,schema_digest) VALUES (:id,'SYN','SYN-V1','AUTHORIZED',:h)"),{'id':iid,'h':'a'*64})
        conn.execute(text('INSERT INTO public.m2_assessments(id,owner_user_id,instrument_id,revision) VALUES (:a,:o,:i,2)'),{'a':aid,'o':actor,'i':iid})
        conn.execute(text('INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,source_fingerprint,policy_fingerprint,work_identity) VALUES (:r,:o,:a,2,:h,:h,:h)'),{'r':rid,'o':actor,'a':aid,'h':'b'*64})
    runtime=create_engine(url.set(username='p1ai_runtime',password=password),hide_parameters=True)
    yield admin,runtime,actor,rid
    runtime.dispose(); admin.dispose()


def test_real_runtime_is_not_superuser_or_bypass(db):
    _,engine,_,_=db
    with engine.connect() as c:
        row=c.execute(text('SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user')).one()
        assert tuple(row)==(False,False)


def test_rls_hides_without_actor_or_for_other_actor(db):
    _,engine,actor,rid=db
    with engine.connect() as c:
        assert c.execute(text('SELECT count(*) FROM project1_ai.runs')).scalar_one()==0
        c.execute(text("SELECT set_config('project1.actor_id',:a,true)"),{'a':str(uuid4())})
        assert c.execute(text('SELECT count(*) FROM project1_ai.runs')).scalar_one()==0
        c.execute(text("SELECT set_config('project1.actor_id',:a,true)"),{'a':str(actor)})
        assert c.execute(text('SELECT count(*) FROM project1_ai.runs')).scalar_one()==1


def test_cross_owner_ledger_cannot_reserve(db):
    _,engine,_,rid=db
    with pytest.raises(WorkflowHeld,match='WORKFLOW_RUN_NOT_FOUND'):
        PostgresAttemptLedger(engine,uuid4(),rid).reserve('BDJ','SYN','c'*64,'d'*64)


def test_concurrent_same_stage_exactly_one_reservation_and_restart_denied(db):
    _,engine,actor,rid=db
    def attempt(_):
        try: return PostgresAttemptLedger(engine,actor,rid).reserve('BDJ','SYN','c'*64,'d'*64)
        except WorkflowHeld: return None
    with ThreadPoolExecutor(max_workers=2) as pool: outcomes=list(pool.map(attempt,range(2)))
    assert sum(x is not None for x in outcomes)==1
    with pytest.raises(WorkflowHeld,match='ALREADY_RESERVED'):
        PostgresAttemptLedger(engine,actor,rid).reserve('BDJ','SYN','c'*64,'d'*64)


def test_receipt_persists_new_connection_and_is_append_only(db):
    admin,engine,actor,rid=db
    ledger=PostgresAttemptLedger(engine,actor,rid)
    ledger.finish(1,'unknown_outcome',None)
    with admin.connect() as c:
        assert c.execute(text('SELECT outcome FROM project1_ai.attempt_receipts WHERE run_id=:r'),{'r':rid}).scalar_one()=='unknown_outcome'
    with engine.begin() as c:
        c.execute(text("SELECT set_config('project1.actor_id',:a,true)"),{'a':str(actor)})
        with pytest.raises(DBAPIError):
            c.execute(text('UPDATE project1_ai.runs SET id=id WHERE id=:r'),{'r':rid})
    with engine.begin() as c:
        with pytest.raises(DBAPIError): c.execute(text('DELETE FROM project1_ai.attempt_receipts'))


def test_attempt_budget_bound_and_uc_not_modified(db):
    admin,_,actor,rid=db
    with admin.begin() as c:
        with pytest.raises(DBAPIError):
            c.execute(text("INSERT INTO project1_ai.attempts(run_id,owner_user_id,attempt_no,stage,prompt_version,prompt_hash,request_hash) VALUES (:r,:a,7,'QJ','SYN',:h,:h)"),{'r':rid,'a':actor,'h':'e'*64})
    with admin.connect() as c:
        assert c.execute(text("SELECT to_regnamespace('project1_uc')")).scalar_one() is None
        assert c.execute(text('SELECT count(*) FROM public.m2_answer_revisions')).scalar_one()==0


def test_migration_rerun_without_receipt_refused_without_modification(db):
    admin,_,_,_=db
    migration=(Path(__file__).resolve().parents[2]/'migrations/project1_ai/20261111_01_candidate_ledger.sql').read_text()
    with admin.connect() as c:
        raw=c.connection.driver_connection
        with raw.cursor() as cursor:
            with pytest.raises(Exception): cursor.execute(migration)
        raw.rollback()
        assert c.execute(text('SELECT count(*) FROM project1_ai.schema_versions')).scalar_one()==1


def test_audit_principal_reads_metadata_but_cannot_write(db):
    admin,_,_,_=db
    password=secrets.token_urlsafe(32)
    with admin.begin() as conn:
        from psycopg2 import sql
        with conn.connection.driver_connection.cursor() as cur:
            cur.execute(sql.SQL('ALTER ROLE p1ai_audit LOGIN PASSWORD {}').format(sql.Literal(password)))
    audit=create_engine(admin.url.set(username='p1ai_audit',password=password),hide_parameters=True)
    try:
        with audit.connect() as c:
            assert c.execute(text('SELECT count(*) FROM project1_ai.attempts')).scalar_one()==1
            with pytest.raises(DBAPIError):
                c.execute(text('DELETE FROM project1_ai.attempts'))
        with audit.connect() as c:
            with pytest.raises(DBAPIError): c.execute(text('SELECT * FROM public.m2_answer_revisions'))
    finally:
        audit.dispose()
