-- CP-10C / DEF-09 — rollback for 20261118_06_research_objective_write.sql
--
-- STATUS: PREPARED ONLY. NOT APPLIED.
--
-- Restores the exact prior posture: SELECT-only grant, SELECT-only policy.
-- No data is touched: rows already written under the granted path remain, because revoking
-- INSERT does not delete history and the provenance table is append-only by design.

BEGIN;

DROP POLICY IF EXISTS owner_insert ON public.m2_research_objective_sources;
REVOKE INSERT ON public.m2_research_objective_sources FROM p1_m2_runtime;

COMMIT;
