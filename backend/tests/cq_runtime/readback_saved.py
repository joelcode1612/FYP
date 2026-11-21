"""Re-open a saved private test cluster, execute delivered read-only SQL, stop it.

Usage: backend/.venv/Scripts/python.exe backend/tests/cq_runtime/readback_saved.py EVIDENCE_DIRECTORY
Never opens Dss or another existing database. Password stays in a private
environment variable and is never printed or passed on the command line.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys


def main():
    out = Path(sys.argv[1]).resolve()
    cfg = json.loads((out/'private_pg_connection.json').read_text())
    row = json.loads((out/'ee01_readback.json').read_text())['current']
    assert (cfg['host'],cfg['port'],cfg['database'],cfg['role']) == (
        '127.0.0.1',55443,'project1_cq_runtime_test','p1_ee01_runtime')
    cluster = Path(cfg['cluster']).resolve()
    assert cluster.parent == Path(os.environ['TEMP']).resolve() and cluster.name.startswith('project1_cq_runtime_')
    assert row['scope'] == 'ISOLATED_TEST'
    binaries = Path(cfg.get('postgres_bin',r'C:\Program Files\PostgreSQL\18\bin')).resolve()
    assert binaries in (Path(r'C:\Program Files\PostgreSQL\16\bin'),Path(r'C:\Program Files\PostgreSQL\18\bin'))
    control = [str(binaries/'pg_ctl.exe'),'-D',str(cluster/'data')]
    status = subprocess.run([*control,'status'],capture_output=True)
    assert status.returncode in (0,3)
    started = status.returncode == 3
    if started:
        with socket.socket() as probe: probe.bind(('127.0.0.1',55443))
        # Windows daemon children can inherit PIPE handles and prevent
        # communicate() from finishing even after pg_ctl exits. Use a file.
        with (out/'readback_control.log').open('a',encoding='utf-8') as log:
            # Read-only replay needs few connections; keep the private instance
            # small on the owner's resource-constrained Windows machine.
            subprocess.run([*control,'-l',str(cluster/'readback.log'),'-o',
                           '-h 127.0.0.1 -p 55443 -c shared_buffers=16MB -c work_mem=1MB '
                           '-c maintenance_work_mem=16MB -c max_connections=12 '
                           '-c max_worker_processes=0 -c autovacuum=off','-w','start'],
                           check=True,stdout=log,stderr=subprocess.STDOUT)
    env = {**os.environ,'PGHOST':cfg['host'],'PGPORT':str(cfg['port']),
           'PGDATABASE':cfg['database'],'PGUSER':cfg['role'],'PGPASSWORD':cfg['password']}
    try:
        for name in ('VERIFY_EE01_SCHEMA','VERIFY_EE01_AGGREGATES','VERIFY_CQ_TO_REPORT_LINEAGE','VERIFY_EE01_FROM_CQ'):
            args = [str(binaries/'psql.exe'),'-X','-v','ON_ERROR_STOP=1',
                    '-v','actor_id='+row['owner_user_id'],'-v','assessment_id='+row['assessment_id'],
                    '-v','campaign_id='+row['campaign_id'],'-v','snapshot_id='+row['id'],
                    '-f',str(Path(__file__).parent/(name+'.sql'))]
            result = subprocess.run(args,env=env,capture_output=True,text=True,encoding='utf-8')
            (out/(name+'_manual_replay.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
            if result.returncode: raise RuntimeError(name+' failed; inspect the saved log.')
            if name=='VERIFY_EE01_FROM_CQ':
                oracle=[json.loads(line) for line in result.stdout.splitlines() if line.strip().startswith('{')]
                assert len(oracle)==1 and oracle[0]['matches_saved_counts'] is True
                (out/'independent_raw_CQ_oracle.json').write_text(json.dumps(oracle[0],indent=2),encoding='utf-8')
            print(name+': PASS; output '+str(out/(name+'_manual_replay.log')))
        lineage=out/'connected_persistence_lineage.json'
        if lineage.is_file() and (out/'private_cq_connection.json').is_file():
            admin=json.loads((out/'private_cq_connection.json').read_text())
            assert (admin['host'],admin['port'],admin['database'],admin['cluster'],admin['role'],admin['verification_read_only']) == (
                cfg['host'],cfg['port'],cfg['database'],cfg['cluster'],'postgres',True)
            saved=json.loads(lineage.read_text())
            read_env={**env,'PGUSER':admin['role'],'PGPASSWORD':admin['password'],
                      'PGOPTIONS':'-c default_transaction_read_only=on'}
            command=[str(binaries/'psql.exe'),'-X','-v','ON_ERROR_STOP=1',
                '-v','actor_id='+saved['campaign']['owner_user_id'],
                '-v','assessment_id='+saved['campaign']['assessment_id'],
                '-v','campaign_id='+saved['session']['campaign_id'],
                '-v','session_id='+saved['session']['session_id'],
                '-f',str(Path(__file__).parent/'VERIFY_CQ_PERSISTENCE.sql')]
            result=subprocess.run(command,env=read_env,capture_output=True,text=True,encoding='utf-8')
            (out/'VERIFY_CQ_PERSISTENCE_manual_replay.log').write_text(result.stdout+result.stderr,encoding='utf-8')
            if result.returncode:raise RuntimeError('CQ persistence SQL failed; inspect saved log.')
            print('VERIFY_CQ_PERSISTENCE: PASS (private administrative connection, READ ONLY)')
    finally:
        if started:
            with (out/'readback_control.log').open('a',encoding='utf-8') as log:
                subprocess.run([*control,'-m','fast','-w','stop'],check=True,stdout=log,stderr=subprocess.STDOUT)


if __name__ == '__main__': main()
