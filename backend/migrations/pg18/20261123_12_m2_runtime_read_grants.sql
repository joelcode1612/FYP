-- =====================================================================
-- 20261123_12_m2_runtime_read_grants.sql
-- =====================================================================
-- Purpose
--   Grant ``p1_m2_runtime`` (the M2 lane's connection role) SELECT on the ten
--   ``public.m2_*`` tables it is expected to read but could not.
--
--   Measured failure (POST /api/v1/assessments/ succeeded, then the workspace
--   loaded two 503s):
--     GET /api/v1/m2/assessments/by-marketplace/{id}       -> 503
--     GET /api/v1/assessments/{id}/workflow-readiness      -> 503
--
--   Reproduced in-process (tools/pg18_diag_m2_link.py), real error:
--     sqlalchemy.exc.ProgrammingError:
--       (psycopg2.errors.InsufficientPrivilege)
--       permission denied for table m2_assessment_links
--     SQL: select l.m2_assessment_id, a.revision, a.instrument_id
--            from public.m2_assessment_links l
--            join public.m2_assessments a on a.id = l.m2_assessment_id
--           where l.marketplace_assessment_id = :mp and l.revoked_at is null
--
--   Both endpoints convert SQLAlchemyError into a 503, which is why the log
--   only showed "Service Unavailable" and not the privilege error.
--
-- Scope
--   SELECT only. No INSERT/UPDATE/DELETE and no ownership: these are read
--   surfaces for the M2 runtime. Writes stay with the roles that already hold
--   them.
--
-- Safety
--   Only a ``project1_pg18_%`` database on port 5544 may run this file.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
    t    text;
    n    int  := 0;
BEGIN
    IF db NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: % is not a project1_pg18_* database', db;
    END IF;
    IF port <> 5544 THEN
        RAISE EXCEPTION 'REFUSED: port % is not the isolated PG18 cluster (5544)', port;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
        RAISE EXCEPTION 'REFUSED: role p1_m2_runtime does not exist';
    END IF;

    FOREACH t IN ARRAY ARRAY[
        'm2_assessment_links',
        'm2_business_context_builds',
        'm2_business_contexts',
        'm2_candidate_owner_reviews',
        'm2_candidate_review_assignments',
        'm2_desired_options',
        'm2_research_clarifications',
        'm2_research_objective_sources',
        'm2_research_revisions',
        'm2_review_question_versions'
    ]
    LOOP
        IF to_regclass('public.' || t) IS NULL THEN
            RAISE NOTICE 'public.% is absent; skipped', t;
            CONTINUE;
        END IF;
        EXECUTE format('GRANT SELECT ON public.%I TO p1_m2_runtime', t);
        n := n + 1;
    END LOOP;

    RAISE NOTICE 'SELECT granted on % m2 relation(s) to p1_m2_runtime', n;
END
$$;
