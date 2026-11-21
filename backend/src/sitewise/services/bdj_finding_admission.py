"""Materialise validated BDJ findings as durable M2 rows and link them.

Why this exists
    A validated cloud BDJ result stores its findings only inside
    ``project1_ai.bdj_results.result_payload``. Nothing creates a
    ``public.m2_bdj_findings`` row, so a finding has no identity that review,
    approval or an objective can point at. ``project1_ai.bdj_result_findings``
    already requires ``finding_id NOT NULL REFERENCES public.m2_bdj_findings(id)``
    and is therefore unfillable today.

Two connections, on purpose
    ``public.m2_bdj_findings`` is writable only by ``p1_m2_runtime``;
    ``project1_ai.bdj_result_findings`` only by ``p1ai_runtime``. This function
    takes both rather than widening either grant. The caller already holds both.

Identity is content-derived
    ``finding_id = uuid5(NS, assessment|revision|rule|rule_version|source_digest)``
    where ``source_digest = sha256(','.join(sorted(answer_revision_ids)))``.
    The same canonical form the D3 migration derives, so re-running an execution
    reproduces the same id instead of creating a duplicate.

What this does NOT claim
    Authority stays ``candidate``. No review, no approval, no verification, no
    objective. ``review_state`` is written once and the table is append-only, so
    this function can never promote anything later.
"""
from __future__ import annotations

import hashlib
from uuid import NAMESPACE_URL, UUID, uuid5

from sqlalchemy import text

FINDING_NAMESPACE = 'sitewise-bdj-finding/1'


def source_digest(answer_revision_ids) -> str:
    """Canonical source digest. Must match public.m2_bdj_source_identity(json)."""
    ids = sorted(str(x) for x in answer_revision_ids)
    return hashlib.sha256(','.join(ids).encode('utf-8')).hexdigest()


def finding_identity(assessment_id, revision, rule_id, rule_version, digest: str) -> UUID:
    return uuid5(NAMESPACE_URL, '|'.join((
        FINDING_NAMESPACE, str(assessment_id), str(int(revision)),
        str(rule_id), str(rule_version), digest)))


def _bind(conn, actor_id, identity_assertion):
    """Bind the actor on a runtime connection, minting an assertion if needed."""
    if identity_assertion is None:
        from sitewise.core.config import settings as _settings
        if getattr(_settings, 'm2_protected_identity_enabled', False):
            from sitewise.db.m2_identity_assertion import mint_m2_assertion
            identity_assertion = mint_m2_assertion(
                actor_id, _settings.m2_identity_assertion_key.get_secret_value())
    if identity_assertion is not None:
        conn.execute(text("SELECT set_config('project1.identity_assertion', :v, true)"),
                     {'v': identity_assertion})
    else:
        conn.execute(text("SELECT set_config('project1.actor_id', :a, true)"),
                     {'a': str(actor_id)})


def admit_and_link(*, m2_session, runtime_engine, actor_id, assessment_id: UUID,
                   revision: int, result: dict, ruleset_version: str | None = None,
                   identity_assertion: str | None = None) -> dict:
    """Insert missing findings, then link them to the result. Idempotent.

    Returns a summary so a caller can assert rather than assume.
    """
    findings = result.get('findings') or []
    result_id = result.get('result_id')
    if result_id is None:
        raise ValueError('A persisted result_id is required before linking findings.')

    if ruleset_version is None:
        # The read projection does not expose ruleset_version, so take it from the
        # row the findings belong to rather than trusting a caller-supplied label.
        with runtime_engine.begin() as conn:
            conn.exec_driver_sql('SET LOCAL ROLE p1ai_runtime')
            _bind(conn, actor_id, identity_assertion)
            ruleset_version = conn.execute(text(
                'SELECT ruleset_version FROM project1_ai.bdj_results WHERE result_id=:r'),
                {'r': UUID(str(result_id))}).scalar_one()

    admitted, reused = [], 0
    # Dependent M2 child policies still key on project1.actor_id even under the
    # protected rehearsal (which protects m2_assessments only). Bind it as well as
    # whatever the session already set, so the insert works under either policy.
    m2_session.execute(text("SELECT set_config('project1.actor_id', :a, true)"),
                       {'a': str(actor_id)})
    for finding in findings:
        refs = finding.get('source_refs') or []
        answer_ids = [r['answer_revision_id'] for r in refs if r.get('answer_revision_id')]
        digest = source_digest(answer_ids)
        fid = finding_identity(assessment_id, revision, finding['rule_id'],
                               ruleset_version, digest)
        row = {
            'id': fid, 'assessment': assessment_id, 'revision': revision,
            'rule_id': finding['rule_id'], 'rule_version': ruleset_version,
            'sources': _json(answer_ids),
            'issue_type': finding.get('kind') or 'INFORMATION_GAP',
            'explanation': finding.get('observed_condition') or '',
            'not_proven': finding.get('counterargument') or '',
            'next_action': finding.get('next_action') or '',
        }
        inserted = m2_session.execute(text(
            'INSERT INTO public.m2_bdj_findings '
            '(id, assessment_id, assessment_revision, rule_id, rule_version, '
            ' source_answer_ids, issue_type, explanation, not_proven, next_action, review_state) '
            'VALUES (:id,:assessment,:revision,:rule_id,:rule_version,'
            " CAST(:sources AS json),:issue_type,:explanation,:not_proven,:next_action,'CANDIDATE') "
            'ON CONFLICT DO NOTHING'), row).rowcount
        admitted.append(str(fid))
        if inserted == 0:
            reused += 1

    # The link insert runs on a different connection, so the finding rows must be
    # committed first or the FK cannot see them. Two transactions by design: if
    # linking fails, the residue is a CANDIDATE finding carrying no authority.
    m2_session.commit()

    links = 0
    with runtime_engine.begin() as conn:
        # The engine connects as p1ai_engine, which has no USAGE on project1_ai;
        # the restricted runtime role does. Same switch result_store uses.
        conn.exec_driver_sql('SET LOCAL ROLE p1ai_runtime')
        _bind(conn, actor_id, identity_assertion)
        for fid in admitted:
            links += conn.execute(text(
                'INSERT INTO project1_ai.bdj_result_findings '
                '(result_id, finding_id, owner_user_id, authority) '
                "VALUES (:result_id,:finding_id,:actor,'candidate') "
                'ON CONFLICT DO NOTHING'),
                {'result_id': UUID(str(result_id)), 'finding_id': UUID(fid),
                 'actor': actor_id}).rowcount

    return {'result_id': str(result_id), 'finding_ids': admitted,
            'new_findings': len(admitted) - reused, 'reused_findings': reused,
            'links_inserted': links}


def _json(value) -> str:
    import json
    return json.dumps(value)
