"""Read-only projection test for Activity History.

Gated on `ACTIVITY_HISTORY_DB_URL` so the default suite stays hermetic. The
test only reads: it opens no transaction that writes, and it asserts on the
columns the repository is supposed to surface.

Why this exists: the previous reader selected a single `row.get('decision')`
and `row.get('evaluator_version')` across five differently-shaped tables. The
result was that every `ANSWER_SAVED` carried `status=None` while
`m2_answer_revisions.answer_state` sat unread, so 61 persisted answers rendered
as "outcome not supplied". A unit test with a fake repository could not catch
that, because the defect was in which columns were selected.
"""
from __future__ import annotations

import os

import pytest
from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import Session

if not os.environ.get('ACTIVITY_HISTORY_DB_URL'):
    pytest.skip(
        'Set ACTIVITY_HISTORY_DB_URL to run against a database with M2 rows.',
        allow_module_level=True,
    )

from sitewise.repositories.m2_repository import SqlModelM2Repository

ANSWER_STATES = {'ANSWERED', 'NOT_PROVIDED', 'SKIPPED_OPTIONAL', 'UNDECIDED'}

# The M2 runtime role is subject to row-level security, so every row is hidden
# until `project1.actor_id` is bound on the connection — the service does this
# per request. Without the binding the fixture sees zero rows and the module
# skips, which reads as "no data" when the truth is "not permitted".
OWNER = os.environ.get(
    'ACTIVITY_HISTORY_OWNER_ID', '11111111-1111-4111-8111-111111111111')


def _engine():
    engine = create_engine(os.environ['ACTIVITY_HISTORY_DB_URL'], future=True)

    # Bind on transaction start, not on connect. PostgreSQL's SET is
    # transactional, so a binding made at connect time is undone by the pool's
    # rollback-on-return and the next transaction silently sees zero rows.
    # `is_local=true` re-applies the binding for every transaction, which is
    # exactly the posture the service uses per request.
    @event.listens_for(engine, 'begin')
    def _bind_actor(connection):  # noqa: ANN001
        connection.exec_driver_sql(
            "select set_config('project1.actor_id', %s, true)", (OWNER,))

    return engine


@pytest.fixture(scope='module')
def target():
    """The owner's assessment with the most persisted answers, read-only."""
    engine = _engine()
    with engine.connect() as conn:
        row = conn.execute(text("""
            SELECT a.id, a.owner_user_id, a.revision
              FROM public.m2_assessments a
              JOIN public.m2_answer_revisions r ON r.assessment_id = a.id
             WHERE a.owner_user_id = :owner
             GROUP BY a.id, a.owner_user_id, a.revision
             ORDER BY count(*) DESC
             LIMIT 1
        """), {'owner': OWNER}).mappings().first()
    if row is None:
        pytest.skip(f'No assessment with persisted answers for {OWNER}.')
    return engine, row['id'], row['owner_user_id'], row['revision']


def _events(target):
    engine, assessment_id, owner_id, revision = target
    with Session(engine) as session:
        repo = SqlModelM2Repository(session)
        return repo.read_activity(assessment_id, owner_id, revision, 100)


def test_actor_binding_is_in_force(target):
    """Guard against the skip-shaped false pass.

    If the actor is not bound for the transaction, every relation is hidden by
    row-level security and each assertion below would loop over an empty list
    and pass. This test fails loudly in that case instead.
    """
    engine = target[0]
    with Session(engine) as session:
        bound = session.execute(
            text("select current_setting('project1.actor_id', true)")).scalar()
    assert bound == OWNER, 'the transaction is not bound to the owner'
    assert _events(target), 'no events projected — the reader saw nothing'


def test_answers_report_their_stored_outcome(target):
    events = [e for e in _events(target) if e['kind'] == 'ANSWER_SAVED']
    assert events, 'expected at least one persisted answer'
    for event in events:
        # The regression: this was None for every row.
        assert event.get('status') is not None, event
        assert event['status'] in ANSWER_STATES, event
        assert isinstance(event.get('item_key'), str) and event['item_key'], event


def test_evaluation_version_is_not_reported_as_a_reason(target):
    events = [e for e in _events(target) if e['kind'] == 'BDJ_EVALUATED']
    assert events, 'expected at least one persisted evaluation'
    for event in events:
        assert event.get('evaluator_version'), event
        assert 'reason' not in event, event


def test_confirmation_exposes_a_real_digest(target):
    events = [e for e in _events(target) if e['kind'] == 'CONTEXT_CONFIRMED']
    assert events, 'expected at least one persisted confirmation'
    for event in events:
        digest = event.get('snapshot_digest')
        assert isinstance(digest, str) and len(digest) == 64, event
        int(digest, 16)  # hex, or this raises


def test_no_event_claims_a_field_it_does_not_store(target):
    """A version, a rule id and a reason must not share a key."""
    events = _events(target)
    assert events, 'expected at least one projected event'
    for event in events:
        assert 'reason' not in event or isinstance(event['reason'], str)
        if event['kind'] == 'ANSWER_SAVED':
            # The answer table has no actor column; None is the honest value.
            assert event['actor_id'] is None
        if event['kind'] == 'REVIEW_RECORDED':
            assert event['actor_id'] is not None


def test_reader_is_owner_scoped(target):
    engine, assessment_id, owner_id, revision = target
    with Session(engine) as session:
        repo = SqlModelM2Repository(session)
        other = repo.read_activity(assessment_id, __import__('uuid').uuid4(),
                                   revision, 100)
    assert other == [], 'a non-owner must not read another owner history'
