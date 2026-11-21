"""Infrastructure adapter. Uses the existing SQLModel/SQLAlchemy Session.

The tables live in separate opt-in SQLAlchemy metadata to prevent the legacy
startup create_all hook from silently provisioning an unapproved schema.
"""
from uuid import UUID, uuid4

from sqlalchemy import and_, select, update, func
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

    def read_activity(self, assessment_id: UUID, actor_id: UUID,
                      revision: int, limit: int, *, include_metadata=False) -> list[dict]:
        """Existing receipts only; bounded queries, ownership enforced in SQL.

        Fetch limit+1 from each stream then merge globally in the service.
        A missing stream raises instead of masquerading as an empty history.
        """
        rows = []
        for table, kind in ((answers, 'ANSWER_SAVED'), (evaluations, 'BDJ_EVALUATED'),
                            (reviews, 'REVIEW_RECORDED'), (confirmations, 'CONTEXT_CONFIRMED'),
                            (clarification_events, 'CLARIFICATION_RECORDED')):
            statement = (select(table)
                .join(assessments, table.c.assessment_id == assessments.c.id)
                .where(and_(table.c.assessment_id == assessment_id,
                            assessments.c.owner_user_id == actor_id,
                            table.c.assessment_revision <= revision))
                .order_by(table.c.created_at.desc(), table.c.id.desc()).limit(limit + 1))
            for row in _all(self.session, statement):
                event = {'event_id': row['id'], 'kind': kind,
                    'assessment_revision': row['assessment_revision'],
                    'occurred_at': row['created_at'], 'actor_id': row.get('actor_user_id')}
                if include_metadata:
                    event.update(status=row.get('decision'), source_id=row.get('finding_id'),
                                 reason=row.get('evaluator_version'))
                rows.append(event)
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
                    findings.c.created_at, findings.c.review_state, findings.c.rule_id)
            .join(assessments, findings.c.assessment_id == assessments.c.id)
            .where(assessments.c.id == assessment_id,
                   assessments.c.owner_user_id == actor_id,
                   findings.c.assessment_revision <= revision)
            .order_by(findings.c.created_at.desc(), findings.c.id.desc()).limit(limit + 1))
        for row in _all(self.session, statement):
            events.append({'event_id': row['id'], 'kind': 'CANDIDATE_FINDING_RECORDED',
                'assessment_revision': row['assessment_revision'],
                'occurred_at': row['created_at'], 'actor_id': None, 'module': 'BDJ',
                'status': row['review_state'], 'reason': row['rule_id']})
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
                events.append({'event_id': row['context_id'], 'kind': 'CONTEXT_PERSISTED',
                    'assessment_revision': row['assessment_revision'],
                    'occurred_at': row['created_at'], 'actor_id': None,
                    'module': 'BCB', 'status': row['lifecycle_status'],
                    'reason': row['builder_version'], 'source_id': row['confirmation_id'],
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

    def persist_candidate(self, version, objective_id, receipt):
        import json
        from sqlalchemy import text
        candidate = receipt["candidate"]
        self.session.execute(text("""
            INSERT INTO public.m2_review_question_versions
                (id, objective_id, source_receipt, question, options)
            VALUES (:id,:objective,:receipt,:question,CAST(:options AS jsonb))
            ON CONFLICT(id) DO NOTHING
        """), {"id": version, "objective": objective_id, "receipt": json.dumps(receipt),
               "question": candidate["question"], "options": json.dumps(candidate["options"])})

    def record_owner_review(self, version, reviewer, decision, rationale):
        from sqlalchemy import text
        # Lock the assessment used by M2 revisions while recording this decision.
        return self.session.execute(text("""
            INSERT INTO public.m2_candidate_owner_reviews(candidate_id,reviewer_id,decision,rationale)
            SELECT q.id, a.reviewer_id, :decision, :rationale
            FROM public.m2_candidate_review_assignments a
            JOIN public.m2_review_question_versions q ON q.id=a.candidate_id
            JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id
            JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
            JOIN public.m2_assessments m ON m.id=c.assessment_id
            WHERE q.id=:version AND a.reviewer_id=:reviewer AND m.owner_user_id<>a.reviewer_id
              AND m.confirmed_revision=m.revision AND m.revision=c.assessment_revision
              AND NOT EXISTS(SELECT 1 FROM public.m2_review_question_versions n WHERE n.supersedes=q.id)
            FOR UPDATE OF m
            ON CONFLICT(candidate_id) DO NOTHING
            RETURNING candidate_id,reviewer_id,decision,rationale,recorded_at
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
              AND a.revision=:revision AND c.assessment_revision=a.revision AND a.confirmed_revision=a.revision
            ORDER BY u.created_at,u.id,q.id
        """), dict(id=confirmation_id,actor=actor_id,revision=revision)).mappings()
        return [dict(row) for row in rows]

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
