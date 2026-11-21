"""Read-only registry adapter for a separately provisioned isolated trial DB.

No production registration, database migration or approval writer is provided.
An operator-controlled private cluster must independently establish its identity
and provision a protected registry before this adapter can be used.
"""
from sqlalchemy import text
from sqlalchemy.orm import Session
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.ledger import PostgresAttemptLedger


class PrivateSyntheticTrialRegistry:
    def __init__(self, engine, actor_id, *, verify_private_instance):
        self.engine = engine
        self.actor_id = actor_id
        self.verify_private_instance = verify_private_instance

    def get_server_authorization(self, run_id=None, *, assessment_id=None, revision=None, fingerprint=None):
        with Session(self.engine) as session, session.begin():
            # Reuse the production ledger's restricted-role and actor checks.
            PostgresAttemptLedger(self.engine, self.actor_id, run_id)._scope(session)
            if self.verify_private_instance(session) is not True:
                raise WorkflowHeld('SYNTHETIC_PRIVATE_INSTANCE_UNVERIFIED')
            row = session.execute(text("SELECT to_regclass('project1_ai.synthetic_trial_authority') IS NOT NULL")).scalar()
            if not row:
                raise WorkflowHeld('SYNTHETIC_AUTHORITY_REGISTRY_UNAVAILABLE')
            can_read, can_write, login_can_write, login_is_owner = session.execute(text("SELECT "
                "has_table_privilege(current_user,'project1_ai.synthetic_trial_authority','SELECT'), "
                "has_table_privilege(current_user,'project1_ai.synthetic_trial_authority','INSERT,UPDATE,DELETE,TRUNCATE'), "
                "has_table_privilege(session_user,'project1_ai.synthetic_trial_authority','INSERT,UPDATE,DELETE,TRUNCATE'), "
                "pg_has_role(session_user, (SELECT relowner FROM pg_class WHERE oid="
                "'project1_ai.synthetic_trial_authority'::regclass), 'MEMBER')")).one()
            if not can_read or can_write or login_can_write or login_is_owner:
                raise WorkflowHeld('SYNTHETIC_AUTHORITY_PERMISSIONS_INVALID')
            if run_id is None:
                # Existing operator-provisioned run/decision only. HTTP cannot
                # create an approval or mark a real assessment synthetic.
                rows = session.execute(text('SELECT a.authorization_json FROM project1_ai.synthetic_trial_authority a '
                    'JOIN project1_ai.runs r ON r.id=a.run_id AND r.owner_user_id=a.owner_user_id '
                    'WHERE r.assessment_id=:assessment AND r.assessment_revision=:revision '
                    'AND r.source_fingerprint=:fingerprint AND r.owner_user_id=:owner'),
                    {'assessment':assessment_id, 'revision':revision, 'fingerprint':fingerprint,
                     'owner':self.actor_id}).scalars().all()
                if len(rows) != 1:
                    raise WorkflowHeld('DISCLOSURE_REGISTERED_AUTHORIZATION_REQUIRED')
                result = rows[0]
            else:
                result = session.execute(text('SELECT authorization_json FROM project1_ai.synthetic_trial_authority '
                    'WHERE run_id=:run AND owner_user_id=:owner'),
                    {'run':str(run_id), 'owner':str(self.actor_id)}).scalar_one_or_none()
            return result if isinstance(result, dict) else None
