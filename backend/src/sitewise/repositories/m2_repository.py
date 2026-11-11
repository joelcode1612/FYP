"""Infrastructure adapter. Uses the existing SQLModel/SQLAlchemy Session.

The tables live in separate opt-in SQLAlchemy metadata to prevent the legacy
startup create_all hook from silently provisioning an unapproved schema.
"""
from uuid import UUID, uuid4

from sqlalchemy import and_, select, update, func
from sqlalchemy.orm import Session

from sitewise.db.models.m2_schema import (
    instruments, items, assessments, answers, findings, reviews,
    confirmations, uncertainties, evaluations, clarification_events,
)


def _one(session: Session, statement) -> dict | None:
    result = session.execute(statement).mappings().first()
    return dict(result) if result is not None else None


def _all(session: Session, statement) -> list[dict]:
    return [dict(row) for row in session.execute(statement).mappings().all()]


class SqlModelM2Repository:
    """Implements M2RepositoryPort; commits are owned by application services."""
    def __init__(self, session: Session):
        self.session = session

    def commit(self) -> None:
        self.session.commit()

    def rollback(self) -> None:
        self.session.rollback()

    def get_instrument(self, instrument_id: UUID) -> dict | None:
        return _one(self.session, select(instruments).where(instruments.c.id == instrument_id))

    def list_items(self, instrument_id: UUID) -> list[dict]:
        return _all(self.session, select(items).where(items.c.instrument_id == instrument_id)
                    .order_by(items.c.sort_order, items.c.item_key))

    def get_item(self, instrument_id: UUID, item_key: str) -> dict | None:
        return _one(self.session, select(items).where(and_(
            items.c.instrument_id == instrument_id, items.c.item_key == item_key)))

    def get_assessment(self, assessment_id: UUID, actor_id: UUID) -> dict | None:
        # Unauthorized reads return the same result as missing records.
        return _one(self.session, select(assessments).where(and_(
            assessments.c.id == assessment_id, assessments.c.owner_user_id == actor_id)))

    def get_assessment_for_update(self, assessment_id: UUID, actor_id: UUID) -> dict | None:
        """Serialize state changes for this one owner-scoped assessment on PostgreSQL.

        SQLite ignores FOR UPDATE; SQLite-only tests are not evidence for live
        PostgreSQL row-level locking or database isolation.
        """
        return _one(self.session, select(assessments).where(and_(
            assessments.c.id == assessment_id,
            assessments.c.owner_user_id == actor_id,
        )).with_for_update())

    def create_assessment(self, instrument_id: UUID, actor_id: UUID) -> dict:
        row = {"id": uuid4(), "owner_user_id": actor_id,
               "instrument_id": instrument_id, "revision": 0, "confirmed_revision": None}
        self.session.execute(assessments.insert().values(**row))
        return row

    def bump_revision(self, assessment_id: UUID, expected_revision: int) -> bool:
        # Atomic compare-and-swap works against concurrent writers.
        result = self.session.execute(update(assessments).where(and_(
            assessments.c.id == assessment_id, assessments.c.revision == expected_revision,
        )).values(revision=expected_revision + 1))
        return result.rowcount == 1

    def save_answer(self, assessment_id: UUID, item_id: UUID, revision: int,
                    state: str, value: object) -> dict:
        row = {"id": uuid4(), "assessment_id": assessment_id,
               "item_version_id": item_id, "assessment_revision": revision,
               "answer_state": state, "value_json": value}
        self.session.execute(answers.insert().values(**row))
        return row

    def get_latest_answers(self, assessment_id: UUID, revision: int) -> dict[str, dict]:
        stmt = (select(answers, items.c.item_key)
                .join(items, answers.c.item_version_id == items.c.id)
                .where(and_(answers.c.assessment_id == assessment_id,
                            answers.c.assessment_revision <= revision))
                .order_by(answers.c.assessment_revision.asc()))
        result = {}
        for row in _all(self.session, stmt):
            key = row.pop("item_key")
            result[key] = row
        return result

    def find_current_finding(self, assessment_id: UUID, revision: int,
                             rule_id: str, rule_version: str) -> dict | None:
        return _one(self.session, select(findings).where(and_(
            findings.c.assessment_id == assessment_id,
            findings.c.assessment_revision == revision,
            findings.c.rule_id == rule_id,
            findings.c.rule_version == rule_version,
        )))

    def create_finding(self, assessment_id: UUID, revision: int, finding: dict) -> dict:
        row = {"id": uuid4(), "assessment_id": assessment_id,
               "assessment_revision": revision, **finding}
        self.session.execute(findings.insert().values(**row))
        return row

    def get_findings(self, assessment_id: UUID, revision: int) -> list[dict]:
        return _all(self.session, select(findings).where(and_(
            findings.c.assessment_id == assessment_id,
            findings.c.assessment_revision == revision,
        )).order_by(findings.c.rule_id))

    def get_finding(self, assessment_id: UUID, revision: int, finding_id: UUID) -> dict | None:
        return _one(self.session, select(findings).where(and_(
            findings.c.id == finding_id,
            findings.c.assessment_id == assessment_id,
            findings.c.assessment_revision == revision,
        )))

    def get_clarification_by_request(self, assessment_id: UUID, request_id: UUID) -> dict | None:
        return _one(self.session, select(clarification_events).where(and_(
            clarification_events.c.assessment_id == assessment_id,
            clarification_events.c.request_id == request_id,
        )))

    def add_clarification_event(self, assessment_id: UUID, revision: int,
                                finding_id: UUID, actor_id: UUID,
                                decision: str, request_id: UUID) -> dict:
        previous = self.session.execute(select(func.max(clarification_events.c.event_sequence)).where(and_(
            clarification_events.c.assessment_id == assessment_id,
            clarification_events.c.assessment_revision == revision,
        ))).scalar_one()
        row = {"id": uuid4(), "assessment_id": assessment_id,
               "assessment_revision": revision, "event_sequence": (previous or 0) + 1,
               "finding_id": finding_id,
               "actor_user_id": actor_id, "decision": decision,
               "request_id": request_id}
        self.session.execute(clarification_events.insert().values(**row))
        return row

    def latest_clarifications(self, assessment_id: UUID, revision: int) -> dict[str, dict]:
        stmt = (select(clarification_events)
                .where(and_(clarification_events.c.assessment_id == assessment_id,
                            clarification_events.c.assessment_revision == revision))
                .order_by(clarification_events.c.event_sequence))
        latest = {}
        for event in _all(self.session, stmt):
            latest[str(event["finding_id"])] = event
        return latest

    def get_evaluation(self, assessment_id: UUID, revision: int, evaluator_version: str) -> dict | None:
        return _one(self.session, select(evaluations).where(and_(
            evaluations.c.assessment_id == assessment_id,
            evaluations.c.assessment_revision == revision,
            evaluations.c.evaluator_version == evaluator_version)))

    def add_evaluation(self, assessment_id: UUID, revision: int, evaluator_version: str) -> dict:
        row = {"id": uuid4(), "assessment_id": assessment_id,
               "assessment_revision": revision, "evaluator_version": evaluator_version}
        self.session.execute(evaluations.insert().values(**row))
        return row

    def get_review(self, assessment_id: UUID, revision: int) -> dict | None:
        return _one(self.session, select(reviews).where(and_(
            reviews.c.assessment_id == assessment_id,
            reviews.c.assessment_revision == revision)))

    def add_review(self, assessment_id: UUID, revision: int, actor_id: UUID) -> dict:
        row = {"id": uuid4(), "assessment_id": assessment_id,
               "assessment_revision": revision, "actor_user_id": actor_id}
        self.session.execute(reviews.insert().values(**row))
        return row

    def mark_confirmed(self, assessment_id: UUID, revision: int) -> bool:
        # Exact revision and 'not already confirmed' checks close duplicate requests.
        result = self.session.execute(update(assessments).where(and_(
            assessments.c.id == assessment_id,
            assessments.c.revision == revision,
            assessments.c.confirmed_revision.is_distinct_from(revision),
        )).values(confirmed_revision=revision))
        return result.rowcount == 1

    def create_confirmation(self, assessment_id: UUID, revision: int, actor_id: UUID,
                            snapshot: dict, digest: str, acknowledged: list[str]) -> dict:
        row = {"id": uuid4(), "assessment_id": assessment_id,
               "assessment_revision": revision, "actor_user_id": actor_id,
               "snapshot_json": snapshot, "snapshot_digest": digest,
               "acknowledged_issue_ids": acknowledged}
        self.session.execute(confirmations.insert().values(**row))
        return row

    def get_confirmation(self, confirmation_id: UUID, actor_id: UUID) -> dict | None:
        stmt = select(confirmations).join(
            assessments, confirmations.c.assessment_id == assessments.c.id
        ).where(and_(
            confirmations.c.id == confirmation_id,
            assessments.c.owner_user_id == actor_id,
            # Old snapshots remain readable through future audit logic but
            # cannot receive a new uncertainty as if they were current.
            assessments.c.revision == confirmations.c.assessment_revision,
            assessments.c.confirmed_revision == confirmations.c.assessment_revision,
        ))
        return _one(self.session, stmt)

    def create_uncertainty(self, confirmation_id: UUID, actor_id: UUID, text: str) -> dict:
        row = {"id": uuid4(), "confirmation_id": confirmation_id,
               "actor_user_id": actor_id, "exact_text": text}
        self.session.execute(uncertainties.insert().values(**row))
        return row
