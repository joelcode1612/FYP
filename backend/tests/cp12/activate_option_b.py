"""Controlled, target-specific CP-12 installation for the local Option B demo.

Requires a just-completed write-paused, restore-tested backup, a stopped local
application, the reviewed SQL hashes, and a fresh locked dependency scan. It
does not delete assessments. The explicit receipt records the bounded configured
inventory, rather than asserting that unknown off-system copies do not exist.
"""
import hashlib
import json
import os
import secrets
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
from psycopg2 import sql
from sqlalchemy.engine import make_url

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'artifacts/cp12_20261118'
sys.path.insert(0, str(ROOT / 'backend/src'))
from sitewise.core.config import Settings

TARGET = 'd45366fd-b360-4d49-867a-8b7858b37e5a'
OWNER = '32ef694a-69b0-4863-a77f-b9cf6c056b56'
EXPECTED = {
    'dss_up.sql': '4bf9544b26f0643f51f634e8cb577a22fff53bafdef0ff93178c82c8111bb7f4',
    'marketplace_up.sql': 'a19ccceec56f1b681be84a5a494b8839e125638e8e1382316a02ee0d174d00e8',
    'dss_down.sql': 'dc619b7186755575ee815cda3a1c91e037d8fcc53b451e9f15e58be0ef38c8da',
    'marketplace_down.sql': 'd629ec9681623883b04946116b5fa96b14651e4d1948d4bb9277d737a037177f',
}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    assert len(sys.argv) == 2, 'Pass the new backup results path explicitly'
    backup_path = Path(sys.argv[1]).resolve()
    assert backup_path.parent.parent == OUT.resolve() and backup_path.name == 'results.json'
    backup = json.loads(backup_path.read_text())
    assert backup['status'] == 'PASS'
    completed = datetime.fromisoformat(backup['completed_utc'])
    assert (datetime.now(timezone.utc) - completed).total_seconds() < 300, 'Backup is not fresh'
    for db in ('Dss', 'Final_Location_Analysis'):
        b = backup['databases'][db]
        archive = Path(b['archive']).resolve()
        assert archive.parent == backup_path.parent and b['effective_relation_acl_match']
        assert archive.is_file() and digest(archive) == b['sha256']
    migration_dir = ROOT / 'backend/migrations/cp12'
    for name, expected in EXPECTED.items():
        assert digest(migration_dir / name) == expected, 'Migration hash changed: ' + name
    assert json.loads((OUT/'activation_orchestration_results.json').read_text())['status'] == 'PASS'
    assert json.loads((OUT/'market_lock_timeout_results.json').read_text())['status'] == 'PASS'
    lock_results = json.loads((OUT/'migration_lock_results.json').read_text())
    assert all(lock_results[k]['status'] == 'PASS' for k in ('marketplace', 'dss'))
    assert not socket.socket().connect_ex(('127.0.0.1', 8090)) == 0, 'Application writer is still listening'
    settings = Settings(_env_file=(ROOT/'backend/.env', ROOT/'backend/.env.local'))
    u = make_url(settings.database_url)
    m = make_url(settings.m2_database_url.get_secret_value())
    assert u.database == 'Final_Location_Analysis' and m.database == 'Dss'
    assert u.host in ('localhost', '127.0.0.1') and (u.host, u.port) == (m.host, m.port)
    assert (u.port or 5432) == 5432
    review = OUT/'option_b_owner_inventory_receipt.json'
    review_data = json.loads(review.read_text())
    assert review_data['target'] == TARGET and review_data['owner'] == OWNER
    for filename, expected in review_data['evidence_files'].items():
        assert digest(OUT / filename) == expected, 'Inventory evidence changed'
    receipt = 'OWNER-OPTION-B-TARGET-ONLY;CONFIGURED-INVENTORY-SHA256=' + digest(review)
    result = {'started_utc': datetime.now(timezone.utc).isoformat(), 'backup': str(backup_path),
              'target': TARGET, 'owner': OWNER, 'inventory_receipt': receipt,
              'scope': 'CONFIGURED_PROJECT1_STORAGE_AND_INTEGRATIONS; UNKNOWN_EXTERNAL_COPIES_NOT_CERTIFIED',
              'migration_hashes': EXPECTED, 'databases': {}, 'status': 'STARTED'}
    output = OUT/'option_b_activation_results.json'
    conns = {}
    installation_started = False
    try:
        for kind, db in (('marketplace', 'Final_Location_Analysis'), ('dss', 'Dss')):
            c = psycopg2.connect(host=u.host, port=u.port or 5432, user=u.username,
                                 password=u.password, dbname=db)
            conns[kind] = c
            with c.cursor() as q:
                q.execute("SET LOCAL lock_timeout='5s'")
                q.execute("SELECT to_regnamespace('cp12') IS NULL")
                assert q.fetchone()[0], db + ' already contains cp12'
                q.execute("SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p') ORDER BY 1,2")
                tables = q.fetchall()
                assert len(tables) == backup['databases'][db]['locked_tables'], 'Physical table inventory changed'
                for schema, table in tables:
                    q.execute(sql.SQL('LOCK TABLE {}.{} IN SHARE MODE').format(sql.Identifier(schema), sql.Identifier(table)))
                matches = {}
                for schema, table in tables:
                    q.execute(sql.SQL('SELECT count(*) FROM {}.{} r WHERE lower(to_jsonb(r)::text) LIKE %s').format(sql.Identifier(schema), sql.Identifier(table)), ('%' + TARGET + '%',))
                    count = q.fetchone()[0]
                    if count:
                        matches[schema+'.'+table] = count
                assert matches == ({'public.assessment': 1} if kind == 'marketplace' else {}), 'New target references found'
                result['databases'][db] = {'locked_tables': len(tables), 'uuid_references': matches}
        # Both write pauses are held. Recheck the exact owner, state and link.
        with conns['marketplace'].cursor() as q:
            q.execute('SELECT user_id,property_id,status,requirements IS NULL,requirements_saved_at IS NULL,evidence_reviewed_at IS NULL,explanation_reviewed_at IS NULL,report_generated_at IS NULL FROM public.assessment WHERE assessment_id=%s', (TARGET,))
            row = q.fetchone()
            assert row and str(row[0]) == OWNER and row[1] == 'MD-02521' and row[2] == 'in_progress' and all(row[3:]), 'Target eligibility changed'
        with conns['dss'].cursor() as q:
            q.execute('SELECT count(*) FROM public.m2_assessment_links WHERE marketplace_assessment_id=%s', (TARGET,))
            assert q.fetchone()[0] == 0, 'Target acquired an M2 link'
        env = {**os.environ, 'PGHOST': u.host, 'PGPORT': str(u.port or 5432),
               'PGUSER': u.username, 'PGPASSWORD': u.password}
        def normalize_schema(raw):
            return b'\n'.join(line for line in raw.replace(b'\r', b'').split(b'\n')
                              if not line.startswith((b'\\restrict ', b'\\unrestrict ')))
        for db in ('Dss', 'Final_Location_Analysis'):
            cmd = [r'C:\Program Files\PostgreSQL\16\bin\pg_dump.exe', '--schema-only', '--no-owner']
            if db == 'Final_Location_Analysis':
                cmd.append('--no-acl')
            cmd.append(db)
            schema = subprocess.run(cmd, env=env, capture_output=True, check=True, timeout=60).stdout
            reference = (OUT/(db+'_schema_current.sql')).read_bytes()
            assert normalize_schema(schema) == normalize_schema(reference), db+' schema differs from tested schema'
            result['databases'][db]['tested_schema_match'] = True
        # Both databases were verified absent before any installation attempt.
        # Scripts commit independently; the application remains stopped.
        installation_started = True
        for kind, db in (('dss','Dss'), ('marketplace','Final_Location_Analysis')):
            with conns[kind].cursor() as q:
                q.execute("SELECT set_config('project1.cp12_migration_target',%s,false)", (db,))
                q.execute("SELECT set_config('project1.cp12_migration_receipt',%s,false)", (receipt,))
                q.execute((migration_dir/(kind+'_up.sql')).read_text(encoding='utf-8'))
            result['databases'][db]['migration'] = 'PASS'
            output.write_text(json.dumps(result, indent=2)+'\n')
        secret = secrets.token_bytes(32)
        for kind, db in (('dss','Dss'), ('marketplace','Final_Location_Analysis')):
            c = conns[kind]
            with c.cursor() as q:
                q.execute('INSERT INTO cp12.handoff_key(secret) VALUES (%s)', (psycopg2.Binary(secret),))
                if kind == 'dss':
                    q.execute('UPDATE cp12.policy SET approved=true, external_references_verified=true, receipt=%s', (receipt,))
                else:
                    q.execute('UPDATE cp12.policy SET approved=true, receipt=%s', (receipt,))
                q.execute('INSERT INTO cp12.target_reviews(assessment_id,owner_id,retention_receipt,external_inventory_receipt) VALUES (%s,%s,%s,%s)', (TARGET, OWNER, receipt, receipt))
            c.commit()
            result['databases'][db]['target_review'] = 'PASS'
        proofs = []
        for kind, db in (('dss','Dss'), ('marketplace','Final_Location_Analysis')):
            with conns[kind].cursor() as q:
                q.execute("SELECT cp12.proof('VERIFY',%s,%s,%s)", (TARGET,TARGET,OWNER))
                proofs.append(q.fetchone()[0])
                q.execute('SELECT count(*) FROM cp12.operations')
                assert q.fetchone()[0] == 0
        assert proofs[0] and proofs[0] == proofs[1], 'Cross-database handoff differs'
        result['status'] = 'PASS'
        result['completed_utc'] = datetime.now(timezone.utc).isoformat()
    except Exception as exc:
        result['status'] = 'FAILED'
        result['error'] = type(exc).__name__ + ': ' + str(exc)
        for c in conns.values():
            c.rollback()
        # Only the reviewed down SQL may run, and only before any operation.
        for kind, db in (('marketplace','Final_Location_Analysis'), ('dss','Dss')) if installation_started else ():
            c = conns.get(kind)
            if not c:
                continue
            try:
                with c.cursor() as q:
                    q.execute("SELECT to_regnamespace('cp12') IS NOT NULL")
                    if q.fetchone()[0]:
                        q.execute('SELECT count(*) FROM cp12.operations')
                        assert q.fetchone()[0] == 0, 'Journal is not empty'
                        q.execute("SELECT set_config('project1.cp12_migration_target',%s,false)", (db,))
                        q.execute("SELECT set_config('project1.cp12_migration_receipt',%s,false)", ('OWNER-OPTION-B-FAILURE-ROLLBACK',))
                        q.execute((migration_dir/(kind+'_down.sql')).read_text(encoding='utf-8'))
                        result['databases'].setdefault(db,{})['failure_rollback'] = 'PASS'
            except Exception as rollback_error:
                c.rollback()
                result['databases'].setdefault(db,{})['failure_rollback'] = 'FAILED: '+type(rollback_error).__name__
        raise
    finally:
        for c in conns.values():
            c.rollback()
            c.close()
        output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'status': result['status'], 'evidence': str(output)}, indent=2))

if __name__ == '__main__':
    main()
