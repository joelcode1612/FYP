"""Pinned M2 review projection; no evaluation, decisions or downstream authority."""
from datetime import datetime, timezone
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from sitewise.core.exceptions import ConflictError
from sitewise.services.bdj_service import BDJService
from sitewise.services.m2_service import M2Service
from sitewise.services.ports.m2_repository_port import M2RepositoryPort


class ReadModel(BaseModel):
    model_config = ConfigDict(extra='forbid', frozen=True)


class ReviewAnswer(ReadModel):
    item_key: str
    question: str
    answer_state: str
    value: str | list[str] | None
    source_answer_revision_id: UUID
    source_item_version_id: UUID


class ReviewFinding(ReadModel):
    id: UUID
    rule_id: str
    issue_type: str
    explanation: str
    not_proven: str
    next_action: str
    review_state: str
    source_answer_ids: list[UUID]


class ReviewActivity(ReadModel):
    event_id: UUID
    kind: Literal['ANSWER_SAVED', 'BDJ_EVALUATED', 'REVIEW_RECORDED',
                  'CONTEXT_CONFIRMED', 'CLARIFICATION_RECORDED']
    assessment_revision: int = Field(ge=0)
    occurred_at: datetime
    actor_id: UUID | None


class ConfirmedReview(ReadModel):
    contract_version: Literal['project1-confirmed-review/1'] = 'project1-confirmed-review/1'
    assessment_id: UUID
    confirmation_id: UUID
    assessment_revision: int = Field(ge=0)
    snapshot_digest: str = Field(pattern=r'^[0-9a-f]{64}$')
    source_status: Literal['CURRENT_CONFIRMED_SOURCE'] = 'CURRENT_CONFIRMED_SOURCE'
    trust_class: Literal['T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION'] = 'T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION'
    rule_version: str
    evaluation_state: Literal['EVALUATED_CANDIDATE', 'NOT_EVALUATED']
    answers: list[ReviewAnswer]
    findings: list[ReviewFinding]
    activity: list[ReviewActivity]
    activity_truncated: bool
    activity_scope: Literal['M2_RECORDS_THROUGH_CONFIRMED_REVISION'] = 'M2_RECORDS_THROUGH_CONFIRMED_REVISION'
    fielding_authorized: Literal[False] = False
    qj_handoff_authorized: Literal[False] = False
    report_release_authorized: Literal[False] = False


class ConfirmedReviewService:
    def __init__(self, repository: M2RepositoryPort):
        self.repo = repository
        self.m2 = M2Service(repository)
        self.bdj = BDJService(repository)

    def read(self, assessment_id: UUID, actor_id: UUID, *, confirmation_id: UUID,
             expected_revision: int) -> ConfirmedReview:
        # Same repository/transaction: retain the assessment lock until every
        # projection is assembled; normal edit/evaluate/confirm writers share it.
        with self.m2.locked_confirmed_source(assessment_id, actor_id,
                confirmation_id=confirmation_id, expected_revision=expected_revision) as source:
            worksheet = self.bdj.read_worksheet(assessment_id, actor_id)
            snapshot = source['snapshot']
            if (worksheet['assessment_id'] != str(assessment_id) or
                    worksheet['revision'] != expected_revision or
                    (snapshot.get('bdj_rule_version') is not None and
                     worksheet['rule_version'] != snapshot['bdj_rule_version']) or
                    worksheet['evaluation_state'] != 'EVALUATED_CANDIDATE' or
                    sorted(str(f['id']) for f in worksheet['findings']) !=
                    snapshot.get('unresolved_candidate_findings')):
                raise ConflictError('Review source revision or ruleset has changed.')
            pinned = {a['answer_revision_id']: a for a in snapshot['answer_revisions']}
            answers_out = []
            for answer in worksheet['declared_m2_answers']:
                saved = pinned.get(answer['source_answer_revision_id'])
                if saved is None or any(saved[k] != answer[v] for k, v in (
                        ('item_key', 'item_key'), ('item_version_id', 'source_item_version_id'),
                        ('answer_state', 'answer_state'), ('value', 'value'))):
                    raise ConflictError('Review answer source does not match its confirmation.')
                answers_out.append(ReviewAnswer(**answer))
            findings_out = []
            rendered_sources = {str(answer.source_answer_revision_id) for answer in answers_out}
            for finding in worksheet['findings']:
                if (finding['assessment_id'] != assessment_id or
                        finding['assessment_revision'] != expected_revision or
                        not finding['source_answer_ids'] or
                        not set(finding['source_answer_ids']).issubset(rendered_sources)):
                    raise ConflictError('Review finding has an unbound source.')
                findings_out.append(ReviewFinding(**{k: finding[k] for k in ReviewFinding.model_fields}))
            activity = self.repo.read_activity(assessment_id, actor_id, expected_revision, 50)
            # PostgreSQL returns aware timestamptz. The isolated SQLite adapter
            # returns naive values from its UTC CURRENT_TIMESTAMP.
            for event in activity:
                at = event['occurred_at']
                event['occurred_at'] = at.replace(tzinfo=timezone.utc) if at.tzinfo is None else at.astimezone(timezone.utc)
            activity.sort(key=lambda e: (e['occurred_at'], str(e['event_id'])), reverse=True)
            return ConfirmedReview(
                assessment_id=assessment_id, confirmation_id=confirmation_id,
                assessment_revision=expected_revision, snapshot_digest=source['snapshot_digest'],
                rule_version=worksheet['rule_version'], evaluation_state=worksheet['evaluation_state'],
                answers=answers_out, findings=findings_out,
                activity=[ReviewActivity(**e) for e in activity[:50]],
                activity_truncated=len(activity) > 50,
            )
