"""Owner-scoped, read-only projection of questionnaire publication metadata.

Why a separate interface
------------------------
The Activity History is served by the M2 runtime principal (``p1_m2_runtime``).
That principal holds ``SELECT`` on ``cq_campaigns`` and ``cq_manifest_releases``
but **no policy grants it a row**: every CQ ``SELECT`` policy is declared
``TO p1_ee01_runtime``. Reading CQ metadata from the M2 connection therefore
returns zero rows silently -- which the UI would have to render as "no
questionnaire", a false statement.

Rather than widen ``p1_m2_runtime`` or weaken a policy, this module reads CQ
metadata as the principal that already owns it. It opens a **read-only,
REPEATABLE READ** transaction as ``p1_ee01_runtime``, binds
``project1.actor_id`` to the entrepreneur, and lets the existing
``ee01_owner_read`` policies do the scoping:

    cq_campaigns          owner_user_id = current_setting('project1.actor_id')
    cq_manifest_releases  id IN (SELECT release_id FROM cq_campaigns)
    cq_question_assignments release_id IN (SELECT release_id FROM cq_campaigns)

So: no GRANT is added, no policy is created or altered, and RLS is not bypassed.
The boundary is enforced by the database, not by this module.

What is deliberately absent
---------------------------
``cq_participants``, ``cq_effective_answers``, ``cq_answer_revisions``,
``cq_presentations``, ``cq_render_events``, ``cq_routing_decisions`` and
``cq_consent_events`` are **not read at all**.

``cq_sessions`` and ``cq_submission_receipts`` are read, but only through
:data:`SESSION_SQL`, which projects **aggregate counts and timestamps and
nothing else**: no session id, no respondent id, no receipt payload, no
request hash. The aggregate answers "how many sessions exist, how many were
submitted, how many receipts were stored, and when was the last one" -- which
is what an assessment-level history needs -- while leaving every row-level
fact inside the boundary. Publication status is a property of a campaign and
its release; the counts are the size of the response, not a description of the
people who responded. A caller cannot recover an individual from a ``count``,
and :func:`aggregate_statements_are_projection_free` is what keeps that true.

Failure is a state, not an exception
------------------------------------
``publication_metadata()`` never raises. A refused connection, an unverified
principal or a missing table returns ``state='UNAVAILABLE'`` with a reason code,
because the caller must render a limitation -- never infer "not published" from
"could not read".
"""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from sitewise.core.config import settings
from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest

CONTRACT_VERSION = 'cq-publication-metadata/2'

#: The only principal allowed to read CQ metadata. A superuser or BYPASSRLS
#: login would make every policy decorative while still returning plausible
#: rows, so it is refused rather than trusted.
CQ_PRINCIPAL = 'p1_ee01_runtime'

#: The only two statements this module can issue. Named so the privacy boundary
#: is testable: neither mentions a respondent-scoped table, so no filter can be
#: forgotten. Adding a table here is a deliberate, reviewable act.
CAMPAIGN_SQL = """
    SELECT c.id            AS campaign_id,
           c.assessment_id,
           c.owner_user_id,
           c.release_id,
           c.created_at    AS campaign_created_at,
           r.manifest_hash,
           r.policy_hash,
           r.source_class,
           r.created_at    AS release_created_at,
           r.manifest_json,
           r.policy_json,
           (SELECT count(*)
              FROM public.cq_bank_versions b
             WHERE b.version = r.manifest_json ->> 'bank_version') AS bank_rows
      FROM public.cq_campaigns c
      JOIN public.cq_manifest_releases r ON r.id = c.release_id
     WHERE c.assessment_id = :aid
       AND c.owner_user_id = :actor
"""

ASSIGNMENT_SQL = """
    SELECT count(*)                AS assignment_count,
           count(DISTINCT slot_id) AS distinct_slots
      FROM public.cq_question_assignments
     WHERE release_id = :rid
"""

#: Aggregate response size for one campaign.
#:
#: Every selected expression is an aggregate or a timestamp: ``count(*)``,
#: ``count(*) FILTER``, ``min``, ``max``. No row-level column is projected, so
#: there is no shape in which this statement can return a person. The receipt
#: subquery is scoped through ``cq_sessions`` for the same campaign, which is
#: also how the RLS policies scope it.
SESSION_SQL = """
    SELECT count(*)                                              AS session_count,
           count(*) FILTER (WHERE s.state = 'SUBMITTED')         AS submitted_session_count,
           count(*) FILTER (WHERE s.state = 'ACTIVE')            AS open_session_count,
           count(*) FILTER (WHERE s.state = 'WITHDRAWN')         AS withdrawn_session_count,
           min(s.created_at)                                     AS first_session_at,
           max(s.created_at)                                     AS last_session_at,
           (SELECT count(*)
              FROM public.cq_submission_receipts r
             WHERE r.session_id IN (SELECT x.id FROM public.cq_sessions x
                                     WHERE x.campaign_id = :cid))  AS receipt_count
      FROM public.cq_sessions s
     WHERE s.campaign_id = :cid
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


#: Row-level respondent fields that must never appear in an aggregate
#: statement. ``session_id`` is not on this list because it is used as a join
#: predicate (``r.session_id IN (...)``), which projects nothing; the fields
#: here are the ones that would carry an identity or a response body.
FORBIDDEN_IN_AGGREGATE = (
    'respondent_user_id',
    'payload_json',
    'receipt_hash',
    'request_hash',
)


def aggregate_statements_are_projection_free() -> bool:
    """True when the aggregate statement projects no row-level respondent field.

    This exists so the privacy claim is checkable rather than aspirational: the
    counts above are only defensible while the statement that produces them
    cannot also produce a person.
    """
    statements = SESSION_SQL.lower()
    return not any(field in statements for field in FORBIDDEN_IN_AGGREGATE)


def publication_metadata(actor_id, assessment_id) -> dict:
    """Return publication metadata for one assessment, scoped to ``actor_id``.

    ``state`` is one of:

    ``AVAILABLE``    the read succeeded; ``assessments[assessment_id]`` is present
    ``UNAVAILABLE``  the read could not be performed -- never "not published"

    The per-assessment ``state`` is one of ``PUBLISHED``, ``NOT_PUBLISHED`` or
    ``INTEGRITY_FAILED``.
    """
    from sitewise.repositories.cq_repository import get_cq_engine

    try:
        engine = get_cq_engine()
    except CqRefused as exc:
        return _unavailable(getattr(exc, 'code', 'CQ_INTERFACE_UNVERIFIED'),
                            str(exc))
    except (ValueError, TypeError) as exc:
        return _unavailable('CQ_INTERFACE_UNVERIFIED', str(exc))

    sql = text(CAMPAIGN_SQL)
    counts = text(ASSIGNMENT_SQL)
    sessions_sql = text(SESSION_SQL)

    try:
        with engine.begin() as conn:
            # Both SET TRANSACTION statements must precede any query, and the
            # transaction must be read-only: this path must never be able to
            # write CQ evidence, even by mistake.
            conn.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
            conn.execute(text('SET TRANSACTION READ ONLY'))
            role = conn.execute(text(
                'SELECT current_user, rolsuper, rolbypassrls '
                '  FROM pg_roles WHERE rolname = current_user')).one()
            if tuple(role) != (CQ_PRINCIPAL, False, False):
                return _unavailable(
                    'CQ_RESTRICTED_ROLE_REQUIRED',
                    f'effective principal is {role[0]!r}, expected {CQ_PRINCIPAL!r}')
            conn.execute(text("SELECT set_config('project1.actor_id', :actor, true)"),
                         {'actor': str(actor_id)})

            row = conn.execute(sql, {'aid': str(assessment_id),
                                     'actor': str(actor_id)}).mappings().first()
            if row is None:
                return {
                    'contract_version': CONTRACT_VERSION,
                    'state': 'AVAILABLE',
                    'reason': None,
                    'detail': None,
                    'assessments': {str(assessment_id): {
                        'state': 'NOT_PUBLISHED',
                        'detail': 'No campaign is owned by this actor for this assessment.',
                    }},
                }

            manifest = row['manifest_json'] or {}
            policy = row['policy_json'] or {}
            assignment = (manifest.get('assignment') or {})
            questions = manifest.get('questions') or []
            authorized = manifest.get('authorized_question_ids') or []

            integrity = (digest(manifest) == row['manifest_hash']
                         and digest(policy) == row['policy_hash'])

            c = conn.execute(counts, {'rid': str(row['release_id'])}).mappings().one()
            assignment_count = int(c['assignment_count'] or 0)
            distinct_slots = int(c['distinct_slots'] or 0)

            # Aggregate response size. Counts and timestamps only -- see
            # SESSION_SQL. This is the size of the response, not a description
            # of the respondents.
            s = conn.execute(sessions_sql,
                             {'cid': str(row['campaign_id'])}).mappings().one()
            session_count = int(s['session_count'] or 0)
            submitted = int(s['submitted_session_count'] or 0)
            receipts = int(s['receipt_count'] or 0)

            published_at_revision = assignment.get('assessment_revision')
            current_revision = conn.execute(text(
                'SELECT revision FROM public.m2_assessments WHERE id = :aid'),
                {'aid': str(assessment_id)}).scalar()

            return {
                'contract_version': CONTRACT_VERSION,
                'state': 'AVAILABLE',
                'reason': None,
                'detail': None,
                'assessments': {str(assessment_id): {
                    'state': 'PUBLISHED' if integrity else 'INTEGRITY_FAILED',
                    'detail': None if integrity else
                              'Stored manifest/policy hash does not match the stored body.',
                    'campaign_id': str(row['campaign_id']),
                    'release_id': str(row['release_id']),
                    'campaign_created_at': _iso(row['campaign_created_at']),
                    'release_created_at': _iso(row['release_created_at']),
                    'manifest_hash': row['manifest_hash'],
                    'policy_hash': row['policy_hash'],
                    'source_class': row['source_class'],
                    'bank_version': manifest.get('bank_version'),
                    'bank_version_rows': int(row['bank_rows'] or 0),
                    'lane': manifest.get('lane'),
                    'mode': manifest.get('mode'),
                    'title': manifest.get('title'),
                    'question_count': len(questions),
                    'authorized_question_count': len(authorized),
                    'assignment_count': assignment_count,
                    'distinct_slot_count': distinct_slots,
                    # Aggregate response size. Counts only: no session id, no
                    # respondent id, no answer, no receipt body.
                    'session_count': session_count,
                    'submitted_session_count': submitted,
                    'open_session_count': int(s['open_session_count'] or 0),
                    'withdrawn_session_count': int(s['withdrawn_session_count'] or 0),
                    'receipt_count': receipts,
                    # Duplicate submission attempts are idempotent: one receipt
                    # per submitted session. A mismatch is an integrity signal,
                    # not a reason to adjust either number.
                    'receipts_match_submitted_sessions': receipts == submitted,
                    'first_session_at': _iso(s['first_session_at']),
                    'last_session_at': _iso(s['last_session_at']),
                    'release_complete': (integrity
                                         and distinct_slots == len(questions)
                                         and len(questions) > 0),
                    # Currentness is derived, never assumed: the release was
                    # built against one M2 revision, and a later assessment
                    # revision makes the publication historical.
                    'published_at_revision': published_at_revision,
                    'current_revision': current_revision,
                    'is_current_for_revision': (published_at_revision
                                                == current_revision),
                    # Fielding authority is a deployment flag, not a row.
                    'fielding_enabled': bool(settings.cq_runtime_enabled),
                }},
            }
    except CqRefused as exc:
        return _unavailable(getattr(exc, 'code', 'CQ_METADATA_REFUSED'), str(exc))
    except SQLAlchemyError as exc:
        # A missing table, a revoked privilege or a dropped connection is a
        # source limitation. It is never evidence that nothing was published.
        return _unavailable('CQ_METADATA_SOURCE_ERROR', type(exc).__name__)
