"""Retire the unused legacy ``public.property`` table.

Revision ID: 0005_drop_legacy_property
Revises: 0004_owner_listing_verification
Create Date: 2026-11-10

Reviewed for data loss and dependency risk (task Phase 5):

* ``public.property`` contains EXACTLY ZERO rows on the target deployment
  (verified before this migration runs; the upgrade aborts otherwise).
* ``fyp.rental_properties`` (1,183 rows) is the canonical operational table;
  the verification tables were already rebound to it by 0004.
* The eight child tables that still reference ``property.property_id``
  (ai_explanation, nearby_competitor, property_feature, property_foot_traffic,
  property_geospatial_feature, property_photo, recommendation_result,
  virtual_tour) are ALL EMPTY and belong to features that remain live, so
  only their legacy FK CONSTRAINTS are dropped — no child table is removed
  and no child row is lost.
* No views, materialized views or triggers depend on the table; its only
  index is the primary key.
* ``public.users`` / ``public.address`` / ``auth.users`` are unrelated and
  are NOT touched.
* RESTRICT (never CASCADE) is used, so any unreviewed dependency discovered
  at execution time aborts the migration instead of destroying it.

The downgrade recreates the empty legacy table + child FKs so the migration
is reversible (the table was empty, so no data can be lost either way).
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0005_drop_legacy_property"
down_revision = "0004_owner_listing_verification"
branch_labels = None
depends_on = None

#: Empty child tables whose legacy FK constraint is retired (table kept).
_CHILD_FKS = (
    "ai_explanation",
    "nearby_competitor",
    "property_feature",
    "property_foot_traffic",
    "property_geospatial_feature",
    "property_photo",
    "recommendation_result",
    "virtual_tour",
)

_PROPERTY_DDL = """
CREATE TABLE public.property (
    property_id integer NOT NULL,
    address_id uuid,
    district_id character varying(50),
    user_id uuid,
    company_name character varying(255),
    normalized_address character varying(255),
    property_type_normalized character varying(100),
    tenure character varying(50),
    floor_level character varying(50),
    unit_position character varying(50),
    built_up_area_sqft numeric,
    land_area_sqft numeric,
    frontage_ft numeric,
    depth_ft numeric,
    facing_direction character varying(50),
    bathroom_count integer,
    parking_spaces integer,
    title character varying(255),
    description text,
    status character varying(50),
    price numeric,
    bedrooms integer,
    year_built integer,
    CONSTRAINT property_pkey PRIMARY KEY (property_id),
    CONSTRAINT property_address_id_fkey FOREIGN KEY (address_id)
        REFERENCES public.address (address_id),
    CONSTRAINT property_district_id_fkey FOREIGN KEY (district_id)
        REFERENCES public.district_demographic (district_id),
    CONSTRAINT property_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES public.users (user_id)
)
"""


def _has_table(bind, name: str) -> bool:
    return sa.inspect(bind).has_table(name)


def upgrade() -> None:
    bind = op.get_bind()

    count = int(
        bind.execute(sa.text("SELECT count(*) FROM public.property")).scalar_one()
    )
    if count != 0:
        raise RuntimeError(
            f"public.property holds {count} rows; refusing to drop a "
            "non-empty table. Back up and migrate the rows first."
        )

    for table in _CHILD_FKS:
        if not _has_table(bind, table):
            continue
        bind.execute(
            sa.text(
                f"ALTER TABLE {table} DROP CONSTRAINT IF EXISTS "
                f"{table}_property_id_fkey"
            )
        )

    if _has_table(bind, "property"):
        bind.execute(sa.text("DROP TABLE public.property RESTRICT"))


def downgrade() -> None:
    bind = op.get_bind()
    if not _has_table(bind, "property"):
        bind.execute(sa.text(_PROPERTY_DDL))
    for table in _CHILD_FKS:
        if not _has_table(bind, table):
            continue
        bind.execute(
            sa.text(
                f"ALTER TABLE {table} ADD CONSTRAINT "
                f"{table}_property_id_fkey FOREIGN KEY (property_id) "
                "REFERENCES public.property(property_id)"
            )
        )
