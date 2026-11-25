"""Server/CLI-only capability over immutable import provenance; no HTTP flag."""
from dataclasses import dataclass
from uuid import UUID
from sqlalchemy import text
from sitewise.domain.customer_questionnaire import digest
from sitewise.domain.cq_runtime import CqRefused


@dataclass(frozen=True)
class SyntheticPreviewAuthorization:
    """Capability to read one synthetic run as a developer preview.

    ``run_id`` may be ``None`` for a **record-addressed** read, where the caller
    cannot know the run before reading the record that names it (the HTTP
    measurement and report-readback routes are exactly this case: the snapshot id
    is in the path, the run id is only in the snapshot's metadata).

    ``None`` is deliberately **not** a wildcard. It is only honoured when
    ``developer_user_id`` is set, which forces the per-run
    ``cq_synthetic_preview_grants`` check below to run first. Without a grant row
    for the resolved run the read still fails with
    ``SYNTHETIC_PREVIEW_NOT_AUTHORIZED``, and every other condition — origin,
    effective mode, ``real_reportable``, retirement — is unchanged.
    """
    run_id: UUID | None = None
    purpose: str = 'LOCAL_DEVELOPER_DIAGNOSTIC_READ_ONLY'
    developer_user_id: UUID | None = None

    @classmethod
    def for_record(cls, developer_user_id, purpose='LOCAL_DEVELOPER_DIAGNOSTIC_READ_ONLY'):
        """An authorization resolved against whatever run the record belongs to."""
        return cls(run_id=None, purpose=purpose, developer_user_id=developer_user_id)


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
    # A record-addressed read has no run id to compare, so the equality is
    # replaced by "the per-run grant check above already passed". That is only
    # true when a developer identity was supplied; otherwise the request is
    # treated exactly as before and refused.
    record_addressed = (isinstance(authorization,SyntheticPreviewAuthorization)
                        and authorization.run_id is None
                        and authorization.developer_user_id is not None)
    if (not isinstance(authorization,SyntheticPreviewAuthorization)
        or (not record_addressed and authorization.run_id!=run['run_id'])
        or authorization.purpose!='LOCAL_DEVELOPER_DIAGNOSTIC_READ_ONLY'
        or run['origin']!='SYNTHETIC_TEST' or run['effective_mode']!='DEVELOPER_PREVIEW' or run['real_reportable']
        or c.scalar(text('SELECT count(*) FROM cq_synthetic_import_retirements WHERE run_id=:id'),{'id':run['run_id']})):
        raise CqRefused('SYNTHETIC_DATA_NOT_REPORTABLE',403)
    return dict(run)
