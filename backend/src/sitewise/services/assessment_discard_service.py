"""CP-12 durable two-database discard. No runtime DDL or privileged URL fallback.

The reviewed database interfaces are deliberately required. A missing migration
is availability failure, never permission to use the legacy marketplace delete.
"""
from uuid import UUID, uuid5, NAMESPACE_URL
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sitewise.core.exceptions import AssessmentError
from sitewise.db.m2_session import get_m2_engine


class AssessmentDiscardService:
    def __init__(self, marketplace_engine, dss_engine=None):
        self.market = marketplace_engine
        self.dss = dss_engine

    def _call(self, engine, function, actor, **params):
        # Function names are internal constants, never request input.
        try:
            with engine.begin() as c:
                # The reviewed Dss cleanup uses a three-second lock timeout.
                # Apply the same bound to every stage, including the FLA row
                # lock: the configured PostgreSQL default is otherwise zero
                # (wait indefinitely). A timeout rolls back this stage only.
                c.execute(text("SELECT set_config('lock_timeout', '3s', true)"))
                c.execute(text("SELECT set_config('project1.actor_id', :actor, true)"),
                          {'actor': str(actor)})
                return c.execute(text(function), params).scalar_one()
        except SQLAlchemyError as exc:
            code = getattr(getattr(exc, 'orig', None), 'pgcode', None)
            if code in ('42883', '42P01', '42501'):
                raise AssessmentError(
                    'Permanent discard is unavailable until the reviewed CP-12 database interfaces and permissions are installed.',
                    code='DISCARD_NOT_PROVISIONED', status_code=503) from exc
            if code == 'P0001':
                # Database functions emit only bounded machine-readable codes.
                reason = getattr(getattr(exc.orig, 'diag', None), 'message_primary', '')
                if not reason.startswith('DISCARD_') or len(reason) > 100:
                    reason = 'DISCARD_RETRY_REQUIRED'
                messages = {
                    'DISCARD_ALREADY_CONFIRMED': 'Confirmed assessments cannot be permanently discarded.',
                    'DISCARD_PROTECTED_LIFECYCLE': 'This assessment has protected progress and cannot be permanently discarded.',
                    'DISCARD_PROTECTED_OR_UNKNOWN_REFERENCE': 'Other saved evidence refers to this assessment. Permanent discard is refused.',
                    'DISCARD_TARGET_RETENTION_UNVERIFIED': 'Retention and source checks for this assessment have not been approved.',
                    'DISCARD_RETENTION_OR_EXTERNAL_REFS_UNVERIFIED': 'Retention and external source checks have not been approved.',
                    'DISCARD_SCHEMA_INVENTORY_CHANGED': 'The database structure has changed. Discard requires a new dependency review.',
                }
                raise AssessmentError(messages.get(reason, 'Permanent discard could not proceed. The saved recovery state is preserved for review.'),
                                      code=reason, status_code=409) from exc
            raise AssessmentError('Discard could not finish. Retry the same assessment; recovery state is preserved.',
                                  code='DISCARD_RETRY_REQUIRED', status_code=503) from exc

    def discard(self, assessment_id: UUID, owner_id: UUID):
        # Establish ownership before policy inspection. A completed retry uses
        # its owner-bound journal; an absent parent alone is never authority.
        with self.market.connect() as c:
            owner = c.execute(text('SELECT user_id FROM public.assessment WHERE assessment_id=:id'),
                              {'id': str(assessment_id)}).scalar()
            if owner is None:
                installed = c.execute(text("SELECT to_regclass('cp12.operations') IS NOT NULL")).scalar_one()
                if installed:
                    owner = c.execute(text('SELECT owner_id FROM cp12.operations WHERE assessment_id=:id'),
                                      {'id': str(assessment_id)}).scalar()
            if owner is None:
                raise AssessmentError('That assessment does not exist. Orphan recovery is a separately authorized operation.',
                                      code='assessment_not_found', status_code=404)
            if str(owner) != str(owner_id):
                raise AssessmentError('This assessment belongs to another account.',
                                      code='assessment_forbidden', status_code=403)
        # Stable per-owner/per-record operation identity also supports legacy
        # DELETE clients and retries after the marketplace row has disappeared.
        key = uuid5(NAMESPACE_URL, f'project1:discard:{owner_id}:{assessment_id}')
        p = {'key': str(key), 'aid': str(assessment_id)}
        dss = self.dss if self.dss is not None else get_m2_engine()
        self._call(dss, 'SELECT cp12.inspect(:aid)', owner_id, aid=str(assessment_id))
        proof = self._call(self.market, 'SELECT cp12.prepare(:key, :aid)', owner_id, **p)
        self._call(dss, 'SELECT cp12.reserve(:key, :aid, :proof)', owner_id, **p, proof=proof)
        removed = self._call(dss, 'SELECT cp12.remove_draft(:key, :aid, :proof)', owner_id, **p, proof=proof)
        finished = self._call(self.market, 'SELECT cp12.finish(:key, :aid, :proof)', owner_id, **p, proof=removed)
        self._call(dss, 'SELECT cp12.complete(:key, :aid, :proof)', owner_id, **p, proof=finished)
        return key

    def assert_available(self, assessment_id, owner_id):
        # Before provisioning there can be no CP-12 pending operation. After
        # provisioning reads/resume must respect the durable barrier as well.
        with self.market.connect() as c:
            installed = c.execute(text("SELECT to_regclass('cp12.operations') IS NOT NULL")).scalar_one()
            if installed:
                pending = c.execute(text("SELECT EXISTS(SELECT 1 FROM cp12.operations WHERE assessment_id=:id AND owner_id=:owner AND phase<>'COMPLETE')"),
                                    {'id': str(assessment_id), 'owner': str(owner_id)}).scalar_one()
                if pending:
                    raise AssessmentError('This assessment has a pending permanent discard. Retry the discard to recover.',
                                          code='DISCARD_IN_PROGRESS', status_code=409)
