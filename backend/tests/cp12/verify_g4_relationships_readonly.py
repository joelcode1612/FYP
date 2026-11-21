"""G4 operational residue and ownership verification; read-only live SQL only."""
import json,re,sys
from pathlib import Path
from datetime import datetime,timezone
import psycopg2
from psycopg2 import sql
from sqlalchemy.engine import make_url
ROOT=Path(__file__).resolve().parents[3]; OUT=ROOT/'artifacts/cp12_20261118'
sys.path.insert(0,str(ROOT/'backend/src'))
from sitewise.core.config import Settings
OWNER='32ef694a-69b0-4863-a77f-b9cf6c056b56'
TEMP='3796bc61-b007-42c4-89a7-7dc9999a3c7f'
MID='a506910e-7ccf-4b64-b1aa-4b2fd64c43fe'
NEW='ad723b3f-5937-44f3-bb94-3d0f3048c034'
NEW_MID='b28cd847-89f6-4994-adad-f79846f77c2e'
OLD='d45366fd-b360-4d49-867a-8b7858b37e5a'
HISTORIC='0a79fba2-3a39-4bd1-96b0-f245a1b2c0a7'

def main():
    u=make_url(Settings(_env_file=(ROOT/'backend/.env',ROOT/'backend/.env.local')).database_url)
    assert u.host in ('localhost','127.0.0.1') and u.database=='Final_Location_Analysis' and (u.port or 5432)==5432
    result={'observed_utc':datetime.now(timezone.utc).isoformat(),'mode':'READ_ONLY','databases':{}}
    needles={TEMP,MID,OLD}
    readback=json.loads((OUT/'option_b_m2_readback_revision12.json').read_text())
    # Recover exact temporary child identifiers captured by the actual HTTP recorder.
    for line in (OUT/'live_http_exchanges.jsonl').read_text(encoding='utf8').splitlines():
        e=json.loads(line)
        if TEMP in e['path'] or MID in e['path']:
            def visit(v):
                if isinstance(v,dict):
                    for k,x in v.items():
                        if k in ('id','link_id','projection_id') and isinstance(x,str) and re.fullmatch('[0-9a-f-]{36}',x):needles.add(x)
                        if k not in ('items','instrument'):visit(x)
                elif isinstance(v,list):
                    for x in v:visit(x)
            # Restrict to answer/link data, excluding shared item definitions.
            body=e.get('response') or {}
            for key in ('answers','answer','link'):
                if isinstance(body,dict) and key in body:visit(body[key])
            if isinstance(body,dict) and body.get('m2_assessment_id')==MID:
                if body.get('link_id'):needles.add(body['link_id'])
    for db in ('Final_Location_Analysis','Dss'):
        c=psycopg2.connect(host=u.host,port=u.port or 5432,user=u.username,password=u.password,dbname=db,
                          options='-c default_transaction_read_only=on -c statement_timeout=60000')
        c.set_session(readonly=True,isolation_level='REPEATABLE READ')
        info={'operational_residue':{}}
        try:
            with c.cursor() as q:
                q.execute("SELECT n.nspname,p.relname FROM pg_class p JOIN pg_namespace n ON n.oid=p.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','cp12') AND n.nspname NOT LIKE 'pg_%' AND p.relkind IN ('r','p') ORDER BY 1,2")
                tables=q.fetchall()
                for schema,table in tables:
                    q.execute(sql.SQL('SELECT count(*) FROM {}.{} r WHERE lower(to_jsonb(r)::text) LIKE ANY(%s)').format(sql.Identifier(schema),sql.Identifier(table)),(['%'+x+'%' for x in needles],))
                    n=q.fetchone()[0]
                    if n:info['operational_residue'][schema+'.'+table]=n
                assert not info['operational_residue'], 'Unexpected operational residue'
                if db=='Final_Location_Analysis':
                    q.execute('SELECT assessment_id::text,user_id::text,property_id,status,created_at,updated_at FROM public.assessment ORDER BY assessment_id')
                    info['assessments']=[dict(zip(('id','owner','property_id','status','created_at','updated_at'),r)) for r in q.fetchall()]
                    market={x['id']:x for x in info['assessments']}
                    assert NEW in market and market[NEW]['owner']==OWNER and market[NEW]['property_id']=='MD-02521'
                    assert TEMP not in market and OLD not in market
                else:
                    q.execute('SELECT l.link_id::text,l.marketplace_assessment_id::text,l.m2_assessment_id::text,l.user_id::text,l.revoked_at,a.owner_user_id::text,a.revision,a.confirmed_revision,(SELECT count(*) FROM m2_answer_revisions r WHERE r.assessment_id=a.id) FROM public.m2_assessment_links l LEFT JOIN public.m2_assessments a ON a.id=l.m2_assessment_id ORDER BY l.link_id')
                    info['links']=[dict(zip(('link_id','marketplace_id','m2_id','owner','revoked_at','m2_owner','revision','confirmed_revision','answer_rows'),r)) for r in q.fetchall()]
                    new=[x for x in info['links'] if x['marketplace_id']==NEW]
                    assert len(new)==1 and new[0]['m2_id']==NEW_MID and new[0]['owner']==new[0]['m2_owner']==OWNER
                    assert new[0]['revoked_at'] is None and new[0]['revision']==0 and new[0]['answer_rows']==0 and new[0]['confirmed_revision'] is None
                    dangling=[x for x in info['links'] if x['revoked_at'] is None and x['marketplace_id'] not in market]
                    assert len(dangling)==1 and dangling[0]['marketplace_id']==HISTORIC
                    info['preserved_historical_dangling_link']=dangling
                    q.execute('SELECT count(*) FROM public.m2_assessment_links WHERE m2_assessment_id=%s AND revoked_at IS NULL',(NEW_MID,));assert q.fetchone()[0]==1
                q.execute('SELECT assessment_id::text,phase FROM cp12.operations ORDER BY assessment_id')
                info['retained_deletion_journals']=q.fetchall()
                assert dict(info['retained_deletion_journals'])=={OLD:'COMPLETE',TEMP:'COMPLETE'}
        finally:c.rollback();c.close()
        result['databases'][db]=info
    result['status']='PASS'
    result['deleted_identifier_count_scanned']=len(needles)
    (OUT/'g4_relationships_and_residue.json').write_text(json.dumps(result,indent=2,default=str)+'\n')
    print(json.dumps({'status':'PASS','deleted_identifiers_scanned':len(needles),'new_blank_revision':0,'new_blank_answers':0,'historical_orphan_preserved':True}))
if __name__=='__main__':main()
