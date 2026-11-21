"""Bounded local-development import. -WhatIf never migrates or inserts."""
import argparse
from datetime import datetime,timezone
import hashlib
import html
import json
import os
from pathlib import Path
import sys
from uuid import UUID,uuid5,NAMESPACE_URL

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from dotenv import dotenv_values
from sqlalchemy import create_engine,inspect,select,MetaData,Table,text
from sqlalchemy.engine import make_url
from sitewise.domain.customer_questionnaire import digest
from sitewise.services.synthetic_dss_import import SyntheticDssImporter,load_package,normalized
from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization
from sitewise.services.ee01_service import Ee01Service


def configured_urls():
    config={**dotenv_values(ROOT/'.env'),**dotenv_values(ROOT/'.env.local')}
    raw=os.environ.get('M2_DATABASE_URL') or config.get('M2_DATABASE_URL')
    runtime=os.environ.get('EE01_DATABASE_URL') or config.get('EE01_DATABASE_URL')
    if not raw or not runtime:raise ValueError('Dedicated M2/EE01 URLs required; no analytics fallback')
    admin,app=make_url(raw),make_url(runtime)
    if any(u.database!='Dss' or u.host not in ('localhost','127.0.0.1','::1') or u.drivername!='postgresql+psycopg2' for u in (admin,app)):
        raise ValueError('Only explicitly configured local Dss is allowed')
    if app.username!='p1_ee01_runtime':raise ValueError('Restricted EE-01 runtime login required')
    return admin,app


def footprint(c):
    result={}
    for name in inspect(c).get_table_names(schema='public'):
        if name.startswith('cq_synthetic_import_'):continue
        t=Table(name,MetaData(),autoload_with=c);pk=list(t.primary_key.columns)
        result[name]={}
        for r in c.execute(select(t)).mappings():
            value=normalized(dict(r));key={p.name:value[p.name] for p in pk} if pk else value
            result[name][digest(key)]=digest(value)
    return result


def preserved(before,after):
    return all(all(after.get(t,{}).get(k)==v for k,v in rows.items()) for t,rows in before.items())


def apply_boundary_migration(c,receipt):
    p=ROOT/'migrations/cq/20261116_03_synthetic_import_boundary.sql'
    sha=hashlib.sha256(p.read_bytes()).hexdigest()
    previous=c.scalar(text("SELECT migration_sha256 FROM cq_schema_migrations WHERE version='20261116_03'"))
    if previous:
        if previous!=sha:raise ValueError('Existing synthetic migration hash differs')
        # Later migrations can extend these guards. Retry must not reinstall
        # an older CREATE OR REPLACE function over the interactive boundary.
        return sha
    c.execute(text("SELECT set_config('project1.cq_migration_target',current_database(),true),"
        "set_config('project1.cq_migration_receipt',:receipt,true),set_config('project1.cq_migration_sha256',:sha,true)"),{'receipt':receipt,'sha':sha})
    # No bind parameters: PL/pgSQL format('%I',...) must reach psycopg2 intact.
    with c.connection.driver_connection.cursor() as cursor:
        cursor.execute(p.read_text().replace('BEGIN;','',1).rsplit('COMMIT;',1)[0])
    return sha


def readback(admin,app,run_id,output):
    engine=create_engine(admin,hide_parameters=True,connect_args={'options':'-c default_transaction_read_only=on'})
    with engine.connect() as c:
        c.execute(text('SET TRANSACTION READ ONLY'))
        run=c.execute(text('SELECT * FROM cq_synthetic_import_runs WHERE run_id=:id'),{'id':run_id}).mappings().one()
        records=c.execute(text('SELECT table_name,count(*) AS rows FROM cq_synthetic_import_records WHERE run_id=:id GROUP BY table_name ORDER BY table_name'),{'id':run_id}).mappings().all()
        snapshots=c.execute(text("SELECT s.* FROM ee01_measurement_snapshots s JOIN cq_synthetic_import_records r ON r.table_name='ee01_measurement_snapshots' AND r.record_key->>'id'=s.id::text WHERE r.run_id=:id ORDER BY s.cutoff,s.metadata_json->>'rule'"),{'id':run_id}).mappings().all()
        production_q=c.scalar(text("SELECT count(*) FROM cq_sessions s JOIN cq_session_controls ctl ON ctl.session_id=s.id JOIN cq_synthetic_import_records r ON r.table_name='cq_sessions' AND r.record_key->>'id'=s.id::text WHERE r.run_id=:id AND ctl.research_mode='CUSTOMER_DEMAND_SURVEY' AND ctl.eligibility='ELIGIBLE'"),{'id':run_id})
        active_profiles=c.scalar(text("SELECT count(*) FROM users u JOIN cq_synthetic_import_records r ON r.table_name='users' AND r.record_key->>'user_id'=u.user_id::text WHERE r.run_id=:id AND (u.account_status<>'suspended' OR u.email_verified)"),{'id':run_id})
        reconciliation=[];models={}
        for record in c.execute(text('SELECT * FROM cq_synthetic_import_records WHERE run_id=:id ORDER BY table_name,record_key_hash'),{'id':run_id}).mappings():
            name=record['table_name']
            if name not in models:models[name]=Table(name,MetaData(),autoload_with=c)
            t=models[name]
            row=c.execute(select(t).where(*[t.c[k]==v for k,v in record['record_key'].items()])).mappings().one()
            reconciliation.append({'table':record['table_name'],'key':record['record_key'],
                'expected_sha256':record['imported_sha256'],'actual_sha256':digest(normalized(dict(row))),
                'matches':record['imported_sha256']==digest(normalized(dict(row)))})
        sessions=c.execute(text("SELECT s.id,s.campaign_id,s.release_id,s.revision,s.state,ctl.eligibility,ctl.research_mode,"
            "CASE WHEN s.state='ACTIVE' AND (SELECT action FROM cq_lifecycle_events l WHERE l.session_id=s.id ORDER BY revision DESC LIMIT 1)='PAUSE' THEN 'PAUSED' ELSE s.state END AS status,"
            '(SELECT count(*) FROM cq_submission_receipts x WHERE x.session_id=s.id) AS receipts '
            "FROM cq_sessions s JOIN cq_session_controls ctl ON ctl.session_id=s.id JOIN cq_synthetic_import_records r ON r.table_name='cq_sessions' AND r.record_key->>'id'=s.id::text WHERE r.run_id=:id ORDER BY s.id"),{'id':run_id}).mappings().all()
    runtime=create_engine(app,hide_parameters=True,connect_args={'options':'-c default_transaction_read_only=on'})
    preview=Ee01Service(runtime,SyntheticPreviewAuthorization(run_id));ordinary=Ee01Service(runtime)
    actual=[]
    for s in snapshots:
        row=preview.read(run['owner_user_id'],s['assessment_id'],s['campaign_id'],s['id'])
        try:ordinary.read(run['owner_user_id'],s['assessment_id'],s['campaign_id'],s['id'])
        except Exception as exc:
            if getattr(exc,'code',None)!='SYNTHETIC_DATA_NOT_REPORTABLE':raise
        else:raise ValueError('Ordinary report read leaked synthetic data')
        actual.append(row)
    if production_q or active_profiles or not all(r['matches'] for r in reconciliation):raise ValueError('Synthetic exclusion/profile/integrity failed')
    result=normalized({'run_id':run_id,'database':admin.database,'host':admin.host,'port':admin.port or 5432,
        'records':records,'snapshots':actual,'production_qualified_cohort':production_q,
        'login_enabled_mock_profiles':active_profiles,'ordinary_report_access':'DENIED_SYNTHETIC_DATA_NOT_REPORTABLE',
        'sessions':[dict(s) for s in sessions],'row_reconciliation':reconciliation,
        'real_fielding_authorized':False,'real_report_admission_authorized':False})
    output.mkdir(parents=True,exist_ok=True)
    (output/'Dss_readback.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    cards=[]
    for r in actual:
        cells=''.join('<tr>'+''.join('<td>'+html.escape(str(x))+'</td>' for x in (v['code'],v['x'],v['v'],v['diagnostic_percentage'],v['status']))+'</tr>' for v in r['cells'])
        cards.append('<section><h2>'+html.escape(r['metadata_json']['rule'])+'</h2><p>Q/S/A/V: '+
            '/'.join(str(r[k]) for k in ('q','s','a','v'))+'</p><p>Cutoff '+html.escape(r['cutoff'])+
            '</p><table><tr><th>Category</th><th>x</th><th>V</th><th>Diagnostic %</th><th>Official status</th></tr>'+cells+'</table></section>')
    page='<html><meta charset="utf-8"><title>SYNTHETIC TEST — local developer preview</title><style>body{font:16px system-ui;max-width:1100px;margin:32px auto;background:#fff8db}h1{background:#111;color:#fff;padding:24px}section{border:2px dashed #a66;padding:20px;margin:24px 0}td,th{border:1px solid #999;padding:8px}table{border-collapse:collapse}.watermark{position:fixed;bottom:0;background:#111;color:white;padding:12px;width:100%}</style><h1>SYNTHETIC TEST — NOT REAL SURVEY FINDINGS</h1><p>Local developer artifact only. Simulated nonhuman consent; no participant collection, scientific authorization, A10 admission or released report.</p><p>Import run '+str(run_id)+'</p>'+''.join(cards)+'<div class="watermark">SYNTHETIC / DEVELOPER PREVIEW / NOT REPORTABLE</div></html>'
    (output/'SYNTHETIC_DEVELOPER_PREVIEW.html').write_text(page,encoding='utf-8')
    engine.dispose();runtime.dispose()
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package',type=Path)
    parser.add_argument('--research-modes',type=Path)
    parser.add_argument('--consent-purposes',type=Path)
    parser.add_argument('--run-id',type=UUID,required=True)
    parser.add_argument('--target',choices=['Dss'],required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--what-if',action='store_true')
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--readback',action='store_true')
    parser.add_argument('--retire',type=str)
    parser.add_argument('--confirm-local-development',choices=['Dss'])
    parser.add_argument('--backup-receipt',type=Path)
    parser.add_argument('--clone-receipt',type=Path)
    parser.add_argument('--operator-receipt')
    parser.add_argument('--grant-developer',type=UUID)
    parser.add_argument('--verified-principal-receipt',type=Path)
    args=parser.parse_args();admin,app=configured_urls();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    if args.grant_developer:
        if args.confirm_local_development!='Dss' or not args.operator_receipt or not args.verified_principal_receipt:
            raise ValueError('Verified existing phone principal and explicit local operator confirmation required')
        receipt=json.loads(args.verified_principal_receipt.read_text())
        if receipt.get('user_id')!=str(args.grant_developer) or receipt.get('account_status')!='active':
            raise ValueError('Existing authenticated principal receipt mismatch')
        config={**dotenv_values(ROOT/'.env'),**dotenv_values(ROOT/'.env.local')}
        auth_url=make_url(os.environ.get('DATABASE_URL') or config['DATABASE_URL'])
        if auth_url.host not in ('localhost','127.0.0.1','::1') or auth_url.drivername!='postgresql+psycopg2':
            raise ValueError('Local existing authentication database required')
        auth_engine=create_engine(auth_url,hide_parameters=True,connect_args={'options':'-c default_transaction_read_only=on'})
        with auth_engine.connect() as c:
            profile=c.execute(text('SELECT user_id,role,account_status,email_verified FROM users WHERE user_id=:id'),{'id':args.grant_developer}).mappings().one()
            if profile['account_status']!='active':raise ValueError('Existing account is inactive')
            anchor=digest(normalized(dict(profile)))
        with create_engine(admin,hide_parameters=True).begin() as c:
            c.execute(text("INSERT INTO cq_synthetic_preview_grants(run_id,developer_user_id,principal_source,profile_anchor_sha256,operator_receipt) VALUES(:run,:dev,'EXISTING_VERIFIED_APP_PROFILE',:sha,:receipt) ON CONFLICT DO NOTHING"),
                {'run':args.run_id,'dev':args.grant_developer,'sha':anchor,'receipt':args.operator_receipt})
        auth_engine.dispose()
        print('Read-only developer grant recorded for existing authenticated profile; no account created.');return
    if args.readback:
        result=readback(admin,app,args.run_id,out);print(json.dumps({'run_id':str(args.run_id),'snapshots':len(result['snapshots']),'production_Q':result['production_qualified_cohort']}));return
    if args.retire:
        if args.confirm_local_development!='Dss' or not args.operator_receipt:raise ValueError('Explicit local operator confirmation required')
        with create_engine(admin,hide_parameters=True).begin() as c:
            c.execute(text('INSERT INTO cq_synthetic_import_retirements(run_id,reason) VALUES(:id,:reason) ON CONFLICT DO NOTHING'),{'id':args.run_id,'reason':args.retire})
        print('Exact synthetic run retired; no records deleted.');return
    data,plan,plan_hash=load_package(args.package,{'research_modes':args.research_modes,'consent_purposes':args.consent_purposes})
    importer=SyntheticDssImporter(create_engine(admin,hide_parameters=True),data,plan,plan_hash)
    if not args.apply:
        with importer.engine.connect() as c:
            c.execute(text('SET TRANSACTION READ ONLY'))
            state=importer.validate_schema_and_conflicts(c,args.run_id)
            needs_migration=c.scalar(text("SELECT to_regclass('cq_synthetic_import_runs')")) is None
        result={'mode':'WHAT_IF_READ_ONLY','state':state,'target':'Dss','run_id':str(args.run_id),
                'plan_sha256':plan_hash,'plan':plan,'metadata_migration_required':needs_migration}
        (out/'what_if.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print('WHATIF:',state,'12 profiles / 11 sessions / 3 recomputed diagnostic snapshots. No database changes.');return
    if args.confirm_local_development!='Dss' or not args.operator_receipt or not args.backup_receipt or not args.clone_receipt:
        raise ValueError('Backup, clone proof and explicit local Dss confirmation required')
    backup=json.loads(args.backup_receipt.read_text());clone=json.loads(args.clone_receipt.read_text())
    if backup['target']!='Dss' or hashlib.sha256(Path(backup['path']).read_bytes()).hexdigest()!=backup['sha256']:
        raise ValueError('Backup verification failed')
    migration_hash=hashlib.sha256((ROOT/'migrations/cq/20261116_03_synthetic_import_boundary.sql').read_bytes()).hexdigest()
    if not clone.get('all_checks_passed') or clone.get('plan_sha256')!=plan_hash or clone.get('migration_sha256')!=migration_hash or clone.get('backup_sha256')!=backup['sha256']:
        raise ValueError('Clone verification does not match this package/plan/migration/backup')
    with importer.engine.begin() as c:
        c.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
        c.execute(text("SET LOCAL TIME ZONE 'UTC'"))
        before=footprint(c)
        apply_boundary_migration(c,args.operator_receipt)
        result=importer.apply_in_transaction(c,args.run_id,args.operator_receipt)
        after=footprint(c)
        if not preserved(before,after):raise ValueError('Original rows changed; transaction aborted')
    (out/'original_row_hashes_before.json').write_text(json.dumps(before,indent=2),encoding='utf-8')
    (out/'post_import_table_counts.json').write_text(json.dumps({t:len(v) for t,v in after.items()},indent=2),encoding='utf-8')
    (out/'import_receipt.json').write_text(json.dumps({**result,'plan_sha256':plan_hash,'migration_sha256':migration_hash,
        'backup_sha256':backup['sha256'],'original_rows_preserved':True},indent=2),encoding='utf-8')
    readback(admin,app,args.run_id,out)
    print(result['status'],str(args.run_id),'Original rows preserved. No real fielding or report release.')


if __name__=='__main__':
    try:main()
    except Exception as exc:
        print('ABORTED:',type(exc).__name__,str(exc) if isinstance(exc,(ValueError,RuntimeError)) else 'See private operator logs; no credentials printed.',file=sys.stderr)
        raise SystemExit(1)
