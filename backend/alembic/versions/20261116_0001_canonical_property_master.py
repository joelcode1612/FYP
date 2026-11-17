"""Bind every remaining property relationship to the canonical master.

Revision ID: 0011_canonical_property_master
Revises: 0010_property_enrichment
Create Date: 2026-11-16

``fyp.rental_properties`` is the only authoritative commercial-property
master. This revision closes the last three places where that identity was
not enforced by the schema:

1. ``fyp.property_enrichment_category`` and ``fyp.property_feature_freshness``
   carried a bare ``property_id`` with no foreign key, so dangling rows could
   accumulate for properties that no longer exist. The orphan rows (all
   referencing ids above the live ``rental_properties`` max id, i.e. records
   of already-deleted properties) are removed and the canonical relationship
   is enforced with ``ON DELETE CASCADE`` — the same semantics the other
   operational related tables (photos, features, geospatial features) use.
2. ``fyp.rental_properties.owner_user_id`` (the authenticated Supabase
   identity UUID) is bound to ``public.users(user_id)`` with
   ``ON DELETE SET NULL``, mirroring the legacy ``owner_id`` behaviour:
   deleting an account leaves the listing unassigned rather than destroyed.
   The legacy BIGINT ``owner_id`` → ``fyp.users(id)`` foreign key is kept
   untouched for historical rows.

The ``fyp.catalogue_properties`` research-catalogue view (EP-/MD- workbook
attributes exposed over the canonical ``catalogue_*`` columns) already
existed before this revision and is intentionally left as the documented
read surface for the 955 research rows.

Applied out-of-band like revisions 0004-0010; the statements are idempotent.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0011_canonical_property_master"
down_revision = "0010_property_enrichment"
branch_labels = None
depends_on = None

_DDL = (
    # 1. Dangling per-category enrichment rows: their property ids no longer
    #    exist in the master, so they can never be displayed or refreshed.
    """
    DELETE FROM fyp.property_enrichment_category e
    WHERE NOT EXISTS (
        SELECT 1 FROM fyp.rental_properties r WHERE r.id = e.property_id
    )
    """,
    """
    DELETE FROM fyp.property_feature_freshness f
    WHERE NOT EXISTS (
        SELECT 1 FROM fyp.rental_properties r WHERE r.id = f.property_id
    )
    """,
    # 2. Enforce the canonical relationship on the two bookkeeping tables.
    """
    DO $$
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = 'fyp.property_enrichment_category'::regclass
              AND conname = 'property_enrichment_category_property_fk'
        ) THEN
            ALTER TABLE fyp.property_enrichment_category
                ADD CONSTRAINT property_enrichment_category_property_fk
                FOREIGN KEY (property_id)
                REFERENCES fyp.rental_properties(id)
                ON DELETE CASCADE;
        END IF;
    END
    $$;
    """,
    """
    DO $$
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = 'fyp.property_feature_freshness'::regclass
              AND conname = 'property_feature_freshness_property_fk'
        ) THEN
            ALTER TABLE fyp.property_feature_freshness
                ADD CONSTRAINT property_feature_freshness_property_fk
                FOREIGN KEY (property_id)
                REFERENCES fyp.rental_properties(id)
                ON DELETE CASCADE;
        END IF;
    END
    $$;
    """,
    # 3. Authenticated ownership identity: bind the UUID column to the user
    #    mirror. SET NULL matches the legacy owner_id behaviour.
    """
    DO $$
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = 'fyp.rental_properties'::regclass
              AND conname = 'rental_properties_owner_user_id_fkey'
        ) THEN
            ALTER TABLE fyp.rental_properties
                ADD CONSTRAINT rental_properties_owner_user_id_fkey
                FOREIGN KEY (owner_user_id)
                REFERENCES public.users(user_id)
                ON DELETE SET NULL;
        END IF;
    END
    $$;
    """,
)


def upgrade() -> None:
    bind = op.get_bind()
    for ddl in _DDL:
        bind.execute(sa.text(ddl))


def downgrade() -> None:
    bind = op.get_bind()
    for ddl in (
        (
            "ALTER TABLE fyp.rental_properties "
            "DROP CONSTRAINT IF EXISTS rental_properties_owner_user_id_fkey"
        ),
        (
            "ALTER TABLE fyp.property_feature_freshness "
            "DROP CONSTRAINT IF EXISTS property_feature_freshness_property_fk"
        ),
        (
            "ALTER TABLE fyp.property_enrichment_category "
            "DROP CONSTRAINT IF EXISTS property_enrichment_category_property_fk"
        ),
    ):
        bind.execute(sa.text(ddl))
    # The purged orphan rows are intentionally not restored: they referenced
    # property ids that no longer exist anywhere in the master.
