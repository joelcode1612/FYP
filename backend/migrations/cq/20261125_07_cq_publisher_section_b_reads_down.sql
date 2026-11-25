-- =====================================================================
-- 20261125_07 (down) — withdraw the publisher's Section B reads
--
-- Revoking SELECT removes the publisher's ability to compose Section B. It
-- destroys no data: the candidates, reviews and objective decisions all remain,
-- and the next publication simply refuses again rather than publishing a
-- 13-question instrument that silently omits the approved additional question.
--
-- Releases already published keep their manifest, which is the record of what
-- was actually released.
--
-- Explicit operator execution only. Never run at startup.
-- =====================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF current_setting('project1.cq_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.cq_migration_receipt', true), '') IS NULL
     OR coalesce(current_setting('project1.cq_migration_sha256', true), '') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Explicit target, receipt and hash required';
  END IF;
END $$;

REVOKE SELECT ON public.m2_qg_candidates            FROM p1_cq_publisher;
REVOKE SELECT ON public.m2_qg_candidate_reviews     FROM p1_cq_publisher;
REVOKE SELECT ON public.m2_bdj_objective_admissions FROM p1_cq_publisher;
REVOKE SELECT ON public.m2_bdj_objective_decisions  FROM p1_cq_publisher;
REVOKE SELECT ON public.m2_bdj_objective_proposals  FROM p1_cq_publisher;

DELETE FROM cq_schema_migrations WHERE version = '20261125_07';

COMMIT;
