"""Owner-operated local fixture import; never a participant collection API."""
from copy import deepcopy
from collections.abc import Mapping
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
from uuid import UUID
from zipfile import ZipFile

from sqlalchemy import MetaData,Table,inspect,select,text
from sitewise.domain.customer_questionnaire import digest
from sitewise.services.ee01_service import Ee01Service
from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization

ORDER=['users','m2_instrument_versions','m2_assessments','cq_bank_versions','cq_manifest_releases',
 'cq_question_assignments','cq_campaigns','cq_participants','cq_sessions','cq_consent_events',
 'cq_stimulus_deliveries','cq_routing_decisions','cq_presentations','cq_answer_revisions',
 'cq_effective_answers','cq_submission_receipts','cq_lifecycle_events','cq_render_events',
 'cq_rejected_answer_events','cq_session_controls']
DERIVED=['ee01_measurement_snapshots','ee01_source_units','ee01_category_cells','ee01_report_readbacks']


def normalized(value):
    if isinstance(value,datetime):
        return value.astimezone(timezone.utc).isoformat() if value.tzinfo else value.isoformat()
    if isinstance(value,Mapping):return {k:normalized(v) for k,v in value.items()}
    if isinstance(value,(list,tuple)):return [normalized(v) for v in value]
    if isinstance(value,UUID):return str(value)
    if value is None or isinstance(value,(str,int,float,bool)):return value
    return str(value)


def load_package(path,contracts):
    raw=Path(path).read_bytes();sha=hashlib.sha256(raw).hexdigest()
    with ZipFile(path) as z:
        if any(Path(n).is_absolute() or '..' in Path(n).parts for n in z.namelist()):raise ValueError('Unsafe ZIP path')
        manifest=json.loads(z.read('MANIFEST.json'))
        for name,entry in manifest.items():
            if hashlib.sha256(z.read(name)).hexdigest()!=entry['sha256']:raise ValueError('Package checksum mismatch')
        payload=json.loads(z.read('mock_records.json'));tables=payload['tables']
    if payload.get('classification')!='TEST_ONLY / NOT_FIELD_DATA' or payload.get('external_auth_accounts_created'):
        raise ValueError('Explicit synthetic, non-auth fixture required')
    if set(tables)!=set(ORDER+DERIVED):raise ValueError('Unexpected fixture table set')
    if (len(tables['users']),len(tables['cq_sessions']),len(tables['ee01_measurement_snapshots']))!=(12,11,3):
        raise ValueError('Package row counts differ')
    if any(not r['email'].endswith('@test.invalid') for r in tables['users']):raise ValueError('Real profile detected')
    if any(r['source_class']!='SYNTHETIC_FIXTURE' for r in tables['cq_manifest_releases']):raise ValueError('Non-test release detected')
    if any(r['scope']!='ISOLATED_TEST' or r['status']!='WITHHELD_NOT_AUTHORIZED' for r in tables[DERIVED[0]]):
        raise ValueError('Non-diagnostic snapshot detected')
    if any(r['percentage'] is not None for r in tables['ee01_category_cells']):raise ValueError('Reportable percentage prohibited')
    owners={r['owner_user_id'] for r in tables['cq_campaigns']}
    if len(owners)!=1:raise ValueError('Exactly one test owner required')
    definitions={}
    for name,p in contracts.items():
        b=Path(p).read_bytes();definitions[name]={'sha256':hashlib.sha256(b).hexdigest(),'document':json.loads(b)}
    if definitions['research_modes']['document']['status']!='DESIGN_ONLY_NOT_ADOPTED':
        raise ValueError('Research authority changed; review required')
    if definitions['consent_purposes']['document']['status']!='DRAFT_DO_NOT_SHOW_TO_REAL_PARTICIPANTS':
        raise ValueError('Consent authority changed; review required')
    plan={'package_sha256':sha,'contracts':definitions,'owner_user_id':next(iter(owners)),
          'origin':'SYNTHETIC_TEST','effective_mode':'DEVELOPER_PREVIEW',
          'consent_semantics':'SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT',
          'profiles':'SUSPENDED_AND_EMAIL_UNVERIFIED','calculation':'RECOMPUTE_SYNTHETIC_DIAGNOSTICS_V1',
          'expected_counts':{k:len(v) for k,v in tables.items()}}
    return tables,plan,digest(plan)


class SyntheticDssImporter:
    def __init__(self,engine,tables,plan,plan_hash):
        self.engine,self.data,self.plan,self.plan_hash=engine,tables,plan,plan_hash
        self.models={}

    def model(self,c,name):
        if name not in ORDER+DERIVED:raise ValueError('Table is not an approved fixture target')
        if name not in self.models:self.models[name]=Table(name,MetaData(),autoload_with=c)
        return self.models[name]

    def key(self,c,name,row):
        return {k.name:str(row[k.name]) for k in self.model(c,name).primary_key.columns}

    def find(self,c,name,key):
        t=self.model(c,name)
        return c.execute(select(t).where(*[t.c[k]==v for k,v in key.items()])).mappings().one_or_none()

    def validate_schema_and_conflicts(self,c,run_id):
        present=c.scalar(text("SELECT to_regclass('cq_synthetic_import_runs')"))
        if present:
            run=c.execute(text('SELECT * FROM cq_synthetic_import_runs WHERE run_id=:id'),{'id':run_id}).mappings().one_or_none()
            if run:
                if run['package_sha256']!=self.plan['package_sha256'] or run['plan_sha256']!=self.plan_hash:
                    raise ValueError('Run identifier reused with different package/plan')
                self.verify_records(c,run_id)
                return 'ALREADY_IMPORTED'
        for name in ORDER:
            t=self.model(c,name)
            for row in self.data[name]:
                if set(row)!=set(t.c.keys()):raise ValueError('Physical field mismatch: '+name)
                if self.find(c,name,self.key(c,name,row)) is not None:
                    raise ValueError('Pre-existing fixture ID; no overwrite: '+name)
        return 'READY'

    def tag(self,c,run_id,name,source,imported):
        sk=self.key(c,name,source);rk=self.key(c,name,imported)
        c.execute(text('INSERT INTO cq_synthetic_import_records(run_id,table_name,source_key,source_key_hash,record_key,record_key_hash,source_sha256,imported_sha256) '
            'VALUES(:run,:t,CAST(:sk AS jsonb),:sh,CAST(:rk AS jsonb),:rh,:source,:actual)'),
            {'run':run_id,'t':name,'sk':json.dumps(sk),'sh':digest(sk),'rk':json.dumps(rk),'rh':digest(rk),
             'source':digest(source),'actual':digest(normalized(dict(imported)))})

    def verify_records(self,c,run_id):
        records=c.execute(text("SELECT * FROM cq_synthetic_import_records WHERE run_id=:run AND record_kind='PACKAGE'"),{'run':run_id}).mappings().all()
        if len(records)!=sum(self.plan['expected_counts'].values()):raise ValueError('Import registry count mismatch')
        for r in records:
            row=self.find(c,r['table_name'],r['record_key'])
            valid=row is not None and digest(normalized(dict(row)))==r['imported_sha256']
            if not valid:raise ValueError('Imported record changed or missing: '+r['table_name'])
        return len(records)

    def apply_in_transaction(self,c,run_id,operator_receipt,fail_after=None):
        c.execute(text("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))"),{'key':'project1-synthetic-'+str(run_id)})
        state=self.validate_schema_and_conflicts(c,run_id)
        if state=='ALREADY_IMPORTED':return {'status':state,'run_id':str(run_id),'rows':self.verify_records(c,run_id)}
        inserted=[];counter=0
        for name in ORDER:
            t=self.model(c,name)
            for original in self.data[name]:
                row=deepcopy(original)
                if name=='users':row.update(account_status='suspended',email_verified=False)
                if name=='cq_session_controls':
                    row['research_mode']='DEVELOPER_PREVIEW'
                    row['source_json'].update(research_mode='DEVELOPER_PREVIEW',origin='SYNTHETIC_TEST',
                        synthetic_run_id=str(run_id),real_reportable=False,
                        consent_semantics='SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT')
                    row['source_hash']=digest(row['source_json'])
                actual=c.execute(t.insert().values(**row).returning(t)).mappings().one()
                inserted.append((name,original,dict(actual)));counter+=1
                if fail_after and counter>=fail_after:raise RuntimeError('INTENTIONAL_CLONE_ROLLBACK')
            if name=='users':
                c.execute(text('INSERT INTO cq_synthetic_import_runs(run_id,owner_user_id,package_sha256,plan_sha256,operator_receipt,manifest_json) '
                    'VALUES(:run,:owner,:zip,:plan,:receipt,CAST(:manifest AS jsonb))'),
                    {'run':run_id,'owner':self.plan['owner_user_id'],'zip':self.plan['package_sha256'],'plan':self.plan_hash,
                     'receipt':operator_receipt,'manifest':json.dumps(self.plan)})
        for name,source,actual in inserted:self.tag(c,run_id,name,source,actual)
        # Operator fixture transaction executes the real calculator under its
        # restricted role. Ordinary app connections still use the separate
        # non-superuser login, verified independently after commit.
        c.execute(text('SET LOCAL ROLE p1_ee01_runtime'))
        calculator=Ee01Service(self.engine,SyntheticPreviewAuthorization(run_id),transaction=c)
        results=[]
        try:
            for source in self.data['ee01_measurement_snapshots']:
                actual=calculator.build_diagnostic(UUID(source['owner_user_id']),UUID(source['assessment_id']),UUID(source['campaign_id']),
                    source['slot_id'],datetime.fromisoformat(source['cutoff']),source['metadata_json']['rule'])
                if tuple(actual[k] for k in ('q','s','a','v'))!=tuple(source[k] for k in ('q','s','a','v')):
                    raise ValueError('Recomputed diagnostic counts differ')
                results.append((source,actual))
        finally:c.execute(text('RESET ROLE'))
        mapping={source['id']:actual['id'] for source,actual in results}
        for name in DERIVED:
            t=self.model(c,name)
            for source in self.data[name]:
                if name=='ee01_measurement_snapshots':key={'id':mapping[source['id']]}
                elif name=='ee01_report_readbacks':
                    actual=c.execute(select(t).where(t.c.snapshot_id==mapping[source['snapshot_id']])).mappings().one()
                    self.tag(c,run_id,name,source,actual);continue
                else:
                    key={**self.key(c,name,source),'snapshot_id':mapping[source['snapshot_id']]}
                actual=self.find(c,name,key)
                if actual is None:raise ValueError('Calculated child row missing: '+name)
                if name=='ee01_category_cells' and (actual['x']!=source['x'] or actual['v']!=source['v'] or actual['percentage'] is not None):
                    raise ValueError('Calculated category differs')
                self.tag(c,run_id,name,source,actual)
        return {'status':'IMPORTED','run_id':str(run_id),'rows':self.verify_records(c,run_id),
                'snapshot_mapping':mapping,'package_sha256':self.plan['package_sha256']}
