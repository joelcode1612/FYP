"""Owner-scoped, read-only projection of EE-01 measurement *metadata*.

Why a separate interface
------------------------
The Activity History is served by the M2 runtime principal (``p1_m2_runtime``).
That principal holds no ``SELECT`` on any ``ee01_*`` table, and the EE-01 read
path is bound to ``p1_ee01_runtime`` with ``project1.actor_id`` set. Granting
the M2 principal access to measurement evidence in order to draw a history
page would widen the read surface of the measurement module for a display
concern.

Instead this module performs the same read the EE-01 service already performs
-- a **read-only, REPEATABLE READ** transaction as ``p1_ee01_runtime`` with
``project1.actor_id`` bound -- and lets the existing policies scope the rows::

    ee01_measurement_snapshots  owner_user_id = current_setting('project1.actor_id')
    ee01_report_readbacks       snapshot_id IN (SELECT id FROM ee01_measurement_snapshots)

No GRANT is added, no policy is created or altered, and RLS is not bypassed.

What this projection is, and is not
-----------------------------------
It answers three separate questions, which are kept in three separate fields
because conflating them is how "the number computed" becomes "the finding is
accepted":

``computation``            a measurement row exists and its stored metadata
                           hash still matches its content
``scientific_acceptance``  never asserted here; the stored gates say the
                           A/revision/scientific adapter is unverified
``report_authorization``   the stored readback status, which is currently
                           ``REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE``

What is deliberately absent
---------------------------
``q``, ``s``, ``a``, ``v``, the ``ee01_category_cells`` values and every
``ee01_source_units`` row are **not selected**. Those are the measurement and
its per-session evidence; this is its provenance. A history page that shows
that a measurement ran, against which slot, at which cutoff, from which class
of evidence, and whether its findings were admitted, needs none of them --
and ``ee01_source_units`` carries session identifiers, so reading it would put
respondent-scoped rows on an assessment-level page.

Failure is a state, not an exception
------------------------------------
``measurement_metadata()`` never raises. A refused connection, an unverified
principal or a missing table returns ``state='UNAVAILABLE'`` with a reason
code, because the caller must render a limitation -- never infer "no
measurement was taken" from "could not read".
"""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest

CONTRACT_VERSION = 'ee01-measurement-metadata/1'

#: The only principal allowed to read EE-01 metadata. A superuser or BYPASSRLS
#: login would make every policy decorative while still returning plausible
#: rows, so it is refused rather than trusted.
CQ_PRINCIPAL = 'p1_ee01_runtime'

#: Scope values written by ``Ee01Service.build_diagnostic``: a release whose
#: ``source_class`` is ``SYNTHETIC_FIXTURE`` is measured as ``ISOLATED_TEST``,
#: anything else as ``PRODUCTION``.
PREVIEW_SCOPE = 'ISOLATED_TEST'
CUSTOMER_SCOPE = 'PRODUCTION'

#: The three statements this module can issue. Named so the privacy boundary
#: is testable: none of them selects a measurement value, a category cell or a
#: per-session source unit. Adding one is a deliberate, reviewable act.
CAMPAIGN_SQL = """
    SELECT c.id         AS campaign_id,
           c.release_id AS release_id
      FROM public.cq_campaigns c
     WHERE c.assessment_id = :aid
       AND c.owner_user_id = :actor
"""

SNAPSHOT_SQL = """
    SELECT s.id             AS snapshot_id,
           s.slot_id,
           s.question_version,
           s.cutoff,
           s.created_at,
           s.fingerprint,
           s.rules_hash,
           s.source_hash,
           s.scope,
           s.status,
           s.metadata_json,
           r.status         AS admission_status,
           r.context_json   AS admission_context
      FROM public.ee01_measurement_snapshots s
      LEFT JOIN LATERAL (
            SELECT status, context_json
              FROM public.ee01_report_readbacks
             WHERE snapshot_id = s.id
             ORDER BY created_at DESC
             LIMIT 1) r ON TRUE
     WHERE s.assessment_id = :aid
       AND s.campaign_id   = :cid
       AND s.owner_user_id = :actor
     ORDER BY s.created_at DESC, s.id DESC
     LIMIT :n
"""


def _iso(value):
    return value.astimezone(timezone.utc).isoformat() if value else None


def _unavailable(reason: str, detail: str | None = None) -> dict:
    return {
        'contract_version': CONTRACT_VERSION,
        'state': 'UNAVAILABLE',
        'reason': reason,
        'detail': detail,
        'assessments': {},
    }


def evidence_class(scope, origin) -> str:
    """Classify the stored evidence, refusing to guess when it is ambiguous.

    ``scope`` is written by the measurement itself, so it is the stronger
    signal: an ``ISOLATED_TEST`` snapshot is developer-preview evidence even
    when the run identifier was not recorded on the metadata. A ``PRODUCTION``
    scope that nevertheless claims a synthetic origin is contradictory, and is
    reported as such rather than resolved in either direction.
    """
    if scope == PREVIEW_SCOPE:
        return 'DEVELOPER_PREVIEW'
    if scope == CUSTOMER_SCOPE:
        if origin == 'SYNTHETIC_TEST':
            return 'CONTRADICTORY'
        return 'CUSTOMER_RESEARCH'
    return 'UNCLASSIFIED'


def _project(row) -> dict:
    metadata = row['metadata_json'] or {}
    origin = metadata.get('origin')
    context = row['admission_context'] or {}

    # The same integrity rule the EE-01 service applies, restricted to the
    # metadata hash: the per-source-unit check needs respondent-scoped rows,
    # so it is not repeated here. A mismatch means the row's own content no
    # longer matches the hash it was stored under, and the measurement cannot
    # be asserted to have produced what it says it produced.
    integrity_ok = digest(metadata) == row['rules_hash']

    findings = context.get('findings') or []
    gates = list(context.get('gates') or [])
    if origin == 'SYNTHETIC_TEST' and 'SYNTHETIC_DATA_NOT_REPORTABLE' not in gates:
        gates.append('SYNTHETIC_DATA_NOT_REPORTABLE')

    return {
        'snapshot_id': str(row['snapshot_id']),
        'slot_id': row['slot_id'],
        'question_version': row['question_version'],
        'cutoff': _iso(row['cutoff']),
        'created_at': _iso(row['created_at']),
        # Snapshot identity: the fingerprint pins the calculation, and the two
        # input hashes pin what it was calculated over.
        'snapshot_version': {
            'fingerprint': row['fingerprint'],
            'rules_hash': row['rules_hash'],
            'source_hash': row['source_hash'],
        },
        'scope': row['scope'],
        'evidence_class': evidence_class(row['scope'], origin),
        'origin': origin,
        'synthetic_run_id': metadata.get('synthetic_run_id'),
        'real_reportable': metadata.get('real_reportable'),
        'consent_semantics': metadata.get('consent_semantics'),
        'cutoff_basis': metadata.get('cutoff_basis'),
        'measurement_status': row['status'],
        'computation': 'COMPUTED' if integrity_ok else 'INTEGRITY_INVALID',
        'scientific_acceptance': 'NOT_ACCEPTED',
        'report_authorization': 'NOT_AUTHORIZED',
        'admission_status': row['admission_status'] or 'NOT_RECORDED',
        'finding_count': len(findings),
        'authority': context.get('authority') or 'AUTHORITY_UNVERIFIED',
        'gates': gates,
        'scientific_gaps': list(metadata.get('scientific_gaps') or []),
        'measurement_values_exposed': False,
    }


def _summarise(measurements: list[dict]) -> dict:
    by_class: dict[str, int] = {}
    by_status: dict[str, int] = {}
    for item in measurements:
        by_class[item['evidence_class']] = by_class.get(item['evidence_class'], 0) + 1
        by_status[item['measurement_status']] = (
            by_status.get(item['measurement_status'], 0) + 1)
    cutoffs = [m['cutoff'] for m in measurements if m['cutoff']]
    return {
        'snapshot_count': len(measurements),
        'slot_count': len({m['slot_id'] for m in measurements}),
        'slots': sorted({m['slot_id'] for m in measurements}),
        'by_evidence_class': by_class,
        'by_measurement_status': by_status,
        'customer_research_snapshot_count': by_class.get('CUSTOMER_RESEARCH', 0),
        'latest_cutoff': max(cutoffs) if cutoffs else None,
    }


def measurement_metadata(actor_id, assessment_id, *, limit: int = 50) -> dict:
    """Return measurement metadata for one assessment, scoped to ``actor_id``.

    ``state`` is one of:

    ``AVAILABLE``    the read succeeded; ``assessments[assessment_id]`` is present
    ``UNAVAILABLE``  the read could not be performed -- never "no measurement"

    The per-assessment ``state`` is one of ``NO_CAMPAIGN`` (nothing has been
    published, so nothing could be measured -- not a failure) or
    ``MEASURED`` / ``NOT_MEASURED`` (a campaign exists; snapshots may still be
    absent, which means no measurement has been taken yet).
    """
    from sitewise.repositories.cq_repository import get_cq_engine

    try:
        engine = get_cq_engine()
    except CqRefused as exc:
        return _unavailable(getattr(exc, 'code', 'CQ_INTERFACE_UNVERIFIED'),
                            str(exc))
    except (ValueError, TypeError) as exc:
        return _unavailable('CQ_INTERFACE_UNVERIFIED', str(exc))

    try:
        with engine.begin() as conn:
            # Both SET TRANSACTION statements must precede any query, and the
            # transaction must be read-only: this path must never be able to
            # write measurement evidence, even by mistake.
            conn.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
            conn.execute(text('SET TRANSACTION READ ONLY'))
            role = conn.execute(text(
                'SELECT current_user, rolsuper, rolbypassrls '
                '  FROM pg_roles WHERE rolname = current_user')).one()
            if tuple(role) != (CQ_PRINCIPAL, False, False):
                return _unavailable(
                    'EE01_RESTRICTED_ROLE_REQUIRED',
                    f'effective principal is {role[0]!r}, expected {CQ_PRINCIPAL!r}')
            conn.execute(text("SELECT set_config('project1.actor_id', :actor, true)"),
                         {'actor': str(actor_id)})

            campaign = conn.execute(
                text(CAMPAIGN_SQL),
                {'aid': str(assessment_id), 'actor': str(actor_id)}).mappings().first()
            if campaign is None:
                return {
                    'contract_version': CONTRACT_VERSION,
                    'state': 'AVAILABLE',
                    'reason': None,
                    'detail': None,
                    'assessments': {str(assessment_id): {
                        'state': 'NO_CAMPAIGN',
                        'detail': 'No campaign is owned by this actor for this '
                                  'assessment, so no measurement can be bound to it.',
                        'campaign_id': None,
                        'release_id': None,
                        'measurements': [],
                        'summary': _summarise([]),
                    }},
                }

            rows = conn.execute(
                text(SNAPSHOT_SQL),
                {'aid': str(assessment_id), 'cid': str(campaign['campaign_id']),
                 'actor': str(actor_id), 'n': int(limit)}).mappings().all()
            measurements = [_project(row) for row in rows]

            return {
                'contract_version': CONTRACT_VERSION,
                'state': 'AVAILABLE',
                'reason': None,
                'detail': None,
                'assessments': {str(assessment_id): {
                    'state': 'MEASURED' if measurements else 'NOT_MEASURED',
                    'detail': None if measurements else
                              'No measurement snapshot exists for this campaign yet.',
                    'campaign_id': str(campaign['campaign_id']),
                    'release_id': str(campaign['release_id']),
                    'measurements': measurements,
                    'summary': _summarise(measurements),
                }},
            }
    except CqRefused as exc:
        return _unavailable(getattr(exc, 'code', 'EE01_METADATA_REFUSED'), str(exc))
    except SQLAlchemyError as exc:
        # A missing table, a revoked privilege or a dropped connection is a
        # source limitation. It is never evidence that nothing was measured.
        return _unavailable('EE01_METADATA_SOURCE_ERROR', type(exc).__name__)
