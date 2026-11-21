"""Actual FastAPI creation/link/discard concurrency against an existing private lab.

Two synthetic verified JWT identities and a synthetic catalogue row; no live data.
JWKS discovery is locally supplied, while signature/role/ownership checks are real.
"""
import json, os, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL
from cryptography.hazmat.primitives.asymmetric import ec
import jwt

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'backend/src'))
OUT=ROOT/'artifacts/cp12_20261118'
lab=json.loads((ROOT/'artifacts/cp11_20261118/private_cluster.json').read_text())
db=json.loads((OUT/'postgres_results.json').read_text())['databases']
assert lab['port']==55447 and lab['host']=='127.0.0.1' and all(x.startswith('cp12_') for x in db)
def url(name,role='postgres'):
    return URL.create('postgresql+psycopg2',username=role,password=lab['password'] if role=='postgres' else lab['runtime_password'],host='127.0.0.1',port=55447,database=name)
for k,v in {'DATABASE_URL':url(db[0]).render_as_string(hide_password=False),'ANALYTICS_DATABASE_URL':url(db[0]).render_as_string(hide_password=False),'M2_DATABASE_URL':url(db[1],'p1_m2_runtime').render_as_string(hide_password=False),'M2_EXPECTED_DATABASE':db[1],'M2_UPSTREAM_ENABLED':'true','DB_AUTO_CREATE':'false','TOKENHARBOR_ENABLED':'false','TOKENHARBOR_API_KEY':'','PROJECT1_WORKFLOW_ENABLED':'false','SUPABASE_URL':'https://cp12.example.test','SUPABASE_JWKS_URL':'https://cp12.example.test/auth/v1/.well-known/jwks.json'}.items():os.environ[k]=v
from sitewise.core.config import settings
from sitewise.core.security import JWKSClient
key=ec.generate_private_key(ec.SECP256R1()); jwk=jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(),as_dict=True);jwk.update(kid='CP12-CREATION',alg='ES256',use='sig')
def fetch(self):
    self._keys={'CP12-CREATION':jwk}; self._fetched_at=time.monotonic();return self._keys
JWKSClient._fetch=fetch
from sitewise.main import app
from fastapi.testclient import TestClient

market=create_engine(url(db[0]),hide_parameters=True);dss=create_engine(url(db[1]),hide_parameters=True)
def execute(e,q,**p):
    with e.begin() as c:
        r=c.execute(text(q),p);return r.scalar() if r.returns_rows else None
people=[str(uuid4()),str(uuid4())]; property_id='CP12-API-'+uuid4().hex[:12];inst=uuid4();item=uuid4()
for uid in people:
    for e in (market,dss):execute(e,"INSERT INTO public.users(user_id,email,role,account_status,email_verified,created_at,updated_at) VALUES(:id,:email,'entrepreneur','active',true,now(),now())",id=uid,email=uid+'@example.test')
execute(market,"INSERT INTO sitewise_app.properties(id,title,address,city,state,rental_rm,size_sqft,latitude,longitude,property_type,dataset_validation,source_workbook,source_sheet,source_row,source_data) VALUES(:id,'Synthetic test property','Synthetic','Test','Test',100,100,1,1,'Retail','synthetic','fixture','fixture',1,'{}')",id=property_id)
for uid in people:execute(market,'INSERT INTO public.favorite_property(favorite_id,user_id,property_id,created_at) VALUES(:id,:owner,:property,now())',id=str(uuid4()),owner=uid,property=property_id)
execute(dss,"INSERT INTO m2_instrument_versions(id,code,version_tag,approval_state,schema_digest) VALUES(:id,'M2V1','CP12-SYNTHETIC-CREATION','AUTHORIZED',:digest)",id=inst,digest='a'*64)
execute(dss,"INSERT INTO m2_item_versions(id,instrument_id,item_key,question_text,requiredness,answer_kind,option_values,allowed_states,lifecycle,sort_order) VALUES(:id,:inst,'CP12-API-Q','Synthetic question','REQUIRED','TEXT','{}','[\"ANSWERED\"]','ACTIVE',1)",id=item,inst=inst)
def auth(uid):
    t=jwt.encode({'sub':uid,'email':uid+'@example.test','email_verified':True,'iss':settings.supabase_issuer,'aud':'authenticated','iat':int(time.time()),'exp':int(time.time())+300},key,algorithm='ES256',headers={'kid':'CP12-CREATION'})
    return {'Authorization':'Bearer '+t}
results=[]
client=TestClient(app,raise_server_exceptions=False)
def req(label,method,path,uid,payload=None):
    response=client.request(method,path,headers=auth(uid),json=payload)
    entry={'label':label,'method':method,'path':path,'status':response.status_code,'body':response.json() if response.content else None}
    results.append(entry);(OUT/'two_user_creation_http.json').write_text(json.dumps(results,indent=2)+'\n')
    return response
def create(uid):return req('concurrent_create_'+uid,'POST','/api/v1/assessments/',uid,{'property_id':property_id})
with ThreadPoolExecutor(max_workers=2) as pool:responses=list(pool.map(create,people))
assert all(x.status_code==200 and x.json()['created'] for x in responses),[(x.status_code,x.text) for x in responses]
ids=[x.json()['assessment']['assessment_id'] for x in responses];assert ids[0]!=ids[1]
mids=[]
for uid,aid in zip(people,ids):
    response=req('initialize_m2','POST','/api/v1/m2/assessments/by-marketplace/'+aid+'/link',uid)
    assert response.status_code==200,(response.status_code,response.text)
    mids.append(response.json()['m2_assessment_id'])
assert mids[0]!=mids[1]
for uid,mid in zip(people,mids):
    response=req('save_answer','PUT','/api/v1/m2/assessments/'+mid+'/answers/CP12-API-Q',uid,{'expected_revision':0,'answer_state':'ANSWERED','value':'SYNTHETIC ANSWER'})
    assert response.status_code==200,(response.status_code,response.text)
for e in (market,dss):execute(e,"INSERT INTO cp12.target_reviews VALUES(:id,:owner,'SYNTHETIC-RETENTION','SYNTHETIC-EXTERNAL')",id=ids[0],owner=people[0])
def digest(e,q,**p):return execute(e,q,**p)
before={'assessment':digest(market,'SELECT md5(to_jsonb(r)::text) FROM assessment r WHERE assessment_id=:id',id=ids[1]),'m2':digest(dss,'SELECT md5(to_jsonb(r)::text) FROM m2_assessments r WHERE id=:id',id=mids[1]),'answer':digest(dss,"SELECT md5(string_agg(to_jsonb(r)::text,',' ORDER BY id)) FROM m2_answer_revisions r WHERE assessment_id=:id",id=mids[1]),'link':digest(dss,'SELECT md5(to_jsonb(r)::text) FROM m2_assessment_links r WHERE m2_assessment_id=:id',id=mids[1])}
with ThreadPoolExecutor(max_workers=2) as pool:
    a=pool.submit(req,'discard_a','DELETE','/api/v1/assessments/'+ids[0],people[0]);b=pool.submit(create,people[1]);a=a.result();b=b.result()
assert a.status_code==204,(a.status_code,a.text)
assert b.status_code==200 and not b.json()['created'] and b.json()['assessment']['assessment_id']==ids[1],(b.status_code,b.text)
after={'assessment':digest(market,'SELECT md5(to_jsonb(r)::text) FROM assessment r WHERE assessment_id=:id',id=ids[1]),'m2':digest(dss,'SELECT md5(to_jsonb(r)::text) FROM m2_assessments r WHERE id=:id',id=mids[1]),'answer':digest(dss,"SELECT md5(string_agg(to_jsonb(r)::text,',' ORDER BY id)) FROM m2_answer_revisions r WHERE assessment_id=:id",id=mids[1]),'link':digest(dss,'SELECT md5(to_jsonb(r)::text) FROM m2_assessment_links r WHERE m2_assessment_id=:id',id=mids[1])}
assert before==after
assert execute(market,'SELECT count(*) FROM assessment WHERE assessment_id=:id',id=ids[0])==0
assert execute(dss,'SELECT count(*) FROM m2_assessments WHERE id=:id',id=mids[0])==0
(OUT/'two_user_creation_results.json').write_text(json.dumps({'status':'PASS','scope':'ISOLATED_SYNTHETIC','property':property_id,'owners':people,'assessment_ids':ids,'m2_ids':mids,'owner_b_before':before,'owner_b_after':after,'simultaneous':'discard A / create-or-resume B'},indent=2)+'\n')
print('PASS: two signed-in owners created and linked separate assessments; concurrent discard A / resume B preserved B.')
