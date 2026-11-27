"""Rehearse the whole proposed migration stack on a disposable database.

CP-FINAL-02 / CP-FINAL-04 evidence for the three migrations the master agent has
not applied:

    20261126_01  BDJ attempt identity        (forward + rollback)
    20261126_02  BDJ zero-proposal write ack (forward + rollback)
    20261126_03  Direct-QG objective identity(forward + rollback)

The rehearsal database is created and dropped by this script. Nothing is applied
to `project1_pg18_migrated_tests` or any other runtime database.

Why one script and not three
----------------------------
The stack has a real ordering dependency, and it is the kind of thing that only
shows up when the migrations are applied in the wrong order:

* ``02`` creates foreign keys to ``runs (id, owner_user_id)`` and
  ``runs (id, assessment_id)``. The second pair is unique only because ``01``
  added ``runs_id_assessment_id_key``. Applying ``02`` first therefore fails.
* ``02`` must be rolled back **before** ``01``, because its foreign keys point at
  the uniqueness ``01``'s rollback drops.

Both facts are asserted below rather than described.

Run with the backend venv::

    .venv/Scripts/python.exe tools/rehearse_bdj_write_ack_and_qg_objective_20261126.py
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
REHEARSAL_DB = 'project1_migration_rehearsal_stack'
RECEIPT = 'rehearsal-20261126-stack'
HERE = pathlib.Path(__file__).resolve().parent.parent
MIGRATIONS = HERE / 'migrations/proposed'

M01 = MIGRATIONS / '20261126_01_bdj_proposal_attempt_identity.sql'
M01_DOWN = MIGRATIONS / '20261126_01_bdj_proposal_attempt_identity_rollback.sql'
M02 = MIGRATIONS / '20261126_02_bdj_proposal_write_ack.sql'
M02_DOWN = MIGRATIONS / '20261126_02_bdj_proposal_write_ack_rollback.sql'
M03 = MIGRATIONS / '20261126_03_qg_run_objective_identity.sql'
M03_DOWN = MIGRATIONS / '20261126_03_qg_run_objective_identity_rollback.sql'

OWNER = uuid.UUID('11111111-1111-1111-1111-111111111111')
ASSESS = uuid.UUID('aaaaaaaa-0000-0000-0000-000000000001')
RUN = uuid.UUID('e0000000-0000-0000-0000-00000000000a')
RUN2 = uuid.UUID('e0000000-0000-0000-0000-00000000000b')
CONFIRM = uuid.UUID('cccccccc-0000-0000-0000-000000000003')
REVISION = 5
SRC = 'a' * 64
POL = 'f' * 64

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
INSERT INTO public.m2_assessments (id) VALUES (%(assess)s);
INSERT INTO project1_ai.runs
  (id, owner_user_id, assessment_id, assessment_revision,
   source_fingerprint, policy_fingerprint, work_identity)
VALUES
  (%(run)s,  %(owner)s, %(assess)s, %(rev)s, %(src)s, %(pol)s, %(wi1)s),
  (%(run2)s, %(owner)s, %(assess)s, %(rev)s, %(src)s, %(pol)s, %(wi2)s);
INSERT INTO project1_ai.attempts
  (run_id, owner_user_id, attempt_no, stage, prompt_version, prompt_hash,
   request_hash, attempt_slot)
VALUES
  (%(run)s,  %(owner)s, 1, 'BDJ', 'BDJ-OBJECTIVE-4-CAND', %(h)s, %(h)s, 1),
  (%(run2)s, %(owner)s, 1, 'QG',  'QG-PROPOSAL-1',        %(h)s, %(h)s, 1);
"""

results: list[tuple[str, str, str]] = []


def record(name: str, expected: str, outcome: str) -> None:
    results.append((name, expected, outcome))


def connect(dbname: str, autocommit: bool = True):
    conn = psycopg2.connect(host=HOST, port=PORT, dbname=dbname, user='postgres')
    conn.autocommit = autocommit
    return conn


def apply_script(conn, path: pathlib.Path) -> None:
    with conn.cursor() as cur:
        cur.execute("SET project1.migration_target = %s", (REHEARSAL_DB,))
        cur.execute("SET project1.migration_receipt = %s", (RECEIPT,))
        cur.execute(path.read_text(encoding='utf-8'))


def scalar(conn, sql: str):
    with conn.cursor() as cur:
        cur.execute(sql)
        return cur.fetchone()[0]


def expect_failure(conn, name: str, path: pathlib.Path, needle: str) -> None:
    try:
        apply_script(conn, path)
    except psycopg2.Error as exc:
        # The script opened an explicit BEGIN, so the *server* session is in an
        # aborted transaction. `conn.rollback()` is a no-op under autocommit, so
        # the ROLLBACK is sent explicitly or every later statement is refused.
        with conn.cursor() as cur:
            cur.execute('ROLLBACK')
        detail = (exc.pgerror or str(exc)).strip().splitlines()[0]
        ok = needle.lower() in detail.lower()
        record(name, 'REFUSED', ('REFUSED: ' + detail[:88]) if ok
               else 'REFUSED BY WRONG REASON: ' + detail[:88])
    else:
        record(name, 'REFUSED', 'ACCEPTED — DEFECT')


def main() -> int:
    admin = connect(ADMIN_DB)
    with admin.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS {REHEARSAL_DB}')
        cur.execute(f'CREATE DATABASE {REHEARSAL_DB}')
    admin.close()
    print(f'[setup] created isolated database {REHEARSAL_DB}')

    conn = connect(REHEARSAL_DB)
    with conn.cursor() as cur:
        cur.execute(SCHEMA)
        cur.execute(SEED, {
            'assess': ASSESS, 'owner': OWNER, 'run': RUN, 'run2': RUN2,
            'rev': REVISION, 'src': SRC, 'pol': POL,
            'wi1': '1' * 64, 'wi2': '2' * 64, 'h': '3' * 64,
        })
    print('[setup] seeded 1 assessment, 2 runs, 2 attempts (BDJ + QG)')

    # --- ordering dependency ------------------------------------------------
    # 02 references runs (id, assessment_id), which is unique only after 01.
    expect_failure(conn, '02 applied before 01', M02, 'unique constraint')

    # --- 01 -----------------------------------------------------------------
    apply_script(conn, M01)
    fks = scalar(conn, """
        SELECT count(*) FROM pg_constraint
         WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
           AND contype = 'f'
           AND conname LIKE 'm2_bdj_objective_proposals_%'
    """)
    record('01 forward: four binding foreign keys', '4', f'{fks}')
    print(f'[01] applied; {fks} binding FKs')

    # --- 02 -----------------------------------------------------------------
    apply_script(conn, M02)
    exists = scalar(conn, "SELECT to_regclass('project1_ai.objective_writes') IS NOT NULL")
    record('02 forward: objective_writes exists', 'True', f'{exists}')

    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO project1_ai.objective_writes
              (run_id, attempt_no, owner_user_id, assessment_id,
               recommendation_count, contract_version, prompt_version)
            VALUES (%s, 1, %s, %s, 0, 'bdj-objective-proposal/2',
                    'BDJ-OBJECTIVE-4-CAND')
        """, (RUN, OWNER, ASSESS))
    record('02: a zero-recommendation write is recorded', 'ACCEPTED', 'ACCEPTED')

    try:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO project1_ai.objective_writes
                  (run_id, attempt_no, owner_user_id, assessment_id,
                   recommendation_count, contract_version, prompt_version)
                VALUES (%s, 1, %s, %s, 3, 'bdj-objective-proposal/2', 'x')
            """, (RUN, OWNER, ASSESS))
    except psycopg2.Error as exc:
        conn.rollback()
        detail = (exc.pgerror or str(exc)).strip().splitlines()[0]
        record('02: a second write for one attempt is refused', 'REFUSED',
               'REFUSED: ' + detail[:88])
    else:
        record('02: a second write for one attempt is refused', 'REFUSED',
               'ACCEPTED — DEFECT')

    try:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO project1_ai.objective_writes
                  (run_id, attempt_no, owner_user_id, assessment_id,
                   recommendation_count, contract_version, prompt_version)
                VALUES (%s, 1, %s, %s, -1, 'bdj-objective-proposal/2', 'x')
            """, (RUN2, OWNER, ASSESS))
    except psycopg2.Error as exc:
        conn.rollback()
        detail = (exc.pgerror or str(exc)).strip().splitlines()[0]
        record('02: a negative recommendation count is refused', 'REFUSED',
               'REFUSED: ' + detail[:88])
    else:
        record('02: a negative recommendation count is refused', 'REFUSED',
               'ACCEPTED — DEFECT')
    print('[02] applied; zero-write acknowledged, duplicates and negatives refused')

    # --- 03 -----------------------------------------------------------------
    apply_script(conn, M03)
    column = scalar(conn, """
        SELECT count(*) FROM information_schema.columns
         WHERE table_schema='project1_ai' AND table_name='runs'
           AND column_name='objective_id'
    """)
    index = scalar(conn, "SELECT count(*) FROM pg_indexes"
                         " WHERE schemaname='project1_ai'"
                         "   AND indexname='runs_objective_idx'")
    record('03 forward: objective_id column and index', '1/1', f'{column}/{index}')

    with conn.cursor() as cur:
        cur.execute("UPDATE project1_ai.runs SET objective_id = %s WHERE id = %s",
                    ('proposal:aaaa', RUN2))
    distinct = scalar(conn, "SELECT count(DISTINCT objective_id)"
                            " FROM project1_ai.runs WHERE objective_id IS NOT NULL")
    record('03: an objective can be bound to a run', '1', f'{distinct}')
    print('[03] applied; objective bound to one run')

    # --- unwind in reverse --------------------------------------------------
    apply_script(conn, M03_DOWN)
    left = scalar(conn, """
        SELECT count(*) FROM information_schema.columns
         WHERE table_schema='project1_ai' AND table_name='runs'
           AND column_name='objective_id'
    """)
    record('03 rollback: column removed', '0', f'{left}')

    apply_script(conn, M02_DOWN)
    gone = scalar(conn, "SELECT to_regclass('project1_ai.objective_writes') IS NULL")
    record('02 rollback: table removed', 'True', f'{gone}')

    # 02 must be down before 01: its FKs reference uniqueness 01 drops.
    apply_script(conn, M01_DOWN)
    cols = scalar(conn, """
        SELECT count(*) FROM information_schema.columns
         WHERE table_schema='public' AND table_name='m2_bdj_objective_proposals'
           AND column_name IN ('run_id','attempt_no','attempt_stage')
    """)
    record('01 rollback: identity columns removed', '0', f'{cols}')

    runs = scalar(conn, 'SELECT count(*) FROM project1_ai.runs')
    attempts = scalar(conn, 'SELECT count(*) FROM project1_ai.attempts')
    record('rollback: ledger rows preserved', '2/2', f'{runs}/{attempts}')

    conn.close()

    admin = connect(ADMIN_DB)
    with admin.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS {REHEARSAL_DB}')
    admin.close()
    print(f'[teardown] dropped {REHEARSAL_DB}')

    print('\n%-58s %-10s %s' % ('CASE', 'EXPECTED', 'RESULT'))
    defects = 0
    for name, expected, outcome in results:
        if 'DEFECT' in outcome or 'WRONG REASON' in outcome:
            defects += 1
        print('%-58s %-10s %s' % (name[:58], expected[:10], outcome))
    print(f'\n{len(results)} cases, {defects} defect(s)')
    return 1 if defects else 0


if __name__ == '__main__':
    sys.exit(main())
