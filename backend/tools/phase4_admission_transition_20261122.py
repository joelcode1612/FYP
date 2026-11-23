"""Demonstrate the APPROVED -> HELD -> ADMITTED transition for BDJ objectives.

Runs entirely against the disposable cluster (``project1_workflow_tests@5433``)
as the restricted ``p1_m2_runtime`` principal, so RLS and the append-only
trigger are exercised for real rather than asserted in prose.

What it proves, in order:

1. A REJECTED proposal is ``NOT_ADMISSIBLE`` / ``PROPOSAL_NOT_APPROVED``.
2. A CANDIDATE (undecided) proposal is ``NOT_ADMISSIBLE`` / ``PROPOSAL_NOT_APPROVED``.
3. An APPROVED proposal is ``HELD`` / ``M2_UNCERTAINTY_LINK_REQUIRED`` — approval
   alone confers no authority. This is the state the product is in today.
4. Recording an admission flips it to ``ADMITTED`` / ``ADMISSION_RECORDED``.
5. A foreign actor cannot see or admit the proposal (RLS).
6. Replaying the same admission is idempotent, not a duplicate row.
7. The admission row is append-only (UPDATE and DELETE refused).
8. QJ and QG stay false in every single state, including ADMITTED.

Never connects to Dss or Final_Location_Analysis.
"""
from __future__ import annotations

import json
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import create_engine, text

ROOT = Path(__file__).resolve().parents[2]
TARGET_DB = 'project1_workflow_tests'
TARGET_PORT = 5433
TARGET_HOST = '127.0.0.1'
RUNTIME_ROLE = 'p1_m2_runtime'

#: Deterministic so a re-run replays rather than creating a second admission.
REQUEST_NAMESPACE = uuid.UUID('6f1c9a2e-3b47-4d18-9c55-8a0e2d7b41cc')


def _credentials() -> str:
    for line in (ROOT / 'backend' / '.env').read_text(encoding='utf-8', errors='replace').splitlines():
        match = re.match(r'^DATABASE_URL=(.*)$', line.strip())
        if match:
            return re.sub(r'^.*://[^:]+:([^@]+)@.*$', r'\1', match.group(1))
    raise SystemExit('DATABASE_URL not found in backend/.env')


def _admin_engine(password: str):
    url = f'postgresql+psycopg2://postgres:{password}@{TARGET_HOST}:{TARGET_PORT}/{TARGET_DB}'
    return create_engine(url)


def _runtime_engine(password: str):
    """Connect already switched to the restricted principal.

    ``SET ROLE`` at connect time (rather than ``SET ROLE`` inside a transaction)
    means every statement in every transaction runs as a non-superuser, so the
    ``owner_scope`` policies are live. A superuser session would silently bypass
    them and the ownership test would pass for the wrong reason.
    """
    url = f'postgresql+psycopg2://postgres:{password}@{TARGET_HOST}:{TARGET_PORT}/{TARGET_DB}'
    return create_engine(url, connect_args={'options': f'-c role={RUNTIME_ROLE}'})


def _assert_target(engine) -> dict:
    with engine.connect() as conn:
        database, port, user, privileged = conn.execute(text(
            'SELECT current_database(), inet_server_port(), current_user,'
            ' (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user)'
        )).one()
    if database != TARGET_DB or port != TARGET_PORT:
        raise SystemExit(f'REFUSED: target is {database}@{port}, expected {TARGET_DB}@{TARGET_PORT}')
    return {'database': database, 'port': port, 'principal': user,
            'privileged': bool(privileged)}


def _principal(engine) -> dict:
    with engine.connect() as conn:
        user, privileged = conn.execute(text(
            'SELECT current_user,'
            ' (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user)'
        )).one()
    return {'principal': user, 'privileged': bool(privileged)}


def _proposals(engine, assessment_id) -> list[dict]:
    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT proposal_id, assessment_id, confirmation_id, confirmation_revision,
                   source_fingerprint, review_state, recommendation_status,
                   research_objective, owner_user_id,
                   (SELECT decision FROM public.m2_bdj_objective_decisions d
                     WHERE d.proposal_id = p.proposal_id) AS decision
            FROM public.m2_bdj_objective_proposals p
            WHERE assessment_id = :a
            ORDER BY review_state, proposal_id
        """), {'a': str(assessment_id)}).mappings().all()
    return [dict(r) for r in rows]


def _owner_of(engine, assessment_id) -> str:
    with engine.connect() as conn:
        return str(conn.execute(text(
            'SELECT owner_user_id FROM public.m2_bdj_objective_proposals'
            ' WHERE assessment_id = :a LIMIT 1'), {'a': str(assessment_id)}).scalar_one())


def _state(engine, proposal_id, fingerprint, actor_id) -> dict:
    from sitewise.project1.objective_admission import admission_state
    return admission_state(engine, proposal_id,
                           source_fingerprint=fingerprint, actor_id=actor_id)


def main() -> int:
    from sitewise.project1.objective_admission import (
        ADOPTION_STATUS, record_admission)

    password = _credentials()
    admin = _admin_engine(password)
    runtime = _runtime_engine(password)

    evidence: dict = {
        'checkpoint': 'BDJ_OBJECTIVE_ADMISSION_TRANSITION',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'adoption_status': ADOPTION_STATUS,
        'target': _assert_target(admin),
        # The application calls run as the restricted principal; the admin session
        # is used only to read seed data and to attempt the append-only mutation.
        # Reporting one principal for both would misrepresent the test.
        'principals': {
            'admin_session': _assert_target(admin),
            'application_session': _principal(runtime),
        },
        'data_classification': 'SYNTHETIC_ONLY',
        'cloud_calls': 0,
    }

    with admin.connect() as conn:
        assessment = conn.execute(text("""
            SELECT assessment_id FROM public.m2_bdj_objective_proposals
            GROUP BY assessment_id
            HAVING count(*) = 3
            ORDER BY assessment_id LIMIT 1""")).scalar_one()
        has_table = conn.execute(text(
            "SELECT to_regclass('public.m2_bdj_objective_admissions')")).scalar()
    if has_table is None:
        raise SystemExit('m2_bdj_objective_admissions missing: apply '
                         'backend/migrations/sql/20261122_0400_m2_bdj_objective_admissions.sql')
    evidence['assessment_id'] = str(assessment)

    rows = _proposals(admin, assessment)
    owner = _owner_of(admin, assessment)
    evidence['owner_user_id'] = owner

    # A fresh APPROVED proposal per run. The admission table is append-only by
    # design, so an earlier run's admission can never be removed to re-create a
    # clean "before" state; reusing a proposal would make the harness report
    # ADMITTED as the starting point and quietly weaken the demonstration.
    run_id = uuid.uuid4()
    proposal_id = uuid.uuid5(REQUEST_NAMESPACE, f'proposal:{run_id}')
    source_fingerprint = rows[0]['source_fingerprint']
    confirmation_id = rows[0]['confirmation_id']
    revision = rows[0]['confirmation_revision']
    with admin.begin() as conn:
        conn.execute(text("""
            INSERT INTO public.m2_bdj_objective_proposals (
                proposal_id, evaluation_id, assessment_id, confirmation_id,
                confirmation_revision, source_fingerprint, context_id,
                context_packet_hash, recommendation_status, problem_type,
                problem, research_objective, reason, evidence_limitation,
                source_refs, contract_version, prompt_version, execution_mode,
                validation_status, review_state, owner_user_id)
            VALUES (
                :pid, :eval, :assessment, :confirmation, :revision, :fp, :ctx,
                :ctxh, 'MOST_SUGGESTED', 'SOURCE_CONFIRMED_INFORMATION_GAP',
                :problem, :objective, :reason, NULL, CAST(:refs AS jsonb),
                'bdj-objective-proposal/1', 'ADMISSION-DEMO', 'SIMULATED',
                'VALID', 'APPROVED', :owner)
        """), {
            'pid': str(proposal_id), 'eval': str(uuid.uuid5(REQUEST_NAMESPACE, f'eval:{run_id}')),
            'assessment': str(assessment), 'confirmation': str(confirmation_id),
            'revision': revision, 'fp': source_fingerprint,
            'ctx': str(rows[0]['proposal_id'])[:32], 'ctxh': '0' * 64,
            'problem': 'The trading area for the proposed cafe is undecided.',
            'objective': 'To investigate candidate areas for the proposed cafe.',
            'reason': 'Synthetic proposal seeded by the admission demonstration.',
            'refs': json.dumps([{'item_key': 'M2V1-01',
                                 'answer_revision_id': str(uuid.uuid5(REQUEST_NAMESPACE, f'ans:{run_id}')),
                                 'item_version_id': str(uuid.uuid5(REQUEST_NAMESPACE, f'item:{run_id}'))}]),
            'owner': owner})
        conn.execute(text("""
            INSERT INTO public.m2_bdj_objective_decisions (
                decision_id, proposal_id, decision, decided_by, source_fingerprint,
                confirmation_id, context_packet_hash, note)
            VALUES (:did, :pid, 'APPROVED', :owner, :fp, :confirmation, :ctxh, :note)
        """), {'did': str(uuid.uuid5(REQUEST_NAMESPACE, f'dec:{run_id}')),
               'pid': str(proposal_id), 'owner': owner, 'fp': source_fingerprint,
               'confirmation': str(confirmation_id), 'ctxh': '0' * 64,
               'note': 'Synthetic approval for the admission demonstration.'})

    evidence['seeded_proposal'] = {'proposal_id': str(proposal_id),
                                   'review_state': 'APPROVED',
                                   'note': 'fresh per run; append-only admission prevents reset'}
    evidence['proposals'] = [
        {'proposal_id': str(r['proposal_id']), 'review_state': r['review_state'],
         'decision': r['decision'],
         'source_fingerprint': r['source_fingerprint']}
        for r in rows]

    # --- 1-3: pre-admission states -------------------------------------
    by_state = {r['review_state']: r for r in rows}
    before = {}
    for label, key in (('rejected', 'REJECTED'), ('candidate', 'CANDIDATE')):
        row = by_state[key]
        before[label] = _state(runtime, row['proposal_id'],
                               row['source_fingerprint'], owner)
        before[label]['proposal_id'] = str(row['proposal_id'])

    approved = {'proposal_id': proposal_id, 'source_fingerprint': source_fingerprint}
    before['approved'] = _state(runtime, proposal_id, source_fingerprint, owner)
    before['approved']['proposal_id'] = str(proposal_id)
    fingerprint = source_fingerprint
    evidence['states_before_admission'] = before

    # --- 5: ownership refusal (RLS), attempted before any write ---------
    with admin.connect() as conn:
        foreign = conn.execute(text(
            'SELECT user_id FROM public.users WHERE user_id <> :o LIMIT 1'),
            {'o': owner}).scalar_one()
    foreign_state = _state(runtime, approved['proposal_id'], fingerprint, str(foreign))
    from sitewise.project1.contracts import WorkflowHeld
    try:
        record_admission(runtime, approved['proposal_id'], actor_id=str(foreign),
                         request_id=uuid.uuid5(REQUEST_NAMESPACE, f'foreign:{approved["proposal_id"]}'))
        foreign_write = {'refused': False, 'error': None}
    except WorkflowHeld as exc:
        foreign_write = {'refused': True, 'error': str(exc)}
    evidence['ownership_refusal'] = {
        'foreign_actor_id': str(foreign),
        'state_seen_by_foreign_actor': foreign_state['admission_state'],
        'reason_seen_by_foreign_actor': foreign_state['admission_reason'],
        'write_refused': foreign_write['refused'],
        'write_error': foreign_write['error'],
        'note': 'A foreign owner sees PROPOSAL_NOT_FOUND, not a permission error: '
                'RLS makes the row invisible so no existence oracle is exposed.',
    }

    # --- 4: record the admission ---------------------------------------
    request_id = uuid.uuid5(REQUEST_NAMESPACE, f'admit:{approved["proposal_id"]}')
    first = record_admission(runtime, approved['proposal_id'], actor_id=owner,
                             request_id=request_id, source_fingerprint=fingerprint)
    after = _state(runtime, approved['proposal_id'], fingerprint, owner)
    evidence['admission_write'] = {
        'request_id': str(request_id),
        'created': first['created'],
        'admission_id': first['admission_id'],
        'decision': first['decision'],
        'proposal_hash': first['proposal_hash'],
    }
    evidence['state_after_admission'] = after

    # --- 6: idempotent replay -------------------------------------------
    replay = record_admission(runtime, approved['proposal_id'], actor_id=owner,
                              request_id=request_id, source_fingerprint=fingerprint)
    with admin.connect() as conn:
        row_count = conn.execute(text(
            'SELECT count(*) FROM public.m2_bdj_objective_admissions'
            ' WHERE proposal_id = :p'), {'p': str(approved['proposal_id'])}).scalar_one()
    evidence['replay'] = {
        'created_on_replay': replay['created'],
        'admission_rows_for_proposal': row_count,
        'idempotent': replay['created'] is False and row_count == 1,
    }

    # --- 7: append-only -------------------------------------------------
    mutations = {}
    for label, statement in (
        ('update', 'UPDATE public.m2_bdj_objective_admissions SET decision = '
                   "'WORTH_RESEARCHING' WHERE proposal_id = :p"),
        ('delete', 'DELETE FROM public.m2_bdj_objective_admissions WHERE proposal_id = :p'),
    ):
        try:
            with admin.begin() as conn:
                conn.execute(text(statement), {'p': str(approved['proposal_id'])})
            mutations[label] = {'refused': False, 'detail': 'ALLOWED'}
        except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
            # The message matters: a connection failure would also raise here, and
            # "it errored" is not evidence that the trigger fired.
            mutations[label] = {
                'refused': True,
                'sqlstate': getattr(getattr(exc, 'orig', None), 'pgcode', None),
                'detail': str(getattr(exc, 'orig', exc)).splitlines()[0][:160],
            }
    evidence['append_only'] = mutations

    # --- 8: no authorisation leaks --------------------------------------
    states = [*before.values(), after]
    evidence['authorisation_invariant'] = {
        'qj_execution_all_false': all(s['qj_execution'] is False for s in states),
        'qg_execution_all_false': all(s['qg_execution'] is False for s in states),
        'fielding_all_false': all(s['fielding_authorized'] is False for s in states),
        'note': 'ADMITTED is an admission to research, not a QG authorisation. '
                'The contract keeps qg_execution False in every state.',
    }

    evidence['verdict'] = {
        'rejected_not_admissible': before['rejected']['admission_reason'] == 'PROPOSAL_NOT_APPROVED',
        'candidate_not_admissible': before['candidate']['admission_reason'] == 'PROPOSAL_NOT_APPROVED',
        'approved_is_held': before['approved']['admission_reason'] == 'M2_UNCERTAINTY_LINK_REQUIRED',
        'admission_flips_state': after['admission_state'] == 'ADMITTED',
        'foreign_actor_blind': foreign_state['admission_reason'] == 'PROPOSAL_NOT_FOUND',
        'foreign_write_refused': foreign_write['refused'],
        'replay_idempotent': evidence['replay']['idempotent'],
        'append_only_enforced': all(
            v['refused'] and v['sqlstate'] == '55000' and 'append-only' in v['detail']
            for v in mutations.values()),
        'qg_never_authorised': evidence['authorisation_invariant']['qg_execution_all_false'],
    }
    evidence['verdict']['PASS'] = all(evidence['verdict'].values())

    out = ROOT / 'deliverables' / 'phase4' / 'BDJ_ADMISSION_TRANSITION_20261122.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=1, default=str), encoding='utf-8')

    print(json.dumps({
        'target': evidence['target'],
        'states_before': {k: (v['admission_state'], v['admission_reason'])
                          for k, v in before.items()},
        'after': (after['admission_state'], after['admission_reason']),
        'ownership': evidence['ownership_refusal']['write_refused'],
        'append_only': mutations,
        'verdict': evidence['verdict'],
        'evidence': str(out),
    }, indent=1, default=str))
    return 0 if evidence['verdict']['PASS'] else 1


if __name__ == '__main__':
    sys.exit(main())
