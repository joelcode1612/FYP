"""Record which developer-preview run produced a campaign.

`cq_synthetic_import_records` is how EE-01 resolves a campaign back to the run
that created it: `synthetic_preview_boundary.boundary_run(c, 'cq_campaigns',
{'id': campaign_id})` looks up `record_key_hash = digest({'id': campaign_id})`
and returns the joined run. `Ee01Service.build_diagnostic` then decides
`research_mode` from that run.

Nothing wrote such a row for a campaign created by publication. `--session`
created the run, the case, the preview grant, the execution grant and the
session, but not the campaign binding, so `boundary_run` returned `None`, EE-01
could not distinguish a developer-preview session from a customer-demand one,
and every measurement came back `Q=0 S=0 A=0 V=0` (DD-106).

The row written here states only what happened: a **developer action**, not a
package import. `record_kind='DEVELOPER_ACTION'` is the existing vocabulary for
that (`cq_synthetic_import_records_record_kind_check` allows `PACKAGE` or
`DEVELOPER_ACTION`), and the package verifier only ever reads
`record_kind='PACKAGE'` (`synthetic_dss_import.verify_records`), so this row can
never be counted as an imported package.

This does not claim a verified package, does not set `real_reportable`, and does
not make the run reportable: `boundary_run` still enforces `origin =
SYNTHETIC_TEST`, `effective_mode = DEVELOPER_PREVIEW`, `real_reportable = false`
and the absence of a retirement row.
"""
from sqlalchemy import text

from sitewise.domain.customer_questionnaire import digest


def campaign_binding_key(campaign_id):
    """The exact key `boundary_run` looks up. Never change this shape."""
    return {'id': str(campaign_id)}


def record_campaign_binding(connection, *, run_id, campaign, release_id, manifest_hash):
    """Bind `campaign` to `run_id`. Idempotent by primary key."""
    key = campaign_binding_key(campaign['id'])
    source = {
        'release_id': str(release_id),
        'assessment_id': str(campaign['assessment_id']),
    }
    imported = {k: str(v) for k, v in dict(campaign).items()}
    result = connection.execute(text(
        'INSERT INTO cq_synthetic_import_records(run_id, table_name, source_key, '
        'source_key_hash, record_key, record_key_hash, source_sha256, imported_sha256, '
        "record_kind, origin, real_reportable) VALUES (:run, 'cq_campaigns', "
        'CAST(:sk AS jsonb), :sh, CAST(:rk AS jsonb), :rh, :src, :imp, '
        "'DEVELOPER_ACTION', 'SYNTHETIC_TEST', false) "
        'ON CONFLICT (table_name, record_key_hash) DO NOTHING '
        'RETURNING run_id'),
        {'run': str(run_id), 'sk': _json(source), 'sh': digest(source),
         'rk': _json(key), 'rh': digest(key),
         'src': manifest_hash, 'imp': digest(imported)})
    row = result.first()
    return 'RECORDED' if row else 'ALREADY_RECORDED'


def _json(value):
    import json
    return json.dumps(value, sort_keys=True)
