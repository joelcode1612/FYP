"""Read-only, schema-only Dss export and non-disclosing preservation evidence."""
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess

import psycopg2
from psycopg2 import sql
from dotenv import dotenv_values
from sqlalchemy.engine import make_url


class DssSchemaCapture:
    def __init__(self, backend, output, binaries):
        config = {**dotenv_values(backend/'.env'), **dotenv_values(backend/'.env.local')}
        raw = os.environ.get('M2_DATABASE_URL') or config.get('M2_DATABASE_URL')
        if not raw:
            raise RuntimeError('Dedicated M2_DATABASE_URL required; no analytics fallback.')
        self.url = make_url(raw)
        if (self.url.drivername != 'postgresql+psycopg2' or self.url.database != 'Dss'
                or self.url.host not in ('127.0.0.1','localhost','::1')):
            raise RuntimeError('Read-only source must be the verified local Dss target.')
        self.output, self.binaries = output, binaries

    def inspect(self):
        u = self.url
        with psycopg2.connect(host=u.host,port=u.port or 5432,dbname=u.database,user=u.username,
                              password=u.password,options='-c default_transaction_read_only=on') as conn:
            with conn.cursor() as c:
                c.execute('SELECT current_database(),version(),current_setting(\'transaction_read_only\')')
                identity = c.fetchone()
                assert identity[0] == 'Dss' and identity[2] == 'on'
                c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
                names = [r[0] for r in c.fetchall()]
                contents = {}
                for name in names:
                    # Never return original record values or credentials.
                    c.execute(sql.SQL("SELECT count(*),md5(coalesce(string_agg(md5(t::text),'' ORDER BY md5(t::text)),'')) FROM public.{} t").format(sql.Identifier(name)))
                    count, fingerprint = c.fetchone()
                    contents[name] = {'count':count,'content_fingerprint':fingerprint}
                c.execute("SELECT DISTINCT unnest(roles)::text FROM pg_policies WHERE schemaname='public' ORDER BY 1")
                roles = [r[0] for r in c.fetchall() if r[0] not in ('public','postgres')]
                physical = physical_definition(c)
        return {'database':'Dss','host':u.host,'port':u.port or 5432,'driver':u.drivername,
                'server_version':identity[1],'read_only':True,'contents':contents,
                'policy_roles':roles,'physical':physical}

    def export(self):
        before = self.inspect()
        u = self.url
        schema = self.output/'current_Dss_schema.sql'
        env = {**os.environ,'PGHOST':u.host,'PGPORT':str(u.port or 5432),'PGDATABASE':'Dss',
               'PGUSER':u.username,'PGPASSWORD':u.password,'PGOPTIONS':'-c default_transaction_read_only=on'}
        result = subprocess.run([str(self.binaries/'pg_dump.exe'),'--schema-only','--no-owner',
                '--no-privileges','--lock-wait-timeout=5s','--file='+str(schema)],
                env=env,capture_output=True,text=True,encoding='utf-8')
        (self.output/'source_schema_export.log').write_text(result.stderr,encoding='utf-8')
        if result.returncode:
            raise RuntimeError('Read-only Dss schema export failed; inspect source_schema_export.log.')
        before.update(schema_sha256=hashlib.sha256(schema.read_bytes()).hexdigest(),cloned_records=0)
        (self.output/'Dss_source_before.json').write_text(json.dumps(before,indent=2),encoding='utf-8')
        return schema,before

    def verify_unchanged(self, before):
        after = self.inspect()
        after['schema_and_records_unchanged'] = (after['contents']==before['contents'] and after['physical']==before['physical'])
        after['source_writes_performed_by_runner'] = False
        (self.output/'Dss_source_after.json').write_text(json.dumps(after,indent=2),encoding='utf-8')
        if not after['schema_and_records_unchanged']:
            raise RuntimeError('Dss changed during verification; do not overwrite concurrent user changes.')


def physical_definition(cursor):
    """Portable PostgreSQL 16/18 structural comparison; excludes auto NOT NULL constraints."""
    cursor.execute("SELECT table_name,column_name,data_type,udt_name,is_nullable,column_default,ordinal_position "
                   "FROM information_schema.columns WHERE table_schema='public' ORDER BY table_name,ordinal_position")
    columns = [list(r) for r in cursor.fetchall()]
    cursor.execute("SELECT t.relname,c.conname,c.contype,pg_get_constraintdef(c.oid) FROM pg_constraint c "
                   "JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace "
                   "WHERE n.nspname='public' AND c.contype IN ('p','f','u','c','x') ORDER BY 1,2")
    constraints = [list(r) for r in cursor.fetchall()]
    cursor.execute("SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY 1,2")
    indexes = [list(r) for r in cursor.fetchall()]
    return {'columns':columns,'constraints':constraints,'indexes':indexes}


def comparable_physical(physical):
    """Normalize only literal varchar[] -> text[] deparse expansion on restore.

    Keep all other casts, expressions, identifiers, literal codes and their
    order. This is not a general SQL whitespace/cast stripping operation.
    """
    result=json.loads(json.dumps(physical))
    literal=r"'(?:''|[^'])*'"
    array=r'\(ARRAY\[((?:'+literal+r'::character varying)(?:, '+literal+r'::character varying)*)\]\)::text\[\]'
    for row in result['constraints']:
        expression=row[3]
        expression=re.sub(array,lambda m:'ARRAY['+m[1].replace('::character varying','::text')+']',expression)
        expression=re.sub(r'\(('+literal+r')::character varying\)::text',lambda m:m[1]+'::text',expression)
        row[3]=expression
    return result
