"""Read-only report audit. Writes evidence files only, never application data."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import traceback
from uuid import UUID

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'backend/src'))
import psycopg2
from psycopg2.extras import RealDictCursor
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlmodel import Session
from sitewise.core.config import settings

OWNER = UUID('32ef694a-69b0-4863-a77f-b9cf6c056b56')
IDS = ['ad723b3f-5937-44f3-bb94-3d0f3048c034', 'ffa8c0a3-fcd9-4e12-afa1-b7ce6392cc1b']
FILES = [
 'fyp_jaspr_web/lib/pages/entrepreneur/assessment_report_view.dart',
 'fyp_jaspr_web/lib/pages/entrepreneur/assessment_workspace_page.dart',
 'fyp_jaspr_web/lib/data/assessment_report.dart', 'fyp_jaspr_web/lib/data/assessment_api.dart',
 'fyp_jaspr_web/lib/pages/entrepreneur/report_template_sections.dart',
 'fyp_jaspr_web/lib/pages/entrepreneur/report_activity_views.dart',
 'backend/src/sitewise/api/v1/assessments.py', 'backend/src/sitewise/api/v1/reports.py',
 'backend/src/sitewise/services/report_service.py',
 'backend/src/sitewise/services/assessment_service.py',
 'backend/src/sitewise/services/explanation_service.py',
 'backend/src/sitewise/repositories/catalog_repository.py',
 'backend/src/sitewise/repositories/fyp_property_repository.py',
 'backend/src/sitewise/services/project1_read_service.py',
]

def dump(name, data):
    (OUT / name).write_text(json.dumps(data, indent=2, default=str, ensure_ascii=False), encoding='utf-8')

def read(c, sql, params=None):
    with c.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(sql, params or ())
        return [dict(v) for v in cur.fetchall()]

def connect(raw):
    u = make_url(raw)
    return psycopg2.connect(host=u.host, port=u.port or 5432, dbname=u.database,
        user=u.username, password=u.password, connect_timeout=8,
        options='-c default_transaction_read_only=on -c statement_timeout=15000')

def error(exc):
    original = getattr(exc, 'orig', exc)
    diag = getattr(original, 'diag', None)
    return {'type': type(exc).__name__, 'sqlstate': getattr(original, 'pgcode', None),
        'primary': getattr(diag, 'message_primary', None) or str(exc).split('\n')[0],
        'statement': getattr(exc, 'statement', None),
        'frames': [{'file': str(Path(f.filename).relative_to(ROOT)) if Path(f.filename).is_relative_to(ROOT) else Path(f.filename).name,
                    'line': f.lineno, 'function': f.name} for f in traceback.extract_tb(exc.__traceback__)]}

def snapshot(label):
    result = {'captured_at': datetime.now(timezone.utc).isoformat(), 'mode': 'READ ONLY', 'sources': []}
    for f in FILES:
        p = ROOT / f
        result['sources'].append({'path': f, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
    for name, raw in [('app', settings.database_url), ('analytics', settings.analytics_database_url),
                      ('m2', settings.m2_database_url.get_secret_value())]:
        c = connect(raw)
        try:
            data = {'identity': read(c, "SELECT current_database() AS database,current_user AS role,current_setting('transaction_read_only') AS read_only")}
            data['relations'] = read(c, "SELECT table_schema,table_name FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema') AND (table_name ~* '(report|admission|explan|evidence|claim|assessment|subject_features|cq_campaign|ee01_|business_context|confirmation|catalogue_properties|property_population)') ORDER BY 1,2")
            if name == 'app':
                data['assessments'] = read(c, 'SELECT * FROM public.assessment WHERE assessment_id=ANY(%s::uuid[]) ORDER BY assessment_id', (IDS,))
                # Hash the existing identity row without exporting personal fields.
                rows = read(c, "SELECT to_jsonb(u) AS row FROM public.\"user\" u WHERE user_id=%s", (str(OWNER),))
                data['existing_user_row_hash'] = hashlib.sha256(json.dumps(rows, sort_keys=True, default=str).encode()).hexdigest()
            if name == 'analytics':
                data['columns'] = read(c, "SELECT table_schema,table_name,column_name,data_type FROM information_schema.columns WHERE (table_schema='sitewise_analytics' AND table_name='subject_features') OR (table_schema='fyp' AND table_name='catalogue_properties') ORDER BY table_schema,table_name,ordinal_position")
                for table, key, value in [('fyp.catalogue_properties', 'id', 'MD-02521'), ('fyp.catalogue_properties', 'id', 'MD-01965'),
                                           ('sitewise_analytics.subject_features', 'canonical_property_id', 'MD-02521'), ('sitewise_analytics.subject_features', 'canonical_property_id', 'MD-01965')]:
                    data.setdefault('selected_rows', []).append({'table': table, 'key': value,
                        'rows': read(c, f'SELECT * FROM {table} WHERE {key}=%s', (value,))})
            if name == 'm2':
                read(c, "SELECT set_config('project1.actor_id',%s,true)", (str(OWNER),))
                data['links'] = read(c, 'SELECT * FROM m2_assessment_links WHERE marketplace_assessment_id=ANY(%s::uuid[]) ORDER BY marketplace_assessment_id', (IDS,))
                mids = [str(v['m2_assessment_id']) for v in data['links'] if v.get('revoked_at') is None]
                data['assessments'] = read(c, 'SELECT id,owner_user_id,revision,confirmed_revision,instrument_id FROM m2_assessments WHERE id=ANY(%s::uuid[]) ORDER BY id', (mids,))
                data['confirmations'] = read(c, "SELECT id,assessment_id,assessment_revision,snapshot_digest,snapshot_json->>'snapshot_contract_version' AS contract FROM m2_confirmation_snapshots WHERE assessment_id=ANY(%s::uuid[]) ORDER BY assessment_id,assessment_revision", (mids,))
                data['columns'] = read(c, "SELECT table_schema,table_name,column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name ~* '(cq_campaign|ee01_|report|admission|business_context|research_objective)' ORDER BY table_name,ordinal_position")
            result[name] = data
        except Exception as exc:
            result[name] = {'error': error(exc)}
        finally:
            c.rollback()
            c.close()
    dump(f'db_{label}.json', result)
    return result

def report_reads():
    from sitewise.services.assessment_service import AssessmentService
    from sitewise.services.report_service import ReportService, requirement_matching
    from sitewise.services.explanation_service import ExplanationService
    from sitewise.repositories.catalog_repository import CatalogRepository
    output = {'mode': 'DIRECT EXISTING SERVICES, READ-ONLY DATABASE TRANSACTIONS; NOT AUTHENTICATED HTTP', 'records': []}
    engines = [create_engine(raw, connect_args={'options': '-c default_transaction_read_only=on -c statement_timeout=15000'}, hide_parameters=True)
               for raw in [settings.database_url, settings.analytics_database_url]]
    try:
        for aid in IDS:
            one = {'assessment_id': aid, 'steps': []}
            with Session(engines[0]) as app, Session(engines[1]) as analytics:
                service = AssessmentService(app, analytics)
                try:
                    assessment = service.get_owned(UUID(aid), OWNER)
                    one['steps'].append({'operation': 'get_owned', 'result': 'PASS', 'property_id': assessment.property_id})
                    record = service.payload(assessment)
                    one['assessment_payload'] = record
                    one['steps'].append({'operation': 'assessment payload', 'result': 'PASS'})
                    property_report = ReportService(app).generate_property_report(assessment.property_id)
                    one['property_report'] = property_report
                    one['steps'].append({'operation': 'property report', 'result': 'PASS'})
                    evidence = CatalogRepository(analytics).get_evidence(assessment.property_id)
                    one['evidence'] = evidence
                    one['steps'].append({'operation': 'catalogue evidence', 'result': 'PASS'})
                    explanation = ExplanationService(app, analytics).latest_for_assessment(assessment)
                    one['explanation'] = explanation
                    one['steps'].append({'operation': 'persisted explanation read', 'result': 'PASS', 'present': explanation is not None})
                    report = ReportService(app).generate_assessment_report(assessment=record,
                        property_report=property_report, explanation=explanation, evidence=evidence)
                    one['report'] = report
                    repeated = ReportService(app).generate_assessment_report(assessment=record,
                        property_report=property_report, explanation=explanation, evidence=evidence)
                    normalized = lambda r: {k: v for k, v in r.items() if k != 'generated_at'}
                    one['same_input_content_reproducible'] = normalized(report) == normalized(repeated)
                    one['steps'].append({'operation': 'report assembly', 'result': 'PASS'})
                except Exception as exc:
                    one['steps'].append({'operation': 'first failing step', 'result': 'FAIL', 'error': error(exc)})
                finally:
                    app.rollback()
                    analytics.rollback()
            output['records'].append(one)
        # Illustrative pure-function negative probes: no questionnaire or database mutations.
        output['rule_probes'] = [
            {'case': 'rent/area missing', 'input': {'requirements': {}, 'property': {}}, 'result': requirement_matching({}, {})},
            {'case': 'walking measurement exists without suitability threshold',
             'input': {'customer_access_mode': 'walking', 'nearest_transit_walk_m': 99999},
             'result': requirement_matching({'customer_access_mode': 'walking'}, {}, {'available': True, 'groups': [{'metrics': [{'key': 'nearest_transit_walk_m', 'status': 'available', 'value': 99999}]}]})},
        ]
        dump('direct_service_readback.json', output)
    finally:
        for engine in engines:
            engine.dispose()
    return output

if __name__ == '__main__':
    label = sys.argv[1] if len(sys.argv) > 1 else 'before'
    data = snapshot(label)
    print(json.dumps({'snapshot': label, 'identity': {k: v.get('identity', v.get('error')) for k,v in data.items() if k in ('app','analytics','m2')}}, default=str))
    if label == 'before':
        out = report_reads()
        print(json.dumps({'read_steps': [{'id': x['assessment_id'], 'steps': x['steps']} for x in out['records']]}, default=str))
