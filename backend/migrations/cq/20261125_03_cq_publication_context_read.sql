-- =====================================================================
-- 20261125_03 — publisher read of the build receipt (DD-096 follow-up)
--
-- Why this is a separate migration
--   ``20261125_02`` created ``p1_cq_publisher`` and granted it SELECT on the
--   five M2 tables the *binding comparison* reads. It is already applied
--   (ledger ``20261125_02``, sha256 ``14fe6c26…``) and applied history is
--   immutable here: a file whose hash no longer matches its ledger row is
--   refused by every migration's own guard. So the publisher's read set is
--   extended in a new migration rather than by editing a recorded one.
--
-- Why the table is needed at all
--   ``20261125_02`` cannot publish an entrepreneur-specific release without
--   choosing *which* business context the manifest binds to. DD-093 Option A
--   settled that: ``m2_business_context_builds`` is the record of what the
--   build actually wrote, so the PERSISTED receipt for the confirmed revision
--   is the authority. Selecting from ``m2_business_contexts`` alone
--   (``ORDER BY assessment_revision DESC``) breaks ties arbitrarily among the
--   several PERSISTED rows a revision accumulates, which is the defect DD-093
--   closed. Publication must not reintroduce it.
--
-- What is granted
--   SELECT, on one table, to one role. The table's policy is already
--   ``owner_scope TO public`` on ``project1_actor()``, so the publisher sees
--   the build receipts of the actor it is bound to and no others. No policy is
--   created or altered, and no other principal moves.
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
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_cq_publisher') THEN
    RAISE EXCEPTION 'p1_cq_publisher missing: apply 20261125_02 first';
  END IF;
  IF to_regclass('public.m2_business_context_builds') IS NULL THEN
    RAISE EXCEPTION 'm2_business_context_builds missing: apply the DD-093 migration first';
  END IF;
  IF EXISTS (SELECT 1 FROM cq_schema_migrations
              WHERE version = '20261125_03'
                AND migration_sha256 <> current_setting('project1.cq_migration_sha256')) THEN
    RAISE EXCEPTION 'Migration hash differs';
  END IF;
END $$;

GRANT SELECT ON public.m2_business_context_builds TO p1_cq_publisher;

DO $$
BEGIN
  IF NOT has_table_privilege('p1_cq_publisher',
                             'public.m2_business_context_builds', 'SELECT') THEN
    RAISE EXCEPTION 'publisher cannot read the build receipt';
  END IF;
  IF has_table_privilege('p1_cq_publisher',
                         'public.m2_business_context_builds', 'INSERT')
     OR has_table_privilege('p1_cq_publisher',
                            'public.m2_business_context_builds', 'UPDATE')
     OR has_table_privilege('p1_cq_publisher',
                            'public.m2_business_context_builds', 'DELETE') THEN
    RAISE EXCEPTION 'publisher must not write the build receipt';
  END IF;
  -- The receipt table's scoping policy is unchanged and still applies to
  -- every role, so this grant widens *who may ask*, not *which rows answer*.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='m2_business_context_builds'
                    AND policyname='owner_scope' AND cmd='ALL'
                    AND qual LIKE '%project1_actor%') THEN
    RAISE EXCEPTION 'owner_scope policy on m2_business_context_builds changed shape';
  END IF;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261125_03', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
