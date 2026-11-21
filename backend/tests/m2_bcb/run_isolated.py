"""Restore read-only Dss schema to a NEW private cluster and test M2 → BCB.

Never connects to an existing server. No source/approval data is cloned.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile


# TEST-ONLY mirror of migrations/project1_ai/20261116_02_m2_runtime_role.sql,
# applied to the disposable cluster so the restricted-principal path can be
# exercised against real RLS. The reviewed migration guards on database name
# 'Dss' and is never run here; this block is not a product migration and widens
# no grant beyond that reviewed file.
RUNTIME_ROLE_SQL = """
CREATE ROLE p1_m2_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
GRANT USAGE ON SCHEMA public TO p1_m2_runtime;
GRANT SELECT ON public.m2_instrument_versions, public.m2_item_versions TO p1_m2_runtime;
GRANT SELECT, INSERT, UPDATE ON
  public.m2_assessments,
  public.m2_answer_revisions,
  public.m2_bdj_evaluations,
  public.m2_bdj_findings,
  public.m2_review_events,
  public.m2_confirmation_snapshots,
  public.m2_confirmed_uncertainties,
  public.m2_clarification_events
TO p1_m2_runtime;
GRANT SELECT, INSERT, UPDATE ON
  public.m2_business_contexts,
  public.m2_business_context_builds
TO p1_m2_runtime;
CREATE POLICY owner_scope ON public.m2_assessments
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
      'm2_answer_revisions', 'm2_bdj_evaluations', 'm2_bdj_findings',
      'm2_review_events', 'm2_confirmation_snapshots', 'm2_clarification_events']
  LOOP
    EXECUTE format(
      'CREATE POLICY owner_scope ON public.%I
         USING (assessment_id IN (SELECT id FROM public.m2_assessments))
         WITH CHECK (assessment_id IN (SELECT id FROM public.m2_assessments))', t);
  END LOOP;
END $$;
CREATE POLICY owner_scope ON public.m2_confirmed_uncertainties
  USING (confirmation_id IN (SELECT id FROM public.m2_confirmation_snapshots))
  WITH CHECK (confirmation_id IN (SELECT id FROM public.m2_confirmation_snapshots));
CREATE POLICY owner_scope ON public.m2_business_contexts
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY owner_scope ON public.m2_business_context_builds
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY reference_read ON public.m2_instrument_versions FOR SELECT USING (true);
CREATE POLICY reference_read ON public.m2_item_versions FOR SELECT USING (true);
"""


def main():
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--suite', choices=['regression','current-instrument','cp13-bcb','cp13-v2-prep','confirmation-first','candidate-review','binding-test','bdj-connected','bdj-output'], default='regression')
    parser.add_argument('--select', help='Optional pytest -k selection, recorded with deselected counts.')
    parser.add_argument('--with-candidate-review', action='store_true',
                        help='Apply existing review migration only to the fresh private test database.')
    parser.add_argument('--preserve-synthetic-source', action='store_true',
                        help='Save only the explicitly selected synthetic BDJ lab data for guarded restore.')
    parser.add_argument('--restore-synthetic-source', type=Path,
                        help='Restore a previously guarded synthetic snapshot into this fresh private lab.')
    parser.add_argument('--candidate-port', type=int, default=55441,
                        help='Alternate loopback port for private candidate-review or confirmation-first tests.')
    args = parser.parse_args()
    if args.candidate_port != 55441 and (args.suite not in ('candidate-review', 'confirmation-first', 'bdj-connected', 'bdj-output') or
            not 1024 <= args.candidate_port <= 65535):
        raise SystemExit('An alternate port is limited to the private candidate or confirmation suite.')
    if args.preserve_synthetic_source and (args.suite != 'confirmation-first' or
            args.select != 'test_v101_export_private_synthetic_source'):
        raise SystemExit('Synthetic snapshot requires the exact private BDJ source test.')
    if args.restore_synthetic_source and (args.suite != 'confirmation-first' or
            args.select != 'test_v105_validate_restored_synthetic'):
        raise SystemExit('Synthetic restore requires the exact private restore validation test.')
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    if out == root or root in out.parents: raise SystemExit('Evidence must be outside backend.')
    out.mkdir(parents=True, exist_ok=True)
    binaries = Path(r'C:\Program Files\PostgreSQL\18\bin')
    for name in ('initdb.exe','pg_ctl.exe','psql.exe','pg_dump.exe'):
        if not (binaries/name).is_file(): raise SystemExit('Missing installed PostgreSQL binary: '+name)
    with socket.socket() as probe: probe.bind(('127.0.0.1',args.candidate_port))
    lab = Path(tempfile.mkdtemp(prefix='project1_m2_bcb_'))
    print('NEW private PostgreSQL lab: '+str(lab), flush=True)
    password = secrets.token_urlsafe(32)
    pwfile = lab/'init_password'; pwfile.write_text(password,encoding='ascii')
    env = os.environ.copy()
    env.update(PGHOST='127.0.0.1',PGPORT=str(args.candidate_port),PGUSER='postgres',PGPASSWORD=password,PGDATABASE='postgres')
    started = False
    schema = root/'tests/m2_bcb/fixtures/dss_m2_schema_20261113.sql'
    migration = root/'migrations/m2/20261113_01_confirmed_context_persistence.sql'
    try:
        with (out/'cluster_setup.log').open('w',encoding='utf-8') as log:
            def run(command): subprocess.run(command,env=env,cwd=root,stdout=log,stderr=log,check=True)
            run([str(binaries/'initdb.exe'),'-D',str(lab/'data'),'-U','postgres','--encoding=UTF8',
                '--locale=C','-A','scram-sha-256','--pwfile='+str(pwfile)])
            pwfile.unlink()
            run([str(binaries/'pg_ctl.exe'),'-D',str(lab/'data'),'-l',str(lab/'postgres.log'),
                '-o',f'-h 127.0.0.1 -p {args.candidate_port}','-w','start'])
            started=True
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c','CREATE DATABASE project1_m2_bcb_test'])
            env['PGDATABASE']='project1_m2_bcb_test'
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-f',str(schema)])
            denied = subprocess.run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-f',str(migration)],
                env=env,cwd=root,capture_output=True,text=True)
            (out/'migration_without_receipt.log').write_text(denied.stdout+denied.stderr,encoding='utf-8')
            if denied.returncode == 0: raise RuntimeError('Migration guard did not reject missing receipt.')
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",'-f',str(migration)])
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                 "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                 '-f', str(root/'migrations/m2/20261114_02_research_objective_sources.sql')])
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                 "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                 '-f', str(root/'migrations/m2/20261115_01_candidate_owner_review.sql')])
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                 "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                 '-f', str(root/'migrations/m2/20261115_02_workflow_projection.sql')])
            # Restricted M2 principal + owner policies, test-only (see constant).
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c', RUNTIME_ROLE_SQL])
            if args.suite == 'binding-test':
                run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1',
                     '-f', str(root/'migrations/m2/20261118_05_assessment_binding_links.sql')])
                env['M2_BINDING_TEST'] = '1'
            # The reviewed trigger grant the runtime role needs for any M2 write;
            # it runs once against this fresh cluster, after the role exists.
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                 "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                 '-f', str(root/'migrations/m2/20261117_04_workflow_trigger_grant.sql')])
            # The deferred trigger also reads the workflow views at COMMIT; the
            # reviewed read-scope migration grants and owner-scopes that chain.
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                 "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                 '-f', str(root/'migrations/m2/20261117_05_workflow_view_read_scope.sql')])
            if args.suite == 'candidate-review':
                # The candidate-review test module refuses all database names
                # except this one. It is created only in this private cluster.
                run([str(binaries/'psql.exe'), '-d', 'postgres', '-v', 'ON_ERROR_STOP=1',
                     '-c', 'CREATE DATABASE project1_workflow_tests TEMPLATE project1_m2_bcb_test'])
                run([str(binaries/'psql.exe'), '-d', 'project1_workflow_tests', '-v', 'ON_ERROR_STOP=1', '-c',
                     "SET project1.m2_bcb_migration_target='project1_workflow_tests'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                     '-f', str(root/'migrations/m2/20261118_02_candidate_review_v2.sql')])
            if args.with_candidate_review:
                run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                     "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                     '-f', str(root/'migrations/m2/20261118_02_candidate_review_v2.sql')])
            if args.restore_synthetic_source:
                snapshot = args.restore_synthetic_source.resolve(strict=True)
                if not snapshot.read_text(encoding='utf-8').startswith('-- TEST-ONLY SYNTHETIC DATA. NEVER RESTORE INTO ORIGINAL Dss.'):
                    raise RuntimeError('Synthetic snapshot guard not found.')
                # The fresh private database's freeze triggers otherwise see
                # definitions loaded after assessments as edits. Disable only
                # during restore; the following independent test validates the
                # immutable snapshot and the original triggers remain enabled.
                restore_env = env.copy()
                restore_env['PGOPTIONS'] = '-c session_replication_role=replica'
                subprocess.run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-f',str(snapshot)],
                               env=restore_env,cwd=root,stdout=log,stderr=log,check=True)
            if env.get('PART_TWO_CROSS_APP')=='1':
                run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                    "SET project1.cq_migration_target='project1_m2_bcb_test'; SET project1.cq_migration_receipt='SYNTHETIC-PRIVATE-CROSS-APP-ONLY';",'-f',str(root/'migrations/cq/20261113_01_cq_runtime.sql')])
                run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                    "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                    '-f',str(root/'migrations/m2/20261115_03_workflow_cq_bridge.sql')])
                # Reviewed CQ read scope for the same deferred workflow trigger.
                run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                    "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                    '-f',str(root/'migrations/m2/20261117_06_workflow_cq_read_scope.sql')])
                env.update(CQ_RUNTIME_ENABLED='true',CQ_PRIVATE_CLUSTER=str(lab))
            env.update(DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:{args.candidate_port}/project1_m2_bcb_test',
                M2_DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:{args.candidate_port}/project1_m2_bcb_test',
                M2_EXPECTED_DATABASE='project1_m2_bcb_test',
                M2_BCB_PRIVATE_PORT=str(args.candidate_port),
                ANALYTICS_DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:{args.candidate_port}/project1_m2_bcb_test',
                M2_UPSTREAM_ENABLED='true',M2_BCB_PERSISTENCE_ENABLED='true',
                # 90 is an explicit TEST value for the validity basis, NOT a
                # product rule: the production setting has no default.
                PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS='90',
                PROJECT1_CP07_ENABLED='false',PROJECT1_WORKFLOW_ENABLED=('true' if args.suite in ('bdj-connected','bdj-output') else 'false'),TOKENHARBOR_ENABLED='false',
                PYTHONPATH=str(root/'src')+os.pathsep+str(root),PYTHONIOENCODING='utf-8',
                M2_BCB_PRIVATE_CLUSTER=str(lab),M2_BCB_EVIDENCE=str(out),PYTHONDONTWRITEBYTECODE='1')
            outcome = subprocess.run([sys.executable,'-B','-m','pytest',
                ('tests/m2_bcb/test_g2_bdj_output_connected.py' if args.suite=='bdj-output'
                 else 'tests/m2_bcb/test_g1_bdj_connected.py' if args.suite=='bdj-connected'
                 else 'tests/m2_bcb/test_candidate_revision.py' if args.suite=='candidate-review'
                 else 'tests/m2_bcb/test_bdj_restore.py' if args.restore_synthetic_source
                 else 'tests/m2_bcb/test_confirmation_first.py' if args.suite in ('confirmation-first','binding-test')
                 else 'tests/m2_bcb/test_adopted_m2_v1.py' if args.suite=='current-instrument'
                 else 'tools/cp13_verification/postgres_checks.py' if args.suite=='cp13-bcb'
                 else 'tools/cp13_verification/v2/postgres_source_preparation.py' if args.suite=='cp13-v2-prep'
                 else 'tests/m2_bcb/test_postgres_api.py'),
                '--confcutdir=tests/m2_bcb','-q','--junitxml='+str(out/'pytest.xml'),
                *(['-k',args.select] if args.select else [])],
                env=env,cwd=root,capture_output=True,text=True,encoding='utf-8',
                # CP-06: the suite outgrew the original 240s cap (measured 251.49s and
                # 246.28s on 2026-11-17, timing out three times). Raised to 900s so the
                # runner fails on a real test failure rather than on its own clock. This
                # is the only change made here; no test was skipped, weakened or retried.
                timeout=1200 if env.get('PART_TWO_CROSS_APP')=='1' else 900)
            (out/'pytest.log').write_text(outcome.stdout+outcome.stderr,encoding='utf-8')
            print(outcome.stdout+outcome.stderr,flush=True)
            if (args.suite=='cp13-v2-prep' or args.preserve_synthetic_source) and outcome.returncode==0:
                # Preserve ONLY this new synthetic lab's data for an approved
                # later replay with identical source IDs/fingerprints. Never
                # export original Dss data or credentials.
                snapshot=out/'private_synthetic_data.sql'
                run([str(binaries/'pg_dump.exe'),'--data-only','--no-owner','--no-privileges',
                     '--exclude-table=public.test_bcb_bindings',
                     '--exclude-table=public.assessment_workflow_projection','--file='+str(snapshot)])
                guard="""-- TEST-ONLY SYNTHETIC DATA. NEVER RESTORE INTO ORIGINAL Dss.
DO $$ BEGIN
 IF current_database()<>'project1_m2_bcb_test' OR inet_server_port() IS DISTINCT FROM 55441
 THEN RAISE EXCEPTION 'CP13 fixture restore requires its private database and port'; END IF;
END $$;
"""
                snapshot.write_text(guard+snapshot.read_text(encoding='utf-8'),encoding='utf-8')
            run([str(binaries/'pg_dump.exe'),'--schema-only','--no-owner','--no-privileges','--file='+str(out/'private_schema_after.sql')])
            # Exercise removal only inside the disposable database, after capturing its schema.
            rollback = '''
            BEGIN;
            DO $$ DECLARE t record; BEGIN
              FOR t IN SELECT tgname,tgrelid::regclass AS relation FROM pg_trigger
                       WHERE tgfoid IN ('public.m2_workflow_change()'::regprocedure,to_regprocedure('public.m2_workflow_cq_change()')) LOOP
                EXECUTE format('DROP TRIGGER %I ON %s',t.tgname,t.relation);
              END LOOP;
            END $$;
            DROP FUNCTION public.m2_workflow_change();
            DROP FUNCTION public.refresh_m2_workflow(uuid);
            DROP VIEW public.m2_workflow_summary;
            DROP VIEW public.m2_workflow_campaigns;
            DROP FUNCTION IF EXISTS public.m2_workflow_cq_change();
            DROP TABLE public.assessment_workflow_projection;
            COMMIT;
            SELECT to_regclass('public.assessment_workflow_projection') IS NULL
                   AND to_regclass('public.m2_assessments') IS NOT NULL;
            '''
            check = subprocess.run([str(binaries/'psql.exe'),'-XAt','-v','ON_ERROR_STOP=1','-c',rollback],
                                   env=env,cwd=root,capture_output=True,text=True,check=True)
            (out/'projection_rollback.log').write_text(check.stdout)
            if check.stdout.strip().splitlines()[-1] != 't':
                raise RuntimeError('Isolated projection removal failed.')
            (out/'run.json').write_text(json.dumps({'exit_code':outcome.returncode,'cluster':str(lab),
                'database':'project1_m2_bcb_test','port':args.candidate_port,'source_schema_sha256':hashlib.sha256(schema.read_bytes()).hexdigest(),
                'migration_sha256':hashlib.sha256(migration.read_bytes()).hexdigest(),
                'migration_without_receipt_rejected':True,'live_database_writes':False,
                'data':'explicit synthetic instrument and authority fixtures; actual PostgreSQL persistence',
                'lifespan':'off','production_acceptance':False},indent=2),encoding='utf-8')
            return outcome.returncode
    finally:
        if pwfile.exists(): pwfile.unlink()
        if started:
            subprocess.run([str(binaries/'pg_ctl.exe'),'-D',str(lab/'data'),'-m','fast','-w','stop'],
                env=env,capture_output=True,check=True)
            print('Private cluster stopped; live Dss was not written.',flush=True)


if __name__=='__main__': raise SystemExit(main())
