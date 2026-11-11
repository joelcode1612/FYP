"""Isolated candidate metadata. Never registered with application create_all()."""
from sqlalchemy import (
    JSON, CheckConstraint, Column, DDL, ForeignKey, Integer, MetaData, String, Table,
    UniqueConstraint, event,
)

customer_candidate_metadata = MetaData()

sessions = Table(
    'cq_candidate_sessions', customer_candidate_metadata,
    Column('id', String(80), primary_key=True),
    Column('purpose', String(32), nullable=False),
    Column('revision', Integer, nullable=False),
    Column('contract_digest', String(64), nullable=False),
    Column('policy_digest', String(64), nullable=False),
    Column('policy_snapshot', JSON, nullable=False),
    Column('context', JSON, nullable=False),
    CheckConstraint("purpose = 'SYNTHETIC_ONLY'", name='ck_cq_synthetic_only'),
    CheckConstraint('revision >= 0', name='ck_cq_revision'),
)

displays = Table(
    'cq_candidate_displays', customer_candidate_metadata,
    Column('id', String(36), primary_key=True),
    Column('session_id', String(80), ForeignKey('cq_candidate_sessions.id'), nullable=False),
    Column('question_id', String(3), nullable=False),
    Column('feature_id', String(80), nullable=False),
    Column('revision', Integer, nullable=False),
    Column('context_digest', String(64), nullable=False),
    Column('provenance', JSON, nullable=False),
    UniqueConstraint('session_id', 'question_id', 'feature_id', 'revision', 'context_digest',
                     name='uq_cq_display'),
)

events = Table(
    'cq_candidate_response_history', customer_candidate_metadata,
    Column('id', String(36), primary_key=True),
    Column('session_id', String(80), ForeignKey('cq_candidate_sessions.id'), nullable=False),
    Column('question_id', String(3), nullable=False),
    Column('feature_id', String(80), nullable=False),
    Column('revision', Integer, nullable=False),
    Column('request_id', String(80), nullable=False),
    Column('request_digest', String(64), nullable=False),
    Column('display_id', String(36), ForeignKey('cq_candidate_displays.id')),
    Column('answer_state', String(32), nullable=False),
    Column('raw_response', JSON),
    Column('reason', String(160)),
    Column('context_digest', String(64), nullable=False),
    Column('provenance', JSON, nullable=False),
    UniqueConstraint('session_id', 'request_id', name='uq_cq_request'),
    UniqueConstraint('session_id', 'question_id', 'feature_id', 'revision',
                     name='uq_cq_answer_revision'),
    CheckConstraint("answer_state IN ('NOT_SHOWN','SKIPPED','REFUSED','INVALID',"
                    "'ANSWERED_SUBSTANTIVE','ANSWERED_NON_SUBSTANTIVE')", name='ck_cq_state'),
)

pretests = Table(
    'cq_candidate_structured_pretests', customer_candidate_metadata,
    Column('id', String(36), primary_key=True),
    Column('session_id', String(80), ForeignKey('cq_candidate_sessions.id'), nullable=False),
    Column('question_id', String(3), nullable=False),
    Column('feature_id', String(80), nullable=False),
    Column('locale', String(2), nullable=False),
    Column('check_code', String(40), nullable=False),
    Column('result_code', String(20), nullable=False),
    Column('question_version', String(100), nullable=False),
    Column('route_revision', Integer, nullable=False),
    Column('policy_digest', String(64), nullable=False),
    Column('option_bank_digest', String(64), nullable=False),
    CheckConstraint("locale IN ('EN','BM')", name='ck_cq_locale'),
    CheckConstraint("result_code IN ('CORRECT','INCORRECT','UNSURE','NOT_APPLICABLE')",
                    name='ck_cq_pretest_result'),
)

exposures = Table(
    'cq_candidate_stimulus_exposures', customer_candidate_metadata,
    Column('id', String(36), primary_key=True),
    Column('session_id', String(80), ForeignKey('cq_candidate_sessions.id'), nullable=False),
    Column('revision', Integer, nullable=False),
    Column('asset_kind', String(20), nullable=False),
    Column('asset_digest', String(64), nullable=False),
    Column('provenance', JSON, nullable=False),
    UniqueConstraint('session_id', 'revision', name='uq_cq_exposure_revision'),
)

# Database enforcement supplements the service's append-only API. These hooks
# apply only to the isolated synthetic SQLite schema; PostgreSQL candidate DDL
# carries equivalent triggers in the inactive migration draft.
for history_table in (displays, events, pretests, exposures):
    for operation in ('UPDATE', 'DELETE'):
        trigger = DDL(
            f'CREATE TRIGGER {history_table.name}_no_{operation.lower()} '
            f'BEFORE {operation} ON {history_table.name} '
            "BEGIN SELECT RAISE(ABORT, 'Candidate history is append-only'); END"
        ).execute_if(dialect='sqlite')
        event.listen(history_table, 'after_create', trigger)
