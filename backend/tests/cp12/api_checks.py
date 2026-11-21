"""Actual ASGI app/routes/auth verification against disposable CP12 databases.

Only JWKS discovery is replaced with an ephemeral test public key. JWT signature,
profile, role, ownership, service and SQL paths are the real application code.
No lifespan/startup tasks run. This is G2 evidence, not browser/live evidence.
"""
import json
import os
from pathlib import Path
import time
from uuid import UUID

import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient
from sqlalchemy.engine import make_url

assert make_url(os.environ['DATABASE_URL']).port == 55447
assert make_url(os.environ['DATABASE_URL']).database.startswith('cp12_')
from sitewise.core.config import settings
from sitewise.core.security import JWKSClient

key = ec.generate_private_key(ec.SECP256R1())
jwk = jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(), as_dict=True)
jwk.update(kid='CP12-EPHEMERAL', alg='ES256', use='sig')
def fetch(self):
    self._keys = {'CP12-EPHEMERAL': jwk}
    self._fetched_at = time.monotonic()
    return self._keys
JWKSClient._fetch = fetch

from sitewise.main import app
from sitewise.db.session import engine
from sqlalchemy import text
from sitewise.services.assessment_discard_service import AssessmentDiscardService

data = json.loads(Path(os.environ['CP12_API_CASES']).read_text())
out = Path(os.environ['CP12_API_OUTPUT'])
client = TestClient(app, raise_server_exceptions=False)
exchanges=[]

def token(uid):
    return jwt.encode({'sub':uid, 'email':uid+'@example.test', 'email_verified':True,
                       'iss':settings.supabase_issuer, 'aud':'authenticated',
                       'iat':int(time.time()), 'exp':int(time.time())+300},key,algorithm='ES256',headers={'kid':'CP12-EPHEMERAL'})

def call(name, aid, uid, expected):
    headers={} if uid is None else {'Authorization':'Bearer '+token(uid)}
    r=client.delete('/api/v1/assessments/'+aid,headers=headers)
    exchanges.append({'test':name,'method':'DELETE','path':'/api/v1/assessments/'+aid,
                      'transport':'ASGI_TESTCLIENT_NOT_LIVE_BROWSER','status':r.status_code,
                      'response':r.json() if r.content else None,'expected':expected,
                      'pass':r.status_code==expected})
    out.write_text(json.dumps(exchanges,indent=2)+'\n')
    assert r.status_code==expected, (name,r.status_code,r.text)

def cross(name, method, path, who, body=None):
    response=client.request(method,path,headers={'Authorization':'Bearer '+token(who)},json=body)
    ok=response.status_code in (403,404)
    exchanges.append({'test':name,'method':method,'path':path,'status':response.status_code,
                      'response':response.json() if response.content else None,'pass':ok,
                      'transport':'ASGI_TESTCLIENT_NOT_LIVE_BROWSER'})
    out.write_text(json.dumps(exchanges,indent=2)+'\n')
    assert ok,(name,response.status_code,response.text)

def own(name,path,who):
    response=client.get(path,headers={'Authorization':'Bearer '+token(who)})
    exchanges.append({'test':name,'method':'GET','path':path,'status':response.status_code,
                      'transport':'ASGI_TESTCLIENT_NOT_LIVE_BROWSER','pass':response.status_code==200})
    out.write_text(json.dumps(exchanges,indent=2)+'\n')
    assert response.status_code==200,(name,response.status_code,response.text)

uid=data['owner']; aid=data['eligible']
for label,who,pair in (('a',uid,data['pair_a']),('b',data['other'],data['pair_b'])):
    own(label+'_own_assessment','/api/v1/assessments/'+pair[0],who)
    own(label+'_own_m2','/api/v1/m2/assessments/'+pair[1],who)
for label,who,pair in (('a_to_b',uid,data['pair_b']),('b_to_a',data['other'],data['pair_a'])):
    cross(label+'_assessment_read','GET','/api/v1/assessments/'+pair[0],who)
    cross(label+'_assessment_edit','PATCH','/api/v1/assessments/'+pair[0],who,{'requirements':{}})
    cross(label+'_assessment_delete','DELETE','/api/v1/assessments/'+pair[0],who)
    cross(label+'_m2_read','GET','/api/v1/m2/assessments/'+pair[1],who)
    cross(label+'_m2_edit','PUT','/api/v1/m2/assessments/'+pair[1]+'/answers/CP12-Q',who,{'expected_revision':1,'answer_state':'ANSWERED','value':'TEST'})
call('pair_a_delete_preserves_b',data['pair_a'][0],uid,204)
call('missing_authentication',aid,None,401)
call('different_authenticated_owner',aid,data['other'],403)
call('protected_evaluation',data['protected'],uid,409)
call('eligible_discard',aid,uid,204)
call('repeat_same_discard',aid,uid,204)
# Failure after Dss commit is injected in the coordinator transport only, not
# the SQL adapters; retry uses the original endpoint and durable journal.
original=AssessmentDiscardService._call
def crash(self, db, function, actor, **params):
    if 'cp12.finish' in function: raise RuntimeError('SYNTHETIC_INTERRUPTION')
    return original(self,db,function,actor,**params)
AssessmentDiscardService._call=crash
try:
    call('interrupt_after_dss_commit',data['failure'],uid,500)
finally:
    AssessmentDiscardService._call=original
call('recover_through_same_endpoint',data['failure'],uid,204)
with engine.connect() as c:
    assert c.execute(text('SELECT count(*) FROM assessment WHERE assessment_id=:id'),{'id':data['sentinel']}).scalar_one()==1
print(json.dumps({'checks':len(exchanges),'passed':sum(x['pass'] for x in exchanges)}))
