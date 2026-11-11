
-- Project1 CP1-B4 synthetic fixture seeding
-- PostgreSQL 18 / 127.0.0.1:5433
-- Database: dss_uc_stage_tests
-- TEST ONLY: never run against Dss.
--
-- Creates synthetic M2 and UC records.
-- Preserves all pre-existing records.
-- Uses one atomic transaction.
-- UC history is append-only; do not manually delete
-- these candidates after creation.

BEGIN;

SET LOCAL timezone = 'UTC';
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '5s';

DO $fixture$
DECLARE
    instrument_id uuid := gen_random_uuid();

    actor_a uuid := gen_random_uuid();
    actor_b uuid := gen_random_uuid();

    assessment_a uuid := gen_random_uuid();
    assessment_b uuid := gen_random_uuid();

    snapshot_a uuid := gen_random_uuid();
    snapshot_b uuid := gen_random_uuid();

    candidate_a uuid := gen_random_uuid();
    candidate_b uuid := gen_random_uuid();
    candidate_stale uuid := gen_random_uuid();

    version_a uuid := gen_random_uuid();
    version_b uuid := gen_random_uuid();
    stale_v1 uuid := gen_random_uuid();
    stale_v2 uuid := gen_random_uuid();

    snapshot_json_a json :=
        '{"_test":true,"fixture":"CP1-B4","owner":"A"}';

    snapshot_json_b json :=
        '{"_test":true,"fixture":"CP1-B4","owner":"B"}';

    hash_a bytea;
    hash_b bytea;
BEGIN
    -- Hard safety boundary.
    IF current_database() <> 'dss_uc_stage_tests'
       OR inet_server_port() <> 5433
       OR session_user <> 'postgres'
       OR current_setting('server_version_num')::integer
          NOT BETWEEN 180000 AND 189999
       OR current_setting('data_directory')
          <> 'C:/Program Files/PostgreSQL/18/data'
    THEN
        RAISE EXCEPTION
            'CP1-B4 SAFETY STOP: Incorrect PostgreSQL target';
    END IF;

    IF to_regclass('project1_uc.candidate_versions') IS NULL
       OR to_regclass('public.m2_confirmation_snapshots') IS NULL
       OR to_regclass('public.m2_instrument_versions') IS NULL
       OR to_regprocedure(
            'project1_uc.assert_current(uuid)'
          ) IS NULL
    THEN
        RAISE EXCEPTION 'Required M2/UC schema missing';
    END IF;

    -- Refuse to seed this labeled fixture twice.
    IF EXISTS (
        SELECT 1
        FROM public.users
        WHERE email IN (
            'cp1-b4-stage-a@example.invalid',
            'cp1-b4-stage-b@example.invalid'
        )
    )
    OR EXISTS (
        SELECT 1
        FROM public.m2_instrument_versions
        WHERE code = 'UC-B4-TEST'
    )
    THEN
        RAISE EXCEPTION
            'CP1-B4 fixture already exists; inspect before rerunning';
    END IF;

    -- Synthetic instrument: not scientifically authorized.
    INSERT INTO public.m2_instrument_versions (
        id,
        code,
        version_tag,
        approval_state,
        schema_digest,
        created_at
    )
    VALUES (
        instrument_id,
        'UC-B4-TEST',
        'v1-synthetic',
        'TEST_ONLY',
        encode(
            sha256(convert_to('UC-B4-TEST', 'UTF8')),
            'hex'
        ),
        now()
    );

    -- Two independent synthetic users.
    INSERT INTO public.users (
        user_id,
        email,
        full_name,
        role,
        account_status,
        email_verified,
        created_at,
        updated_at
    )
    VALUES
    (
        actor_a,
        'cp1-b4-stage-a@example.invalid',
        'CP1-B4 Synthetic A',
        'entrepreneur',
        'active',
        true,
        now(),
        now()
    ),
    (
        actor_b,
        'cp1-b4-stage-b@example.invalid',
        'CP1-B4 Synthetic B',
        'entrepreneur',
        'active',
        true,
        now(),
        now()
    );

    -- Current confirmed M2 assessments.
    INSERT INTO public.m2_assessments (
        id, owner_user_id, instrument_id,
        revision, confirmed_revision
    )
    VALUES
        (assessment_a, actor_a, instrument_id, 1, 1),
        (assessment_b, actor_b, instrument_id, 1, 1);

    -- Current M2 confirmation snapshots.
    INSERT INTO public.m2_confirmation_snapshots (
        id,
        assessment_id,
        assessment_revision,
        actor_user_id,
        snapshot_json,
        snapshot_digest,
        acknowledged_issue_ids
    )
    VALUES
    (
        snapshot_a,
        assessment_a,
        1,
        actor_a,
        snapshot_json_a,
        encode(
            sha256(convert_to(snapshot_json_a::text, 'UTF8')),
            'hex'
        ),
        '[]'::json
    ),
    (
        snapshot_b,
        assessment_b,
        1,
        actor_b,
        snapshot_json_b,
        encode(
            sha256(convert_to(snapshot_json_b::text, 'UTF8')),
            'hex'
        ),
        '[]'::json
    );

    -- Exact UC source hashes, calculated in UTC.
    SELECT sha256(
        convert_to(to_jsonb(s)::text, 'UTF8')
    )
    INTO hash_a
    FROM public.m2_confirmation_snapshots s
    WHERE s.id = snapshot_a;

    SELECT sha256(
        convert_to(to_jsonb(s)::text, 'UTF8')
    )
    INTO hash_b
    FROM public.m2_confirmation_snapshots s
    WHERE s.id = snapshot_b;

    -- Two live candidates and a separate stale-test candidate.
    INSERT INTO project1_uc.candidates (
        id, assessment_id, created_by_login
    )
    VALUES
        (candidate_a, assessment_a, 'postgres'),
        (candidate_b, assessment_b, 'postgres'),
        (candidate_stale, assessment_a, 'postgres');

    INSERT INTO project1_uc.candidate_versions (
        id,
        candidate_id,
        version_no,
        origin,
        suggested_by_user_id,
        source_snapshot_id,
        source_snapshot_hash,
        exact_text,
        rationale,
        model_provenance,
        created_by_login
    )
    VALUES
    (
        version_a,
        candidate_a,
        1,
        'ENTREPRENEUR',
        actor_a,
        snapshot_a,
        hash_a,
        'CP1-B4-A-LIVE',
        'Synthetic owner A authorization test',
        '{}'::jsonb,
        'postgres'
    ),
    (
        version_b,
        candidate_b,
        1,
        'ENTREPRENEUR',
        actor_b,
        snapshot_b,
        hash_b,
        'CP1-B4-B-LIVE',
        'Synthetic owner B authorization test',
        '{}'::jsonb,
        'postgres'
    ),
    (
        stale_v1,
        candidate_stale,
        1,
        'ENTREPRENEUR',
        actor_a,
        snapshot_a,
        hash_a,
        'CP1-B4-STALE-V1',
        'Deliberately superseded synthetic version',
        '{}'::jsonb,
        'postgres'
    ),
    (
        stale_v2,
        candidate_stale,
        2,
        'ENTREPRENEUR',
        actor_a,
        snapshot_a,
        hash_a,
        'CP1-B4-STALE-V2',
        'Current replacement of synthetic stale version',
        '{}'::jsonb,
        'postgres'
    );

    -- Validate both current candidates using UC's real
    -- evidence-integrity function.
    PERFORM project1_uc.assert_current(version_a);
    PERFORM project1_uc.assert_current(version_b);
    PERFORM project1_uc.assert_current(stale_v2);

    -- The old version must be rejected as superseded.
    BEGIN
        PERFORM project1_uc.assert_current(stale_v1);
        RAISE EXCEPTION
            'CP1-B4 error: stale version was accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%superseded%' THEN
            RAISE;
        END IF;
    END;

    RAISE NOTICE 'CP1-B4 synthetic fixtures validated';
END;
$fixture$;

COMMIT;
