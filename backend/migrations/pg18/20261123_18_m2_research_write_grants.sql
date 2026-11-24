-- =====================================================================
-- 20261123_18_m2_research_write_grants.sql
--
-- Purpose
--   Make the research-objective write path usable by the M2 lane:
--   ``p1_m2_runtime`` gains INSERT on ``m2_research_objective_sources``,
--   ``m2_research_revisions`` and ``m2_research_clarifications``, and each table
--   gains the INSERT policy it never had.
--
-- Reason
--   ``POST /m2/confirmations/{id}/research-objectives`` is the only route that
--   records a research objective, and therefore the only way stage 3 can ever
--   complete. It failed with a bare
--
--     503 {"code":"M2_SOURCE_UNAVAILABLE"}
--
--   reproduced against this cluster:
--
--     has_table_privilege('p1_m2_runtime','m2_research_objective_sources','INSERT') -> false
--
--   The tables were readable and unwritable, and — unlike the m2_* tables fixed
--   in 20261123_02..17 — they also carry only a SELECT policy. Granting INSERT
--   alone would still be refused by RLS, so this file adds the matching INSERT
--   policy rather than disabling RLS.
--
-- Scope
--   Append-only. No UPDATE and no DELETE: an objective is an immutable version,
--   revisions are new rows, and nothing in the workflow rewrites history.
--   The INSERT policy reuses the existing owner_scope predicate — the row's
--   objective must be one the acting owner can already see — so the grant
--   widens the privilege and not the scope. ``project1.actor_id`` is set per
--   transaction by the M2 session; without it the predicate matches nothing.
--
-- Safety
--   Only a ``project1_pg18_%`` database on port 5544 may run this file.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
    tbl  text;
    col  text;
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

    FOR tbl, col IN
        SELECT v.t, v.c FROM (VALUES
            ('m2_research_objective_sources', 'objective_id'),
            ('m2_research_clarifications',    'objective_id'),
            ('m2_research_revisions',         'parent_id')
        ) AS v(t, c)
    LOOP
        IF to_regclass('public.' || tbl) IS NULL THEN
            RAISE EXCEPTION 'REFUSED: public.% is absent', tbl;
        END IF;

        EXECUTE format('GRANT INSERT ON public.%I TO p1_m2_runtime', tbl);

        -- Idempotent: re-running the file must not create a duplicate policy.
        IF NOT EXISTS (SELECT 1 FROM pg_policies
                       WHERE schemaname = 'public' AND tablename = tbl
                         AND policyname = 'insert_scope') THEN
            EXECUTE format(
                'CREATE POLICY insert_scope ON public.%I FOR INSERT '
                'WITH CHECK (%I IN (SELECT id FROM public.m2_confirmed_uncertainties))',
                tbl, col);
        END IF;

        RAISE NOTICE 'INSERT granted on public.% to p1_m2_runtime', tbl;
    END LOOP;
END $$;

-- Fail closed: the M2 lane must not have acquired a destructive capability.
DO $$
DECLARE bad text;
BEGIN
    SELECT string_agg(t, ', ') INTO bad
    FROM unnest(ARRAY['m2_research_objective_sources',
                      'm2_research_clarifications',
                      'm2_research_revisions']) t
    WHERE has_table_privilege('p1_m2_runtime', 'public.' || t, 'DELETE')
       OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'TRUNCATE');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'REFUSED: p1_m2_runtime holds DELETE/TRUNCATE on %', bad;
    END IF;
END $$;
