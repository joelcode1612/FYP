"""Agent listing change requests (additive + reversible).

Revision ID: 0007_listing_change_requests
Revises: 0006_listing_address_fields
Create Date: 2026-11-11

Two NEW tables in the application schema; no existing table, column or row
is touched:

* ``listing_change_request`` — one agent edit cycle on an ASSIGNED listing.
  ``changes`` holds {field: {"from": …, "to": …}} captured server-side from
  the live ``fyp.rental_properties`` row; ``status`` walks
  draft -> pending -> approved / rejected / changes_requested. An agent
  never writes ``fyp.rental_properties`` directly; only the administrator
  decision endpoint applies approved changes.
* ``listing_change_audit`` — append-only event history (draft saves, review
  requests, administrator decisions, agent notes) with actor + timestamp.

Rollback drops exactly these two tables.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0007_listing_change_requests"
down_revision = "0006_listing_address_fields"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            CREATE TABLE IF NOT EXISTS listing_change_request (
                change_request_id uuid PRIMARY KEY,
                listing_id integer NOT NULL
                    REFERENCES fyp.rental_properties(id),
                proposed_by uuid NOT NULL REFERENCES users(user_id),
                changes jsonb NOT NULL DEFAULT '{}'::jsonb,
                status varchar(24) NOT NULL DEFAULT 'draft',
                reason varchar(2000),
                reviewed_by uuid REFERENCES users(user_id),
                review_note varchar(2000),
                created_at timestamp with time zone NOT NULL DEFAULT now(),
                updated_at timestamp with time zone NOT NULL DEFAULT now(),
                CONSTRAINT ck_listing_change_request_status CHECK (
                    status IN ('draft','pending','approved','rejected',
                               'changes_requested')
                )
            )
            """
        )
    )
    bind.execute(
        sa.text(
            "CREATE INDEX IF NOT EXISTS ix_listing_change_request_listing_id "
            "ON listing_change_request (listing_id)"
        )
    )
    bind.execute(
        sa.text(
            "CREATE INDEX IF NOT EXISTS ix_listing_change_request_status "
            "ON listing_change_request (status)"
        )
    )
    bind.execute(
        sa.text(
            "CREATE INDEX IF NOT EXISTS ix_listing_change_request_proposed_by "
            "ON listing_change_request (proposed_by)"
        )
    )
    bind.execute(
        sa.text(
            """
            CREATE TABLE IF NOT EXISTS listing_change_audit (
                audit_id uuid PRIMARY KEY,
                change_request_id uuid
                    REFERENCES listing_change_request(change_request_id),
                listing_id integer NOT NULL
                    REFERENCES fyp.rental_properties(id),
                action varchar(40) NOT NULL,
                actor_user_id uuid NOT NULL REFERENCES users(user_id),
                note varchar(2000),
                created_at timestamp with time zone NOT NULL DEFAULT now()
            )
            """
        )
    )
    bind.execute(
        sa.text(
            "CREATE INDEX IF NOT EXISTS ix_listing_change_audit_request_id "
            "ON listing_change_audit (change_request_id)"
        )
    )
    bind.execute(
        sa.text(
            "CREATE INDEX IF NOT EXISTS ix_listing_change_audit_listing_id "
            "ON listing_change_audit (listing_id)"
        )
    )
    bind.execute(
        sa.text(
            "CREATE INDEX IF NOT EXISTS ix_listing_change_audit_created_at "
            "ON listing_change_audit (created_at)"
        )
    )


def downgrade() -> None:
    bind = op.get_bind()
    bind.execute(sa.text("DROP TABLE IF EXISTS listing_change_audit"))
    bind.execute(sa.text("DROP TABLE IF EXISTS listing_change_request"))
