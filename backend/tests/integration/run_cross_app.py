"""Private FastAPI HTTP -> shared Dart DTO acceptance boundary tests.

Synthetic signed identities and memory-only SQLite; normal lifespan is disabled.
This verifies the held CA-01/CA-02 boundary, not successful research pipelines.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
from uuid import UUID


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--worker',action='store_true')
    parser.add_argument('--mobile',action='store_true',help='Exercise the actual Flutter MobileApiClient')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    if not args.worker:
        env=os.environ.copy()
        fake='postgresql+psycopg2://disabled:disabled@127.0.0.1:1/project1_http_lab'
        env.update(DATABASE_URL=fake,ANALYTICS_DATABASE_URL=fake,
            M2_UPSTREAM_ENABLED='false',PROJECT1_CP07_ENABLED='false',PROJECT1_WORKFLOW_ENABLED='false',
            PYTHONPATH=str(root/'src'),PYTHONIOENCODING='utf-8',P1_HTTP_LAB='1')
        args.output.mkdir(parents=True,exist_ok=True)
        command=[sys.executable,'-B',str(Path(__file__).resolve()),
            '--worker','--output',str(args.output.resolve())]
        if args.mobile: command.append('--mobile')
        return subprocess.call(command,cwd=root,env=env)
    if os.environ.get('P1_HTTP_LAB')!='1': raise SystemExit('Private runner required.')
    import psycopg2
    def deny(*a,**kw): raise RuntimeError('Non-fixture connection refused.')
    psycopg2.connect=deny
    from sqlalchemy.engine import Engine
    original=Engine.connect
    def connect(engine,*a,**kw):
        if engine.url.get_backend_name()!='sqlite' or engine.url.database not in (None,'',':memory:'):
            return deny()
        return original(engine,*a,**kw)
    Engine.connect=connect
    from sqlalchemy import create_engine
    from sqlalchemy.pool import StaticPool
    from sqlmodel import Session
    from sitewise.main import app
    from sitewise import dependencies as deps
    from sitewise.core.security import SupabaseJWTVerifier
    from sitewise.db.session import get_db
    from sitewise.db.analytics_session import get_analytics_db
    from sitewise.db.models.user import User
    from sitewise.db.models.assessment import Assessment
    import jwt
    import uvicorn
    from cryptography.hazmat.primitives.asymmetric import ec

    db=create_engine('sqlite://',poolclass=StaticPool,connect_args={'check_same_thread':False})
    User.__table__.create(db)
    Assessment.__table__.create(db)
    actor,other,aid=[UUID('00000000-0000-4000-8000-'+f'{i:012d}') for i in (1,2,3)]
    with Session(db) as session:
        for uid in [actor,other]:
            session.add(User(user_id=uid,email=f'{uid}@test.invalid',role='entrepreneur',
                account_status='active',email_verified=True))
        session.add(Assessment(assessment_id=aid,user_id=actor,property_id='SYNTHETIC-HTTP-PROPERTY'))
        session.commit()
    def memory_session():
        with Session(db) as session: yield session
    app.dependency_overrides[get_db]=memory_session
    app.dependency_overrides[get_analytics_db]=memory_session
    key=ec.generate_private_key(ec.SECP256R1())
    public=jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(),as_dict=True)
    public.update(kid='p1-http-lab',use='sig',alg='ES256')
    verifier=SupabaseJWTVerifier(jwks_url='https://test.invalid/jwks',issuer='https://test.invalid/auth/v1',audiences=['authenticated'])
    verifier.jwks._keys={'p1-http-lab':public}
    verifier.jwks._fetched_at=time.monotonic()
    deps._verifier=verifier
    def token(uid):
        now=int(time.time())
        return jwt.encode({'sub':str(uid),'email':f'{uid}@test.invalid','email_verified':True,
            'iss':'https://test.invalid/auth/v1','aud':'authenticated','iat':now,'exp':now+600},
            key,algorithm='ES256',headers={'kid':'p1-http-lab'})
    bound=socket.socket()
    bound.bind(('127.0.0.1',0))
    bound.listen(128)
    port=bound.getsockname()[1]
    server=uvicorn.Server(uvicorn.Config(app,lifespan='off',log_level='error',access_log=False))
    thread=threading.Thread(target=server.run,kwargs={'sockets':[bound]},daemon=True)
    thread.start()
    try:
        deadline=time.monotonic()+15
        while not server.started and thread.is_alive() and time.monotonic()<deadline: time.sleep(.02)
        if not server.started: raise RuntimeError('Private HTTP listener did not start.')
        env=os.environ.copy()
        env.update(P1_HTTP_BASE=f'http://127.0.0.1:{port}',P1_HTTP_TOKEN=token(actor),
            P1_HTTP_OTHER_TOKEN=token(other),P1_HTTP_ASSESSMENT=str(aid))
        if args.mobile:
            command=[str(root.parent/'.fvm/flutter_sdk/bin/flutter.bat'),'test','--no-pub',
                f'--dart-define=API_BASE_URL=http://127.0.0.1:{port}',
                '--dart-define=API_HOST_MODE=adb-reverse',
                'test/auth/mobile_api_client_test.dart','--reporter','expanded']
            directory=root.parent/'fyp_mobile_app'
            prefix='mobile_api_http'
        else:
            command=['dart.bat','test','test/project1_http_contract_test.dart','--reporter','expanded']
            directory=root.parent/'shared_logic'
            prefix='cross_app_http'
        result=subprocess.run(command,cwd=directory,env=env,capture_output=True,text=True,encoding='utf-8',timeout=180)
        (args.output/(prefix+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
        (args.output/(prefix+'_result.json')).write_text(json.dumps({
            'exit_code':result.returncode,'database':'private memory-only SQLite',
            'lifespan':'off','authentication':'real verifier, synthetic signed key',
            'CA-01':'HELD_BOUNDARY_TESTED; full journey BLOCKED',
            'CA-02':'HELD_BOUNDARY_TESTED; full journey BLOCKED',
            'live_database_access':False,'dependency_overrides':'get_db and get_analytics_db -> private SQLite',
        },indent=2),encoding='utf-8')
        print(result.stdout+result.stderr)
        return result.returncode
    finally:
        server.should_exit=True
        thread.join(timeout=15)
        bound.close()
        app.dependency_overrides.clear()
        db.dispose()


if __name__=='__main__': raise SystemExit(main())
