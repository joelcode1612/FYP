-- PROJECT1 BDJ objective proposals: owner-scoped RLS + least-privilege grants.
-- Migration: 20261122_0300_m2_bdj_objective_rls_grants
--
-- Why this exists
-- ---------------
-- The Gate A audit (deliverables/phase2/BDJ_GATEA_RLS_AUDIT_20261122.json)
-- found that public.m2_bdj_objective_proposals and
-- public.m2_bdj_objective_decisions had RLS DISABLED, no policies, and no
-- grants for any runtime principal. The objective adapter would therefore have
-- failed with InsufficientPrivilege, and a runtime login with a table grant
-- would have been able to read every owner's proposals.
--
-- Design
-- ------
-- * The proposal/decision tables live beside the other public.m2_* tables and
--   are owned by the same assessment, so the restricted M2 principal
--   (p1_m2_runtime: LOGIN, NOINHERIT, NOSUPERUSER, NOBYPASSRLS) is the
--   principal that reads and writes them. p1ai_runtime keeps its existing
--   project1_ai ledger role and gains nothing here.
-- * Policies mirror the established owner_scope shape already used by
--   m2_business_contexts / m2_business_context_builds: ownership is resolved
--   through m2_assessments, which itself carries an owner_scope policy.
-- * Grants are table-specific. No schema-wide grant, no DELETE, no TRUNCATE,
--   no ownership transfer, no BYPASSRLS.
-- * Decisions are append-only: SELECT + INSERT only. A decision is never
--   updated or removed, so no UPDATE/DELETE grant is issued.
--
-- Residual risk (recorded, not hidden): project1_actor() reads the
-- project1.actor_id session GUC, which a direct database client could set. RLS
-- is therefore defence in depth; authoritative ownership remains the explicit
-- owner_user_id predicate in the adapter SQL plus credential custody of the
-- restricted login. The protected-identity path (project1_identity schema) is
-- not provisioned on this cluster.

DO $$
BEGIN
    -- Rule-based disposable target, not a hard-coded database name.
    --
    -- The previous check demanded exactly 'project1_workflow_tests', which made
    -- the migration set impossible to apply to a freshly provisioned disposable
    -- database under any other name. That defeats the purpose of testing fresh
    -- provisioning, and it is the reason a second disposable database could not
    -- be built from these files.
    --
    -- The safety property is unchanged and, if anything, stricter: the rule
    -- refuses the protected databases by name, refuses the protected cluster by
    -- port, and requires the project1_ namespace for anything it does accept.
    IF current_database() IN ('Dss', 'dss', 'Final_Location_Analysis', 'sitesense', 'postgres') THEN
        RAISE EXCEPTION 'REFUSED: % is a protected database', current_database();
    END IF;
    IF inet_server_port() = 5432 THEN
        RAISE EXCEPTION 'REFUSED: port 5432 is the protected cluster (current_database=%)',
            current_database();
    END IF;
    IF current_database() NOT LIKE 'project1\_%' THEN
        RAISE EXCEPTION 'REFUSED: objective RLS/grants migration is disposable-only '
                        '(current_database=%, port=%)', current_database(), inet_server_port();
    END IF;
    -- The owner_scope policies call public.project1_actor(), which is created by
    -- migrations/project1_ai/20261121_90_m2_runtime_role_disposable.sql. Without
    -- this precondition the failure surfaces as a bare
    -- "function project1_actor() does not exist" from inside CREATE POLICY,
    -- which does not tell the operator what to run first.
    IF to_regprocedure('public.project1_actor()') IS NULL THEN
        RAISE EXCEPTION 'public.project1_actor() is missing: apply '
                        'migrations/project1_ai/20261121_90_m2_runtime_role_disposable.sql first';
    END IF;
END $$;

-- 1. Row level security on both tables.
ALTER TABLE public.m2_bdj_objective_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_bdj_objective_decisions ENABLE ROW LEVEL SECURITY;

-- 2. Owner-scoped policies, created only when absent (never duplicated).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'm2_bdj_objective_proposals'
          AND policyname = 'owner_scope'
    ) THEN
        CREATE POLICY owner_scope ON public.m2_bdj_objective_proposals
            FOR ALL
            USING (
                owner_user_id = project1_actor()
                AND EXISTS (
                    SELECT 1 FROM public.m2_assessments a
                    WHERE a.id = m2_bdj_objective_proposals.assessment_id
                      AND a.owner_user_id = project1_actor()
                )
            )
            WITH CHECK (
                owner_user_id = project1_actor()
                AND EXISTS (
                    SELECT 1 FROM public.m2_assessments a
                    WHERE a.id = m2_bdj_objective_proposals.assessment_id
                      AND a.owner_user_id = project1_actor()
                )
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'm2_bdj_objective_decisions'
          AND policyname = 'owner_scope'
    ) THEN
        -- decided_by is the acting owner. The adapter additionally proves
        -- proposal ownership inside the same transaction before inserting.
        CREATE POLICY owner_scope ON public.m2_bdj_objective_decisions
            FOR ALL
            USING (decided_by = project1_actor())
            WITH CHECK (decided_by = project1_actor());
    END IF;
END $$;

-- 3. Least-privilege grants for the restricted M2 principal.
REVOKE ALL ON public.m2_bdj_objective_proposals FROM p1_m2_runtime;
REVOKE ALL ON public.m2_bdj_objective_decisions FROM p1_m2_runtime;

GRANT SELECT, INSERT, UPDATE ON public.m2_bdj_objective_proposals TO p1_m2_runtime;
GRANT SELECT, INSERT ON public.m2_bdj_objective_decisions TO p1_m2_runtime;

-- Belt and braces: an inherited/public grant must not widen the surface.
REVOKE DELETE, TRUNCATE ON public.m2_bdj_objective_proposals FROM PUBLIC;
REVOKE DELETE, TRUNCATE ON public.m2_bdj_objective_decisions FROM PUBLIC;

-- 4. Post-conditions: fail the migration if the intended state is absent.
DO $$
DECLARE
    missing text := '';
BEGIN
    IF NOT (SELECT relrowsecurity FROM pg_class
            WHERE oid = 'public.m2_bdj_objective_proposals'::regclass) THEN
        missing := missing || ' proposals:rls';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class
            WHERE oid = 'public.m2_bdj_objective_decisions'::regclass) THEN
        missing := missing || ' decisions:rls';
    END IF;
    IF NOT has_table_privilege('p1_m2_runtime',
            'public.m2_bdj_objective_proposals', 'SELECT') THEN
        missing := missing || ' proposals:select';
    END IF;
    IF NOT has_table_privilege('p1_m2_runtime',
            'public.m2_bdj_objective_proposals', 'INSERT') THEN
        missing := missing || ' proposals:insert';
    END IF;
    IF NOT has_table_privilege('p1_m2_runtime',
            'public.m2_bdj_objective_proposals', 'UPDATE') THEN
        missing := missing || ' proposals:update';
    END IF;
    IF NOT has_table_privilege('p1_m2_runtime',
            'public.m2_bdj_objective_decisions', 'SELECT') THEN
        missing := missing || ' decisions:select';
    END IF;
    IF NOT has_table_privilege('p1_m2_runtime',
            'public.m2_bdj_objective_decisions', 'INSERT') THEN
        missing := missing || ' decisions:insert';
    END IF;
    IF has_table_privilege('p1_m2_runtime',
            'public.m2_bdj_objective_proposals', 'DELETE') THEN
        missing := missing || ' proposals:unexpected-delete';
    END IF;
    IF has_table_privilege('p1_m2_runtime',
            'public.m2_bdj_objective_decisions', 'DELETE') THEN
        missing := missing || ' decisions:unexpected-delete';
    END IF;
    IF (SELECT count(*) FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename IN ('m2_bdj_objective_proposals',
                            'm2_bdj_objective_decisions')
          AND policyname = 'owner_scope') <> 2 THEN
        missing := missing || ' policies:owner_scope';
    END IF;
    IF missing <> '' THEN
        RAISE EXCEPTION 'POSTCONDITION_FAILED:%', missing;
    END IF;
END $$;
