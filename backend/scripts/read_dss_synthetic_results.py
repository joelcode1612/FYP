"""Read-only actual Dss verification; never creates/migrates/replays a cluster."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from uuid import UUID
from import_mock_to_dss import ROOT,configured_urls,readback


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run-id',type=UUID,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();admin,app=configured_urls();readback(admin,app,a.run_id,a.output)
    binary=Path(r'C:\Program Files\PostgreSQL\16\bin\psql.exe')
    env={**os.environ,'PGHOST':admin.host,'PGPORT':str(admin.port or 5432),
         'PGUSER':admin.username,'PGPASSWORD':admin.password,'PGDATABASE':'Dss',
         'PGOPTIONS':'-c default_transaction_read_only=on -c statement_timeout=60000'}
    results={}
    for name in ('VERIFY_DSS_SYNTHETIC_PERSISTENCE','VERIFY_DSS_EE01_AGGREGATES','VERIFY_DSS_EE01_RAW_ORACLE','VERIFY_DSS_SYNTHETIC_INTERACTIVE'):
        result=subprocess.run([str(binary),'-X','-v','ON_ERROR_STOP=1','-v','run_id='+str(a.run_id),
            '-f',str(ROOT/'tests/cq_runtime'/(name+'.sql'))],env=env,capture_output=True,text=True,encoding='utf-8')
        (a.output/(name+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
        results[name]=result.returncode
        if name=='VERIFY_DSS_EE01_RAW_ORACLE' and result.returncode==0:
            rows=[json.loads(line) for line in result.stdout.splitlines() if line.strip().startswith('{')]
            (a.output/'independent_Dss_CQ_oracles.json').write_text(json.dumps(rows,indent=2))
            if len(rows)!=3 or not all(r['matches_saved_counts'] for r in rows):results[name]=1
    (a.output/'sql_exit_codes.json').write_text(json.dumps(results,indent=2))
    print(json.dumps(results));raise SystemExit(0 if all(v==0 for v in results.values()) else 1)


if __name__=='__main__':main()
