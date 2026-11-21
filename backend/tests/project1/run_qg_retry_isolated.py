r"""Isolated PostgreSQL 18 harness for CP-08 item 6 (QG retry slots).

Starts a NEW private cluster on loopback port 55441 inside a temporary
directory, creates a fresh database, applies the real existing migrations plus
the new retry-slots migration, and drives PostgresAttemptLedger through the
restricted execution principal (p1ai_engine -> SET LOCAL ROLE p1ai_runtime).

No existing database is touched. No DDL or DML is issued against Dss. The
cluster is always stopped, and JSON evidence is written to
<repo>/artifacts/cp08_qg_retry/ whether the run passes or fails.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
from uuid import uuid4


PORT = 55441
DATABASE = 'project1_workflow_tests'
PRIVATE_DB = 'cp08_qg_retry_tests'  # also accepted by the new migration guard


def main():
    root = Path(__file__).resolve().parents[2]          # .../backend
    repo_root = root.parent
    binaries = Path(os.environ.get('CP08_PG_BIN', r'C:\Program Files\PostgreSQL\18\bin'))
    for name in ('initdb.exe', 'pg_ctl.exe', 'psql.exe'):
        if not (binaries / name).is_file():
            raise SystemExit(f'Missing PostgreSQL 18 binary: {binaries / name}')

    with socket.socket() as probe:
        probe.bind(('127.0.0.1', PORT))  # refuse to run if the port is taken

    lab = Path(tempfile.mkdtemp(prefix='cp08_qg_retry_'))
    password = secrets.token_urlsafe(32)
    engine_password = secrets.token_urlsafe(32)
    pwfile = lab / 'init_password'
    pwfile.write_text(password, encoding='ascii')

    env = os.environ.copy()
    env.update(PGPASSWORD=password, PGHOST='127.0.0.1', PGPORT=str(PORT),
               PGUSER='postgres', PGDATABASE='postgres')

    checks = []
    evidence = {}
    error = None
    ok = False
    started = False

    def check(name, passed, detail=''):
        passed = bool(passed)
        checks.append({'name': name, 'ok': passed, 'detail': str(detail)})
        print(f"{'PASS' if passed else 'FAIL'} {name}"
              + (f' :: {detail}' if detail != '' else ''), flush=True)
        if not passed:
            raise AssertionError(f'{name}: {detail}')

    def psql(*args):
        proc = subprocess.run([str(binaries / 'psql.exe'), '-v', 'ON_ERROR_STOP=1', *args],
                              env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f'psql {args} failed: {proc.stderr.strip()}')
        return proc.stdout

    def setting_sql():
        return (f"SET project1.migration_target='{DATABASE}'; "
                "SET project1.migration_receipt='CP08-QG-RETRY-ISOLATED-PRIVATE-LAB-ONLY';")

    try:
        with (lab / 'setup.log').open('w', encoding='utf-8') as log:
            def setup(args):
                subprocess.run(args, env=env, cwd=root, stdout=log,
                               stderr=log, check=True)

            setup([str(binaries / 'initdb.exe'), '-D', str(lab / 'data'), '-U', 'postgres',
                   '--encoding=UTF8', '--locale=C', '-A', 'scram-sha-256',
                   f'--pwfile={pwfile}'])
            pwfile.unlink(missing_ok=True)
            setup([str(binaries / 'pg_ctl.exe'), '-D', str(lab / 'data'),
                   '-l', str(lab / 'postgres.log'), '-o', f'-h 127.0.0.1 -p {PORT}',
                   '-w', 'start'])
            started = True
            psql('-c', f'CREATE DATABASE {DATABASE}')
            # Second private DB, used below to verify the inverse rollback.
            # Its name is the third one the new migration's guard accepts.
            psql('-c', f'CREATE DATABASE {PRIVATE_DB}')
        env['PGDATABASE'] = DATABASE

        # Minimal M2 authority only: the ledger FK needs public.m2_assessments(id).
        psql('-c', 'CREATE TABLE public.m2_assessments (id uuid PRIMARY KEY)')

        migrations = [
            '20261111_01_candidate_ledger.sql',
            '20261117_01_execution_principal.sql',
        ]
        for name in migrations:
            psql('-c', setting_sql(), '-f', str(root / 'migrations/project1_ai' / name))
            print(f'APPLIED {name}', flush=True)

        from sqlalchemy import create_engine, text
        from sqlalchemy.exc import DBAPIError, IntegrityError
        from sitewise.project1.contracts import WorkflowHeld
        from sitewise.project1.ledger import PostgresAttemptLedger

        url = f'postgresql+psycopg2://postgres:{password}@127.0.0.1:{PORT}/{DATABASE}'
        admin = create_engine(url, hide_parameters=True)

        actor, assessment_id, run_id = uuid4(), uuid4(), uuid4()
        with admin.begin() as c:
            c.execute(text('INSERT INTO public.m2_assessments(id) VALUES (:id)'),
                      {'id': assessment_id})
            c.execute(text('INSERT INTO project1_ai.runs '
                '(id,owner_user_id,assessment_id,assessment_revision,'
                'source_fingerprint,policy_fingerprint,work_identity) '
                'VALUES (:r,:o,:a,2,:h,:h,:h)'),
                {'r': run_id, 'o': actor, 'a': assessment_id, 'h': 'b' * 64})

        def constraint_names():
            with admin.connect() as c:
                return set(c.execute(text(
                    "SELECT conname FROM pg_constraint "
                    "WHERE conrelid='project1_ai.attempts'::regclass")).scalars().all())

        before = constraint_names()
        check('legacy_unique_present_before_migration',
              'attempts_run_id_stage_key' in before, sorted(before))

        # Prove the pre-migration schema really did reject a second QG attempt.
        # Both INSERTs happen in one rolled-back transaction, so no evidence
        # row is created or discarded and the later ledger path starts clean.
        with admin.connect() as c:
            tx = c.begin()
            old_rejected, old_detail = False, ''
            try:
                c.execute(text('INSERT INTO project1_ai.attempts '
                    '(run_id,owner_user_id,attempt_no,stage,prompt_version,prompt_hash,request_hash) '
                    "VALUES (:r,:o,1,'QG','QG-PROPOSE-6-CAND',:h,:h)"),
                    {'r': run_id, 'o': actor, 'h': 'c' * 64})
                c.execute(text('INSERT INTO project1_ai.attempts '
                    '(run_id,owner_user_id,attempt_no,stage,prompt_version,prompt_hash,request_hash) '
                    "VALUES (:r,:o,2,'QG','QG-PROPOSE-6-CAND',:h,:h)"),
                    {'r': run_id, 'o': actor, 'h': 'd' * 64})
            except IntegrityError as exc:
                old_rejected, old_detail = True, str(exc.orig)
            finally:
                tx.rollback()
        check('old_schema_rejected_second_qg_attempt',
              old_rejected and 'attempts_run_id_stage_key' in old_detail,
              old_detail.strip())

        # The migration under test.
        psql('-c', setting_sql(), '-f',
             str(root / 'migrations/project1_ai/20261118_03_qg_retry_slots.sql'))
        print('APPLIED 20261118_03_qg_retry_slots.sql', flush=True)

        after = constraint_names()
        check('legacy_unique_removed_after_migration',
              'attempts_run_id_stage_key' not in after, sorted(after))
        check('new_unique_installed', 'attempts_run_stage_slot_key' in after, sorted(after))
        with admin.connect() as c:
            has_slot = c.execute(text(
                "SELECT EXISTS (SELECT 1 FROM information_schema.columns "
                "WHERE table_schema='project1_ai' AND table_name='attempts' "
                "AND column_name='attempt_slot')")).scalar_one()
            versions = c.execute(text(
                'SELECT version FROM project1_ai.schema_versions ORDER BY version')).scalars().all()
        check('attempt_slot_column_present', has_slot)
        check('schema_version_recorded',
              '20261118_03_qg_retry_slots' in versions, list(versions))

        # Restricted execution principal: p1ai_engine with SET LOCAL ROLE.
        psql('-c', f"ALTER ROLE p1ai_engine PASSWORD '{engine_password}'")
        restricted_url = (f'postgresql+psycopg2://p1ai_engine:{engine_password}'
                          f'@127.0.0.1:{PORT}/{DATABASE}')
        restricted = create_engine(restricted_url, hide_parameters=True)
        ledger = PostgresAttemptLedger(restricted, actor, run_id)

        n1 = ledger.reserve('QG', 'QG-PROPOSE-6-CAND', 'a' * 64, '1' * 64, attempt_slot=1)
        ledger.finish(n1, 'returned', '2' * 64)
        check('slot1_attempt_no_is_1', n1 == 1, n1)

        cols = ('run_id,owner_user_id,attempt_no,stage,attempt_slot,prompt_version,'
                'prompt_hash,request_hash,reserved_at')
        with admin.connect() as c:
            first_row = dict(c.execute(text(
                f'SELECT {cols} FROM project1_ai.attempts WHERE run_id=:r'),
                {'r': run_id}).mappings().one())
        attempt1_snapshot = {k: str(v) for k, v in first_row.items()}

        n2 = ledger.reserve('QG', 'QG-PROPOSE-6-CAND', 'a' * 64, '3' * 64, attempt_slot=2)
        ledger.finish(n2, 'returned', '4' * 64)
        check('slot2_attempt_no_is_2', n2 == 2, n2)

        with admin.connect() as c:
            attempts = [dict(r) for r in c.execute(text(
                'SELECT attempt_no,stage,attempt_slot,prompt_hash,request_hash '
                'FROM project1_ai.attempts WHERE run_id=:r ORDER BY attempt_no'),
                {'r': run_id}).mappings().all()]
            receipts = [dict(r) for r in c.execute(text(
                'SELECT attempt_no,outcome,output_digest '
                'FROM project1_ai.attempt_receipts WHERE run_id=:r ORDER BY attempt_no'),
                {'r': run_id}).mappings().all()]
            final_first = dict(c.execute(text(
                f'SELECT {cols} FROM project1_ai.attempts '
                'WHERE run_id=:r AND attempt_no=1'), {'r': run_id}).mappings().one())

        check('two_attempt_rows', len(attempts) == 2, attempts)
        check('attempt_numbers_are_1_and_2',
              [r['attempt_no'] for r in attempts] == [1, 2])
        check('distinct_slots_are_1_and_2',
              [r['attempt_slot'] for r in attempts] == [1, 2])
        check('both_attempts_are_qg', all(r['stage'] == 'QG' for r in attempts))
        check('two_receipts_for_both_attempts',
              len(receipts) == 2 and [r['attempt_no'] for r in receipts] == [1, 2],
              receipts)
        final_snapshot = {k: str(v) for k, v in final_first.items()}
        check('historical_attempt1_unchanged',
              final_snapshot == attempt1_snapshot,
              {'before': attempt1_snapshot, 'after': final_snapshot})

        # Duplicate slot: both the app guard and the DB constraint must refuse.
        try:
            ledger.reserve('QG', 'QG-PROPOSE-6-CAND', 'a' * 64, '5' * 64, attempt_slot=2)
            dup_code = ''
        except WorkflowHeld as exc:
            dup_code = str(exc)
        check('duplicate_slot_refused_by_ledger',
              dup_code == 'MODEL_STAGE_ALREADY_RESERVED', dup_code)

        with admin.connect() as c:
            tx = c.begin()
            dbdup, dbdup_detail = False, ''
            try:
                c.execute(text('INSERT INTO project1_ai.attempts '
                    '(run_id,owner_user_id,attempt_no,stage,attempt_slot,'
                    'prompt_version,prompt_hash,request_hash) '
                    "VALUES (:r,:o,3,'QG',2,:v,:h,:h)"),
                    {'r': run_id, 'o': actor, 'v': 'v', 'h': '6' * 64})
            except IntegrityError as exc:
                dbdup, dbdup_detail = True, str(exc.orig)
            finally:
                tx.rollback()
        check('db_unique_rejects_duplicate_slot',
              dbdup and 'attempts_run_stage_slot_key' in dbdup_detail, dbdup_detail.strip())

        # The immutable_history trigger must still fire for UPDATE and DELETE.
        def mutation_probe(sql):
            with admin.connect() as c:
                tx = c.begin()
                rejected, detail = False, ''
                try:
                    c.execute(text(sql), {'r': run_id})
                except DBAPIError as exc:
                    rejected, detail = True, str(exc.orig)
                finally:
                    tx.rollback()
            return rejected, detail

        upd_ok, upd_detail = mutation_probe(
            'UPDATE project1_ai.attempts SET prompt_version=prompt_version WHERE run_id=:r')
        check('append_only_trigger_rejects_update',
              upd_ok and 'Workflow history is append-only' in upd_detail, upd_detail.strip())
        del_ok, del_detail = mutation_probe(
            'DELETE FROM project1_ai.attempts WHERE run_id=:r')
        check('append_only_trigger_rejects_delete',
              del_ok and 'Workflow history is append-only' in del_detail, del_detail.strip())

        with admin.connect() as c:
            final_count = c.execute(text(
                'SELECT count(*) FROM project1_ai.attempts WHERE run_id=:r'),
                {'r': run_id}).scalar_one()
        check('probe_rollbacks_left_history_intact', final_count == 2, final_count)

        # Verify the inverse rollback in the second private database of this
        # throwaway cluster. Only a minimal post-migration shape is created by
        # hand here; no production object and no existing DB is involved.
        private_url = f'postgresql+psycopg2://postgres:{password}@127.0.0.1:{PORT}/{PRIVATE_DB}'
        private_admin = create_engine(private_url, hide_parameters=True)
        with private_admin.begin() as c:
            c.execute(text('CREATE SCHEMA project1_ai'))
            c.execute(text('CREATE TABLE project1_ai.schema_versions('
                'version text PRIMARY KEY, receipt text NOT NULL, '
                'applied_at timestamptz NOT NULL DEFAULT now())'))
            c.execute(text("INSERT INTO project1_ai.schema_versions(version,receipt) "
                "VALUES ('20261118_03_qg_retry_slots','rollback-check')"))
            c.execute(text('CREATE TABLE project1_ai.attempts('
                'run_id uuid NOT NULL, owner_user_id uuid NOT NULL, '
                'attempt_no integer NOT NULL CHECK (attempt_no BETWEEN 1 AND 6), '
                "stage text NOT NULL CHECK (stage IN ('BDJ','QJ','QG')), "
                'prompt_version text NOT NULL, prompt_hash text NOT NULL, '
                'request_hash text NOT NULL, '
                'reserved_at timestamptz NOT NULL DEFAULT now(), '
                'attempt_slot integer NOT NULL DEFAULT 1 CHECK (attempt_slot BETWEEN 1 AND 3), '
                'PRIMARY KEY(run_id,attempt_no), '
                'UNIQUE(run_id,owner_user_id,attempt_no), '
                'CONSTRAINT attempts_run_stage_slot_key UNIQUE(run_id,stage,attempt_slot))'))
        saved_db = env['PGDATABASE']
        env['PGDATABASE'] = PRIVATE_DB
        try:
            psql('-c', (f"SET project1.migration_target='{PRIVATE_DB}'; "
                        "SET project1.migration_receipt='CP08-ROLLBACK-CHECK-ONLY';"),
                 '-f', str(root / 'migrations/project1_ai'
                           / '20261118_03_qg_retry_slots_rollback.sql'))
            print('APPLIED 20261118_03_qg_retry_slots_rollback.sql', flush=True)
        finally:
            env['PGDATABASE'] = saved_db
        with private_admin.connect() as c:
            rb_names = set(c.execute(text(
                "SELECT conname FROM pg_constraint "
                "WHERE conrelid='project1_ai.attempts'::regclass")).scalars().all())
            rb_slot = c.execute(text(
                "SELECT EXISTS (SELECT 1 FROM information_schema.columns "
                "WHERE table_schema='project1_ai' AND table_name='attempts' "
                "AND column_name='attempt_slot')")).scalar_one()
            rb_versions = c.execute(text(
                'SELECT version FROM project1_ai.schema_versions')).scalars().all()
        check('rollback_restores_legacy_unique',
              'attempts_run_id_stage_key' in rb_names, sorted(rb_names))
        check('rollback_drops_new_unique',
              'attempts_run_stage_slot_key' not in rb_names, sorted(rb_names))
        check('rollback_drops_slot_column', not rb_slot)
        check('rollback_removes_schema_version',
              '20261118_03_qg_retry_slots' not in rb_versions, list(rb_versions))
        private_admin.dispose()

        restricted.dispose()
        admin.dispose()

        evidence = {
            'classification': 'PRIVATE_SYNTHETIC_ONLY',
            'not_live': True,
            'directive': 'CP-08 item 6 - QG retry slots',
            'generated_at': datetime.now(timezone.utc).isoformat(),
            'cluster': {'binaries': str(binaries), 'port': PORT, 'temp_dir': str(lab),
                        'database': DATABASE, 'additional_private_database': PRIVATE_DB,
                        'fresh_cluster': True},
            'migrations_applied': migrations + ['20261118_03_qg_retry_slots.sql'],
            'constraints_before': sorted(before),
            'constraints_after': sorted(after),
            'pre_migration_second_qg_insert': {'rejected': old_rejected,
                                               'detail': old_detail.strip()},
            'run_id': str(run_id),
            'actor_id': str(actor),
            'attempts': [{k: str(v) for k, v in r.items()} for r in attempts],
            'receipts': [{k: str(v) for k, v in r.items()} for r in receipts],
            'rollback_verified_in': PRIVATE_DB,
            'checks': checks,
        }
        ok = all(c['ok'] for c in checks)
    except Exception as exc:  # evidence and cluster shutdown still happen
        error = f'{type(exc).__name__}: {exc}'
        print('ERROR ' + error, flush=True)
    finally:
        pwfile.unlink(missing_ok=True)
        if started:
            try:
                with (lab / 'stop.log').open('w', encoding='utf-8') as log:
                    subprocess.run([str(binaries / 'pg_ctl.exe'), '-D', str(lab / 'data'),
                                    '-m', 'fast', '-w', 'stop'], env=env, cwd=root,
                                   stdout=log, stderr=log, check=True)
                print(f'STOPPED private cluster on port {PORT}', flush=True)
            except Exception as exc:
                print(f'ERROR stopping cluster: {exc}', flush=True)
                ok = False

        evidence.setdefault('classification', 'PRIVATE_SYNTHETIC_ONLY')
        evidence.setdefault('not_live', True)
        evidence['generated_at'] = datetime.now(timezone.utc).isoformat()
        evidence['error'] = error
        evidence['checks'] = checks
        evidence['ok'] = ok and error is None
        out_dir = repo_root / 'artifacts' / 'cp08_qg_retry'
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file = out_dir / 'qg_retry_slots_evidence.json'
        out_file.write_text(json.dumps(evidence, indent=2, default=str), encoding='utf-8')
        print(f'EVIDENCE {out_file}', flush=True)
        print(f'RESULT {"PASS" if evidence["ok"] else "FAIL"} '
              f'({sum(c["ok"] for c in checks)}/{len(checks)} checks)', flush=True)

    return 0 if ok and error is None else 1


if __name__ == '__main__':
    raise SystemExit(main())
