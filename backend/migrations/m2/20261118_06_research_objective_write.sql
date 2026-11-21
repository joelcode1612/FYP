-- CP-10C / DEF-09 — least-privilege research-objective write path
--
-- STATUS: PREPARED ONLY. NOT APPLIED TO Dss.
--
-- WHAT IS ACTUALLY MISSING (measured, not assumed)
--   p1_m2_runtime holds SELECT only on public.m2_research_objective_sources, so the write
--   fails closed with 503 M2_SOURCE_UNAVAILABLE. But a GRANT alone would still fail, because
--   the table's only policy is `owner_scope FOR SELECT`. Row-level security denies an INSERT
--   when no INSERT policy exists, regardless of table privileges.
--
--   Sibling tables are already writable by the same principal:
--     m2_confirmed_uncertainties  INSERT,SELECT,UPDATE
--     m2_confirmation_snapshots   INSERT,SELECT,UPDATE
--
-- SO THE FIX IS TWO STATEMENTS, NOT ONE
--   1. GRANT INSERT (no UPDATE: the source row is append-only provenance).
--   2. An INSERT policy whose WITH CHECK resolves the parent uncertainty through the same
--      owner-scoped table the SELECT policy already uses, so a caller cannot attach
--      provenance to another entrepreneur's uncertainty.
--
-- WHY NOT UPDATE
--   The provenance payload is a historical receipt. Allowing UPDATE would let a later
--   transaction rewrite the source of an objective that was already recorded.

BEGIN;

GRANT INSERT ON public.m2_research_objective_sources TO p1_m2_runtime;

DROP POLICY IF EXISTS owner_insert ON public.m2_research_objective_sources;
CREATE POLICY owner_insert ON public.m2_research_objective_sources
    FOR INSERT
    WITH CHECK (
        objective_id IN (SELECT id FROM public.m2_confirmed_uncertainties)
    );

COMMIT;
