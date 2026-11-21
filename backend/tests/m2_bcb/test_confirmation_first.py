"""Actual signed HTTP + disposable PostgreSQL: declaration confirmation first.

No production registration, profile, assessment, model call or policy adoption.
"""
import hashlib
import json
import os
import time
import pytest
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from uuid import UUID, uuid4

from sqlalchemy import text

from test_postgres_api import lab, case_name, create, answer


def test_private_actual_m2_session_protected_owner_read(lab, monkeypatch):
    """Actual M2 session + signed HTTP; only assessment RLS is migrated privately."""
    import secrets
    from pathlib import Path
    from pydantic import SecretStr
    from sqlalchemy import create_engine
    from sqlalchemy.engine import make_url
    from sitewise.core.config import settings
    from sitewise.db import m2_session
    from sitewise.db.m2_identity_assertion import mint_m2_assertion

    mid = create(lab)
    key, password = secrets.token_bytes(32), secrets.token_hex(24)
    with lab['db'].begin() as conn:
        conn.execute(text("ALTER ROLE p1_m2_runtime PASSWORD '" + password + "'"))
    path = Path(__file__).resolve().parents[2] / 'migrations/m2/20261121_01_protected_identity_private_rehearsal.sql'
    # Rehearsal must reject even this disposable target without the explicit
    # synthetic receipt and leave the original private schema intact.
    raw = lab['db'].raw_connection()
    try:
        cur = raw.cursor()
        with pytest.raises(Exception) as denied:
            cur.execute(path.read_text(encoding='utf-8'))
        assert getattr(denied.value, 'pgcode', None) == 'P0001'
        raw.rollback()
    finally:
        raw.close()
    with lab['db'].connect() as conn:
        assert conn.scalar(text("SELECT to_regnamespace('project1_identity') IS NULL"))
        assert conn.scalar(text('SELECT count(*) FROM public.m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 1
    raw = lab['db'].raw_connection()
    try:
        cur = raw.cursor()
        cur.execute("SET project1.identity_test_receipt='PRIVATE-SYNTHETIC-ONLY'")
        cur.execute(path.read_text(encoding='utf-8'))
        raw.commit()
    finally:
        raw.close()
    with lab['db'].begin() as conn:
        conn.execute(text('INSERT INTO project1_identity.private_key VALUES (1,:key)'), {'key':key})
    url = make_url(os.environ['DATABASE_URL']).set(username='p1_m2_runtime', password=password)
    engine = create_engine(url, hide_parameters=True)
    monkeypatch.setattr(m2_session, 'get_m2_engine', lambda: engine)
    monkeypatch.setattr(settings, 'm2_protected_identity_enabled', True)
    monkeypatch.setattr(settings, 'm2_identity_assertion_key', SecretStr(key.hex()))
    try:
        lab['request']('GET', f'/assessments/{mid}', 200)
        lab['request']('GET', f'/assessments/{mid}', 404, uid=lab['other'])
        lab['request']('GET', f'/assessments/{mid}', 401, uid=None)
        with engine.begin() as conn:
            assert conn.execute(text('SELECT current_user,session_user')).one() == ('p1_m2_runtime','p1_m2_runtime')
            conn.execute(text("SELECT set_config('project1.actor_id',:actor,true)"), {'actor':str(lab['actor'])})
            assert conn.scalar(text('SELECT count(*) FROM m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 0
            token = mint_m2_assertion(lab['other'],key.hex())
            conn.execute(text("SELECT set_config('project1.identity_assertion',:value,true)"), {'value':token})
            assert conn.scalar(text('SELECT count(*) FROM m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 0
            forged = token.replace(str(lab['other']),str(lab['actor']))
            conn.execute(text("SELECT set_config('project1.identity_assertion',:value,true)"), {'value':forged})
            assert conn.scalar(text('SELECT count(*) FROM m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 0
            expired = mint_m2_assertion(lab['actor'],key.hex(),now=int(time.time())-31)
            conn.execute(text("SELECT set_config('project1.identity_assertion',:value,true)"), {'value':expired})
            assert conn.scalar(text('SELECT count(*) FROM m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 0
    finally:
        engine.dispose()
    rollback = Path(__file__).resolve().parents[2] / 'migrations/m2/20261121_01_protected_identity_private_rehearsal_rollback.sql'
    raw = lab['db'].raw_connection()
    try:
        cur = raw.cursor()
        cur.execute("SET project1.identity_test_receipt='PRIVATE-SYNTHETIC-ONLY'")
        cur.execute(rollback.read_text(encoding='utf-8'))
        raw.commit()
    finally:
        raw.close()
    with lab['db'].connect() as conn:
        assert conn.scalar(text("SELECT to_regnamespace('project1_identity') IS NULL"))
        assert conn.scalar(text('SELECT count(*) FROM public.m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 1
        policy = conn.scalar(text("SELECT qual FROM pg_policies WHERE schemaname='public' "
            "AND tablename='m2_assessments' AND policyname='owner_scope'"))
        assert 'project1.actor_id' in policy  # legacy policy restored in this disposable cluster only


def test_private_signed_actor_prototype_rejects_guc_impersonation(lab):
    """Isolated signed assertion experiment; not the SiteWise review integration."""
    import hashlib
    import hmac
    import secrets
    from sqlalchemy import create_engine
    from sqlalchemy.engine import make_url
    from sqlalchemy.exc import DBAPIError

    password, key = secrets.token_hex(24), secrets.token_bytes(32)
    with lab['db'].begin() as c:
        c.execute(text("ALTER ROLE p1_m2_runtime PASSWORD '" + password + "'"))
        c.exec_driver_sql('CREATE EXTENSION IF NOT EXISTS pgcrypto')
        c.exec_driver_sql('CREATE SCHEMA private_authz_test')
        c.exec_driver_sql('REVOKE ALL ON SCHEMA private_authz_test FROM PUBLIC')
        c.exec_driver_sql('CREATE TABLE private_authz_test.signing_keys (id integer PRIMARY KEY, key bytea NOT NULL)')
        c.execute(text('INSERT INTO private_authz_test.signing_keys VALUES (1,:key)'), {'key':key})
        c.exec_driver_sql('CREATE TABLE private_authz_test.records (id uuid PRIMARY KEY, owner_id uuid NOT NULL, value text NOT NULL)')
        c.execute(text('INSERT INTO private_authz_test.records VALUES (:a,:owner_a,:v),(:b,:owner_b,:v)'),
            {'a':uuid4(),'b':uuid4(),'owner_a':lab['actor'],'owner_b':lab['other'],'v':'SYNTHETIC'})
        c.exec_driver_sql("""CREATE FUNCTION private_authz_test.actor() RETURNS uuid
          LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
          DECLARE token text; pieces text[]; secret bytea; expected text;
          BEGIN
            token := current_setting('private_authz_test.assertion', true);
            IF token IS NULL OR length(token)>256 THEN RETURN NULL; END IF;
            pieces := string_to_array(token, '|');
            IF array_length(pieces,1)<>4 OR pieces[1] !~ '^[0-9a-f-]{36}$'
               OR pieces[2] !~ '^[0-9]{10}$' OR pieces[3] !~ '^[0-9a-f]{32}$'
               OR pieces[4] !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
            IF pieces[2]::bigint <= extract(epoch FROM statement_timestamp())::bigint
               OR pieces[2]::bigint > extract(epoch FROM statement_timestamp())::bigint + 60
               THEN RETURN NULL; END IF;
            SELECT k.key INTO secret FROM private_authz_test.signing_keys k WHERE k.id=1;
            expected := encode(public.hmac(convert_to(pieces[1]||'|'||pieces[2]||'|'||pieces[3], 'UTF8'), secret, 'sha256'), 'hex');
            IF expected <> pieces[4] THEN RETURN NULL; END IF;
            RETURN pieces[1]::uuid;
          EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN RETURN NULL;
          END $$""")
        c.exec_driver_sql('REVOKE ALL ON FUNCTION private_authz_test.actor() FROM PUBLIC')
        c.exec_driver_sql('ALTER TABLE private_authz_test.records ENABLE ROW LEVEL SECURITY')
        c.exec_driver_sql('CREATE POLICY own_test_row ON private_authz_test.records USING (owner_id = private_authz_test.actor()) WITH CHECK (owner_id = private_authz_test.actor())')
        c.exec_driver_sql('GRANT USAGE ON SCHEMA private_authz_test TO p1_m2_runtime')
        c.exec_driver_sql('GRANT EXECUTE ON FUNCTION private_authz_test.actor() TO p1_m2_runtime')
        c.exec_driver_sql('GRANT SELECT, INSERT ON private_authz_test.records TO p1_m2_runtime')

    def assertion(actor, expiry):
        body = f'{actor}|{expiry}|{secrets.token_hex(16)}'
        return body + '|' + hmac.new(key, body.encode(), hashlib.sha256).hexdigest()
    url = make_url(os.environ['DATABASE_URL']).set(username='p1_m2_runtime', password=password)
    engine = create_engine(url, hide_parameters=True)
    try:
        with engine.begin() as c:
            assert c.execute(text('SELECT current_user, session_user')).one() == ('p1_m2_runtime','p1_m2_runtime')
            assert not c.scalar(text("SELECT has_table_privilege(current_user,'private_authz_test.signing_keys','SELECT')"))
            c.execute(text("SELECT set_config('private_authz_test.assertion',:v,true)"),
                      {'v':assertion(lab['actor'], int(time.time())+40)})
            assert c.scalar(text('SELECT count(*) FROM private_authz_test.records')) == 1
            c.execute(text("SELECT set_config('project1.actor_id',:v,true)"), {'v':str(lab['other'])})
            assert c.scalar(text('SELECT owner_id FROM private_authz_test.records')) == lab['actor']
            forged = assertion(lab['actor'], int(time.time())+40).replace(str(lab['actor']), str(lab['other']))
            c.execute(text("SELECT set_config('private_authz_test.assertion',:v,true)"), {'v':forged})
            assert c.scalar(text('SELECT count(*) FROM private_authz_test.records')) == 0
            c.execute(text("SELECT set_config('private_authz_test.assertion',:v,true)"),
                      {'v':assertion(lab['actor'], int(time.time())-2)})
            assert c.scalar(text('SELECT count(*) FROM private_authz_test.records')) == 0
        with engine.begin() as c:
            c.execute(text("SELECT set_config('private_authz_test.assertion',:v,true)"),
                      {'v':assertion(lab['actor'], int(time.time())+40)})
            with pytest.raises(DBAPIError) as denied:
                c.execute(text('INSERT INTO private_authz_test.records VALUES (:id,:other,:v)'),
                          {'id':uuid4(),'other':lab['other'],'v':'forbidden'})
            assert denied.value.orig.pgcode == '42501'

        # Test-only HTTP bridge using the existing Supabase verifier and a
        # synthetic key. It is deliberately not installed in production app.
        import jwt
        from cryptography.hazmat.primitives.asymmetric import ec
        from fastapi import FastAPI, Header, HTTPException
        from fastapi.testclient import TestClient
        from sitewise.core.exceptions import AuthError
        from sitewise.core.security import SupabaseJWTVerifier
        signing = ec.generate_private_key(ec.SECP256R1())
        jwk = jwt.algorithms.ECAlgorithm.to_jwk(signing.public_key(), as_dict=True)
        jwk.update(kid='test-key', use='sig', alg='ES256')
        verifier = SupabaseJWTVerifier(jwks_url='https://test.invalid/keys',
            issuer='https://test.invalid/auth', audiences=['authenticated'], leeway=0)
        verifier.jwks.get_key = lambda kid: jwk if kid == 'test-key' else (_ for _ in ()).throw(AuthError('unknown key'))
        app = FastAPI()
        @app.get('/synthetic-records')
        def records(authorization: str = Header(default='')):
            try:
                if not authorization.startswith('Bearer '): raise AuthError('missing')
                actor = UUID(verifier.verify(authorization[7:]).subject)
            except (AuthError, ValueError):
                raise HTTPException(status_code=401) from None
            with engine.begin() as c:
                c.execute(text("SELECT set_config('private_authz_test.assertion',:v,true)"),
                          {'v':assertion(actor, int(time.time())+40)})
                return {'owners':[str(row[0]) for row in c.execute(text('SELECT owner_id FROM private_authz_test.records'))]}
        def token(actor, **changes):
            now=int(time.time())
            claims={'sub':str(actor),'iat':now,'exp':now+60,'aud':'authenticated','iss':'https://test.invalid/auth'}
            claims.update(changes)
            return jwt.encode(claims, signing, algorithm='ES256', headers={'kid':'test-key'})
        with TestClient(app) as client:
            for actor in (lab['actor'], lab['other']):
                response=client.get('/synthetic-records',headers={'Authorization':'Bearer '+token(actor)})
                assert response.status_code == 200 and response.json()['owners'] == [str(actor)]
            for bad in (token(lab['actor'], exp=int(time.time())-2),
                        token(lab['actor'], aud='wrong'), token(lab['actor'], iss='https://wrong.invalid'),
                        token(lab['actor'])[:-4]+'AAAA'):
                assert client.get('/synthetic-records',headers={'Authorization':'Bearer '+bad}).status_code == 401
    finally:
        engine.dispose()


def test_private_runtime_role_actor_binding_trust_boundary(lab):
    """A direct runtime login can set a custom GUC; never use this as authority alone."""
    import secrets
    from sqlalchemy import create_engine
    from sqlalchemy.engine import make_url
    mid = create(lab)
    password = secrets.token_hex(24)  # newly generated for this private cluster only
    with lab['db'].begin() as conn:
        conn.execute(text("ALTER ROLE p1_m2_runtime PASSWORD '" + password + "'"))
    url = make_url(os.environ['DATABASE_URL']).set(username='p1_m2_runtime', password=password)
    engine = create_engine(url, hide_parameters=True)
    try:
        with engine.begin() as conn:
            assert conn.execute(text('SELECT current_user,session_user')).one() == ('p1_m2_runtime', 'p1_m2_runtime')
            privileges = conn.execute(text("SELECT "
                "has_table_privilege(current_user,'public.m2_candidate_review_assignments','SELECT'), "
                "has_table_privilege(current_user,'public.m2_candidate_review_assignments','INSERT'), "
                "has_table_privilege(current_user,'public.m2_candidate_owner_reviews','SELECT'), "
                "has_table_privilege(current_user,'public.m2_candidate_owner_reviews','INSERT')")).one()
            assert tuple(privileges) == (False, False, True, False)
            conn.execute(text("SELECT set_config('project1.actor_id', :actor, true)"), {'actor':str(lab['other'])})
            assert conn.scalar(text('SELECT count(*) FROM m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 0
            # This direct login, unlike the API boundary, has no verified JWT.
            conn.execute(text("SELECT set_config('project1.actor_id', :actor, true)"), {'actor':str(lab['actor'])})
            assert conn.scalar(text('SELECT count(*) FROM m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 1
    finally:
        engine.dispose()


@pytest.mark.skipif(os.environ.get('M2_BINDING_TEST') != '1', reason='requires isolated binding-test schema')
def test_marketplace_bound_answer_fails_after_link_revocation(lab):
    """Runs only in the private binding-test cluster, with synthetic IDs."""
    mid = create(lab)
    marketplace, link_id = uuid4(), uuid4()
    with lab['db'].begin() as c:
        c.execute(text('INSERT INTO public.m2_assessment_links '
            '(link_id,m2_assessment_id,marketplace_assessment_id,user_id,created_by) '
            'VALUES (:link,:mid,:market,:actor,:actor)'),
            {'link':link_id,'mid':UUID(mid),'market':marketplace,'actor':lab['actor']})
    # A conflicting revocation cannot pass the link lock during a bound write.
    from sqlmodel import Session
    from sqlalchemy.exc import OperationalError
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    def concurrent_revoke():
        try:
            with lab['db'].begin() as c:
                c.execute(text("SET LOCAL lock_timeout = '250ms'"))
                c.execute(text('UPDATE public.m2_assessment_links SET revoked_at=now(), '
                    'revoked_by=:actor,revoke_reason=:reason WHERE link_id=:link'),
                    {'link':link_id,'actor':lab['actor'],'reason':'SYNTHETIC RACE'})
        except OperationalError as exc:
            return getattr(exc.orig, 'pgcode', None)
        return 'unexpected-success'
    with Session(lab['db']) as session:
        assert SqlModelM2Repository(session).lock_active_marketplace_binding(UUID(mid), lab['actor'], marketplace)
        with ThreadPoolExecutor(max_workers=1) as pool:
            assert pool.submit(concurrent_revoke).result(timeout=5) == '55P03'
        session.rollback()
    path = f'/assessments/{mid}/answers/M2-01'
    body = {'expected_revision':0,'answer_state':'ANSWERED','value':'SYNTHETIC_A',
            'marketplace_assessment_id':str(marketplace)}
    lab['request']('PUT', path, 200, json=body)
    body.update(expected_revision=1,value='SYNTHETIC_B')
    # Race the real HTTP answer operation against link revocation. Hold the
    # link, wait for the API's locking SELECT, then revoke and commit first.
    with lab['db'].connect() as holder:
        transaction = holder.begin()
        holder.execute(text('SELECT link_id FROM public.m2_assessment_links WHERE link_id=:link FOR UPDATE'), {'link':link_id})
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(lab['request'], 'PUT', path, 409, json=body)
                deadline = time.monotonic() + 5
                observed_wait = False
                while time.monotonic() < deadline:
                    with lab['db'].connect() as observer:
                        observed_wait = observer.scalar(text("SELECT EXISTS (SELECT 1 FROM pg_stat_activity "
                            "WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE :query)"),
                            {'query':'%SELECT link_id FROM public.m2_assessment_links%'})
                    if observed_wait:
                        break
                    time.sleep(.025)
                if not observed_wait:
                    transaction.rollback()
                    raise AssertionError('HTTP request did not reach the link lock')
                holder.execute(text('UPDATE public.m2_assessment_links SET revoked_at=now(), '
                    'revoked_by=:actor,revoke_reason=:reason WHERE link_id=:link'),
                    {'link':link_id,'actor':lab['actor'],'reason':'SYNTHETIC TEST'})
                transaction.commit()
                pending.result(timeout=8)
        finally:
            if transaction.is_active:
                transaction.rollback()
    bound = {'expected_revision':1,'marketplace_assessment_id':str(marketplace)}
    lab['request']('POST', f'/assessments/{mid}/review', 409, json=bound)
    lab['request']('POST', f'/assessments/{mid}/confirm', 409,
                   json={**bound, 'acknowledged_issue_ids':[]})
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT revision FROM public.m2_assessments WHERE id=:id'), {'id':UUID(mid)}) == 1
        assert c.scalar(text('SELECT count(*) FROM public.m2_answer_revisions WHERE assessment_id=:id'), {'id':UUID(mid)}) == 1
        assert c.scalar(text('SELECT count(*) FROM public.m2_confirmation_snapshots WHERE assessment_id=:id'), {'id':UUID(mid)}) == 0


def test_candidate_old_confirmation_stays_hidden_after_new_confirmation(lab):
    """Private synthetic fixture; no finding or questionnaire is authorized."""
    from sqlmodel import Session
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    mid = complete(lab)
    first = confirm(lab, mid)
    objective, candidate = uuid4(), uuid4()
    with lab['db'].begin() as conn:
        conn.execute(text('INSERT INTO public.m2_confirmed_uncertainties '
            '(id,confirmation_id,actor_user_id,exact_text) VALUES (:id,:cid,:actor,:text)'),
            {'id': objective, 'cid': UUID(first['id']), 'actor': lab['actor'], 'text': 'SYNTHETIC ONLY'})
        conn.execute(text('INSERT INTO public.m2_research_objective_sources '
            '(objective_id,provenance) VALUES (:id,CAST(:source AS jsonb))'),
            {'id': objective, 'source': '{}'})
        conn.execute(text('INSERT INTO public.m2_review_question_versions '
            '(id,objective_id,source_receipt,question,options) VALUES (:id,:objective,:receipt,:question,CAST(:options AS jsonb))'),
            {'id': candidate, 'objective': objective, 'receipt': '{}', 'question': 'Synthetic?', 'options': '[]'})
    with Session(lab['db']) as session:
        assert SqlModelM2Repository(session).candidate_version(candidate, lab['actor']) is not None
    answer(lab, mid, 'M2-04', 'SYNTHETIC revised.', 3)
    confirm(lab, mid, 4)
    with Session(lab['db']) as session:
        assert SqlModelM2Repository(session).candidate_version(candidate, lab['actor']) is None


def test_new_workflow_readiness_uses_persisted_confirmation_and_detects_edit(lab):
    from types import SimpleNamespace
    from sqlmodel import Session
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.m2_service import M2Service
    from sitewise.services.assessment_workflow_readiness import workflow_readiness

    mid = complete(lab)
    receipt = confirm(lab, mid)
    marketplace = SimpleNamespace(assessment_id=uuid4(), property_selected_at='selected')
    # This test uses a stub link; cross-database link and HTTP integration are
    # separate checks. All M2 source validation reads actual private PostgreSQL.
    link = SimpleNamespace(resolve=lambda **kw: SimpleNamespace(m2_assessment_id=UUID(mid)))
    with Session(lab['db']) as session:
        service = M2Service(SqlModelM2Repository(session))
        result = workflow_readiness(marketplace, lab['actor'], None, link, service)
        assert result['stage_2']['confirmation_id'] == receipt['id']
        assert result['stage_3']['enterable'] is True
        assert result['stage_3']['complete'] is False
    answer(lab, mid, 'M2-04', 'SYNTHETIC changed after confirmation.', 3)
    with Session(lab['db']) as session:
        result = workflow_readiness(marketplace, lab['actor'], None, link,
                                    M2Service(SqlModelM2Repository(session)))
        assert result['stage_2']['complete'] is False
        assert result['stage_3']['enterable'] is False


def complete(lab):
    mid = create(lab)
    answer(lab, mid, 'M2-01', 'SYNTHETIC_A', 0)
    answer(lab, mid, 'M2-04', 'SYNTHETIC confirmation-first test café.', 1)
    answer(lab, mid, 'M2-05', 'TAKEAWAY_FOCUSED', 2)
    return mid


def confirm(lab, mid, revision=3):
    lab['request']('POST', f'/assessments/{mid}/review', json={'expected_revision': revision})
    return lab['request']('POST', f'/assessments/{mid}/confirm',
                          json={'expected_revision': revision, 'acknowledged_issue_ids': []}).json()


def test_A_B_complete_without_any_bdj_receipt(lab):
    mid = complete(lab)
    receipt = confirm(lab, mid)
    snap = receipt['snapshot_json']
    assert snap['snapshot_contract_version'] == 'm2-confirmation/3'
    assert snap['confirmation_scope'] == 'M2_DECLARATIONS_ONLY'
    assert 'bdj_evaluation_id' not in snap and 'bdj_rule_version' not in snap
    assert snap['unresolved_candidate_findings'] == []
    assert snap['finding_decision_event_refs'] == {}
    assert snap['review_event_id']
    assert receipt['snapshot_digest'] == hashlib.sha256(json.dumps(
        snap, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT count(*) FROM m2_bdj_evaluations WHERE assessment_id=:id'), {'id': UUID(mid)}) == 0
        assert c.scalar(text('SELECT count(*) FROM m2_bdj_findings WHERE assessment_id=:id'), {'id': UUID(mid)}) == 0
        assert c.scalar(text('SELECT snapshot_digest FROM m2_confirmation_snapshots WHERE id=:id'), {'id': UUID(receipt['id'])}) == receipt['snapshot_digest']
    current = lab['request']('GET', f'/assessments/{mid}/confirmation-current').json()
    assert current['id'] == receipt['id']
    reviewed = lab['request']('GET', f'/assessments/{mid}/confirmed-review',
        params={'confirmation_id': receipt['id'], 'expected_revision': 3}).json()
    assert reviewed['evaluation_state'] == 'NOT_EVALUATED'
    assert not reviewed['findings'] and len(reviewed['answers']) == 3


def test_C_incomplete_review_and_confirmation_refused(lab):
    mid = create(lab)
    for action in ('review', 'confirm'):
        result = lab['request']('POST', f'/assessments/{mid}/{action}', 409,
                               json={'expected_revision': 0}).json()
        assert result['detail']['code'] == 'M2_REQUIRED_DECLARATIONS_MISSING'
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT count(*) FROM m2_confirmation_snapshots WHERE assessment_id=:id'), {'id': UUID(mid)}) == 0


def test_E_F_stale_cross_owner_and_auth_refused(lab):
    mid = complete(lab)
    for action in ('review', 'confirm'):
        lab['request']('POST', f'/assessments/{mid}/{action}', 409, json={'expected_revision': 2})
        lab['request']('POST', f'/assessments/{mid}/{action}', 404, uid=lab['other'], json={'expected_revision': 3})
        lab['request']('POST', f'/assessments/{mid}/{action}', 401, uid=None, json={'expected_revision': 3})
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT count(*) FROM m2_confirmation_snapshots WHERE assessment_id=:id'), {'id': UUID(mid)}) == 0


def test_H_edit_preserves_snapshot_but_invalidates_currentness(lab):
    mid = complete(lab)
    receipt = confirm(lab, mid)
    answer(lab, mid, 'M2-04', 'SYNTHETIC edited declaration.', 3)
    lab['request']('GET', f'/assessments/{mid}/confirmation-current', 404)
    lab['request']('GET', f'/assessments/{mid}/confirmed-review', 409,
                   params={'confirmation_id': receipt['id'], 'expected_revision': 3})
    with lab['db'].connect() as c:
        saved = c.execute(text('SELECT snapshot_json,snapshot_digest FROM m2_confirmation_snapshots WHERE id=:id'), {'id': UUID(receipt['id'])}).mappings().one()
        assert saved['snapshot_json'] == receipt['snapshot_json']
        assert saved['snapshot_digest'] == receipt['snapshot_digest']


def test_no_pre_bdj_acknowledgements_are_invented(lab):
    mid = complete(lab)
    lab['request']('POST', f'/assessments/{mid}/review', json={'expected_revision': 3})
    result = lab['request']('POST', f'/assessments/{mid}/confirm', 409,
        json={'expected_revision': 3, 'acknowledged_issue_ids': [str(uuid4())]}).json()
    assert result['detail']['code'] == 'M2_DECLARATION_FINDING_ACK_NOT_ALLOWED'


def test_D_I_J_all_eleven_M2V1_items_and_separate_BDJ_gate(lab):
    from scripts.register_m2_v1 import register
    iid = register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')['instrument_id']
    mid = lab['request']('POST', '/assessments', 201, json={'instrument_version_id': iid}).json()['id']
    values = {
        'M2V1-01':'UNDECIDED', 'M2V1-02':'HYBRID', 'M2V1-03':['COFFEE'],
        'M2V1-04':['STUDENTS','OFFICE_WORKERS'], 'M2V1-05':'STUDENTS',
        'M2V1-06':'QUALITY', 'M2V1-07':'STUDY_WORK', 'M2V1-08':['NONE'],
        'M2V1-09':['CONCEPT_INTEREST','PRICE_ACCEPTABILITY'],
        'M2V1-10':'CONCEPT_INTEREST', 'M2V1-11':'EXPLORE',
    }
    for rev, (key,value) in enumerate(values.items()):
        answer(lab, mid, key, value, rev)
    lab['request']('PUT', f'/assessments/{mid}/answers/M2V1-07', 422,
        json={'expected_revision':11, 'answer_state':'NOT_APPLICABLE', 'value':None})
    lab['request']('POST', f'/assessments/{mid}/bdj/evaluate', 409, json={'expected_revision':11})
    receipt = confirm(lab, mid, 11)
    lab['request']('POST', f'/assessments/{mid}/bdj/evaluate', 503, json={'expected_revision':11})
    review = lab['request']('GET', f'/assessments/{mid}/confirmed-review',
        params={'confirmation_id':receipt['id'], 'expected_revision':11}).json()
    assert {a['item_key']:a['value'] for a in review['answers']} == values
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id'), {'id': UUID(mid)}) == 11
        assert c.scalar(text('SELECT count(*) FROM m2_bdj_evaluations WHERE assessment_id=:id'), {'id': UUID(mid)}) == 0
    objective_text = '  SYNTHETIC concept interest  '
    objective = lab['request']('POST', f"/confirmations/{receipt['id']}/research-objectives", 201,
        json={'expected_revision':11, 'origin':'ENTREPRENEUR', 'objective':objective_text}).json()
    assert objective['source']['priority'] == 'CONCEPT_INTEREST'
    assert objective['source']['assessment_revision'] == 11
    assert objective['exact_text'] == objective_text
    workspace = lab['request']('GET', f"/confirmations/{receipt['id']}/research-workspace",
                               params={'expected_revision':11}).json()
    assert any(row['id'] == objective['id'] and row['exact_text'] == objective['exact_text']
               for row in workspace['objectives'])
    row = next(row for row in workspace['objectives'] if row['id'] == objective['id'])
    assert row['objective_version_id'] == objective['id']
    assert row['owner_decision'] == 'CONFIRMED'
    assert row['approval_status'] == 'CONFIRMED_BY_OWNER'
    with lab['db'].connect() as c:
        saved = c.execute(text('SELECT provenance FROM m2_research_objective_sources WHERE objective_id=:id'),
                          {'id': UUID(objective['id'])}).scalar_one()
    assert saved['snapshot_digest'] == objective['source']['snapshot_digest']
    assert saved['answer_revisions']['M2V1-09']['answer_revision_id']
    assert saved['owner_user_id'] == str(lab['actor'])
    assert saved['objective_version'] == objective['id']
    assert saved['owner_decision'] == 'CONFIRMED'
    bcb = lab['request']('POST', f'/assessments/{mid}/business-context', 503,
        json={'confirmation_id': receipt['id'], 'expected_revision':11,
              'objective_id':objective['id']}).json()
    assert bcb['detail']['code'] == 'BCB_BINDING_AUTHORITY_UNVERIFIED'
    lab['request']('POST', f"/confirmations/{receipt['id']}/research-objectives", 404,
        uid=lab['other'], json={'expected_revision':11, 'origin':'ENTREPRENEUR', 'objective':'SYNTHETIC other owner'})
    lab['request']('POST', f"/confirmations/{receipt['id']}/research-objectives", 409,
        json={'expected_revision':11, 'origin':'BDJ', 'objective':'SYNTHETIC unverified finding'})
    answer(lab, mid, 'M2V1-11', 'UNSURE', 11)
    # The current-confirmation lookup hides stale snapshots as 404.
    lab['request']('POST', f"/confirmations/{receipt['id']}/research-objectives", 404,
        json={'expected_revision':11, 'origin':'ENTREPRENEUR', 'objective':'SYNTHETIC stale'})


def test_duplicate_confirmation_is_refused_without_overwriting(lab):
    mid = complete(lab)
    original = confirm(lab, mid)
    result = lab['request']('POST', f'/assessments/{mid}/confirm', 409,
        json={'expected_revision':3}).json()
    assert result['detail']['code'] == 'M2_ALREADY_CONFIRMED_OR_CHANGED'
    with lab['db'].connect() as c:
        snapshots = c.execute(text('SELECT id,snapshot_digest FROM m2_confirmation_snapshots WHERE assessment_id=:id'), {'id': UUID(mid)}).mappings().all()
        assert len(snapshots) == 1
        assert str(snapshots[0]['id']) == original['id']
        assert snapshots[0]['snapshot_digest'] == original['snapshot_digest']


def test_current_m2v1_objective_to_real_bcb_resolver(lab):
    """Synthetic only: use the normal resolver, not the fixture BCB binding."""
    from scripts.register_m2_v1 import register
    from sitewise import dependencies as deps
    iid = register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')['instrument_id']
    mid = lab['request']('POST', '/assessments', 201, json={'instrument_version_id': iid}).json()['id']
    values = {'M2V1-01':'UNDECIDED', 'M2V1-02':'HYBRID', 'M2V1-03':['COFFEE'],
              'M2V1-04':['STUDENTS','OFFICE_WORKERS'], 'M2V1-05':'STUDENTS', 'M2V1-06':'QUALITY',
              'M2V1-07':'STUDY_WORK', 'M2V1-08':['NONE'], 'M2V1-09':['CONCEPT_INTEREST','PRICE_ACCEPTABILITY'],
              'M2V1-10':'CONCEPT_INTEREST', 'M2V1-11':'EXPLORE'}
    for rev, (key, value) in enumerate(values.items()):
        answer(lab, mid, key, value, rev)
    confirmation = confirm(lab, mid, 11)
    objective = lab['request']('POST', f"/confirmations/{confirmation['id']}/research-objectives", 201,
        json={'expected_revision':11, 'origin':'ENTREPRENEUR', 'objective':'SYNTHETIC concept interest'}).json()
    override = lab['app'].dependency_overrides.pop(deps.get_bcb_bindings_resolver_factory)
    try:
        response = lab['request']('POST', f'/assessments/{mid}/business-context', (200,201,409,503),
            json={'confirmation_id':confirmation['id'], 'expected_revision':11, 'objective_id':objective['id']})
        assert response.status_code in (200,201), response.text
        packet = response.json()['packet']
        assert packet['confirmed_uncertainty']['id'] == objective['id']
        assert packet['confirmation']['id'] == confirmation['id']
        assert packet['confirmation']['revision'] == 11
        restored = lab['request']('GET', f"/assessments/{mid}/business-contexts/{response.json()['context_id']}").json()
        assert restored['packet']['packet_hash'] == packet['packet_hash']
        assert restored['packet']['confirmed_uncertainty']['id'] == objective['id']
        lab['request']('GET', f"/assessments/{mid}/business-contexts/{response.json()['context_id']}",
                       404, uid=lab['other'])
        with lab['db'].connect() as conn:
            assert conn.scalar(text('SELECT count(*) FROM m2_business_contexts WHERE context_id=:id'),
                               {'id':UUID(response.json()['context_id'])}) == 1
    finally:
        lab['app'].dependency_overrides[deps.get_bcb_bindings_resolver_factory] = override


def test_discovery_candidate_real_answer_revision_provenance(lab):
    """Candidate-only; confirms source pointers against private PostgreSQL."""
    from scripts.register_m2_v1 import register
    from sitewise.project1.bdj_discovery_candidate import project_declared_signals
    from sitewise.project1.contracts import WorkflowHeld
    from sitewise.project1.projection import M2SourceProjection
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sqlmodel import Session
    iid = register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')['instrument_id']
    mid = lab['request']('POST', '/assessments', 201, json={'instrument_version_id': iid}).json()['id']
    values = {'M2V1-01':'UNDECIDED', 'M2V1-02':'HYBRID', 'M2V1-03':['COFFEE'],
              'M2V1-04':['STUDENTS','OFFICE_WORKERS'], 'M2V1-05':'STUDENTS', 'M2V1-06':'QUALITY',
              'M2V1-07':'STUDY_WORK', 'M2V1-08':['UNKNOWN'], 'M2V1-09':['CONCEPT_INTEREST'],
              'M2V1-10':'CONCEPT_INTEREST', 'M2V1-11':'UNSURE'}
    for rev, (key, value) in enumerate(values.items()):
        answer(lab, mid, key, value, rev)
    confirmation = confirm(lab, mid, 11)
    with Session(lab['db']) as session:
        repo = SqlModelM2Repository(session)
        from sitewise.services.m2_service import M2Service
        with M2Service(repo).locked_confirmed_source(UUID(mid), lab['actor'],
                confirmation_id=UUID(confirmation['id']), expected_revision=11) as locked:
            assert locked['snapshot_digest'] == confirmation['snapshot_digest']
        definitions = repo.list_items(UUID(iid))
        packet = M2SourceProjection(repo).read(UUID(mid), lab['actor'], 11)
    signals = project_declared_signals(packet, definitions)
    assert signals['source_fingerprint'] == packet['source_fingerprint']
    refs = [ref for signal in signals['signals'] for ref in signal['source_refs']]
    assert refs and all('value' not in ref for ref in refs)
    with lab['db'].connect() as c:
        for ref in refs:
            row = c.execute(text('SELECT assessment_id,item_version_id FROM m2_answer_revisions WHERE id=:id'),
                            {'id': UUID(ref['answer_revision_id'])}).mappings().one()
            assert str(row['assessment_id']) == mid
            assert str(row['item_version_id']) == ref['item_version_id']
        saved = c.execute(text('SELECT snapshot_digest,snapshot_json FROM m2_confirmation_snapshots WHERE id=:id'),
                          {'id': UUID(confirmation['id'])}).mappings().one()
        old = saved['snapshot_digest']
        pinned = {str(row['answer_revision_id']) for row in saved['snapshot_json']['answer_revisions']}
        assert {ref['answer_revision_id'] for ref in refs} <= pinned
    assert old == confirmation['snapshot_digest']
    answer(lab, mid, 'M2V1-11', 'EXPLORE', 11)
    with Session(lab['db']) as session:
        repo = SqlModelM2Repository(session)
        stale = M2SourceProjection(repo).read(UUID(mid), lab['actor'], 12)
    with pytest.raises(WorkflowHeld, match='BDJ_CONFIRMED_M2V1_REQUIRED'):
        project_declared_signals(stale, definitions)
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT snapshot_digest FROM m2_confirmation_snapshots WHERE id=:id'),
                         {'id': UUID(confirmation['id'])}).scalar_one() == old


def test_v101_export_private_synthetic_source(lab):
    """Export only private fixture data for offline request construction."""
    import json
    import os
    from pathlib import Path
    from scripts.register_m2_v1 import register
    from sitewise.project1.contracts import digest
    from sitewise.project1.bdj_discovery_candidate import project_declared_signals
    from sitewise.project1.projection import M2SourceProjection
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sqlmodel import Session
    output = os.environ.get('BDJ_V101_SYNTHETIC_OUTPUT')
    if not output:
        pytest.skip('explicit private synthetic output path required')
    iid = register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')['instrument_id']
    mid = lab['request']('POST', '/assessments', 201, json={'instrument_version_id': iid}).json()['id']
    values = {'M2V1-01':'UNDECIDED', 'M2V1-02':'HYBRID', 'M2V1-03':['COFFEE'],
              'M2V1-04':['STUDENTS','OFFICE_WORKERS'], 'M2V1-05':'STUDENTS', 'M2V1-06':'QUALITY',
              'M2V1-07':'STUDY_WORK', 'M2V1-08':['UNKNOWN'], 'M2V1-09':['CONCEPT_INTEREST'],
              'M2V1-10':'CONCEPT_INTEREST', 'M2V1-11':'UNDECIDED'}
    for rev, (key, value) in enumerate(values.items()): answer(lab, mid, key, value, rev)
    confirmation = confirm(lab, mid, 11)
    with Session(lab['db']) as session:
        repo = SqlModelM2Repository(session)
        from sitewise.services.m2_service import M2Service
        with M2Service(repo).locked_confirmed_source(UUID(mid), lab['actor'],
                confirmation_id=UUID(confirmation['id']), expected_revision=11) as locked:
            assert locked['snapshot_digest'] == confirmation['snapshot_digest']
        definitions = repo.list_items(UUID(iid))
        packet = M2SourceProjection(repo).read(UUID(mid), lab['actor'], 11)
    packet['confirmation'] = {'confirmation_id': str(confirmation['id']),
                              'snapshot_digest': confirmation['snapshot_digest']}
    # Test-only classification; normal server source does not currently supply it.
    packet['data_class'] = 'SYNTHETIC_NONHUMAN'
    packet['purpose'] = 'SYNTHETIC_BDJ_DIAGNOSTIC'
    packet['source_fingerprint'] = digest({k:v for k,v in packet.items() if k != 'source_fingerprint'})
    projected = project_declared_signals(packet, definitions)
    assert projected['source_fingerprint'] == packet['source_fingerprint']
    with lab['db'].connect() as c:
        pinned = c.execute(text('SELECT snapshot_digest,snapshot_json FROM m2_confirmation_snapshots WHERE id=:id'),
                           {'id': UUID(confirmation['id'])}).mappings().one()
        assert pinned['snapshot_digest'] == confirmation['snapshot_digest']
        revisions = {str(x['answer_revision_id']) for x in pinned['snapshot_json']['answer_revisions']}
        assert all(d['answer_revision_id'] in revisions for d in packet['declarations'])
    Path(output).write_text(json.dumps({'packet': packet, 'actor_id': str(lab['actor']),
        'definitions': definitions, 'classification': 'SYNTHETIC_NONHUMAN',
        'dispatch_authorized': False}, indent=2, default=str), encoding='utf-8')


def test_v105_validate_restored_synthetic():
    """Verify the named source after a guarded restore into a new private lab."""
    import json
    import os
    from pathlib import Path
    from sqlalchemy import create_engine, text
    from sqlalchemy.engine import make_url
    from sqlmodel import Session
    from sitewise.project1.contracts import digest
    from sitewise.project1.projection import M2SourceProjection
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.m2_service import M2Service
    source_path = os.environ.get('BDJ_V105_RESTORE_SOURCE')
    if not source_path: pytest.skip('explicit synthetic source evidence required')
    source = json.loads(Path(source_path).read_text(encoding='utf-8'))
    packet = source['packet']; actor = UUID(source['actor_id']); mid = UUID(packet['assessment_id'])
    url = make_url(os.environ['DATABASE_URL'])
    assert (url.host, url.port, url.database) == ('127.0.0.1',55441,'project1_m2_bcb_test')
    db = create_engine(url, hide_parameters=True)
    try:
        with db.connect() as c:
            assert Path(c.execute(text('SHOW data_directory')).scalar_one()).resolve() == (Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'data').resolve()
            assert c.execute(text('SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id'), {'id':mid}).scalar_one() == 11
        with Session(db) as session:
            repo = SqlModelM2Repository(session)
            with M2Service(repo).locked_confirmed_source(mid, actor,
                    confirmation_id=UUID(packet['confirmation']['confirmation_id']), expected_revision=11) as verified:
                assert verified['snapshot_digest'] == packet['confirmation']['snapshot_digest']
            restored = M2SourceProjection(repo).read(mid, actor, 11)
        restored['confirmation'] = packet['confirmation']
        restored['data_class'] = 'SYNTHETIC_NONHUMAN'
        restored['purpose'] = 'SYNTHETIC_BDJ_DIAGNOSTIC'
        restored['source_fingerprint'] = digest({k:v for k,v in restored.items() if k != 'source_fingerprint'})
        assert restored == packet
    finally:
        db.dispose()


def test_v13_real_m2_bcb_qg_owner_review_private(lab, monkeypatch):
    """Actual signed HTTP and persisted BCB; QG policy/model are test-only."""
    from scripts.register_m2_v1 import register
    from sitewise import dependencies as deps
    from sitewise.project1.contracts import digest
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.confirmation_service import ConfirmationService
    from sitewise.services.qg_candidate_service import QgCandidateService
    from sqlmodel import Session

    iid = register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')['instrument_id']
    mid = lab['request']('POST', '/assessments', 201, json={'instrument_version_id': iid}).json()['id']
    values = {'M2V1-01':'UNDECIDED', 'M2V1-02':'HYBRID', 'M2V1-03':['COFFEE'],
        'M2V1-04':['STUDENTS','OFFICE_WORKERS'], 'M2V1-05':'STUDENTS', 'M2V1-06':'QUALITY',
        'M2V1-07':'STUDY_WORK', 'M2V1-08':['NONE'], 'M2V1-09':['CONCEPT_INTEREST'],
        'M2V1-10':'CONCEPT_INTEREST', 'M2V1-11':'EXPLORE'}
    for rev, (key, value) in enumerate(values.items()): answer(lab, mid, key, value, rev)
    confirmation = confirm(lab, mid, 11)
    objective = lab['request']('POST', f"/confirmations/{confirmation['id']}/research-objectives", 201,
        json={'expected_revision':11, 'origin':'ENTREPRENEUR',
              'objective':'SYNTHETIC interest in the proposed cafe'}).json()
    old_resolver = lab['app'].dependency_overrides.pop(deps.get_bcb_bindings_resolver_factory)
    session = Session(lab['db'])
    try:
        response = lab['request']('POST', f'/assessments/{mid}/business-context', (200,201),
            json={'confirmation_id':confirmation['id'],'expected_revision':11,'objective_id':objective['id']})
        context = response.json(); packet = context['packet']; cid = context['context_id']
        contexts = deps.get_persisted_business_context_service(deps.get_bcb_bindings_resolver_factory())
        class Authority:
            measurement_policy_version = 'SYNTHETIC-ONLY'
            def resolve_version(self, source): return {'uncertainty_version':objective['id']}
            def require_current(self, source, task): pass
        raw = {'decision':'DRAFT','question':'Would you consider the proposed cafe?',
            'justification':'Synthetic test candidate','construct_interpretation':'Stated interest',
            'response_options':['Yes','No'],'response_codes':['YES','NO'],'routing':{'YES':'END','NO':'END'},
            'reference_period':'','measurement_description':'Proposed interest',
            'denominator_specification':'YES and NO respondents','limitations':'Synthetic proposal; no observations.',
            'unresolved_assumptions':[],'missing_business_facts':[], 'used_confirmed_facts':[objective['id']],
            'fixed_measurement':{'contract_version':'P1-QG-FIXED-OPTION-1.0','response_format':'BINARY_CHOICE',
                'construct':'Interest','population':'Synthetic test population',
                'options':[{'code':'YES','label':'Yes','order':0},{'code':'NO','label':'No','order':1}],
                'min_selections':1,'max_selections':1,'interpretation':'Proposed interest',
                'limitations':'Synthetic proposal; no observations.'}}
        calls = []
        def runner(*args): calls.append('QG'); return raw
        def policy(assessment, context_id, actor, selected, source):
            return {'policy_version':'SYNTHETIC-ONLY','assessment_id':str(assessment),
                'context_id':str(context_id),'owner_id':str(actor.user_id),'objective_approved':True,
                'authority_reference':'ISOLATED-TEST-ONLY','objective_version':objective['id'],
                'objective_id':objective['id'],'assessment_revision':11,'context_hash':source['packet_hash'],
                'approved_population':'Synthetic test population','supported_formats':['BINARY_CHOICE'],
                'period_required':False}
        service = QgCandidateService(contexts=contexts, confirmation=ConfirmationService(SqlModelM2Repository(session)),
            authority=Authority(), runner=runner, enabled=True, fixed_policy_resolver=policy)
        service._reserve = lambda _id: lambda _attempt: None
        lab['app'].dependency_overrides[deps.get_qg_candidate_service] = lambda: service
        generated = lab['request']('POST', f"/research-objectives/{objective['id']}/qg-candidate", 200,
            json={'expected_revision':11,'context_id':cid}).json()
        assert generated['status'] == 'VALIDATED_OUTPUT' and calls == ['QG']
        version = generated['version']
        saved = lab['request']('GET', f'/research-questions/{version}').json()
        assert saved['objective_id'] == objective['id'] and saved['source_fingerprint'] == packet['packet_hash']
        assert [(x['code'],x['label']) for x in saved['options']] == [('YES','Yes'),('NO','No')]
        raw['question'] = 'Would you visit the proposed synthetic cafe?'
        pending = lab['request']('POST', f"/research-objectives/{objective['id']}/qg-candidate", 200,
            json={'expected_revision':11,'context_id':cid}).json()['version']
        raw['question'] = 'Would you recommend the proposed synthetic cafe?'
        stale_candidate = lab['request']('POST', f"/research-objectives/{objective['id']}/qg-candidate", 200,
            json={'expected_revision':11,'context_id':cid}).json()['version']
        with lab['db'].connect() as c:
            diagnostic = dict(c.execute(text("SELECT "
                "has_table_privilege('p1_m2_runtime','public.m2_candidate_owner_reviews','INSERT') AS review_insert, "
                "has_table_privilege('p1_m2_runtime','public.m2_candidate_review_assignments','SELECT') AS assignment_select, "
                "(SELECT count(*) FROM m2_candidate_review_assignments WHERE candidate_id=:id AND reviewer_id=:actor) AS owner_assignments"),
                {'id':UUID(version),'actor':lab['actor']}).mappings().one())
        from pathlib import Path
        (Path(os.environ['M2_BCB_EVIDENCE'])/'v13_review_diagnostic.json').write_text(json.dumps(diagnostic),encoding='utf-8')
        restricted = None
        if os.environ.get('M2_PROTECTED_REVIEW_TEST') == '1':
            import secrets
            from pydantic import SecretStr
            from sqlalchemy import create_engine
            from sqlalchemy.engine import make_url
            from sitewise.core.config import settings
            from sitewise.db import m2_session
            # QG's shared test session has already committed the candidate;
            # release its read transaction before private policy DDL.
            session.rollback()
            key, password = secrets.token_bytes(32), secrets.token_hex(24)
            with lab['db'].begin() as c:
                c.execute(text("ALTER ROLE p1_m2_runtime PASSWORD '"+password+"'"))
            migration = Path(__file__).resolve().parents[2] / 'migrations/m2/20261121_01_protected_identity_private_rehearsal.sql'
            raw_conn = lab['db'].raw_connection()
            try:
                cur = raw_conn.cursor()
                cur.execute("SET project1.identity_test_receipt='PRIVATE-SYNTHETIC-ONLY'")
                cur.execute(migration.read_text(encoding='utf-8'))
                raw_conn.commit()
            finally:
                raw_conn.close()
            with lab['db'].begin() as c:
                c.execute(text('INSERT INTO project1_identity.private_key VALUES (1,:key)'), {'key':key})
                c.exec_driver_sql((Path(__file__).parent/'protected_review_private_policies.sql').read_text(encoding='utf-8'))
                c.exec_driver_sql((Path(__file__).parent/'protected_review_function_private.sql').read_text(encoding='utf-8'))
            restricted = create_engine(make_url(os.environ['DATABASE_URL']).set(
                username='p1_m2_runtime',password=password), hide_parameters=True)
            monkeypatch.setattr(m2_session, 'get_m2_engine', lambda: restricted)
            monkeypatch.setattr(m2_session, 'get_bcb_engine', lambda: restricted)
            monkeypatch.setattr(settings, 'm2_protected_identity_enabled', True)
            monkeypatch.setattr(settings, 'm2_identity_assertion_key', SecretStr(key.hex()))
            lab['request']('GET', f'/assessments/{mid}/business-contexts/{cid}', 200)
            # Replace the QG double's admin-backed Session with a per-request
            # real authenticated M2 session. Provider/policy remain explicit
            # test doubles; readback authorization and SQL use the runtime role.
            from fastapi import Depends
            def protected_qg(m2db=Depends(deps.get_m2_scoped_db)):
                protected = QgCandidateService(
                    contexts=deps.get_persisted_business_context_service(deps.get_bcb_bindings_resolver_factory()),
                    confirmation=ConfirmationService(SqlModelM2Repository(m2db)),
                    authority=Authority(), runner=runner, enabled=True, fixed_policy_resolver=policy)
                protected._reserve = lambda _id: lambda _attempt: None
                return protected
            lab['app'].dependency_overrides[deps.get_qg_candidate_service] = protected_qg
            lab['request']('GET', f'/research-questions/{version}', 200)
            lab['request']('GET', f'/research-questions/{version}', 404, uid=lab['other'])
            # Check the real protected review connection's database identity
            # and verify that an editable legacy actor GUC grants no M2 row.
            with restricted.begin() as c:
                assert c.execute(text('SELECT current_user, session_user')).one() == ('p1_m2_runtime','p1_m2_runtime')
                assert c.scalar(text("SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname=current_user")) is False
                assert not c.scalar(text("SELECT has_table_privilege(current_user,'project1_identity.private_key','SELECT')"))
                assert not c.scalar(text("SELECT has_table_privilege(current_user,'public.m2_candidate_owner_reviews','INSERT')"))
                assert not c.scalar(text("SELECT has_table_privilege(current_user,'public.m2_candidate_review_assignments','INSERT')"))
                c.execute(text("SELECT set_config('project1.actor_id',:actor,true)"), {'actor':str(lab['actor'])})
                assert c.scalar(text('SELECT count(*) FROM public.m2_assessments WHERE id=:id'),
                                {'id':UUID(mid)}) == 0
            # An explicit test-only assigned reviewer is NOT the assessment owner.
            # The current owner-only policies must not be mistaken for a working
            # assigned-reviewer authorization path. 404 is recorded as an
            # integration blocker, not the intended product behavior.
            with lab['db'].begin() as c:
                c.execute(text('INSERT INTO public.m2_candidate_review_assignments '
                    '(candidate_id,reviewer_id,authority_reference) VALUES (:candidate,:reviewer,:authority)'),
                    {'candidate':UUID(pending),'reviewer':lab['staff'],
                     'authority':'PRIVATE SYNTHETIC ASSIGNED REVIEWER'})
            lab['request']('POST', f'/research-questions/{pending}/owner-review', 404,
                uid=lab['other'], json={'decision':'APPROVE_FOR_REVIEW','rationale':'Not assigned'})
            with lab['db'].connect() as c:
                projection_before = c.scalar(text('SELECT max(projection_sequence) FROM assessment_workflow_projection WHERE assessment_id=:id'),
                                             {'id':UUID(mid)})
            denied_review = lab['request']('POST', f'/research-questions/{pending}/owner-review', 201,
                uid=lab['staff'], json={'decision':'APPROVE_FOR_REVIEW',
                                        'rationale':'Private independent reviewer test'})
            assert 'snapshot_json' not in denied_review.text
            lab['request']('POST', f'/research-questions/{pending}/owner-review', 404,
                uid=lab['staff'], json={'decision':'REJECT','rationale':'Duplicate reviewer decision'})
            with lab['db'].connect() as c:
                assert c.scalar(text('SELECT count(*) FROM m2_candidate_owner_reviews '
                    'WHERE candidate_id=:id AND reviewer_id=:reviewer'),
                    {'id':UUID(pending),'reviewer':lab['staff']}) == 1
                projection_after = c.execute(text('SELECT projection_sequence, projection_data FROM assessment_workflow_projection '
                    'WHERE assessment_id=:id ORDER BY projection_sequence DESC LIMIT 1'), {'id':UUID(mid)}).mappings().one()
                assert projection_after['projection_sequence'] > projection_before
                assert any(str(candidate['id']) == pending and candidate['owner_decision'] == 'APPROVE_FOR_REVIEW'
                           for candidate in projection_after['projection_data']['candidates'])
            from sitewise.db.m2_identity_assertion import mint_m2_assertion
            with restricted.begin() as c:
                c.execute(text("SELECT set_config('project1.identity_assertion',:v,true)"),
                          {'v':mint_m2_assertion(lab['staff'],key.hex())})
                assert c.scalar(text('SELECT count(*) FROM public.m2_confirmation_snapshots WHERE id=:id'),
                                {'id':UUID(confirmation['id'])}) == 0
            (Path(os.environ['M2_BCB_EVIDENCE'])/'restricted_reviewer_blocker.json').write_text(
                json.dumps({'actual_http':denied_review.status_code, 'expected_product_http':201,
                    'status':'PASS_ASSIGNED_REVIEWER_RESTRICTED_FUNCTION',
                    'scope':'private database and signed synthetic reviewer only'}, indent=2), encoding='utf-8')
        from sqlalchemy import event
        from sqlalchemy.engine import Engine
        sql_errors = []
        def capture_error(ctx):
            sql_errors.append({'sqlstate': getattr(ctx.original_exception, 'pgcode', None),
                               'message': str(ctx.original_exception), 'statement': ctx.statement})
        event.listen(Engine, 'handle_error', capture_error)
        try:
            if restricted is not None:
                # Deliberate private trigger failure after owner self-assignment:
                # the transaction must roll the assignment back as well.
                with lab['db'].begin() as c:
                    c.exec_driver_sql("CREATE FUNCTION public.private_review_failure() RETURNS trigger "
                        "LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'SYNTHETIC REVIEW FAILURE'; END $$")
                    c.exec_driver_sql('CREATE TRIGGER private_review_failure BEFORE INSERT ON public.m2_candidate_owner_reviews '
                                      'FOR EACH ROW EXECUTE FUNCTION public.private_review_failure()')
                lab['request']('POST', f'/research-questions/{version}/owner-review', 503,
                    json={'decision':'APPROVE_FOR_REVIEW','rationale':'Synthetic rollback verification'})
                with lab['db'].begin() as c:
                    assert c.scalar(text('SELECT count(*) FROM m2_candidate_review_assignments '
                        'WHERE candidate_id=:id AND reviewer_id=:owner'),
                        {'id':UUID(version),'owner':lab['actor']}) == 0
                    c.exec_driver_sql('DROP TRIGGER private_review_failure ON public.m2_candidate_owner_reviews')
                    c.exec_driver_sql('DROP FUNCTION public.private_review_failure()')
            # No foreign owner can manufacture an assignment or submit a review.
            lab['request']('POST', f'/research-questions/{version}/owner-review', 404,
                uid=lab['other'], json={'decision':'APPROVE_FOR_REVIEW','rationale':'Unrelated actor'})
            lab['request']('POST', f'/research-questions/{version}/owner-review', 201,
                json={'decision':'APPROVE_FOR_REVIEW','rationale':'Synthetic test owner review'})
            lab['request']('POST', f'/research-questions/{version}/owner-review', 404,
                json={'decision':'APPROVE_FOR_REVIEW','rationale':'Duplicate review'})
        finally:
            event.remove(Engine, 'handle_error', capture_error)
            (Path(os.environ['M2_BCB_EVIDENCE'])/'v13_review_sql_errors.json').write_text(
                json.dumps(sql_errors, indent=2), encoding='utf-8')
        reread = lab['request']('GET', f'/research-questions/{version}').json()
        assert reread['decision'] == 'APPROVE_FOR_REVIEW' and reread['fielding_authorized'] is False
        history = lab['request']('GET', f'/research-objectives/{objective["id"]}/research-questions',
                                 params={'expected_revision':11}).json()
        assert any(str(item['version']) == version for item in history['versions'])
        with lab['db'].connect() as c:
            row = c.execute(text('SELECT objective_id,options,source_receipt FROM m2_review_question_versions WHERE id=:id'),
                            {'id':UUID(version)}).mappings().one()
            assert str(row['objective_id']) == objective['id'] and packet['packet_hash'] in row['source_receipt']
            assert c.execute(text('SELECT count(*) FROM m2_candidate_owner_reviews WHERE candidate_id=:id'),
                             {'id':UUID(version)}).scalar_one() == 1
        assert digest({k:v for k,v in packet.items() if k != 'packet_hash'}) == packet['packet_hash']
        # An answer revision invalidates the old confirmation for review, but
        # does not erase the historical decision.
        answer(lab, mid, 'M2V1-02', 'DINE_IN', 11)
        # A separate, unreviewed candidate is needed for the stale-source test.
        lab['request']('POST', f'/research-questions/{stale_candidate}/owner-review', 404,
            json={'decision':'REJECT','rationale':'Stale source'})
        with lab['db'].connect() as c:
            assert c.scalar(text('SELECT count(*) FROM m2_candidate_owner_reviews WHERE candidate_id=:id'),
                            {'id':UUID(version)}) == 1
            assert c.scalar(text('SELECT count(*) FROM m2_candidate_owner_reviews WHERE candidate_id=:id'),
                            {'id':UUID(stale_candidate)}) == 0
    finally:
        lab['app'].dependency_overrides.pop(deps.get_qg_candidate_service, None)
        lab['app'].dependency_overrides[deps.get_bcb_bindings_resolver_factory] = old_resolver
        session.close()
        if 'restricted' in locals() and restricted is not None:
            restricted.dispose()


def test_new_snapshot_is_accepted_by_existing_deterministic_BCB_consumer(lab):
    from test_postgres_api import bind, build
    mid = complete(lab)
    receipt = confirm(lab, mid)
    # Existing explicit fixture-only scope/purpose/validity bindings. No
    # production validity policy, finding approval or downstream permission.
    bind(lab, mid, receipt['id'])
    context = build(lab, mid, receipt['id']).json()
    assert context['assessment_id'] == mid
    assert context['confirmation_id'] == receipt['id']
    assert context['assessment_revision'] == 3
    assert not context['qg_execution_authorized']


def test_review_is_required_and_concurrent_confirmation_creates_one_snapshot(lab):
    mid = complete(lab)
    result = lab['request']('POST', f'/assessments/{mid}/confirm', 409,
        json={'expected_revision':3}).json()
    assert result['detail']['code'] == 'M2_DECLARATION_REVIEW_REQUIRED'
    lab['request']('POST', f'/assessments/{mid}/review', json={'expected_revision':3})
    def submit(_):
        return lab['request']('POST', f'/assessments/{mid}/confirm', (200,409),
            json={'expected_revision':3}).status_code
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(submit, range(2))) == [200,409]
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT count(*) FROM m2_confirmation_snapshots WHERE assessment_id=:id'), {'id': UUID(mid)}) == 1


def test_new_provenance_refuses_tampered_review_items_and_unknown_version(lab):
    from sitewise.domain.m2_provenance import pins_match
    mid = complete(lab)
    receipt = confirm(lab, mid)
    snapshot = receipt['snapshot_json']
    with lab['db'].connect() as c:
        review = dict(c.execute(text('SELECT * FROM m2_review_events WHERE id=:id'), {'id':UUID(snapshot['review_event_id'])}).mappings().one())
        items = [dict(r) for r in c.execute(text('SELECT * FROM m2_item_versions WHERE instrument_id=:id'), {'id':lab['iid']}).mappings()]
    assert pins_match(snapshot, None, review, [], items)
    bad_review = {**review, 'actor_user_id':lab['other']}
    assert not pins_match(snapshot, None, bad_review, [], items)
    bad_items = deepcopy(items)
    bad_items[0]['question_text'] = 'tampered'
    assert not pins_match(snapshot, None, review, [], bad_items)
    for extra in ({'snapshot_contract_version':'UNKNOWN'}, {'bdj_evaluation_id':str(uuid4())}):
        assert not pins_match({**snapshot, **extra}, None, review, [], items)


def test_confirmation_storage_failure_rolls_back_state(lab, monkeypatch):
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    mid = complete(lab)
    lab['request']('POST', f'/assessments/{mid}/review', json={'expected_revision':3})
    def fail(*args, **kwargs):
        raise RuntimeError('SYNTHETIC storage failure')
    monkeypatch.setattr(SqlModelM2Repository, 'create_confirmation', fail)
    lab['request']('POST', f'/assessments/{mid}/confirm', 500,
        json={'expected_revision':3})
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT confirmed_revision FROM m2_assessments WHERE id=:id'), {'id':UUID(mid)}) is None
        assert c.scalar(text('SELECT count(*) FROM m2_confirmation_snapshots WHERE assessment_id=:id'), {'id':UUID(mid)}) == 0


def test_K_actual_assessment_browser(lab):
    import os
    import pytest
    if os.environ.get('M2_BROWSER_DEMO') != '1':
        pytest.skip('Explicit optional browser acceptance against this disposable database only.')
    if os.environ.get('M2_OBJECTIVE_BROWSER') == '1':
        from objective_browser_lab import exercise
    else:
        from confirmation_browser_lab import exercise
    exercise(lab)
