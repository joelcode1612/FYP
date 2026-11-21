"""Infrastructure adapter. Uses the existing SQLModel/SQLAlchemy Session.

The tables live in separate opt-in SQLAlchemy metadata to prevent the legacy
startup create_all hook from silently provisioning an unapproved schema.
"""
from uuid import UUID, uuid4

from sqlalchemy import and_, select, text, update, func
from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError

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

    def lock_active_marketplace_binding(self, assessment_id: UUID, actor_id: UUID,
                                        marketplace_assessment_id: UUID) -> bool:
        """Hold the active Dss link through the owning answer transaction."""
        from sqlalchemy import text
        row = self.session.execute(text("""
            SELECT link_id FROM public.m2_assessment_links
            WHERE m2_assessment_id=:m2 AND marketplace_assessment_id=:marketplace
              AND user_id=:actor AND revoked_at IS NULL FOR SHARE
        """), {'m2': assessment_id, 'marketplace': marketplace_assessment_id,
               'actor': actor_id}).first()
        return row is not None

    def read_activity(self, assessment_id: UUID, actor_id: UUID,
                      revision: int, limit: int) -> list[dict]:
        """Existing receipts only; bounded queries, ownership enforced in SQL.

        Fetch limit+1 from each stream then merge globally in the service.
        A missing stream raises instead of masquerading as an empty history.

        Each stream is projected explicitly. The previous implementation read
        a single `row.get('decision')` / `row.get('evaluator_version')` across
        five differently-shaped tables, which had two consequences that were
        invisible in code review but visible on screen:

          * `status` was `None` for every ANSWER_SAVED, so 61 persisted rows
            rendered as "outcome not supplied" while `answer_state` sat in the
            database unread; and
          * `reason` received an evaluator *version* for BDJ_EVALUATED and a
            *rule id* for candidate findings, so the UI printed a version
            string under the label "Recorded reason".

        Naming the columns per kind is what keeps a stored outcome from being
        reported as missing, and a version from being reported as a reason.
        """
        rows = []
        bounded = limit + 1

        # ANSWER_SAVED — outcome is `answer_state`; `item_key` identifies which
        # question was answered. `m2_answer_revisions` has no actor column, so
        # actor is genuinely absent here rather than merely unselected.
        statement = (select(answers.c.id, answers.c.assessment_revision,
                            answers.c.created_at, answers.c.answer_state,
                            items.c.item_key)
            .join(assessments, answers.c.assessment_id == assessments.c.id)
            .join(items, answers.c.item_version_id == items.c.id)
            .where(and_(answers.c.assessment_id == assessment_id,
                        assessments.c.owner_user_id == actor_id,
                        answers.c.assessment_revision <= revision))
            .order_by(answers.c.created_at.desc(), answers.c.id.desc()).limit(bounded))
        for row in _all(self.session, statement):
            rows.append({'event_id': row['id'], 'kind': 'ANSWER_SAVED',
                'assessment_revision': row['assessment_revision'],
                'occurred_at': row['created_at'], 'actor_id': None,
                'status': row['answer_state'], 'item_key': row['item_key']})

        # BDJ_EVALUATED — a deterministic evaluation receipt. `evaluator_version`
        # is a version, not a reason; it is surfaced under its own name.
        statement = (select(evaluations.c.id, evaluations.c.assessment_revision,
                            evaluations.c.created_at, evaluations.c.evaluator_version)
            .join(assessments, evaluations.c.assessment_id == assessments.c.id)
            .where(and_(evaluations.c.assessment_id == assessment_id,
                        assessments.c.owner_user_id == actor_id,
                        evaluations.c.assessment_revision <= revision))
            .order_by(evaluations.c.created_at.desc(), evaluations.c.id.desc()).limit(bounded))
        for row in _all(self.session, statement):
            rows.append({'event_id': row['id'], 'kind': 'BDJ_EVALUATED',
                'assessment_revision': row['assessment_revision'],
                'occurred_at': row['created_at'], 'actor_id': None,
                'evaluator_version': row['evaluator_version']})

        # REVIEW_RECORDED — the table stores who reviewed and when. It has no
        # decision column, so no status is asserted.
        statement = (select(reviews.c.id, reviews.c.assessment_revision,
                            reviews.c.created_at, reviews.c.actor_user_id)
            .join(assessments, reviews.c.assessment_id == assessments.c.id)
            .where(and_(reviews.c.assessment_id == assessment_id,
                        assessments.c.owner_user_id == actor_id,
                        reviews.c.assessment_revision <= revision))
            .order_by(reviews.c.created_at.desc(), reviews.c.id.desc()).limit(bounded))
        for row in _all(self.session, statement):
            rows.append({'event_id': row['id'], 'kind': 'REVIEW_RECORDED',
                'assessment_revision': row['assessment_revision'],
                'occurred_at': row['created_at'], 'actor_id': row['actor_user_id']})

        # CONTEXT_CONFIRMED — the snapshot digest is the evidence that the
        # confirmation covers the revision it claims. Exposing the digest is
        # not the same as exposing the snapshot payload, which stays private.
        statement = (select(confirmations.c.id, confirmations.c.assessment_revision,
                            confirmations.c.created_at, confirmations.c.actor_user_id,
                            confirmations.c.snapshot_digest)
            .join(assessments, confirmations.c.assessment_id == assessments.c.id)
            .where(and_(confirmations.c.assessment_id == assessment_id,
                        assessments.c.owner_user_id == actor_id,
                        confirmations.c.assessment_revision <= revision))
            .order_by(confirmations.c.created_at.desc(), confirmations.c.id.desc()).limit(bounded))
        for row in _all(self.session, statement):
            rows.append({'event_id': row['id'], 'kind': 'CONTEXT_CONFIRMED',
                'assessment_revision': row['assessment_revision'],
                'occurred_at': row['created_at'], 'actor_id': row['actor_user_id'],
                'snapshot_digest': row['snapshot_digest']})

        # CLARIFICATION_RECORDED — `decision` is a real outcome and `finding_id`
        # is the source record the decision was made about.
        statement = (select(clarification_events.c.id, clarification_events.c.assessment_revision,
                            clarification_events.c.created_at, clarification_events.c.actor_user_id,
                            clarification_events.c.decision, clarification_events.c.finding_id)
            .join(assessments, clarification_events.c.assessment_id == assessments.c.id)
            .where(and_(clarification_events.c.assessment_id == assessment_id,
                        assessments.c.owner_user_id == actor_id,
                        clarification_events.c.assessment_revision <= revision))
            .order_by(clarification_events.c.created_at.desc(),
                      clarification_events.c.id.desc()).limit(bounded))
        for row in _all(self.session, statement):
            rows.append({'event_id': row['id'], 'kind': 'CLARIFICATION_RECORDED',
                'assessment_revision': row['assessment_revision'],
                'occurred_at': row['created_at'], 'actor_id': row['actor_user_id'],
                'status': row['decision'], 'source_id': row['finding_id']})

        return rows

    def read_activity_supplement(self, assessment_id, actor_id, revision, limit):
        """Metadata from existing rows only. Never read text/answers/BCB packets.

        BCB build rows are mutable snapshots, NOT an attempt history. An absent
        optional BCB store must not discard the independent persisted M2 stream.
        """
        events, snapshots = [], []
        assessment = self.get_assessment(assessment_id, actor_id)
        if assessment is None:
            return {'events': [], 'bcb_statuses': [], 'bcb_available': False,
                    'bcb_statuses_truncated': False}
        events.append({'event_id': assessment_id, 'kind': 'ASSESSMENT_CREATED',
            'assessment_revision': 0, 'occurred_at': assessment['created_at'],
            'actor_id': None, 'module': 'M2', 'status': None,
            'reason': 'Persisted assessment creation; creating actor not separately recorded.'})
        statement = (select(findings.c.id, findings.c.assessment_revision,
                    findings.c.created_at, findings.c.review_state, findings.c.rule_id,
                    findings.c.rule_version)
            .join(assessments, findings.c.assessment_id == assessments.c.id)
            .where(assessments.c.id == assessment_id,
                   assessments.c.owner_user_id == actor_id,
                   findings.c.assessment_revision <= revision)
            .order_by(findings.c.created_at.desc(), findings.c.id.desc()).limit(limit + 1))
        for row in _all(self.session, statement):
            # `rule_id` is an identifier, not a reason; it is surfaced as one.
            events.append({'event_id': row['id'], 'kind': 'CANDIDATE_FINDING_RECORDED',
                'assessment_revision': row['assessment_revision'],
                'occurred_at': row['created_at'], 'actor_id': None, 'module': 'BDJ',
                'status': row['review_state'], 'rule_id': row['rule_id'],
                'rule_version': row['rule_version']})
        statement = (select(uncertainties.c.id, uncertainties.c.created_at,
                    uncertainties.c.actor_user_id, confirmations.c.assessment_revision,
                    confirmations.c.id.label('confirmation_id'))
            .join(confirmations, uncertainties.c.confirmation_id == confirmations.c.id)
            .join(assessments, confirmations.c.assessment_id == assessments.c.id)
            .where(assessments.c.id == assessment_id,
                   assessments.c.owner_user_id == actor_id,
                   confirmations.c.assessment_revision <= revision)
            .order_by(uncertainties.c.created_at.desc(), uncertainties.c.id.desc()).limit(limit + 1))
        for row in _all(self.session, statement):
            events.append({'event_id': row['id'], 'kind': 'UNCERTAINTY_CONFIRMED',
                'assessment_revision': row['assessment_revision'],
                'occurred_at': row['created_at'], 'actor_id': row['actor_user_id'],
                'module': 'Business Understanding', 'status': None,
                'reason': 'Separate entrepreneur declaration recorded.',
                'source_id': row['confirmation_id']})
        from sitewise.db.models.business_context_schema import contexts, builds
        available = True
        try:
            # Read-only savepoint contains missing-table/permission failures.
            with self.session.begin_nested():
                stmt = (select(contexts.c.context_id, contexts.c.confirmation_id,
                        contexts.c.assessment_revision, contexts.c.created_at,
                        contexts.c.lifecycle_status, contexts.c.builder_version)
                    .join(assessments, contexts.c.assessment_id == assessments.c.id)
                    .where(assessments.c.id == assessment_id,
                           assessments.c.owner_user_id == actor_id,
                           contexts.c.owner_user_id == actor_id,
                           contexts.c.assessment_revision <= revision)
                    .order_by(contexts.c.created_at.desc(), contexts.c.context_id.desc())
                    .limit(limit + 1))
                context_rows = _all(self.session, stmt)
                stmt = (select(builds.c.confirmation_id, builds.c.assessment_revision,
                        builds.c.status, builds.c.last_code, builds.c.context_id,
                        builds.c.attempt_count, builds.c.updated_at)
                    .join(assessments, builds.c.assessment_id == assessments.c.id)
                    .where(assessments.c.id == assessment_id,
                           assessments.c.owner_user_id == actor_id,
                           builds.c.owner_user_id == actor_id)
                    .order_by(builds.c.updated_at.desc(), builds.c.confirmation_id.desc())
                    .limit(limit + 1))
                snapshots = _all(self.session, stmt)
            for row in context_rows:
                # `builder_version` is a version, not a reason; it is surfaced
                # under its own name so the UI does not print it as a reason.
                events.append({'event_id': row['context_id'], 'kind': 'CONTEXT_PERSISTED',
                    'assessment_revision': row['assessment_revision'],
                    'occurred_at': row['created_at'], 'actor_id': None,
                    'module': 'BCB', 'status': row['lifecycle_status'],
                    'builder_version': row['builder_version'],
                    'source_id': row['confirmation_id'],
                    'source_is_current': row['assessment_revision'] == revision == assessment['confirmed_revision']})
            for row in snapshots:
                row['source_is_current'] = row['assessment_revision'] == revision == assessment['confirmed_revision']
        except SQLAlchemyError:
            available = False
            snapshots = []
        return {'events': events, 'bcb_statuses': snapshots[:limit],
                'bcb_statuses_truncated': len(snapshots) > limit,
                'bcb_available': available}

    def get_instrument(self, instrument_id: UUID) -> dict | None:
        return _one(self.session, select(instruments).where(instruments.c.id == instrument_id))

    def list_authorized_instruments(self, limit: int, offset: int) -> list[dict]:
        return _all(self.session,select(instruments).where(instruments.c.approval_state=='AUTHORIZED',
            select(items.c.id).where(items.c.instrument_id==instruments.c.id,items.c.lifecycle=='ACTIVE',
                items.c.answer_kind!='ACTION').exists()).order_by(instruments.c.created_at.desc(),instruments.c.id).limit(limit).offset(offset))

    def list_owned_assessments(self, actor_id: UUID, limit: int, offset: int) -> list[dict]:
        return _all(self.session,select(assessments).where(assessments.c.owner_user_id==actor_id)
            .order_by(assessments.c.created_at.desc(),assessments.c.id).limit(limit).offset(offset))

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
                             rule_id: str, rule_version: str,
                             source_identity: str | None = None) -> dict | None:
        """First finding for this rule, optionally narrowed to one source.

        ``_one`` takes ``.first()``, so once a rule can emit more than one
        finding this returns an arbitrary row rather than raising. A caller that
        needs the finding for a specific source MUST pass ``source_identity``,
        or it will treat a different finding as if it were this one.

        The filter is applied as raw SQL so a database that has not yet had the
        D3 migration applied keeps working for callers that do not pass it.
        """
        stmt = select(findings).where(and_(
            findings.c.assessment_id == assessment_id,
            findings.c.assessment_revision == revision,
            findings.c.rule_id == rule_id,
            findings.c.rule_version == rule_version,
        ))
        if source_identity is not None:
            stmt = stmt.where(text('source_identity = :source_identity')).params(
                source_identity=source_identity)
        return _one(self.session, stmt)

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

    def save_objective_source(self, objective_id, provenance):
        import json
        from sqlalchemy import text
        self.session.execute(text(
            "INSERT INTO m2_research_objective_sources (objective_id, provenance) "
            "VALUES (:id, CAST(:source AS jsonb))"
        ), {"id": objective_id, "source": json.dumps(provenance)})

    def read_current_objective(self, objective_id, actor_id, expected_revision):
        from sqlalchemy import text
        row = self.session.execute(text("""
            SELECT u.id, u.exact_text, s.provenance
            FROM public.m2_confirmed_uncertainties u
            JOIN public.m2_research_objective_sources s ON s.objective_id = u.id
            JOIN public.m2_confirmation_snapshots c ON c.id = u.confirmation_id
            JOIN public.m2_assessments a ON a.id = c.assessment_id
            WHERE u.id = :objective AND a.owner_user_id = :actor
              AND u.actor_user_id = a.owner_user_id AND c.actor_user_id = a.owner_user_id
              AND c.assessment_revision = :revision AND a.revision = c.assessment_revision
              AND a.confirmed_revision = a.revision
              AND s.provenance->>'snapshot_digest' = c.snapshot_digest
              AND s.provenance->>'confirmation_id' = CAST(c.id AS text)
              AND s.provenance->>'assessment_id' = CAST(a.id AS text)
              AND s.provenance->>'assessment_revision' = CAST(a.revision AS text)
              AND NOT EXISTS (SELECT 1 FROM public.m2_research_revisions r WHERE r.parent_id = u.id)
        """), {"objective": objective_id, "actor": actor_id, "revision": expected_revision}).mappings().first()
        return dict(row) if row else None

    def objective_limitation(self, objective_id):
        from sqlalchemy import text
        row = self.session.execute(text("""
            SELECT c.limitation, c.broader_objective, r.child_id
            FROM public.m2_research_clarifications c LEFT JOIN public.m2_research_revisions r
              ON r.parent_id=c.objective_id WHERE c.objective_id=:id
        """), {"id": objective_id}).mappings().first()
        return dict(row) if row else None

    def link_objective_revision(self, parent_id, child_id, action):
        from sqlalchemy import text
        self.session.execute(text("""
            INSERT INTO public.m2_research_revisions(parent_id,child_id,action)
            VALUES (:parent,:child,:action)
        """), {"parent": parent_id, "child": child_id, "action": action})

    def review_question(self, version):
        from sqlalchemy import text
        row = self.session.execute(text("""
          SELECT q.id,q.objective_id,q.question,q.options,d.option_code
          FROM public.m2_review_question_versions q LEFT JOIN public.m2_desired_options d
            ON d.question_version=q.id WHERE q.id=:id AND NOT EXISTS (
              SELECT 1 FROM public.m2_review_question_versions newer WHERE newer.supersedes=q.id)
        """), {"id":version}).mappings().first()
        return dict(row) if row else None

    def set_desired_option(self, version, actor_id, code):
        from sqlalchemy import text
        if code is None:
            self.session.execute(text("DELETE FROM public.m2_desired_options WHERE question_version=:id AND actor_id=:actor"),
                                 {"id": version, "actor": actor_id})
        else:
            self.session.execute(text("""
              INSERT INTO public.m2_desired_options VALUES (:id,:actor,:code)
              ON CONFLICT(question_version) DO UPDATE SET option_code=excluded.option_code
              WHERE m2_desired_options.actor_id=excluded.actor_id
            """), {"id": version, "actor": actor_id, "code": code})

    def record_qj_limitation(self, objective_id, limitation, proposal):
        from sqlalchemy import text
        self.session.execute(text("""
            INSERT INTO public.m2_research_clarifications(objective_id, limitation, broader_objective)
            VALUES (:id,:limitation,:proposal) ON CONFLICT (objective_id) DO NOTHING
        """), {"id": objective_id, "limitation": limitation, "proposal": proposal})

    def persist_candidate(self, version, objective_id, receipt, supersedes=None):
        """Insert one candidate version; a revision links to the version it replaces.

        ``supersedes`` is the parent-version linkage. It is only accepted when
        the parent's terminal decision is REQUEST_REVISION: without that guard a
        regenerated candidate would silently become a second concurrent
        "current" version, which is the defect this change exists to remove.
        ``supersedes`` is UNIQUE, so the database refuses a second child too.
        """
        import json
        from sqlalchemy import text
        from sitewise.core.exceptions import ConflictError
        candidate = receipt["candidate"]
        # The caller locks the owning assessment before this check. Compare
        # exact question and options within the same objective only: similar
        # wording elsewhere is not evidence of equivalence or shared identity.
        duplicate = self.session.scalar(text("""
            SELECT q.id FROM public.m2_review_question_versions q
            WHERE q.objective_id=:objective AND q.id<>:id
              AND q.question=:question AND q.options=CAST(:options AS jsonb)
              AND NOT EXISTS (SELECT 1 FROM public.m2_review_question_versions n
                              WHERE n.supersedes=q.id)
            LIMIT 1
        """), {"objective": objective_id, "id": version,
               "question": candidate["question"],
               "options": json.dumps(candidate["options"])})
        if duplicate:
            raise ConflictError('QG_EXACT_CANDIDATE_DUPLICATE')
        if supersedes is not None:
            revision_requested = self.session.scalar(text("""
                SELECT 1 FROM public.m2_candidate_owner_reviews
                WHERE candidate_id=:parent AND decision='REQUEST_REVISION'
            """), {"parent": supersedes})
            if not revision_requested:
                raise ValueError("A candidate revision requires a REQUEST_REVISION decision on the parent version.")
        self.session.execute(text("""
            INSERT INTO public.m2_review_question_versions
                (id, objective_id, source_receipt, question, options, supersedes)
            VALUES (:id,:objective,:receipt,:question,CAST(:options AS jsonb),:supersedes)
            ON CONFLICT(id) DO NOTHING
        """), {"id": version, "objective": objective_id, "receipt": json.dumps(receipt),
               "question": candidate["question"], "options": json.dumps(candidate["options"]),
               "supersedes": supersedes})
        if supersedes is not None:
            # The child must be reviewable, otherwise REQUEST_REVISION dead-ends
            # at "No current pending review assignment". Assignments are mutable,
            # so inheriting the parent's reviewers is a plain INSERT.
            self.session.execute(text("""
                INSERT INTO public.m2_candidate_review_assignments(candidate_id,reviewer_id,authority_reference)
                SELECT :id, a.reviewer_id, a.authority_reference
                FROM public.m2_candidate_review_assignments a
                WHERE a.candidate_id=:parent
                ON CONFLICT(candidate_id,reviewer_id) DO NOTHING
            """), {"id": version, "parent": supersedes})

    def candidate_version(self, version, actor_id):
        """One persisted candidate version, owner-scoped.

        Superseded versions remain readable: a revision chain is history, and a
        parent must stay reviewable after its child exists. Ownership is decided
        by the assessment row, never by the caller's claim. A candidate bound to
        an assessment whose confirmation is stale is not readable: the
        confirmed_revision guard closes that read path.
        """
        from sqlalchemy import text
        row = self.session.execute(text("""
            SELECT q.id, q.objective_id, q.question, q.options, q.supersedes,
                   q.source_receipt, u.exact_text,
                   r.decision, r.rationale, r.recorded_at, r.reviewer_id
            FROM public.m2_review_question_versions q
            JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id
            JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
            JOIN public.m2_assessments a ON a.id=c.assessment_id
            LEFT JOIN public.m2_candidate_owner_reviews r ON r.candidate_id=q.id
            WHERE q.id=:id AND a.owner_user_id=:actor AND u.actor_user_id=:actor
              AND a.confirmed_revision=a.revision AND c.assessment_revision=a.revision
        """), {"id": version, "actor": actor_id}).mappings().first()
        return dict(row) if row else None

    def candidate_history(self, objective_id, actor_id, revision):
        """Every version for the objective at the current revision, in chain order.

        ``supersedes`` is the only parent link, so the order is the chain depth
        from each root. A second generation that did not supersede anything is a
        second root and appears at depth 0, which is the truth about the data
        rather than an invented single line.
        """
        from sqlalchemy import text
        rows = self.session.execute(text("""
            WITH RECURSIVE chain AS (
                SELECT q.id, q.supersedes, 0 AS depth
                FROM public.m2_review_question_versions q
                JOIN public.m2_research_objective_sources s ON s.objective_id=q.objective_id
                JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id
                JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
                JOIN public.m2_assessments a ON a.id=c.assessment_id
                WHERE q.objective_id=:objective AND q.supersedes IS NULL
                  AND a.owner_user_id=:actor AND u.actor_user_id=:actor
                  AND a.revision=:revision AND c.assessment_revision=a.revision
                  AND a.confirmed_revision=a.revision
                UNION ALL
                SELECT child.id, child.supersedes, chain.depth+1
                FROM public.m2_review_question_versions child
                JOIN chain ON child.supersedes=chain.id
                WHERE child.objective_id=:objective
            )
            SELECT chain.id, chain.depth, q.objective_id, q.question, q.options,
                   q.supersedes, r.decision, r.rationale, r.recorded_at, r.reviewer_id
            FROM chain
            JOIN public.m2_review_question_versions q ON q.id=chain.id
            LEFT JOIN public.m2_candidate_owner_reviews r ON r.candidate_id=chain.id
            ORDER BY chain.depth, chain.id
        """), {"objective": objective_id, "actor": actor_id,
               "revision": revision}).mappings()
        return [dict(row) for row in rows]

    def record_owner_review(self, version, reviewer, decision, rationale):
        from sqlalchemy import text
        from sitewise.core.config import settings
        if settings.m2_protected_identity_enabled:
            # The database function obtains the reviewer from the verified
            # assertion; the caller cannot select a different identity.
            return self.session.execute(text("""
                SELECT * FROM project1_identity.record_candidate_review(:version,:decision,:rationale)
            """), dict(version=version, decision=decision, rationale=rationale)).mappings().first()
        # The review table's composite foreign key also covers the assessment
        # owner. Create only that owner's own assignment, in this transaction,
        # after checking the current confirmation and candidate. Assigned third
        # party reviewers must continue to have an independently granted row.
        self.session.execute(text("""
            INSERT INTO public.m2_candidate_review_assignments
                (candidate_id, reviewer_id, authority_reference)
            SELECT q.id, :reviewer, 'ASSESSMENT_OWNER'
            FROM public.m2_review_question_versions q
            JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id
            JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
            JOIN public.m2_assessments m ON m.id=c.assessment_id
            WHERE q.id=:version AND m.owner_user_id=:reviewer
              AND m.confirmed_revision=m.revision AND m.revision=c.assessment_revision
              AND NOT EXISTS (SELECT 1 FROM public.m2_review_question_versions n WHERE n.supersedes=q.id)
            FOR UPDATE OF m
            ON CONFLICT(candidate_id,reviewer_id) DO NOTHING
        """), dict(version=version, reviewer=reviewer))
        # Lock the assessment used by M2 revisions while recording this decision.
        # The owner may review their own candidate: ownership is proved by the
        # m2_assessments join (m), not by the reviewer-assignment predicate.
        # An unrelated caller with no assignment matches no row and fails
        # closed. The LEFT JOIN stops the `owner_user_id <> reviewer_id` test
        # from blocking the owner branch; it does not remove the existing
        # FK(candidate_id, reviewer_id) -> review_assignments, so an owner
        # review still needs an assignment row to exist. The persisted
        # reviewer_id must come from the bound :reviewer parameter, never from
        # a.reviewer_id, which is NULL on the owner branch.
        return self.session.execute(text("""
            INSERT INTO public.m2_candidate_owner_reviews(candidate_id,reviewer_id,decision,rationale,context_hash)
            SELECT q.id, :reviewer, :decision, :rationale, c.snapshot_digest
            FROM public.m2_review_question_versions q
            JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id
            JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
            JOIN public.m2_assessments m ON m.id=c.assessment_id
            LEFT JOIN public.m2_candidate_review_assignments a ON a.candidate_id=q.id AND a.reviewer_id=:reviewer
            WHERE q.id=:version AND ((a.reviewer_id=:reviewer AND m.owner_user_id<>a.reviewer_id) OR m.owner_user_id=:reviewer)
              AND m.confirmed_revision=m.revision AND m.revision=c.assessment_revision
              AND NOT EXISTS(SELECT 1 FROM public.m2_review_question_versions n WHERE n.supersedes=q.id)
            FOR UPDATE OF m
            ON CONFLICT(candidate_id) DO NOTHING
            RETURNING candidate_id,reviewer_id,decision,rationale,context_hash,recorded_at
        """), dict(version=version,reviewer=reviewer,decision=decision,rationale=rationale)).mappings().first()

    def research_workspace(self, confirmation_id, actor_id, revision):
        from sqlalchemy import text
        rows = self.session.execute(text("""
            SELECT u.id, u.exact_text, s.provenance, l.limitation, l.broader_objective,
                   r.child_id, q.id AS version, q.question, q.options, d.option_code
            FROM public.m2_confirmation_snapshots c
            JOIN public.m2_assessments a ON a.id=c.assessment_id
            JOIN public.m2_confirmed_uncertainties u ON u.confirmation_id=c.id
            JOIN public.m2_research_objective_sources s ON s.objective_id=u.id
            LEFT JOIN public.m2_research_clarifications l ON l.objective_id=u.id
            LEFT JOIN public.m2_research_revisions r ON r.parent_id=u.id
            LEFT JOIN public.m2_review_question_versions q ON q.objective_id=u.id
              AND NOT EXISTS(SELECT 1 FROM public.m2_review_question_versions n WHERE n.supersedes=q.id)
            LEFT JOIN public.m2_desired_options d ON d.question_version=q.id
            WHERE c.id=:id AND a.owner_user_id=:actor AND u.actor_user_id=:actor
              AND c.actor_user_id=:actor
              AND a.revision=:revision AND c.assessment_revision=a.revision AND a.confirmed_revision=a.revision
              AND s.provenance->>'snapshot_digest'=c.snapshot_digest
              AND s.provenance->>'confirmation_id'=CAST(c.id AS text)
              AND s.provenance->>'assessment_id'=CAST(a.id AS text)
              AND s.provenance->>'assessment_revision'=CAST(a.revision AS text)
            ORDER BY u.created_at,u.id,q.id
        """), dict(id=confirmation_id,actor=actor_id,revision=revision)).mappings()
        from hashlib import sha256
        result = []
        for row in rows:
            item = dict(row)
            source = item['provenance']
            verified = (source.get('objective_contract') == 'entrepreneur-objective/1'
                and source.get('origin') == 'ENTREPRENEUR'
                and source.get('objective_version') == str(item['id'])
                and source.get('owner_user_id') == str(actor_id)
                and source.get('owner_decision') == 'CONFIRMED'
                and source.get('approval_status') == 'CONFIRMED_BY_OWNER'
                and source.get('objective_text_sha256') == sha256(item['exact_text'].encode('utf-8')).hexdigest())
            item['objective_version_id'] = str(item['id']) if verified else None
            item['owner_decision'] = 'CONFIRMED' if verified else None
            item['approval_status'] = ('SUPERSEDED' if verified and item['child_id'] is not None
                else 'CONFIRMED_BY_OWNER' if verified else 'AUTHORITY_UNVERIFIED')
            result.append(item)
        return result

    def assigned_candidate_reviews(self, actor_id):
        import json
        from sqlalchemy import text
        has_projection = self.session.scalar(text("SELECT to_regclass('public.assessment_workflow_projection') IS NOT NULL"))
        projection_join = """          LEFT JOIN LATERAL (
            SELECT projection_sequence,projection_data FROM public.assessment_workflow_projection
            WHERE assessment_id=m.id AND owner_user_id=m.owner_user_id AND assessment_revision=m.revision
            ORDER BY projection_sequence DESC LIMIT 1
          ) p ON true
""" if has_projection else """
          LEFT JOIN (SELECT NULL::bigint AS projection_sequence, NULL::jsonb AS projection_data) p ON false
        """
        rows = self.session.execute(text(f"""
          SELECT q.id,q.question,q.options,q.source_receipt,u.exact_text,c.assessment_revision,
                 d.decision,d.rationale,d.recorded_at,p.projection_sequence,
                 p.projection_data->>'llm_execution' AS model_execution
          FROM public.m2_candidate_review_assignments a
          JOIN public.m2_review_question_versions q ON q.id=a.candidate_id
          JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id
          JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
          JOIN public.m2_assessments m ON m.id=c.assessment_id
          LEFT JOIN public.m2_candidate_owner_reviews d ON d.candidate_id=q.id
          {projection_join}
          WHERE a.reviewer_id=:actor AND m.owner_user_id<>:actor AND m.revision=c.assessment_revision
            AND m.confirmed_revision=m.revision AND NOT EXISTS(
              SELECT 1 FROM public.m2_review_question_versions newer WHERE newer.supersedes=q.id)
          ORDER BY q.id
        """),dict(actor=actor_id)).mappings()
        result=[]
        for row in rows:
            data=dict(row)
            receipt=data.pop("source_receipt")
            try:
                evidence=json.loads(receipt)
            except ValueError:
                evidence={}
            data["classification"]=evidence.get("candidate",{}).get("match_classification")
            data["measurement"]=evidence.get("evaluation",{}).get("qj",{}).get("measurement")
            result.append(data)
        return result

    def latest_confirmation(self, assessment_id, actor_id):
        """Read-only: the most recent confirmation snapshot for an owned
        assessment. RESTORES panel state after reload (CP-10 DEF-06); performs
        no write and no state transition."""
        from sqlalchemy import text
        return self.session.execute(text("""
            SELECT s.id, s.assessment_id, s.assessment_revision, s.actor_user_id,
                   s.created_at,
                   (s.assessment_revision = a.confirmed_revision AND
                    s.assessment_revision = a.revision) AS is_current
            FROM public.m2_confirmation_snapshots s
            JOIN public.m2_assessments a
              ON a.id = s.assessment_id AND a.owner_user_id = s.actor_user_id
            WHERE s.assessment_id = :aid AND a.owner_user_id = :actor
            ORDER BY s.created_at DESC LIMIT 1
        """), dict(aid=assessment_id, actor=actor_id)).mappings().first()

    def workflow_overview(self, assessment_id, actor_id, sequence):
        from sqlalchemy import text
        return self.session.execute(text("""
            SELECT p.projection_id,p.assessment_id,p.assessment_revision,p.schema_version,
                   p.projection_sequence,p.source_fingerprint,p.projection_data,p.created_at,
                   p.projection_sequence=(SELECT max(n.projection_sequence)
                     FROM public.assessment_workflow_projection n WHERE n.assessment_id=p.assessment_id) AS is_current
            FROM public.assessment_workflow_projection p JOIN public.m2_assessments a
              ON a.id=p.assessment_id AND a.owner_user_id=p.owner_user_id
            WHERE p.assessment_id=:aid AND a.owner_user_id=:actor
              AND (CAST(:seq AS bigint) IS NULL OR p.projection_sequence=:seq)
            ORDER BY p.projection_sequence DESC LIMIT 1
        """),dict(aid=assessment_id,actor=actor_id,seq=sequence)).mappings().first()
