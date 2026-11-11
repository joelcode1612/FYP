"""PostgreSQL append-only attempt ledger. Own restricted service connection only."""
from uuid import UUID

from sqlalchemy import text
from sqlmodel import Session

from sitewise.project1.contracts import WorkflowHeld


class PostgresAttemptLedger:
    def __init__(self, engine, actor_id: UUID, run_id: UUID):
        self.engine, self.actor_id, self.run_id = engine, actor_id, run_id

    def _scope(self, session):
        # This adapter is only constructed by the verified server identity path.
        identity = session.execute(text('SELECT current_user, rolsuper, rolbypassrls '
            'FROM pg_roles WHERE rolname=current_user')).one()
        if identity[0] != 'p1ai_runtime' or identity[1] or identity[2]:
            raise WorkflowHeld('RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED')
        session.execute(text("SELECT set_config('project1.actor_id', :actor, true)"),
                        {'actor': str(self.actor_id)})

    def reserve(self, stage, prompt_version, prompt_hash, request_hash):
        if stage not in {'BDJ', 'QJ', 'QG'}:
            raise WorkflowHeld('MODEL_STAGE_UNREGISTERED')
        with Session(self.engine) as session:
            self._scope(session)
            row = session.execute(text('SELECT id FROM project1_ai.runs '
                'WHERE id=:id AND owner_user_id=:actor FOR UPDATE'),
                {'id': self.run_id, 'actor': self.actor_id}).one_or_none()
            if row is None:
                raise WorkflowHeld('WORKFLOW_RUN_NOT_FOUND')
            # Conservatively only one dispatch per stage; retries need a new reviewed
            # reconciler. A reserved row without a receipt is an UNKNOWN outcome.
            previous = session.execute(text('SELECT stage FROM project1_ai.attempts '
                'WHERE run_id=:id'), {'id': self.run_id}).scalars().all()
            if stage in previous:
                raise WorkflowHeld('MODEL_STAGE_ALREADY_RESERVED')
            if len(previous) >= 6:
                raise WorkflowHeld('MODEL_ATTEMPT_BUDGET_EXHAUSTED')
            number = len(previous) + 1
            session.execute(text('INSERT INTO project1_ai.attempts '
                '(run_id, owner_user_id, attempt_no, stage, prompt_version, prompt_hash, request_hash) '
                'VALUES (:run,:actor,:n,:stage,:version,:prompt,:request)'),
                {'run': self.run_id, 'actor': self.actor_id, 'n': number, 'stage': stage,
                 'version': prompt_version, 'prompt': prompt_hash, 'request': request_hash})
            session.commit()  # No provider dispatch before this succeeds.
            return number

    def finish(self, attempt, outcome, output_digest):
        if outcome not in {'returned', 'rejected', 'unknown_outcome'}:
            raise WorkflowHeld('MODEL_RECEIPT_OUTCOME_INVALID')
        with Session(self.engine) as session:
            self._scope(session)
            session.execute(text('INSERT INTO project1_ai.attempt_receipts '
                '(run_id, owner_user_id, attempt_no, outcome, output_digest) '
                'VALUES (:run,:actor,:attempt,:outcome,:digest)'),
                {'run': self.run_id, 'actor': self.actor_id, 'attempt': attempt,
                 'outcome': outcome, 'digest': output_digest})
            session.commit()
