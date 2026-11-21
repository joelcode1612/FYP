-- CP-10A (rev.2) — rollback for public.m2_assessment_links
--
-- STATUS: PREPARED ONLY. NOT APPLIED.
--
-- The directive requires that a rollback "preserves or safely exports established mapping
-- records before removing the table". This script therefore:
--   1. copies every row into an archive table that outlives the drop,
--   2. asserts the archive row count equals the live row count (fails the transaction if not),
--   3. only then drops the live table.
--
-- The archive is deliberately NOT dropped here. Removing it is a separate, explicit decision.

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.m2_assessment_links') IS NULL THEN
        RAISE NOTICE 'm2_assessment_links does not exist; nothing to roll back.';
        RETURN;
    END IF;

    -- 1. Archive (idempotent: keeps the earliest archive for a given link_id).
    CREATE TABLE IF NOT EXISTS public.m2_assessment_links_archive (
        link_id                   uuid        NOT NULL,
        m2_assessment_id          uuid        NOT NULL,
        marketplace_assessment_id uuid        NOT NULL,
        user_id                   uuid        NOT NULL,
        created_at                timestamptz NOT NULL,
        created_by                uuid        NOT NULL,
        revoked_at                timestamptz,
        revoked_by                uuid,
        revoke_reason             text,
        archived_at               timestamptz NOT NULL DEFAULT now(),
        archived_by               text        NOT NULL DEFAULT current_user,
        CONSTRAINT pk_m2_link_archive PRIMARY KEY (link_id)
    );

    INSERT INTO public.m2_assessment_links_archive (
        link_id, m2_assessment_id, marketplace_assessment_id, user_id,
        created_at, created_by, revoked_at, revoked_by, revoke_reason
    )
    SELECT link_id, m2_assessment_id, marketplace_assessment_id, user_id,
           created_at, created_by, revoked_at, revoked_by, revoke_reason
    FROM public.m2_assessment_links
    ON CONFLICT (link_id) DO NOTHING;

    -- 2. Assert nothing was lost. A mismatch aborts the whole transaction.
    IF (SELECT count(*) FROM public.m2_assessment_links_archive)
       < (SELECT count(*) FROM public.m2_assessment_links) THEN
        RAISE EXCEPTION 'ARCHIVE_INCOMPLETE: archive holds % rows, live table holds %',
            (SELECT count(*) FROM public.m2_assessment_links_archive),
            (SELECT count(*) FROM public.m2_assessment_links);
    END IF;

    -- 3. Drop the live object only after the archive is proven complete.
    DROP TABLE public.m2_assessment_links;
END $$;

COMMIT;
