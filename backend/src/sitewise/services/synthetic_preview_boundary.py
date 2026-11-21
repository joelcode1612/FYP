"""Server/CLI-only capability over immutable import provenance; no HTTP flag."""
from dataclasses import dataclass
from uuid import UUID
from sqlalchemy import text
from sitewise.domain.customer_questionnaire import digest
from sitewise.domain.cq_runtime import CqRefused


@dataclass(frozen=True)
class SyntheticPreviewAuthorization:
    run_id: UUID
    purpose: str = 'LOCAL_DEVELOPER_DIAGNOSTIC_READ_ONLY'
    developer_user_id: UUID | None = None


def boundary_run(c, table, key, authorization):
    if not c.scalar(text("SELECT to_regclass('public.cq_synthetic_import_records')")):
        return None
    run=c.execute(text('SELECT r.* FROM cq_synthetic_import_records t JOIN cq_synthetic_import_runs r ON r.run_id=t.run_id '
        'WHERE t.table_name=:table AND t.record_key_hash=:key'),{'table':table,'key':digest(key)}).mappings().first()
    if not run and table=='ee01_measurement_snapshots':
        # Interactive diagnostics are new immutable calculations, not copies
        # from the original ZIP registry. Their hashed metadata pins the run.
        run=c.execute(text("SELECT r.* FROM ee01_measurement_snapshots s JOIN cq_synthetic_import_runs r ON r.run_id::text=s.metadata_json->>'synthetic_run_id' WHERE s.id=:id AND s.metadata_json->>'origin'='SYNTHETIC_TEST'"),{'id':key['id']}).mappings().first()
    if not run:
        return None
    if isinstance(authorization,SyntheticPreviewAuthorization) and authorization.developer_user_id is not None:
        actor=c.scalar(text("SELECT current_setting('project1.actor_id',true)"))
        if actor!=str(authorization.developer_user_id) or not c.scalar(text(
            'SELECT count(*) FROM cq_synthetic_preview_grants WHERE run_id=:run AND developer_user_id=:actor'),
            {'run':run['run_id'],'actor':authorization.developer_user_id}):
            raise CqRefused('SYNTHETIC_PREVIEW_NOT_AUTHORIZED',403)
    if (not isinstance(authorization,SyntheticPreviewAuthorization)
        or authorization.run_id!=run['run_id']
        or authorization.purpose!='LOCAL_DEVELOPER_DIAGNOSTIC_READ_ONLY'
        or run['origin']!='SYNTHETIC_TEST' or run['effective_mode']!='DEVELOPER_PREVIEW' or run['real_reportable']
        or c.scalar(text('SELECT count(*) FROM cq_synthetic_import_retirements WHERE run_id=:id'),{'id':run['run_id']})):
        raise CqRefused('SYNTHETIC_DATA_NOT_REPORTABLE',403)
    return dict(run)
