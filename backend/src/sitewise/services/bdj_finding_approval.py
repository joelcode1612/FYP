"""Record that an owner decided a finding is worth researching (decision S1/A1/P1).

WHAT THIS GRANTS
    Exactly one thing: eligibility to attach the finding to a research objective.
    It does NOT assert the finding is true, and it does NOT make it VERIFIED.
    A1 is self-approval: the same owner who declared the gap decides it is worth
    pursuing. Any report must say so; calling this "independent review" is false.

WHAT IT REFUSES
    * a finding from a different assessment or revision;
    * a confirmation that is not the one this finding was produced under;
    * a second decision for the same (confirmation, finding);
    * a replay of the same request_id.

WHY A HASH
    ``finding_hash`` pins the finding content at decision time. The finding row is
    append-only, so a later mismatch means the decision referred to something that
    is no longer what it described.
"""
from __future__ import annotations

import hashlib
import json
from uuid import UUID, uuid4

from sqlalchemy import text


class ApprovalRefused(ValueError):
    """A decision could not be recorded. The message is a stable code."""


def finding_hash(row: dict) -> str:
    """Canonical hash of the finding content a decision is about."""
    payload = {
        'id': str(row['id']),
        'assessment_id': str(row['assessment_id']),
        'assessment_revision': int(row['assessment_revision']),
        'rule_id': row['rule_id'],
        'rule_version': row['rule_version'],
        # Sorted: the same source set must hash the same regardless of array
        # order, and this matches m2_bdj_source_identity / source_digest.
        'source_answer_ids': sorted(str(x) for x in (row['source_answer_ids'] or [])),
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(',', ':'),
                   ensure_ascii=False).encode('utf-8')).hexdigest()


def approve_finding(*, m2_session, actor_id: UUID, assessment_id: UUID,
                    revision: int, confirmation_id: UUID, finding_id: UUID,
                    request_id: UUID | None = None) -> dict:
    """Record WORTH_RESEARCHING for one finding. Idempotent on request_id."""
    request_id = request_id or uuid4()
    m2_session.execute(text("SELECT set_config('project1.actor_id', :a, true)"),
                       {'a': str(actor_id)})

    assessment = m2_session.execute(text(
        'SELECT revision, confirmed_revision FROM public.m2_assessments '
        'WHERE id=:id AND owner_user_id=:owner'),
        {'id': assessment_id, 'owner': actor_id}).mappings().first()
    if assessment is None:
        raise ApprovalRefused('ASSESSMENT_NOT_FOUND')
    if assessment['confirmed_revision'] != revision or assessment['revision'] != revision:
        raise ApprovalRefused('ASSESSMENT_NOT_CURRENT')

    confirmation = m2_session.execute(text(
        'SELECT 1 FROM public.m2_confirmation_snapshots '
        'WHERE id=:c AND assessment_id=:a AND assessment_revision=:r AND actor_user_id=:o'),
        {'c': confirmation_id, 'a': assessment_id, 'r': revision,
         'o': actor_id}).first()
    if confirmation is None:
        raise ApprovalRefused('CONFIRMATION_MISMATCH')

    finding = m2_session.execute(text(
        'SELECT id, assessment_id, assessment_revision, rule_id, rule_version, '
        'source_answer_ids, review_state FROM public.m2_bdj_findings '
        'WHERE id=:f AND assessment_id=:a AND assessment_revision=:r'),
        {'f': finding_id, 'a': assessment_id, 'r': revision}).mappings().first()
    if finding is None:
        raise ApprovalRefused('FINDING_NOT_FOUND')
    if finding['review_state'] != 'CANDIDATE':
        # S1 can only approve a candidate. A VERIFIED row cannot exist today, and
        # this guard is what keeps that true if one ever does.
        raise ApprovalRefused('FINDING_NOT_CANDIDATE')

    event_id = uuid4()
    inserted = m2_session.execute(text(
        'INSERT INTO public.m2_finding_reviews '
        '(id, finding_id, assessment_id, assessment_revision, confirmation_id, '
        ' actor_user_id, decision, finding_hash, request_id) '
        "VALUES (:id,:f,:a,:r,:c,:o,'WORTH_RESEARCHING',:h,:req) "
        'ON CONFLICT DO NOTHING'),
        {'id': event_id, 'f': finding_id, 'a': assessment_id, 'r': revision,
         'c': confirmation_id, 'o': actor_id, 'h': finding_hash(dict(finding)),
         'req': request_id}).rowcount

    if inserted == 0:
        # Either this request_id was already used, or a decision already exists
        # for this finding under this confirmation. Both are refusals, not no-ops.
        existing = m2_session.execute(text(
            'SELECT id, request_id FROM public.m2_finding_reviews '
            'WHERE confirmation_id=:c AND finding_id=:f'),
            {'c': confirmation_id, 'f': finding_id}).mappings().first()
        if existing and str(existing['request_id']) == str(request_id):
            return {'event_id': str(existing['id']), 'replayed': True,
                    'decision': 'WORTH_RESEARCHING', 'self_approval': True}
        raise ApprovalRefused('FINDING_ALREADY_DECIDED')

    return {'event_id': str(event_id), 'replayed': False,
            'decision': 'WORTH_RESEARCHING', 'self_approval': True,
            'finding_hash': finding_hash(dict(finding))}
