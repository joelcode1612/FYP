"""Versioned explanation-result persistence, separate from the execution ledger.

The ledger answers "did an attempt happen and what did it hash to". It does not
hold the explanation text, the validation findings, the report-section linkage or
the historical versions. This module owns those.

Why not ``ai_explanation``
--------------------------
``sitewise.db.models.ai_explanation`` is a legacy property-scoped table
(``property_id``, ``user_id``, ``content``, ``created_at``). It has no snapshot
binding, no registry version, no validation evidence and no history, and it is
keyed to a property rather than to a measurement. Reusing it would silently give
an explanation the wrong subject, so it is left alone.

Why a new table rather than a ledger column
-------------------------------------------
``project1_ai`` already separates execution from result: ``bdj_results``
(migration ``20261117_03``) stores the validated structured result and its
validation rows beside ``attempts``/``attempt_receipts``. This follows that
approved pattern rather than inventing a second mechanism, and it keeps the
directive's rule that the ledger is an audit trail, not a content store.

Staleness
---------
A result is current only while the source fingerprint, registry version and
ruleset version it was computed under all still match. Nothing is overwritten:
a changed dependency makes the old row non-current and requires revalidation.
That is what makes history reconstructible.

Deterministic results
---------------------
A deterministic explanation writes a row with ``run_id``/``attempt_no`` NULL.
No attempt, receipt or provider identity is fabricated to make the row look
uniform — the ``execution_kind`` column states which producer ran.
"""
from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import datetime
from typing import Protocol
from uuid import UUID, uuid4

from sqlalchemy import text

#: Execution kinds. ``AI_ATTEMPTED`` means a ledger attempt was reserved; it says
#: nothing about whether the candidate was accepted.
DETERMINISTIC_ONLY = 'DETERMINISTIC_ONLY'
AI_ATTEMPTED = 'AI_ATTEMPTED'

VALIDATION_STATUSES = ('not_validated', 'valid', 'invalid')


@dataclass(frozen=True)
class ExplanationResult:
    """One stored explanation, at candidate authority."""
    result_id: str
    assessment_id: str
    campaign_id: str
    snapshot_id: str
    owner_user_id: str
    question_id: str | None
    source_fingerprint: str
    ruleset_version: str
    registry_version: str
    registry_sha256: str
    context_id: str
    task_mode: str
    execution_kind: str
    outcome: str
    validation_status: str
    validation_rules: tuple[str, ...]
    validation_failures: tuple[dict, ...]
    rejection_code: str | None
    retry_authorized: bool
    headline: str
    observation_interpretation: str
    research_interpretation: str
    planning_implication: str
    limitations: str
    summary: str
    insufficient_evidence: bool
    missing_evidence_references: tuple[str, ...]
    report_sections: tuple[str, ...]
    admitted: bool = False
    authority: str = 'CANDIDATE_UNVERIFIED'
    run_id: str | None = None
    attempt_no: int | None = None
    prompt_version: str | None = None
    prompt_sha256: str | None = None
    request_sha256: str | None = None
    model_requested: str | None = None
    model_returned: str | None = None
    created_at: str | None = None
    stale_reason: str | None = None

    @property
    def is_current(self) -> bool:
        return self.stale_reason is None


class ExplanationStorePort(Protocol):
    def record(self, result: ExplanationResult) -> str: ...
    def current(self, *, assessment_id: str, snapshot_id: str,
                question_id: str | None) -> ExplanationResult | None: ...
    def history(self, *, assessment_id: str, snapshot_id: str,
                question_id: str | None) -> list[ExplanationResult]: ...
    def invalidate(self, *, assessment_id: str, snapshot_id: str,
                   question_id: str | None, reason: str) -> int: ...


class InMemoryExplanationStore:
    """Test and development store with the deployed table's semantics.

    Append-only: ``record`` never replaces a row, and ``invalidate`` marks rows
    stale rather than deleting them. ``current`` returns the newest row whose
    dependencies still match, or ``None`` — a stale row is never current.
    """

    def __init__(self) -> None:
        self._rows: list[ExplanationResult] = []

    def record(self, result: ExplanationResult) -> str:
        if result.execution_kind not in (DETERMINISTIC_ONLY, AI_ATTEMPTED):
            raise ValueError('unknown execution_kind')
        if result.validation_status not in VALIDATION_STATUSES:
            raise ValueError('unknown validation_status')
        if result.admitted:
            raise ValueError('an explanation result may not be stored as admitted')
        if result.authority != 'CANDIDATE_UNVERIFIED':
            raise ValueError('an explanation result may not assert authority')
        if result.execution_kind == DETERMINISTIC_ONLY and result.run_id is not None:
            # The inverse of the fabrication rule: a deterministic row must not
            # carry a run id, and an AI row must not omit one.
            raise ValueError('a deterministic result must not name a run')
        if result.execution_kind == AI_ATTEMPTED and result.run_id is None:
            raise ValueError('an AI result must name the run that produced it')
        self._rows.append(result)
        return result.result_id

    def _matching(self, *, assessment_id, snapshot_id, question_id):
        return [row for row in self._rows
                if row.assessment_id == assessment_id
                and row.snapshot_id == snapshot_id
                and row.question_id == question_id]

    def current(self, *, assessment_id: str, snapshot_id: str,
                question_id: str | None) -> ExplanationResult | None:
        live = [row for row in self._matching(
            assessment_id=assessment_id, snapshot_id=snapshot_id,
            question_id=question_id) if row.is_current]
        return live[-1] if live else None

    def history(self, *, assessment_id: str, snapshot_id: str,
                question_id: str | None) -> list[ExplanationResult]:
        return list(self._matching(assessment_id=assessment_id,
                                   snapshot_id=snapshot_id, question_id=question_id))

    def invalidate(self, *, assessment_id: str, snapshot_id: str,
                   question_id: str | None, reason: str) -> int:
        marked = 0
        for index, row in enumerate(self._rows):
            if (row.assessment_id == assessment_id
                    and row.snapshot_id == snapshot_id
                    and row.question_id == question_id
                    and row.is_current):
                self._rows[index] = _with_stale(row, reason)
                marked += 1
        return marked


class PostgresExplanationStore:
    """SQL adapter for ``project1_ai.explanation_results``.

    The table is append-only and owner-scoped. This adapter never updates or
    deletes: invalidation inserts a stale superseding row, so the old result stays
    reconstructible. It also refuses protected database targets before issuing a
    query, because a store that silently reaches a production database is worse
    than a store that is unavailable.
    """

    #: EX-05 is explicitly confined to the two recognised disposable databases.
    DEFAULT_ALLOWED_DATABASES = frozenset({
        'project1_workflow_tests', 'project1_disposable_app'})
    ALLOWED_ROLES = frozenset({'p1ai_runtime', 'p1ai_audit', 'postgres'})

    def __init__(self, engine, *, actor_id: str | None = None,
                 role: str = 'p1ai_runtime',
                 allowed_databases: frozenset[str] | None = None,
                 allowed_port: int = 5433) -> None:
        if role not in self.ALLOWED_ROLES:
            raise ValueError('unsupported explanation store role')
        self.engine = engine
        self.actor_id = str(actor_id) if actor_id is not None else None
        self.role = role
        self.allowed_databases = (allowed_databases or self.DEFAULT_ALLOWED_DATABASES)
        self.allowed_port = int(allowed_port)

    # -- connection scope -------------------------------------------------
    def _guard(self, conn) -> None:
        database, port = conn.execute(
            text('SELECT current_database(), inet_server_port()')).one()
        if (database not in self.allowed_databases
                or int(port) != self.allowed_port):
            raise ValueError(
                f'EXPLANATION_STORE_TARGET_REFUSED: {database}@{port}')

    def _scope(self, conn) -> None:
        if self.actor_id is not None:
            conn.execute(text("SELECT set_config('project1.actor_id', :actor, true)"),
                         {'actor': self.actor_id})
        if self.role != 'postgres':
            # Role names are validated in __init__, so this is not an injection
            # surface. SET LOCAL keeps the privilege confined to this transaction.
            conn.execute(text(f'SET LOCAL ROLE {self.role}'))

    def _validate(self, result: ExplanationResult, *, allow_stale: bool = False) -> None:
        if result.execution_kind not in (DETERMINISTIC_ONLY, AI_ATTEMPTED):
            raise ValueError('unknown execution_kind')
        if result.validation_status not in VALIDATION_STATUSES:
            raise ValueError('unknown validation_status')
        if result.admitted:
            raise ValueError('an explanation result may not be stored as admitted')
        if result.authority != 'CANDIDATE_UNVERIFIED':
            raise ValueError('an explanation result may not assert authority')
        if result.execution_kind == DETERMINISTIC_ONLY and result.run_id is not None:
            raise ValueError('a deterministic result must not name a run')
        if result.execution_kind == AI_ATTEMPTED and (
                result.run_id is None or result.attempt_no is None):
            raise ValueError('an AI result must name the run that produced it')
        if result.validation_status == 'invalid' and not result.rejection_code:
            raise ValueError('an invalid result must name a rejection code')
        if not allow_stale and result.stale_reason is not None:
            raise ValueError('caller may not assert staleness; use invalidate()')
        if self.actor_id is not None and result.owner_user_id != self.actor_id:
            raise ValueError('EXPLANATION_STORE_OWNER_MISMATCH')
        UUID(result.owner_user_id)
        UUID(result.assessment_id)
        UUID(result.campaign_id)
        UUID(result.snapshot_id)
        if result.run_id is not None:
            UUID(result.run_id)

    # -- SQL --------------------------------------------------------------
    _RESULT_COLUMNS = (
        'result_id', 'owner_user_id', 'assessment_id', 'campaign_id',
        'snapshot_id', 'question_id', 'source_fingerprint', 'context_id',
        'registry_version', 'registry_sha256', 'ruleset_version', 'task_mode',
        'execution_kind', 'outcome', 'run_id', 'attempt_no', 'prompt_version',
        'prompt_sha256', 'request_sha256', 'model_requested', 'model_returned',
        'validation_status', 'rejection_code', 'fallback_reason',
        'retry_authorized', 'headline', 'observation_interpretation',
        'research_interpretation', 'planning_implication', 'limitations',
        'summary', 'insufficient_evidence', 'missing_evidence_references',
        'report_sections', 'authority', 'admitted', 'stale_reason',
    )

    def _insert_result(self, conn, result: ExplanationResult) -> str:
        values = {
            'result_id': UUID(result.result_id),
            'owner_user_id': UUID(result.owner_user_id),
            'assessment_id': UUID(result.assessment_id),
            'campaign_id': UUID(result.campaign_id),
            'snapshot_id': UUID(result.snapshot_id),
            'question_id': result.question_id,
            'source_fingerprint': result.source_fingerprint,
            'context_id': result.context_id,
            'registry_version': result.registry_version,
            'registry_sha256': result.registry_sha256,
            'ruleset_version': result.ruleset_version,
            'task_mode': result.task_mode,
            'execution_kind': result.execution_kind,
            'outcome': result.outcome,
            'run_id': UUID(result.run_id) if result.run_id else None,
            'attempt_no': result.attempt_no,
            'prompt_version': result.prompt_version,
            'prompt_sha256': result.prompt_sha256,
            'request_sha256': result.request_sha256,
            'model_requested': result.model_requested,
            'model_returned': result.model_returned,
            'validation_status': result.validation_status,
            'rejection_code': result.rejection_code,
            'fallback_reason': result.outcome[:256],
            'retry_authorized': bool(result.retry_authorized),
            'headline': result.headline,
            'observation_interpretation': result.observation_interpretation,
            'research_interpretation': result.research_interpretation,
            'planning_implication': result.planning_implication,
            'limitations': result.limitations,
            'summary': result.summary,
            'insufficient_evidence': bool(result.insufficient_evidence),
            'missing_evidence_references': list(result.missing_evidence_references),
            'report_sections': list(result.report_sections),
            'authority': result.authority,
            'admitted': False,
            'stale_reason': result.stale_reason,
        }
        columns = ', '.join(self._RESULT_COLUMNS)
        params = ', '.join(f':{name}' for name in self._RESULT_COLUMNS)
        conn.execute(text(
            f'INSERT INTO project1_ai.explanation_results ({columns}) '
            f'VALUES ({params})'), values)

        failures = {f.get('rule_id'): f for f in result.validation_failures}
        rules = tuple(result.validation_rules)
        if result.validation_status == 'valid' and not rules:
            rules = tuple(f'V{n:02d}' for n in range(1, 10))
        for rule_id in rules:
            if rule_id not in failures and result.validation_status != 'valid':
                continue
            failure = failures.get(rule_id, {})
            passed = result.validation_status == 'valid' and not failure
            conn.execute(text(
                'INSERT INTO project1_ai.explanation_result_validations '
                '(result_id, owner_user_id, rule_id, passed, code, detail) '
                'VALUES (:result_id, :owner_user_id, :rule_id, :passed, :code, :detail)'),
                {
                    'result_id': UUID(result.result_id),
                    'owner_user_id': UUID(result.owner_user_id),
                    'rule_id': rule_id,
                    'passed': passed,
                    'code': failure.get('code'),
                    'detail': str(failure.get('detail') or '')[:512] or None,
                })
        return result.result_id

    def _validations(self, conn, result_id: str) -> tuple[tuple[str, ...], tuple[dict, ...]]:
        rows = conn.execute(text(
            'SELECT rule_id, passed, code, detail '
            'FROM project1_ai.explanation_result_validations '
            'WHERE result_id=:result_id ORDER BY rule_id'),
            {'result_id': UUID(result_id)}).mappings().all()
        rules = tuple(str(row['rule_id']) for row in rows)
        failures = tuple(
            {'rule_id': str(row['rule_id']), 'passed': bool(row['passed']),
             'code': row['code'], 'detail': row['detail']}
            for row in rows if not row['passed'])
        return rules, failures

    def _row(self, conn, row) -> ExplanationResult:
        data = dict(row._mapping if hasattr(row, '_mapping') else row)
        rules, failures = self._validations(conn, str(data['result_id']))
        return ExplanationResult(
            result_id=str(data['result_id']),
            assessment_id=str(data['assessment_id']),
            campaign_id=str(data['campaign_id']),
            snapshot_id=str(data['snapshot_id']),
            owner_user_id=str(data['owner_user_id']),
            question_id=data['question_id'],
            source_fingerprint=data['source_fingerprint'],
            registry_version=data['registry_version'],
            registry_sha256=data['registry_sha256'],
            ruleset_version=data['ruleset_version'],
            context_id=data['context_id'],
            task_mode=data['task_mode'],
            execution_kind=data['execution_kind'],
            outcome=data['outcome'],
            validation_status=data['validation_status'],
            validation_rules=rules,
            validation_failures=failures,
            rejection_code=data['rejection_code'],
            retry_authorized=bool(data['retry_authorized']),
            headline=data['headline'],
            observation_interpretation=data['observation_interpretation'],
            research_interpretation=data['research_interpretation'],
            planning_implication=data['planning_implication'],
            limitations=data['limitations'],
            summary=data['summary'],
            insufficient_evidence=bool(data['insufficient_evidence']),
            missing_evidence_references=tuple(data['missing_evidence_references'] or ()),
            report_sections=tuple(data['report_sections'] or ()),
            admitted=bool(data['admitted']),
            authority=data['authority'],
            run_id=str(data['run_id']) if data['run_id'] else None,
            attempt_no=data['attempt_no'],
            prompt_version=data['prompt_version'],
            prompt_sha256=data['prompt_sha256'],
            request_sha256=data['request_sha256'],
            model_requested=data['model_requested'],
            model_returned=data['model_returned'],
            created_at=(data['created_at'].isoformat()
                        if isinstance(data['created_at'], datetime)
                        else data['created_at']),
            stale_reason=data['stale_reason'],
        )

    def _select(self, conn, *, assessment_id, snapshot_id, question_id,
                current_only: bool):
        where = ('assessment_id=:assessment_id AND snapshot_id=:snapshot_id '
                 'AND question_id IS NOT DISTINCT FROM :question_id')
        rows = conn.execute(text(
            'SELECT * FROM project1_ai.explanation_results WHERE ' + where +
            ' ORDER BY created_at DESC, result_id DESC'),
            {'assessment_id': assessment_id, 'snapshot_id': snapshot_id,
             'question_id': question_id}).mappings().all()
        if current_only:
            # Invalidation is append-only: the newest row may be a stale
            # superseding marker. It invalidates the older history without
            # mutating it, and no earlier row becomes current again.
            if not rows or rows[0]['stale_reason'] is not None:
                return []
            return [self._row(conn, rows[0])]
        return [self._row(conn, row) for row in rows]

    @staticmethod
    def _same_content(left: ExplanationResult, right: ExplanationResult) -> bool:
        fields = (
            'assessment_id', 'campaign_id', 'snapshot_id', 'owner_user_id',
            'question_id', 'source_fingerprint', 'context_id', 'registry_version',
            'registry_sha256', 'ruleset_version', 'task_mode', 'execution_kind',
            'outcome', 'run_id', 'attempt_no', 'prompt_version', 'prompt_sha256',
            'request_sha256', 'model_requested', 'model_returned',
            'validation_status', 'rejection_code', 'retry_authorized', 'headline',
            'observation_interpretation', 'research_interpretation',
            'planning_implication', 'limitations', 'summary',
            'insufficient_evidence', 'missing_evidence_references',
            'report_sections', 'authority', 'admitted')
        return all(getattr(left, name) == getattr(right, name) for name in fields)

    # -- store contract ---------------------------------------------------
    def record(self, result: ExplanationResult) -> str:
        self._validate(result)
        with self.engine.begin() as conn:
            self._guard(conn)
            self._scope(conn)
            existing = self._select(
                conn, assessment_id=result.assessment_id,
                snapshot_id=result.snapshot_id, question_id=result.question_id,
                current_only=True)
            if existing and self._same_content(existing[0], result):
                return existing[0].result_id
            return self._insert_result(conn, result)

    def current(self, *, assessment_id: str, snapshot_id: str,
                question_id: str | None) -> ExplanationResult | None:
        with self.engine.begin() as conn:
            self._guard(conn)
            self._scope(conn)
            rows = self._select(conn, assessment_id=assessment_id,
                                snapshot_id=snapshot_id, question_id=question_id,
                                current_only=True)
            return rows[0] if rows else None

    def history(self, *, assessment_id: str, snapshot_id: str,
                question_id: str | None) -> list[ExplanationResult]:
        with self.engine.begin() as conn:
            self._guard(conn)
            self._scope(conn)
            return self._select(conn, assessment_id=assessment_id,
                                snapshot_id=snapshot_id, question_id=question_id,
                                current_only=False)

    def invalidate(self, *, assessment_id: str, snapshot_id: str,
                   question_id: str | None, reason: str) -> int:
        if self.role != 'p1ai_runtime':
            raise ValueError('invalidate requires the runtime role')
        with self.engine.begin() as conn:
            self._guard(conn)
            self._scope(conn)
            current = self._select(conn, assessment_id=assessment_id,
                                   snapshot_id=snapshot_id,
                                   question_id=question_id, current_only=True)
            for row in current:
                tombstone = replace(row, result_id=str(uuid4()),
                                    stale_reason=reason[:128], created_at=None)
                self._validate(tombstone, allow_stale=True)
                self._insert_result(conn, tombstone)
            return len(current)


def _with_stale(row: ExplanationResult, reason: str) -> ExplanationResult:
    from dataclasses import replace
    return replace(row, stale_reason=reason)


def staleness_reason(row: ExplanationResult, *, source_fingerprint: str,
                     registry_version: str, ruleset_version: str) -> str | None:
    """Why a stored result may no longer be used, or ``None`` when it may.

    Checked in dependency order: the measurement first (a different snapshot is a
    different result), then the explanation rules, then the measurement ruleset.
    """
    if row.source_fingerprint != source_fingerprint:
        return 'SOURCE_FINGERPRINT_CHANGED'
    if row.registry_version != registry_version:
        return 'EXPLANATION_REGISTRY_CHANGED'
    if row.ruleset_version != ruleset_version:
        return 'MEASUREMENT_RULESET_CHANGED'
    return None


def build_result(*, record: dict, candidate, registry_version: str,
                 registry_sha256: str, result_id: str,
                 owner_user_id: str, report_sections: tuple[str, ...] = (),
                 created_at: str | None = None) -> ExplanationResult:
    """Turn an ``explanation_execution.result_record`` into a storable row."""
    return ExplanationResult(
        result_id=result_id,
        assessment_id=record['assessment_id'],
        campaign_id=record['campaign_id'],
        snapshot_id=record['snapshot_id'],
        owner_user_id=owner_user_id,
        question_id=record['question_id'],
        source_fingerprint=record['source_fingerprint'],
        ruleset_version=record['ruleset_version'],
        registry_version=registry_version,
        registry_sha256=registry_sha256,
        context_id=record['context_id'],
        task_mode=record.get('task_mode') or candidate.task_mode,
        execution_kind=record['execution_kind'],
        outcome=record['outcome'],
        validation_status=record['validation_status'],
        validation_rules=tuple(record['validation_rules']),
        validation_failures=tuple(record['validation_failures']),
        rejection_code=record['rejection_code'],
        retry_authorized=bool(record['retry_authorized']),
        headline=candidate.headline,
        observation_interpretation=candidate.observation_interpretation,
        research_interpretation=candidate.research_interpretation,
        planning_implication=candidate.planning_implication,
        limitations=candidate.limitations,
        summary=candidate.summary,
        insufficient_evidence=bool(candidate.insufficient_evidence),
        missing_evidence_references=tuple(candidate.missing_evidence_references),
        report_sections=report_sections,
        run_id=record['run_id'],
        attempt_no=record['attempt_no'],
        prompt_version=record['prompt_version'],
        prompt_sha256=record['prompt_sha256'],
        request_sha256=record['request_sha256'],
        model_requested=record['model_requested'],
        model_returned=record['model_returned'],
        created_at=created_at,
    )
