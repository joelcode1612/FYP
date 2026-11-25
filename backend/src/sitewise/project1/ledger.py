"""PostgreSQL append-only attempt ledger. Own restricted service connection only."""
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.project1.contracts import WorkflowHeld


#: Stages that may reserve a new attempt. ``QJ`` is retained because historical
#: rows carry it and the constraint still admits it, but it is not part of the
#: active workflow and no new QJ attempt is expected. ``EXPLANATION`` was added
#: with migration ``20261122_01``; reserving it still requires its own disclosure
#: authorization — a registered stage is not permission to call a provider.
_ALLOWED_STAGES = {'BDJ', 'QJ', 'QG', 'EXPLANATION'}
_MAX_ATTEMPT_SLOT = 3
_MAX_ATTEMPTS_PER_RUN = 6

# One probe per reserve() call. information_schema is readable by the
# restricted execution role, so this works under SET LOCAL ROLE p1ai_runtime.
_SCHEMA_SLOT_COLUMN_SQL = (
    'SELECT EXISTS (SELECT 1 FROM information_schema.columns '
    "WHERE table_schema='project1_ai' AND table_name='attempts' "
    "AND column_name='attempt_slot')")

# Slot 1 deliberately keeps the ORIGINAL statement, without attempt_slot, so
# the ledger still works against a database that has not applied 20261118_03.
_INSERT_LEGACY = (
    'INSERT INTO project1_ai.attempts '
    '(run_id, owner_user_id, attempt_no, stage, prompt_version, prompt_hash, request_hash) '
    'VALUES (:run,:actor,:n,:stage,:version,:prompt,:request)')
_INSERT_SLOT = (
    'INSERT INTO project1_ai.attempts '
    '(run_id, owner_user_id, attempt_no, stage, attempt_slot, prompt_version, prompt_hash, request_hash) '
    'VALUES (:run,:actor,:n,:stage,:slot,:version,:prompt,:request)')


class PostgresAttemptLedger:
    def __init__(self, engine, actor_id: UUID, run_id: UUID):
        self.engine, self.actor_id, self.run_id = engine, actor_id, run_id

    def _scope(self, session):
        # Restricted execution-principal contract (migration 20261117_01).
        # Statements MUST execute as the NOLOGIN restricted role p1ai_runtime,
        # and the login principal MUST be a non-superuser, non-BYPASSRLS role.
        # Two permitted paths reach that state:
        #   * direct restricted login (used only by disposable test clones), or
        #   * the dedicated execution principal p1ai_engine (member of
        #     p1ai_runtime) issuing SET LOCAL ROLE p1ai_runtime.
        # A superuser, a BYPASSRLS login, or the ordinary app role that never
        # switches role must fail closed.
        session_user, current_user, rolsuper, rolbypassrls = session.execute(text(
            'SELECT session_user, current_user, '
            '(SELECT rolsuper FROM pg_roles WHERE rolname=session_user), '
            '(SELECT rolbypassrls FROM pg_roles WHERE rolname=session_user)')).one()
        if rolsuper or rolbypassrls:
            raise WorkflowHeld('RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED')
        if current_user != 'p1ai_runtime':
            try:
                session.execute(text('SET LOCAL ROLE p1ai_runtime'))
            except SQLAlchemyError:
                raise WorkflowHeld('RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED') from None
            current_user = session.execute(text('SELECT current_user')).scalar()
        if current_user != 'p1ai_runtime':
            raise WorkflowHeld('RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED')
        from sitewise.db.m2_session import bind_m2_actor
        bind_m2_actor(session, self.actor_id)

    def reserve(self, stage, prompt_version, prompt_hash, request_hash,
                *, attempt_slot=1, authorization_id=None, authorization_receipt=None):
        """Reserve one attempt in ``attempt_slot`` (1..3).

        Slot 1 is the legacy path and works on an un-migrated ledger. A slot
        above 1 is refused before any INSERT when the ledger schema cannot
        represent it, so an old database never silently loses a retry.

        ``authorization_id`` spends one BDJ real-data authorization in the SAME
        transaction as the attempt row (DD-005 mechanism B). Both commit
        together or neither does, so a second dispatch cannot reuse the
        authorization and a failed spend cannot leave a reserved attempt behind.
        """
        if stage not in _ALLOWED_STAGES:
            raise WorkflowHeld('MODEL_STAGE_UNREGISTERED')
        if (authorization_id is None) != (authorization_receipt is None):
            # Half a spend is a composition error, not a disclosure decision.
            raise WorkflowHeld('BDJ_AUTHORIZATION_RECEIPT_REQUIRED')
        # bool is an int subclass; never read True as slot 1.
        if (isinstance(attempt_slot, bool) or not isinstance(attempt_slot, int)
                or not 1 <= attempt_slot <= _MAX_ATTEMPT_SLOT):
            raise WorkflowHeld('MODEL_STAGE_INVALID_ATTEMPT_SLOT')
        with Session(self.engine) as session:
            self._scope(session)
            row = session.execute(text('SELECT id FROM project1_ai.runs '
                'WHERE id=:id AND owner_user_id=:actor FOR UPDATE'),
                {'id': self.run_id, 'actor': self.actor_id}).one_or_none()
            if row is None:
                raise WorkflowHeld('WORKFLOW_RUN_NOT_FOUND')
            has_slot = bool(session.execute(text(_SCHEMA_SLOT_COLUMN_SQL)).scalar())
            if attempt_slot > 1 and not has_slot:
                # Checked before the attempts read and before any INSERT: the
                # old schema cannot distinguish two attempts at one stage.
                raise WorkflowHeld('WORKFLOW_LEDGER_VERSION_UNSUPPORTED')
            if has_slot:
                attempts = session.execute(text('SELECT attempt_no, stage, attempt_slot '
                    'FROM project1_ai.attempts WHERE run_id=:id'),
                    {'id': self.run_id}).all()
                pairs = [(r[1], r[2]) for r in attempts]
            else:
                attempts = session.execute(text('SELECT attempt_no, stage '
                    'FROM project1_ai.attempts WHERE run_id=:id'),
                    {'id': self.run_id}).all()
                pairs = [(r[1], 1) for r in attempts]
            # A duplicate is now a (stage, slot) pair, not just a stage. A
            # retry of QG in a new slot is a new, history-preserving attempt.
            if (stage, attempt_slot) in pairs:
                raise WorkflowHeld('MODEL_STAGE_ALREADY_RESERVED')
            if len(attempts) >= _MAX_ATTEMPTS_PER_RUN:
                raise WorkflowHeld('MODEL_ATTEMPT_BUDGET_EXHAUSTED')
            # From the largest existing attempt, not len(previous)+1: two QG
            # attempts in one run must not reuse an attempt_no.
            number = max([r[0] for r in attempts], default=0) + 1
            if number > _MAX_ATTEMPTS_PER_RUN:
                raise WorkflowHeld('MODEL_ATTEMPT_BUDGET_EXHAUSTED')
            params = {'run': self.run_id, 'actor': self.actor_id, 'n': number,
                      'stage': stage, 'version': prompt_version,
                      'prompt': prompt_hash, 'request': request_hash}
            if attempt_slot > 1:
                session.execute(text(_INSERT_SLOT), {**params, 'slot': attempt_slot})
            else:
                session.execute(text(_INSERT_LEGACY), params)
            if authorization_id is not None:
                # Same session, therefore same transaction. A refusal here
                # propagates before the commit below, so the attempt row above
                # is rolled back with it: no attempt is consumed and no
                # dispatch can follow.
                from sitewise.project1.real_data_authorization import record_spend
                record_spend(session, authorization_id=authorization_id,
                             run_id=self.run_id, owner_user_id=self.actor_id,
                             attempt_no=number, receipt=authorization_receipt)
            session.commit()  # No provider dispatch before this succeeds.
            return number

    def finish(self, attempt, outcome, output_digest, *,
               model_returned=None, provider_response_status=None):
        """Record the receipt for one reserved attempt.

        ``model_returned`` and ``provider_response_status`` are optional so the
        three-argument call sites keep working unchanged, but they are the only
        way the two existing receipt columns are ever populated. They are
        bounded metadata copied from ``provider.last_execution`` — never prompt
        text, response bodies, headers or credentials — and they are written on
        refusals as well as on successes, because "which model answered" is a
        fact about the attempt, not about its outcome (DD-055).
        """
        if outcome not in {'returned', 'rejected', 'unknown_outcome'}:
            raise WorkflowHeld('MODEL_RECEIPT_OUTCOME_INVALID')
        if model_returned is not None and not isinstance(model_returned, str):
            model_returned = None
        if model_returned is not None and len(model_returned) > 128:
            # The provider's own label is bounded at the edge; a longer value is
            # not an identifier this ledger is willing to store.
            model_returned = None
        if (provider_response_status is not None
                and (isinstance(provider_response_status, bool)
                     or not isinstance(provider_response_status, int)
                     or not 100 <= provider_response_status <= 599)):
            provider_response_status = None
        with Session(self.engine) as session:
            self._scope(session)
            session.execute(text('INSERT INTO project1_ai.attempt_receipts '
                '(run_id, owner_user_id, attempt_no, outcome, output_digest, '
                ' model_returned, provider_response_status) '
                'VALUES (:run,:actor,:attempt,:outcome,:digest,:model,:status)'),
                {'run': self.run_id, 'actor': self.actor_id, 'attempt': attempt,
                 'outcome': outcome, 'digest': output_digest,
                 'model': model_returned, 'status': provider_response_status})
            session.commit()
