"""Additive: unified property verification (listing + ownership dimensions).

Revision ID: 0003_property_verification
Revises: 0002_saved_property_refs
Create Date: 2026-11-09

Three new tables only — ``property_verification`` (one row per owner-submitted
property, both review dimensions plus publication eligibility), and its
``verification_document`` (private storage metadata; the files live on disk,
never in the database) and ``verification_audit`` (every transition, decision
actor and reason) children. No existing table is touched, no column of an
existing table is altered, and ``property`` rows are preserved by construction
(the FK targets ``property.property_id`` read-only).

Idempotent via inspection, like 0001/0002: against a database where startup
``create_all`` already made the tables this is a no-op rather than an error.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0003_property_verification"
down_revision = "0002_saved_property_refs"
branch_labels = None
depends_on = None

_STATUS_CHECK = (
    "({col} IN ('not_submitted','pending','under_review',"
    "'verified','rejected','information_requested'))"
)


def _has_table(bind, name: str) -> bool:
    return sa.inspect(bind).has_table(name)


def upgrade() -> None:
    bind = op.get_bind()

    if not _has_table(bind, "property_verification"):
        op.create_table(
            "property_verification",
            sa.Column("verification_id", sa.Uuid(), primary_key=True),
            sa.Column(
                "property_id",
                sa.Integer(),
                sa.ForeignKey("property.property_id"),
                nullable=False,
            ),
            sa.Column("listing_status", sa.String(length=32), nullable=False),
            sa.Column("ownership_status", sa.String(length=32), nullable=False),
            sa.Column("submitted_by", sa.Uuid(), sa.ForeignKey("users.user_id"), nullable=False),
            sa.Column("reviewed_by", sa.Uuid(), sa.ForeignKey("users.user_id")),
            sa.Column("publication_eligible", sa.Boolean(), nullable=False),
            sa.Column("latest_note", sa.String(length=2000)),
            sa.Column("version", sa.Integer(), nullable=False),
            sa.Column("created_at", sa.DateTime(), nullable=False),
            sa.Column("updated_at", sa.DateTime(), nullable=False),
            sa.UniqueConstraint("property_id", name="uq_property_verification_property"),
            sa.CheckConstraint(
                _STATUS_CHECK.format(col="listing_status"),
                name="ck_property_verification_listing_status",
            ),
            sa.CheckConstraint(
                _STATUS_CHECK.format(col="ownership_status"),
                name="ck_property_verification_ownership_status",
            ),
        )
        op.create_index(
            "ix_property_verification_property_id",
            "property_verification",
            ["property_id"],
        )
        op.create_index(
            "ix_property_verification_submitted_by",
            "property_verification",
            ["submitted_by"],
        )

    if not _has_table(bind, "verification_document"):
        op.create_table(
            "verification_document",
            sa.Column("document_id", sa.Uuid(), primary_key=True),
            sa.Column(
                "verification_id",
                sa.Uuid(),
                sa.ForeignKey("property_verification.verification_id"),
                nullable=False,
            ),
            sa.Column(
                "property_id",
                sa.Integer(),
                sa.ForeignKey("property.property_id"),
                nullable=False,
            ),
            sa.Column("verification_type", sa.String(length=16), nullable=False),
            sa.Column("document_type", sa.String(length=60), nullable=False),
            sa.Column("original_filename", sa.String(length=255), nullable=False),
            sa.Column("storage_key", sa.String(length=120), nullable=False),
            sa.Column("mime_type", sa.String(length=100), nullable=False),
            sa.Column("file_size", sa.Integer(), nullable=False),
            sa.Column("uploaded_by", sa.Uuid(), sa.ForeignKey("users.user_id"), nullable=False),
            sa.Column("uploaded_at", sa.DateTime(), nullable=False),
            sa.Column("status", sa.String(length=20), nullable=False),
            sa.UniqueConstraint("storage_key", name="uq_verification_document_storage_key"),
            sa.CheckConstraint(
                "verification_type IN ('listing','ownership')",
                name="ck_verification_document_type",
            ),
        )
        op.create_index(
            "ix_verification_document_verification_id",
            "verification_document",
            ["verification_id"],
        )
        op.create_index(
            "ix_verification_document_property_id",
            "verification_document",
            ["property_id"],
        )

    if not _has_table(bind, "verification_audit"):
        op.create_table(
            "verification_audit",
            sa.Column("audit_id", sa.Uuid(), primary_key=True),
            sa.Column(
                "property_id",
                sa.Integer(),
                sa.ForeignKey("property.property_id"),
                nullable=False,
            ),
            sa.Column(
                "verification_id",
                sa.Uuid(),
                sa.ForeignKey("property_verification.verification_id"),
            ),
            sa.Column("verification_type", sa.String(length=16)),
            sa.Column("previous_status", sa.String(length=32)),
            sa.Column("new_status", sa.String(length=32)),
            sa.Column("action", sa.String(length=60), nullable=False),
            sa.Column("admin_user_id", sa.Uuid(), sa.ForeignKey("users.user_id")),
            sa.Column("reason", sa.String(length=2000)),
            sa.Column("created_at", sa.DateTime(), nullable=False),
        )
        op.create_index("ix_verification_audit_property_id", "verification_audit", ["property_id"])
        op.create_index(
            "ix_verification_audit_verification_id", "verification_audit", ["verification_id"]
        )
        op.create_index("ix_verification_audit_created_at", "verification_audit", ["created_at"])


def downgrade() -> None:
    # Rollback removes only these three tables; no pre-existing data is
    # affected. Verification documents on disk are left in place (deleting
    # evidence files is a separate, explicit operational action).
    bind = op.get_bind()
    if _has_table(bind, "verification_audit"):
        op.drop_table("verification_audit")
    if _has_table(bind, "verification_document"):
        op.drop_table("verification_document")
    if _has_table(bind, "property_verification"):
        op.drop_table("property_verification")
