"""Pinned M2 review projection; no evaluation, decisions or downstream authority."""
from datetime import datetime, timezone
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from sitewise.core.exceptions import ConflictError
from sitewise.domain.m2_provenance import DECLARATION_SNAPSHOT_VERSIONS
from sitewise.services.bdj_service import BDJService
from sitewise.services.m2_service import M2Service
from sitewise.services.ports.m2_repository_port import M2RepositoryPort


class ReadModel(BaseModel):
    model_config = ConfigDict(extra='forbid', frozen=True)


#: The stored answer value for every M2 V2 answer kind:
#:
#: * ``GEO`` / ``SINGLE``  -> ``str``
#: * ``MULTI``             -> ``list[str]``
#: * ``COMPOSITE``         -> ``dict[str, Any]`` (nested lists/objects allowed)
#:
#: ``COMPOSITE`` is a first-class instrument answer kind, not corrupt data: the
#: M2 V2 instrument declares items such as M2V2-12/13/14/16/17/18/19 as
#: ``answer_kind = COMPOSITE`` and stores a structured object per answer. The
#: original contract only admitted ``str | list[str]``, so any confirmation that
#: pinned a composite answer raised a pydantic ``ValidationError`` and the whole
#: read surfaced as HTTP 500 (DEF-02).
AnswerValue = str | list[str] | dict[str, Any] | None


def is_structured_value(value: object) -> bool:
    """True when a pinned answer value is a ``COMPOSITE`` structured object."""
    return isinstance(value, dict)


#: Frozen original contract. Emitted whenever no composite answer is pinned.
CONTRACT_V1 = 'project1-confirmed-review/1'
#: Identical to V1 except that ``answers[].value`` may also be a JSON object.
CONTRACT_V2 = 'project1-confirmed-review/2'


def review_contract_version(values) -> str:
    """Pick the contract version for a set of pinned answer values.

    Data-driven and never caller-selectable. ``/1`` is emitted unless a
    ``COMPOSITE`` object is actually present, so a reader that only understands
    the original shape can never receive a value it cannot parse.
    """
    return CONTRACT_V2 if any(is_structured_value(v) for v in values) else CONTRACT_V1


class ReviewAnswer(ReadModel):
    item_key: str
    question: str
    answer_state: str
    value: AnswerValue
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
    #: ``/1`` is the frozen original contract: every answer value is ``str``,
    #: ``list[str]`` or ``null``. It is still emitted, byte for byte, whenever the
    #: confirmation pins no structured answer, so existing M2 V1 readers are
    #: unaffected.
    #:
    #: ``/2`` is emitted only when at least one pinned answer is a ``COMPOSITE``
    #: object. The only change is that ``answers[].value`` may then be a JSON
    #: object; every other field, name and guarantee is identical, and the
    #: object is passed through whole rather than flattened or dropped.
    contract_version: Literal[
        'project1-confirmed-review/1', 'project1-confirmed-review/2'
    ] = 'project1-confirmed-review/1'
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
            if snapshot.get('snapshot_contract_version') in DECLARATION_SNAPSHOT_VERSIONS:
                # This reader projects the confirmed declaration, not later
                # model findings or a fabricated evaluation receipt.
                worksheet = {**worksheet, 'findings': [],
                             'evaluation_state':'NOT_EVALUATED', 'rule_version':'NOT_EVALUATED'}
            if (worksheet['assessment_id'] != str(assessment_id) or
                    worksheet['revision'] != expected_revision or
                    (snapshot.get('bdj_rule_version') is not None and
                     worksheet['rule_version'] != snapshot['bdj_rule_version']) or
                    (snapshot.get('snapshot_contract_version') not in DECLARATION_SNAPSHOT_VERSIONS and
                     worksheet['evaluation_state'] != 'EVALUATED_CANDIDATE') or
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
            # `project1-confirmed-review/1` is a frozen worksheet contract and
            # ReviewActivity forbids extra fields. The reader now also returns
            # per-kind enrichment (answer_state, item_key, evaluator_version,
            # snapshot_digest, rule_id) for Activity History; it is projected
            # away here so this contract's payload does not change.
            declared = set(ReviewActivity.model_fields)
            activity = [{k: v for k, v in e.items() if k in declared} for e in activity]
            # Version selection is data-driven, never caller-selectable: the
            # frozen `/1` payload is emitted unless a composite value is actually
            # present. A reader that only understands `/1` therefore never
            # receives a shape it cannot parse, and a reader that understands
            # `/2` branches on a field it can see.
            return ConfirmedReview(
                contract_version=review_contract_version(
                    a.value for a in answers_out),
                assessment_id=assessment_id, confirmation_id=confirmation_id,
                assessment_revision=expected_revision, snapshot_digest=source['snapshot_digest'],
                rule_version=worksheet['rule_version'], evaluation_state=worksheet['evaluation_state'],
                answers=answers_out, findings=findings_out,
                activity=[ReviewActivity(**e) for e in activity[:50]],
                activity_truncated=len(activity) > 50,
            )
