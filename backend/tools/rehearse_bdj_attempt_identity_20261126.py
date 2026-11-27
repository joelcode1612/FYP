"""Rehearse the BDJ attempt-identity migration on an isolated database.

CP-FINAL-02 evidence. Builds a faithful but minimal copy of the three tables the
migration touches, seeds two owners and two assessments, applies the forward
migration, then tries to write the exact wrong rows the binding is supposed to
refuse. Every refusal below is a real defect that a plain
``FOREIGN KEY (run_id, attempt_no)`` would have accepted.

Run with the backend venv::

    .venv/Scripts/python.exe tools/rehearse_bdj_attempt_identity_20261126.py

The rehearsal database is created and dropped by this script; it never touches a
runtime database. Nothing is applied to `project1_pg18_migrated_tests`.
"""
from __future__ import annotations

import pathlib
import sys
import uuid

import psycopg2
from psycopg2.extras import register_uuid

register_uuid()

HOST, PORT = '127.0.0.1', 5544
ADMIN_DB = 'postgres'
REHEARSAL_DB = 'project1_migration_rehearsal'
RECEIPT = 'rehearsal-20261126'
HERE = pathlib.Path(__file__).resolve().parent.parent
FORWARD = HERE / 'migrations/proposed/20261126_01_bdj_proposal_attempt_identity.sql'
ROLLBACK = HERE / 'migrations/proposed/20261126_01_bdj_proposal_attempt_identity_rollback.sql'

SRC_A = 'a' * 64
SRC_B = 'b' * 64

OWNER_A = uuid.UUID('11111111-1111-1111-1111-111111111111')
OWNER_B = uuid.UUID('22222222-2222-2222-2222-222222222222')
ASSESS_A = uuid.UUID('aaaaaaaa-0000-0000-0000-000000000001')
ASSESS_B = uuid.UUID('bbbbbbbb-0000-0000-0000-000000000002')
CONFIRM_A = uuid.UUID('cccccccc-0000-0000-0000-000000000003')
CONFIRM_B = uuid.UUID('dddddddd-0000-0000-0000-000000000004')
RUN_A = uuid.UUID('e0000000-0000-0000-0000-00000000000a')
RUN_B = uuid.UUID('e0000000-0000-0000-0000-00000000000b')
# Two extra runs exist only to isolate one constraint at a time: a run whose
# owner differs but assessment matches, and one whose assessment differs but
# owner matches. Without them the source trigger fires first and the FK is never
# actually exercised.
RUN_OTHER_OWNER = uuid.UUID('e0000000-0000-0000-0000-00000000000c')
RUN_OTHER_ASSESS = uuid.UUID('e0000000-0000-0000-0000-00000000000d')
REVISION = 5

SCHEMA = """
CREATE SCHEMA IF NOT EXISTS project1_ai;

CREATE TABLE public.m2_assessments (id uuid PRIMARY KEY);

CREATE TABLE project1_ai.runs (
  id uuid PRIMARY KEY,
  owner_user_id uuid NOT NULL,
  assessment_id uuid NOT NULL REFERENCES public.m2_assessments (id),
  assessment_revision integer NOT NULL CHECK (assessment_revision >= 0),
  source_fingerprint text NOT NULL CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
  policy_fingerprint text NOT NULL CHECK (policy_fingerprint ~ '^[a-f0-9]{64}$'),
  work_identity text NOT NULL CHECK (work_identity ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, owner_user_id),
  UNIQUE (owner_user_id, work_identity)
);

CREATE TABLE project1_ai.attempts (
  run_id uuid NOT NULL,
  owner_user_id uuid NOT NULL,
  attempt_no integer NOT NULL CHECK (attempt_no BETWEEN 1 AND 6),
  stage text NOT NULL CHECK (stage IN ('BDJ', 'QJ', 'QG')),
  prompt_version text NOT NULL,
  prompt_hash text NOT NULL,
  request_hash text NOT NULL,
  reserved_at timestamptz NOT NULL DEFAULT now(),
  attempt_slot integer NOT NULL CHECK (attempt_slot BETWEEN 1 AND 3),
  PRIMARY KEY (run_id, attempt_no),
  FOREIGN KEY (run_id, owner_user_id)
    REFERENCES project1_ai.runs (id, owner_user_id),
  UNIQUE (run_id, owner_user_id, attempt_no),
  UNIQUE (run_id, stage, attempt_slot)
);

CREATE TABLE public.m2_bdj_objective_proposals (
  proposal_id uuid PRIMARY KEY,
  evaluation_id uuid NOT NULL,
  assessment_id uuid NOT NULL,
  confirmation_id uuid NOT NULL,
  confirmation_revision integer NOT NULL,
  source_fingerprint character(64) NOT NULL,
  context_id varchar NOT NULL,
  context_packet_hash varchar NOT NULL,
  recommendation_status varchar NOT NULL,
  research_objective varchar NOT NULL,
  contract_version varchar NOT NULL,
  prompt_version varchar NOT NULL,
  execution_mode varchar NOT NULL,
  validation_status varchar NOT NULL,
  review_state varchar NOT NULL,
  owner_user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
"""

SEED = """
INSERT INTO public.m2_assessments (id) VALUES (%(aa)s), (%(ab)s);
INSERT INTO project1_ai.runs
  (id, owner_user_id, assessment_id, assessment_revision,
   source_fingerprint, policy_fingerprint, work_identity)
VALUES
  (%(run_a)s, %(oa)s, %(aa)s, %(rev)s, %(src_a)s, %(pol)s, %(wi_a)s),
  (%(run_b)s, %(ob)s, %(ab)s, %(rev)s, %(src_b)s, %(pol)s, %(wi_b)s),
  (%(run_co)s, %(ob)s, %(aa)s, %(rev)s, %(src_a)s, %(pol)s, %(wi_c)s),
  (%(run_ca)s, %(oa)s, %(ab)s, %(rev)s, %(src_b)s, %(pol)s, %(wi_d)s);
INSERT INTO project1_ai.attempts
  (run_id, owner_user_id, attempt_no, stage, prompt_version, prompt_hash,
   request_hash, attempt_slot)
VALUES
  (%(run_a)s, %(oa)s, 1, 'BDJ', 'BDJ-OBJECTIVE-4-CAND', %(h)s, %(h)s, 1),
  (%(run_a)s, %(oa)s, 2, 'QG',  'QG-PROPOSAL-1',        %(h)s, %(h)s, 1),
  (%(run_b)s, %(ob)s, 1, 'BDJ', 'BDJ-OBJECTIVE-4-CAND', %(h)s, %(h)s, 1),
  (%(run_co)s, %(ob)s, 1, 'BDJ', 'BDJ-OBJECTIVE-4-CAND', %(h)s, %(h)s, 1),
  (%(run_ca)s, %(oa)s, 1, 'BDJ', 'BDJ-OBJECTIVE-4-CAND', %(h)s, %(h)s, 1);
"""


def connect(dbname: str, autocommit: bool = False):
    conn = psycopg2.connect(host=HOST, port=PORT, dbname=dbname, user='postgres')
    conn.autocommit = autocommit
    return conn


def seed_params():
    return {
        'aa': ASSESS_A, 'ab': ASSESS_B, 'oa': OWNER_A, 'ob': OWNER_B,
        'run_a': RUN_A, 'run_b': RUN_B, 'rev': REVISION,
        'run_co': RUN_OTHER_OWNER, 'run_ca': RUN_OTHER_ASSESS,
        'src_a': SRC_A, 'src_b': SRC_B, 'pol': 'f' * 64,
        'wi_a': '1' * 64, 'wi_b': '2' * 64, 'wi_c': '4' * 64,
        'wi_d': '5' * 64, 'h': '3' * 64,
    }


def proposal_params(**over):
    base = {
        'proposal_id': uuid.uuid4(), 'evaluation_id': uuid.uuid4(),
        'assessment_id': ASSESS_A, 'confirmation_id': CONFIRM_A,
        'confirmation_revision': REVISION, 'source_fingerprint': SRC_A,
        'context_id': 'ctx', 'context_packet_hash': 'h',
        'recommendation_status': 'MOST_SUGGESTED',
        'research_objective': 'Determine X', 'contract_version':
        'bdj-objective-proposal/2', 'prompt_version': 'BDJ-OBJECTIVE-4-CAND',
        'execution_mode': 'LIVE', 'validation_status': 'VALID',
        'review_state': 'PENDING', 'owner_user_id': OWNER_A,
    }
    base.update(over)
    return base


INSERT = """
INSERT INTO public.m2_bdj_objective_proposals
  (proposal_id, evaluation_id, assessment_id, confirmation_id,
   confirmation_revision, source_fingerprint, context_id, context_packet_hash,
   recommendation_status, research_objective, contract_version, prompt_version,
   execution_mode, validation_status, review_state, owner_user_id,
   run_id, attempt_no)
VALUES
  (%(proposal_id)s, %(evaluation_id)s, %(assessment_id)s, %(confirmation_id)s,
   %(confirmation_revision)s, %(source_fingerprint)s, %(context_id)s,
   %(context_packet_hash)s, %(recommendation_status)s, %(research_objective)s,
   %(contract_version)s, %(prompt_version)s, %(execution_mode)s,
   %(validation_status)s, %(review_state)s, %(owner_user_id)s,
   %(run_id)s, %(attempt_no)s)
"""

results: list[tuple[str, str, str]] = []


def record(name: str, expected: str, outcome: str):
    results.append((name, expected, outcome))


def expect_refused(conn, name: str, params: dict, needle: str):
    """Attempt an insert that must be refused, and name the constraint."""
    try:
        with conn.cursor() as cur:
            cur.execute(INSERT, params)
        conn.rollback()
        record(name, needle, 'ACCEPTED — DEFECT')
    except psycopg2.Error as exc:
        conn.rollback()
        detail = (exc.pgerror or str(exc)).strip().splitlines()[0]
        ok = needle.lower() in detail.lower()
        record(name, needle, ('REFUSED: ' + detail[:96]) if ok
               else 'REFUSED BY WRONG REASON: ' + detail[:96])


def main() -> int:
    admin = connect(ADMIN_DB, autocommit=True)
    with admin.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS {REHEARSAL_DB}')
        cur.execute(f'CREATE DATABASE {REHEARSAL_DB}')
    admin.close()
    print(f'[setup] created isolated database {REHEARSAL_DB}')

    conn = connect(REHEARSAL_DB, autocommit=True)
    with conn.cursor() as cur:
        cur.execute(SCHEMA)
        cur.execute(SEED, seed_params())
        # Two rows that predate the identity, exactly like the 20 live rows.
        cur.execute(
            'INSERT INTO public.m2_bdj_objective_proposals'
            ' (proposal_id, evaluation_id, assessment_id, confirmation_id,'
            '  confirmation_revision, source_fingerprint, context_id,'
            '  context_packet_hash, recommendation_status, research_objective,'
            '  contract_version, prompt_version, execution_mode,'
            '  validation_status, review_state, owner_user_id)'
            ' VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)',
            (uuid.uuid4(), uuid.uuid4(), ASSESS_A, CONFIRM_A, REVISION, SRC_A,
             'ctx', 'h', 'MOST_SUGGESTED', 'Historical one',
             'bdj-objective-proposal/1', 'BDJ-OBJECTIVE-3-CAND', 'LIVE',
             'VALID', 'APPROVED', OWNER_A))
        cur.execute(
            'INSERT INTO public.m2_bdj_objective_proposals'
            ' (proposal_id, evaluation_id, assessment_id, confirmation_id,'
            '  confirmation_revision, source_fingerprint, context_id,'
            '  context_packet_hash, recommendation_status, research_objective,'
            '  contract_version, prompt_version, execution_mode,'
            '  validation_status, review_state, owner_user_id)'
            ' VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)',
            (uuid.uuid4(), uuid.uuid4(), ASSESS_B, CONFIRM_B, REVISION, SRC_B,
             'ctx', 'h', 'MOST_SUGGESTED', 'Historical two',
             'bdj-objective-proposal/1', 'BDJ-OBJECTIVE-3-CAND', 'LIVE',
             'VALID', 'REJECTED', OWNER_B))
    print('[setup] seeded 4 runs, 5 attempts (1 BDJ + 1 QG on run A), 2 historical rows')

    # --- forward -----------------------------------------------------------
    with conn.cursor() as cur:
        cur.execute("SET project1.migration_target = %s", (REHEARSAL_DB,))
        cur.execute("SET project1.migration_receipt = %s", (RECEIPT,))
        cur.execute(FORWARD.read_text(encoding='utf-8'))
    print('[forward] applied')

    with conn.cursor() as cur:
        cur.execute("""
            SELECT count(*) FROM pg_constraint
             WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
               AND contype = 'f'
               AND conname LIKE 'm2_bdj_objective_proposals_%'
        """)
        fks = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals"
                    " WHERE run_id IS NULL")
        historical = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals")
        total = cur.fetchone()[0]
    print(f'[forward] {fks} binding FKs; historical rows still NULL: '
          f'{historical}/{total}')
    assert fks == 4, f'expected 4 binding FKs, found {fks}'
    assert historical == 2 and total == 2, 'historical rows were altered'

    # --- adversarial -------------------------------------------------------
    expect_refused(conn, 'proposal bound to the QG attempt of the same run',
                   proposal_params(run_id=RUN_A, attempt_no=2),
                   'attempt_fkey')
    expect_refused(conn, "another owner's run (same assessment, same source)",
                   proposal_params(run_id=RUN_OTHER_OWNER, attempt_no=1),
                   'owner_fkey')
    expect_refused(conn, 'run of a different assessment (same owner, same source)',
                   proposal_params(run_id=RUN_OTHER_ASSESS, attempt_no=1,
                                   source_fingerprint=SRC_B),
                   'assessment_fkey')
    expect_refused(conn, 'proposal assessment differs from the run',
                   proposal_params(run_id=RUN_A, attempt_no=1,
                                   assessment_id=ASSESS_B),
                   'assessment_fkey')
    expect_refused(conn, 'confirmation revision differs from the run',
                   proposal_params(run_id=RUN_A, attempt_no=1,
                                   confirmation_revision=REVISION + 1),
                   'revision_fkey')
    expect_refused(conn, 'half an identity (run without attempt)',
                   proposal_params(run_id=RUN_A, attempt_no=None),
                   'pair_chk')
    expect_refused(conn, 'source fingerprint differs from the run',
                   proposal_params(run_id=RUN_A, attempt_no=1,
                                   source_fingerprint=SRC_B),
                   'BDJ_PROPOSAL_SOURCE_MISMATCH')
    expect_refused(conn, 'nonexistent attempt',
                   proposal_params(run_id=uuid.uuid4(), attempt_no=1),
                   'attempt_fkey')

    # The correct row must be accepted, or the binding is too tight to use.
    try:
        with conn.cursor() as cur:
            cur.execute(INSERT, proposal_params(run_id=RUN_A, attempt_no=1))
        record('exact identity (run A, attempt 1, BDJ, same owner/assessment/'
               'revision/source)', 'ACCEPTED', 'ACCEPTED')
    except psycopg2.Error as exc:
        conn.rollback()
        record('exact identity', 'ACCEPTED',
               'REFUSED — TOO TIGHT: ' + (exc.pgerror or str(exc))[:96])

    # --- rollback ----------------------------------------------------------
    with conn.cursor() as cur:
        cur.execute("SET project1.migration_target = %s", (REHEARSAL_DB,))
        cur.execute("SET project1.migration_receipt = %s", (RECEIPT,))
        cur.execute(ROLLBACK.read_text(encoding='utf-8'))
    with conn.cursor() as cur:
        cur.execute("""
            SELECT count(*) FROM information_schema.columns
             WHERE table_schema='public'
               AND table_name='m2_bdj_objective_proposals'
               AND column_name IN ('run_id','attempt_no','attempt_stage')
        """)
        leftover = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals")
        after = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM pg_trigger WHERE tgname ="
                    " 'm2_bdj_proposal_source_binding_trg'")
        trig = cur.fetchone()[0]
    print(f'[rollback] leftover columns: {leftover}; rows preserved: {after}; '
          f'trigger remaining: {trig}')
    assert leftover == 0 and trig == 0
    assert after == 3, f'expected 3 rows after rollback, found {after}'

    conn.close()

    admin = connect(ADMIN_DB, autocommit=True)
    with admin.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS {REHEARSAL_DB}')
    admin.close()
    print(f'[teardown] dropped {REHEARSAL_DB}')

    print('\n%-62s %-14s %s' % ('CASE', 'EXPECTED', 'RESULT'))
    defects = 0
    for name, expected, outcome in results:
        if 'DEFECT' in outcome or 'WRONG REASON' in outcome:
            defects += 1
        print('%-62s %-14s %s' % (name[:62], expected[:14], outcome))
    print(f'\n{len(results)} cases, {defects} defect(s)')
    return 1 if defects else 0


if __name__ == '__main__':
    sys.exit(main())
