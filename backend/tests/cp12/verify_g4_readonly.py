"""Compare archived pre-demo COPY data with live read-only database snapshots.

No restores, cluster starts, sequence updates, DDL or DML are executed. Secrets
from new CP12 tables are excluded. Full row multisets include duplicates.
"""
import collections, hashlib, io, json, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
import psycopg2
from psycopg2 import sql
from sqlalchemy.engine import make_url

ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'artifacts/cp12_20261118'
BASE=OUT/'write_paused_backup_20261119_023414'
sys.path.insert(0,str(ROOT/'backend/src'))
from sitewise.core.config import Settings

def sha(raw): return hashlib.sha256(raw).hexdigest()
def multihash(rows): return sha('\n'.join(sorted(rows.elements())).encode())
def parse_dump(raw):
    tables={}; lines=iter(raw.decode('utf-8').splitlines())
    for line in lines:
        match=re.fullmatch(r'COPY (\S+) \((.*)\) FROM stdin;',line)
        if not match: continue
        rows=[]
        for row in lines:
            if row=='\\.': break
            rows.append(row)
        name,cols=match.groups()
        assert name not in tables, 'Duplicate COPY table'
        tables[name]=(cols,collections.Counter(rows))
    return tables
def record(cols,row):
    values=row.split('\t'); names=[x.strip().strip('"') for x in cols.split(',')]
    assert len(values)==len(names)
    secret=re.compile(r'password|secret|token|credential|cookie',re.I)
    return {k:('[REDACTED]' if secret.search(k) else None if v=='\\N' else v) for k,v in zip(names,values)}

def main():
    manifest=json.loads((BASE/'results.json').read_text());assert manifest['status']=='PASS'
    settings=Settings(_env_file=(ROOT/'backend/.env',ROOT/'backend/.env.local'))
    u=make_url(settings.database_url)
    assert u.database=='Final_Location_Analysis' and u.host in ('localhost','127.0.0.1') and (u.port or 5432)==5432
    result={'observed_utc':datetime.now(timezone.utc).isoformat(),'mode':'READ_ONLY_NO_RESTORE_NO_DATABASE_WRITES',
            'baseline':str(BASE/'results.json'),'baseline_utc':manifest['completed_utc'],
            'snapshot_scope':'Repeatable read per database; independent databases, no distributed current snapshot', 'databases':{}}
    for db in ('Final_Location_Analysis','Dss'):
        archive=BASE/(db+'.dump');assert sha(archive.read_bytes())==manifest['databases'][db]['sha256']
        dump=subprocess.run([r'C:\Program Files\PostgreSQL\16\bin\pg_restore.exe','--data-only','--file=-',str(archive)],capture_output=True,check=True)
        before=parse_dump(dump.stdout)
        c=psycopg2.connect(host=u.host,port=u.port or 5432,user=u.username,password=u.password,dbname=db,
                          options='-c default_transaction_read_only=on -c statement_timeout=60000')
        c.set_session(readonly=True,isolation_level='REPEATABLE READ')
        info={'archive_sha256':sha(archive.read_bytes()),'tables':{},'differences':[], 'sequence_differences':[], 'sequences_checked':0}
        try:
            with c.cursor() as q:
                q.execute("SELECT current_database(),current_user,current_setting('transaction_read_only')")
                info['identity']=dict(zip(('database','role','read_only'),q.fetchone()))
                q.execute("SET LOCAL timezone='Asia/Kuala_Lumpur'")
                q.execute("SET LOCAL datestyle='ISO, MDY'")
                q.execute("SET LOCAL extra_float_digits=3")
                q.execute("SET LOCAL bytea_output='hex'")
                q.execute("SELECT quote_ident(n.nspname)||'.'||quote_ident(p.relname) FROM pg_class p JOIN pg_namespace n ON n.oid=p.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%' AND p.relkind IN ('r','p') ORDER BY 1")
                current_tables=set(x[0] for x in q.fetchall())
                info['missing_tables']=sorted(set(before)-current_tables)
                info['new_tables']=sorted(current_tables-set(before))
                for sequence,value,called in re.findall(r"SELECT pg_catalog.setval\('([^']+)', (\d+), (true|false)\);",dump.stdout.decode('utf8')):
                    q.execute('SELECT last_value,is_called FROM '+sequence)
                    current=q.fetchone(); previous=(int(value),called=='true')
                    info['sequences_checked']+=1
                    if current!=previous:
                        info['sequence_differences'].append({'sequence':sequence,'before':previous,'after':current})
                for name,(cols,old) in before.items():
                    if name not in current_tables:continue
                    q.execute("SELECT attname FROM pg_attribute WHERE attrelid=%s::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='' ORDER BY attnum",(name,))
                    assert [r[0] for r in q.fetchall()]==[x.strip().strip('"') for x in cols.split(',')], 'Column inventory changed: '+name
                    buf=io.StringIO()
                    # Table and column identifiers originate from the verified archive.
                    q.copy_expert('COPY (SELECT '+cols+' FROM '+name+') TO STDOUT',buf)
                    new=collections.Counter(buf.getvalue().splitlines())
                    removed=old-new;added=new-old
                    info['tables'][name]={'before_count':sum(old.values()),'after_count':sum(new.values()),
                        'before_sha256':multihash(old),'after_sha256':multihash(new),'unchanged':old==new}
                    if removed or added:
                        info['differences'].append({'table':name,
                          'removed':[record(cols,row) for row in removed.elements()],
                          'added':[record(cols,row) for row in added.elements()]})
                # Record only non-secret journal and review metadata for new schema.
                q.execute('SELECT assessment_id::text,owner_id::text,phase,created_at,completed_at FROM cp12.operations ORDER BY created_at')
                info['deletion_journals']=[dict(zip(('assessment_id','owner_id','phase','created_at','completed_at'),r)) for r in q.fetchall()]
                q.execute('SELECT assessment_id::text,owner_id::text,retention_receipt,external_inventory_receipt FROM cp12.target_reviews ORDER BY assessment_id')
                info['target_reviews']=[dict(zip(('assessment_id','owner_id','retention_receipt','external_inventory_receipt'),r)) for r in q.fetchall()]
        finally:c.rollback();c.close()
        info['baseline_tables']=len(before)
        info['unchanged_tables']=sum(t['unchanged'] for t in info['tables'].values())
        result['databases'][db]=info
    (OUT/'g4_full_table_comparison.json').write_text(json.dumps(result,indent=2,default=str)+'\n',encoding='utf8')
    print(json.dumps({db:{'baseline_tables':d['baseline_tables'],'unchanged_tables':d['unchanged_tables'],
        'changed_tables':[v['table'] for v in d['differences']],'missing_tables':d['missing_tables'],'new_tables':d['new_tables']} for db,d in result['databases'].items()},indent=2))

if __name__=='__main__':main()
