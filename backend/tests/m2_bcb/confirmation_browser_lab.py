"""Optional browser acceptance using the actual compiled app and private DB.

Identity provider is the existing signed-test-JWT authority, not Supabase
production. No auth bypass, provider call, live record or product route is added.
"""
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading
import time
from urllib.parse import urlencode
from uuid import UUID

import httpx
from sqlalchemy import text
from sqlalchemy.engine import make_url
from starlette.responses import JSONResponse
from starlette.routing import Route


def exercise(lab):
    root = Path(__file__).resolve().parents[2]
    out = Path(os.environ['M2_BCB_EVIDENCE'])
    url = make_url(os.environ['DATABASE_URL'])
    assert (url.host,url.port,url.database) == ('127.0.0.1',55441,'project1_m2_bcb_test')
    from sitewise.core.config import settings
    from sitewise.repositories.catalog_repository import PROPERTY_COLUMNS, _COLUMN_METRICS
    from scripts.register_m2_v1 import register

    # Only the disposable database. These are the existing application models,
    # not substitute assessment engines or migration of either live database.
    from sitewise.db.models.assessment import Assessment
    from sitewise.db.models.favourite_property import FavouriteProperty
    Assessment.__table__.create(lab['db'], checkfirst=True)
    FavouriteProperty.__table__.create(lab['db'], checkfirst=True)
    with lab['db'].begin() as c:
        c.execute(text('CREATE SCHEMA IF NOT EXISTS fyp'))
        c.execute(text('CREATE SCHEMA IF NOT EXISTS sitewise_analytics'))
        c.execute(text('CREATE TABLE sitewise_analytics.subject_features (' +
            ','.join(name + ' numeric' for name, *_ in _COLUMN_METRICS) +
            ', canonical_property_id text, imported_at timestamptz, analysis_status text,'
            ' reference_coverage text, feature_snapshot_at timestamptz, inventory_snapshot_at timestamptz,'
            ' parking_status text, self_exclusion_status text, other_features jsonb)'))
        c.execute(text('CREATE TABLE IF NOT EXISTS fyp.catalogue_properties (' + ','.join(
            name + (' numeric' if name in ('rental_rm','size_sqft','latitude','longitude','suitability_score')
                    else ' jsonb' if name == 'dataset_validation' else ' text')
            for name in PROPERTY_COLUMNS) + ')'))
        c.execute(text("INSERT INTO fyp.catalogue_properties(id,title,address,city,state,rental_rm,size_sqft,latitude,longitude,property_type,dataset_validation) VALUES ('MD-02521','TEST ONLY — Fiesta assessment','SYNTHETIC location','Kuala Lumpur','Kuala Lumpur',500,86,NULL,NULL,'Retail space','{}')"))
        # Existing reviewed link schema, applied only to the private database.
        c.execute(text((root/'migrations/m2/20261118_05_assessment_binding_links.sql').read_text(encoding='utf-8-sig')))
    register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')
    headers={'Authorization':'Bearer '+lab['token'](lab['actor'])}
    client=httpx.Client(base_url=lab['base'],headers=headers,timeout=40)
    def request(method,path,body=None):
        response=client.request(method,path,json=body)
        assert response.status_code in (200,201), (path,response.status_code,response.text[:500])
        return response.json()
    request('POST','/api/v1/saved-properties/',{'property_ref':'MD-02521'})
    market=request('POST','/api/v1/assessments/',{'property_id':'MD-02521'})['assessment']['assessment_id']
    mid=request('POST',f'/api/v1/m2/assessments/by-marketplace/{market}/link',{})['m2_assessment_id']
    values={
        'M2V1-01':'UNDECIDED','M2V1-02':'HYBRID','M2V1-03':['COFFEE'],
        'M2V1-04':['STUDENTS','OFFICE_WORKERS'],'M2V1-05':'STUDENTS',
        'M2V1-06':'QUALITY','M2V1-07':'STUDY_WORK','M2V1-08':['NONE'],
        'M2V1-09':['CONCEPT_INTEREST','PRICE_ACCEPTABILITY'],'M2V1-10':'CONCEPT_INTEREST',
    }
    for rev,(item,value) in enumerate(values.items()):
        request('PUT',f'/api/v1/m2/assessments/{mid}/answers/{item}',
            {'expected_revision':rev,'answer_state':'ANSWERED','value':value})

    class Identity(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/start':
                fragment=urlencode({'access_token':lab['token'](lab['actor']),
                    'refresh_token':'SYNTHETIC-NONPRODUCTION-ONLY','expires_in':'1800','token_type':'bearer','type':'magiclink'})
                self.send_response(302)
                self.send_header('Location',lab['base']+'/auth/callback?next=%2Fentrepreneur%2Fassessments#'+fragment)
                self.end_headers()
                return
            if self.path.startswith('/auth/v1/user'):
                body={'id':str(lab['actor']),'aud':'authenticated','role':'authenticated',
                    'email':str(lab['actor'])+'@test.invalid','email_confirmed_at':'2026-01-01T00:00:00Z',
                    'created_at':'2026-01-01T00:00:00Z','app_metadata':{'provider':'email'},'user_metadata':{}}
                self.send_response(200)
                self.send_header('Access-Control-Allow-Origin','*')
                self.send_header('Content-Type','application/json')
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())
                return
            self.send_response(404); self.end_headers()
        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header('Access-Control-Allow-Origin','*')
            self.send_header('Access-Control-Allow-Headers','authorization,apikey,x-client-info,content-type,x-supabase-api-version')
            self.send_header('Access-Control-Allow-Methods','GET,OPTIONS')
            self.end_headers()
        def log_message(self,*args): pass

    identity=ThreadingHTTPServer(('127.0.0.1',0),Identity)
    thread=threading.Thread(target=identity.serve_forever,daemon=True);thread.start()
    # Test-only public client configuration. Real backend JWT verification and
    # private owner/RLS checks are unchanged; no production session is read.
    provider=f'http://127.0.0.1:{identity.server_port}'
    async def configuration(request):
        return JSONResponse({'supabaseUrl':provider,'supabasePublishableKey':'SYNTHETIC-PUBLIC-TEST-KEY'})
    lab['app'].router.routes.insert(0,Route('/auth-config.json',configuration))
    ready={'mode':'SIGNED TEST IDENTITY / ACTUAL SITEWISE UI / DISPOSABLE POSTGRESQL',
        'start_url':provider+'/start','application_url':lab['base']+'/entrepreneur/assessments',
        'marketplace_assessment_id':market,'m2_assessment_id':mid,'prepared_revision':10,
        'expected_ui_answer':{'M2V1-11':'EXPLORE'}, 'real_customer_collection':False}
    (out/'browser_ready.json').write_text(json.dumps(ready,indent=2),encoding='utf-8')
    try:
        deadline=time.monotonic()+900
        while not (out/'browser_finished.json').exists() and time.monotonic()<deadline:
            time.sleep(.3)
        assert (out/'browser_finished.json').exists(), 'Browser acceptance not completed before bounded timeout.'
        receipt=request('GET',f'/api/v1/m2/assessments/{mid}/confirmation-current')
        assert receipt['assessment_revision']==11
        assert receipt['snapshot_contract_version']=='m2-confirmation/3'
        with lab['db'].connect() as c:
            snapshot=c.execute(text('SELECT snapshot_json,snapshot_digest FROM m2_confirmation_snapshots WHERE id=:id'),{'id':UUID(receipt['id'])}).mappings().one()
            rows=c.execute(text('SELECT i.item_key,a.assessment_revision,a.value_json FROM m2_answer_revisions a JOIN m2_item_versions i ON i.id=a.item_version_id WHERE a.assessment_id=:id ORDER BY a.assessment_revision'),{'id':UUID(mid)}).mappings().all()
            assert len(rows)==11 and rows[-1]['value_json']=='EXPLORE'
            assert c.scalar(text('SELECT count(*) FROM m2_bdj_evaluations WHERE assessment_id=:id'),{'id':UUID(mid)})==0
        (out/'browser_database_readback.json').write_text(json.dumps({**ready,'receipt':receipt,
            'snapshot':dict(snapshot),'answer_revisions':[dict(r) for r in rows],
            'verified_at':datetime.now(timezone.utc).isoformat()},indent=2,default=str),encoding='utf-8')
    finally:
        identity.shutdown()
        client.close()
