"""Restore the operator backup to a private clone; never writes to Dss."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from uuid import UUID,uuid4

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
spec=importlib.util.spec_from_file_location('operator_import',ROOT/'scripts/import_mock_to_dss.py')
op=importlib.util.module_from_spec(spec);spec.loader.exec_module(op)
from sqlalchemy import create_engine,text
from sqlalchemy.engine import URL
from sitewise.services.synthetic_dss_import import load_package,SyntheticDssImporter,normalized


def main():
    a=argparse.ArgumentParser();a.add_argument('--evidence',type=Path,required=True)
    a.add_argument('--prior',type=Path,required=True);a.add_argument('--package',type=Path,required=True)
    a.add_argument('--contracts',type=Path,required=True);a.add_argument('--run-id',type=UUID,required=True)
    args=a.parse_args();out=args.evidence;out.mkdir(parents=True,exist_ok=True)
    cfg=json.loads((args.prior/'private_cq_connection.json').read_text())
    assert cfg['host']=='127.0.0.1' and cfg['port']==55443 and cfg['database']=='project1_cq_runtime_test'
    binaries=Path(r'C:\Program Files\PostgreSQL\16\bin');cluster=Path(cfg['cluster'])
    control=[str(binaries/'pg_ctl.exe'),'-D',str(cluster/'data')]
    started=subprocess.run([*control,'status'],capture_output=True).returncode==3
    if started:
        with socket.socket() as s:s.bind(('127.0.0.1',55443))
        with (out/'clone_control.log').open('a') as log:
            subprocess.run([*control,'-l',str(cluster/'synthetic_clone.log'),'-o',
                '-h 127.0.0.1 -p 55443 -c shared_buffers=16MB -c work_mem=1MB -c maintenance_work_mem=16MB -c max_connections=12 -c max_worker_processes=0 -c autovacuum=off',
                '-w','start'],stdout=log,stderr=subprocess.STDOUT,check=True)
    name='project1_dss_mock_'+uuid4().hex[:10]
    url=URL.create('postgresql+psycopg2',username='postgres',password=cfg['password'],host='127.0.0.1',port=55443,database='postgres')
    backup=json.loads((out/'backup_receipt.json').read_text())
    assert hashlib.sha256(Path(backup['path']).read_bytes()).hexdigest()==backup['sha256']
    env={**os.environ,'PGHOST':'127.0.0.1','PGPORT':'55443','PGUSER':'postgres','PGPASSWORD':cfg['password']}
    checks={};engine=None
    try:
        admin=create_engine(url,isolation_level='AUTOCOMMIT')
        with admin.connect() as c:c.exec_driver_sql('CREATE DATABASE '+name)
        admin.dispose()
        with (out/'clone_restore.log').open('w') as log:
            subprocess.run([str(binaries/'pg_restore.exe'),'--exit-on-error','--no-owner','--no-privileges','-d',name,backup['path']],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        checks['backup_restored']=True
        engine=create_engine(url.set(database=name),hide_parameters=True)
        data,plan,ph=load_package(args.package,{'research_modes':args.contracts/'research_modes_v0_7.json','consent_purposes':args.contracts/'consent_purposes_v0_7.json'})
        importer=SyntheticDssImporter(engine,data,plan,ph)
        with engine.begin() as c:
            before=op.footprint(c)
            # pg_restore --no-privileges intentionally strips grants. Reapply
            # the existing idempotent restricted-reader migration on clone only.
            p=ROOT/'migrations/cq/20261116_02_ee01_snapshots.sql'
            c.execute(text("SELECT set_config('project1.cq_migration_target',current_database(),true),set_config('project1.cq_migration_receipt','CLONE_RESTORE',true),set_config('project1.cq_migration_sha256',:sha,true)"),{'sha':hashlib.sha256(p.read_bytes()).hexdigest()})
            with c.connection.driver_connection.cursor() as cursor:
                cursor.execute(p.read_text().replace('BEGIN;','',1).rsplit('COMMIT;',1)[0])
        try:
            with engine.begin() as c:
                c.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
                op.apply_boundary_migration(c,'CLONE_FORCED_ROLLBACK')
                importer.apply_in_transaction(c,args.run_id,'CLONE',fail_after=13)
        except RuntimeError as exc:
            assert str(exc)=='INTENTIONAL_CLONE_ROLLBACK'
        else:raise AssertionError('Forced rollback did not fire')
        with engine.connect() as c:
            checks['rollback_preserves_all_rows']=op.footprint(c)==before
            checks['rollback_removes_new_schema']=c.scalar(text("SELECT to_regclass('cq_synthetic_import_runs')")) is None
        with engine.begin() as c:
            c.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'));c.execute(text("SET LOCAL TIME ZONE 'UTC'"))
            mh=op.apply_boundary_migration(c,'CLONE_VERIFIED')
            imported=importer.apply_in_transaction(c,args.run_id,'CLONE_VERIFIED')
            checks['original_rows_preserved']=op.preserved(before,op.footprint(c))
        with engine.begin() as c:
            counts=op.footprint(c);retry=importer.apply_in_transaction(c,args.run_id,'CLONE_RETRY')
            checks['idempotent']=retry['status']=='ALREADY_IMPORTED' and counts==op.footprint(c)
            checks['production_qualified_zero']=c.scalar(text("SELECT count(*) FROM cq_session_controls WHERE research_mode='CUSTOMER_DEMAND_SURVEY'"))==0
            checks['profiles_suspended']=c.scalar(text("SELECT count(*) FROM users u JOIN cq_synthetic_import_records r ON r.table_name='users' AND r.record_key->>'user_id'=u.user_id::text WHERE u.account_status<>'suspended' OR u.email_verified"))==0
            owner=UUID(plan['owner_user_id'])
            snapshots=c.execute(text('SELECT * FROM ee01_measurement_snapshots')).mappings().all()
            (out/'clone_snapshots.json').write_text(json.dumps(normalized([dict(s) for s in snapshots]),indent=2))
        for label,sql,params in [
            ('mock_profile_cannot_activate',"UPDATE users SET account_status='active',email_verified=true WHERE user_id=:id",{'id':owner}),
            ('append_only_delete_denied','DELETE FROM cq_synthetic_import_runs WHERE run_id=:id',{'id':args.run_id})]:
            try:
                with engine.begin() as c:c.execute(text(sql),params)
            except Exception as exc:
                checks[label]=getattr(exc.orig,'pgcode',None) in ('42501','P0001','55000')
            else:checks[label]=False
        runtime_cfg=json.loads((args.prior/'private_pg_connection.json').read_text())
        runtime=create_engine(url.set(database=name,username='p1_ee01_runtime',password=runtime_cfg['password']),hide_parameters=True)
        from sitewise.services.ee01_service import Ee01Service
        from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization
        preview=Ee01Service(runtime,SyntheticPreviewAuthorization(args.run_id))
        for s in snapshots:
            row=preview.read(owner,s['assessment_id'],s['campaign_id'],s['id'])
            assert row['metadata_json']['origin']=='SYNTHETIC_TEST'
            assert all(cell['percentage'] is None for cell in row['cells'])
            try:Ee01Service(runtime).read(owner,s['assessment_id'],s['campaign_id'],s['id'])
            except Exception as exc:assert exc.code=='SYNTHETIC_DATA_NOT_REPORTABLE'
            else:raise AssertionError('Ordinary read leak')
            try:preview.read(uuid4(),s['assessment_id'],s['campaign_id'],s['id'])
            except Exception as exc:assert exc.status==404
            else:raise AssertionError('Cross owner leak')
        checks['restricted_role_read_and_normal_denial']=True
        # The clone contains the existing real profile from the backup. A
        # clone-only grant tests delegation without creating a login account.
        with engine.begin() as c:
            developer=c.scalar(text("SELECT user_id FROM users WHERE email NOT LIKE '%@test.invalid' ORDER BY user_id LIMIT 1"))
            assert developer is not None
            c.execute(text("INSERT INTO cq_synthetic_preview_grants(run_id,developer_user_id,principal_source,profile_anchor_sha256,operator_receipt) VALUES(:run,:dev,'EXISTING_VERIFIED_APP_PROFILE',:sha,'CLONE_ONLY')"),
                {'run':args.run_id,'dev':developer,'sha':hashlib.sha256(str(developer).encode()).hexdigest()})
        from sitewise.services.synthetic_inspection_service import SyntheticInspectionService
        inspector=SyntheticInspectionService(runtime)
        assert len(inspector.runs(developer)['runs'])==1
        actual=inspector.inspect(developer,args.run_id)
        assert len(actual['sessions'])==11 and len(actual['snapshots'])==3
        (out/'clone_inspection.json').write_text(json.dumps(actual,indent=2))
        assert inspector.runs(uuid4())['runs']==[]
        try:inspector.inspect(uuid4(),args.run_id)
        except Exception as exc:assert exc.status==404
        else:raise AssertionError('Unrelated developer leak')
        checks['developer_grant_inspection']=True
        checks['other_developer_denied']=True
        # Independent raw CQ oracle: only the explicit synthetic mode changes.
        with engine.connect() as c:
            for s in snapshots:
                if s['slot_id']!='Q05':continue
                sql=(ROOT/'tests/cq_runtime/VERIFY_EE01_FROM_CQ.sql').read_text()
                start=sql.index('WITH bound AS');end=sql.index('COMMIT;',start)
                sql=sql[start:end].replace("'CUSTOMER_DEMAND_SURVEY'","'DEVELOPER_PREVIEW'")
                for key,val in {'actor_id':owner,'assessment_id':s['assessment_id'],'campaign_id':s['campaign_id'],'snapshot_id':s['id']}.items():
                    sql=sql.replace(":"+"'"+key+"'", "'"+str(val)+"'")
                row=c.execute(text(sql)).scalar_one()
                (out/('oracle_'+str(s['id'])+'.json')).write_text(json.dumps(row,indent=2))
                assert row['matches_saved_counts']
                if s['q']==8:
                    assert row['from_raw_CQ']['Q']==8 and row['from_raw_CQ']['V']==5
                    assert row['diagnostic_percentage']==60
        checks['independent_Q05_sql_oracle']=True
        # Retirement is reversible via transaction rollback on the clone.
        with engine.connect() as c:
            tx=c.begin();c.execute(text('INSERT INTO cq_synthetic_import_retirements(run_id,reason) VALUES(:id,\'CLONE_ONLY\')'),{'id':args.run_id});tx.rollback()
        checks['retirement_rollback']=True
        runtime.dispose()
        result={'all_checks_passed':all(checks.values()),'checks':checks,'clone_database':name,'clone_port':55443,
                'plan_sha256':ph,'migration_sha256':mh,'backup_sha256':backup['sha256'],'import':imported}
        (out/'clone_receipt.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result,indent=2))
        assert result['all_checks_passed']
    finally:
        if engine:engine.dispose()
        if started:
            with (out/'clone_control.log').open('a') as log:subprocess.run([*control,'-m','fast','-w','stop'],stdout=log,stderr=subprocess.STDOUT,check=True)


if __name__=='__main__':main()
