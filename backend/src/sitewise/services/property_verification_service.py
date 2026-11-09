"""Unified property verification workflow (listing + ownership dimensions).

Lifecycle (spec section 4): the owner submits the property with listing
information and ownership evidence; administrators review each dimension
independently; the property becomes publication-eligible only when BOTH
dimensions are ``verified``. Every transition writes a durable
``verification_audit`` row in the SAME transaction as the status change, and
decision queries take a row lock (``SELECT ... FOR UPDATE``) so concurrent
administrators serialize instead of silently overwriting each other.

Uploading the first evidence auto-creates the submission record in
``not_submitted`` state — documents reference a verification row, so the
record must exist before the submit action can require ownership evidence.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import text
from sqlmodel import Session, select

from sitewise.core.exceptions import (
    ConflictError,
    ForbiddenError,
    NotFoundError,
)
from sitewise.db.models.address import Address
from sitewise.db.models.property_verification import (
    LISTING_STATUSES,
    PropertyVerification,
    VerificationAudit,
    VerificationDocument,
    can_resubmit,
)
from sitewise.db.models.rental_property import RentalProperty
from sitewise.services import verification_storage as storage

DECISIONABLE = ("pending", "under_review")
RESUBMITTABLE = ("not_submitted", "rejected", "information_requested")


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


def property_payload(prop: RentalProperty, session: Session) -> dict[str, Any]:
    address = session.get(Address, prop.address_id) if prop.address_id else None
    return {
        "property_id": prop.property_id,
        "title": prop.title,
        "description": prop.description,
        "property_type": prop.property_type_normalized,
        "monthly_rent": None if prop.price is None else float(prop.price),
        "built_up_area_sqft": None
        if prop.built_up_area_sqft is None
        else float(prop.built_up_area_sqft),
        "land_area_sqft": None if prop.land_area_sqft is None else float(prop.land_area_sqft),
        "address": prop.normalized_address,
        "city": address.city if address else None,
        "state": address.state if address else None,
        "status": prop.status,
        "company_name": prop.company_name,
        "user_id": None if prop.user_id is None else str(prop.user_id),
    }


def verification_payload(v: PropertyVerification) -> dict[str, Any]:
    return {
        "verification_id": str(v.verification_id),
        "property_id": v.property_id,
        "listing_status": v.listing_status,
        "ownership_status": v.ownership_status,
        "publication_eligible": v.publication_eligible,
        "submitted_by": str(v.submitted_by),
        "reviewed_by": None if v.reviewed_by is None else str(v.reviewed_by),
        "latest_note": v.latest_note,
        "version": v.version,
        "submitted_at": _iso(v.created_at),
        "updated_at": _iso(v.updated_at),
    }


def document_payload(d: VerificationDocument) -> dict[str, Any]:
    return {
        "document_id": str(d.document_id),
        "verification_id": str(d.verification_id),
        "property_id": d.property_id,
        "verification_type": d.verification_type,
        "document_type": d.document_type,
        "original_filename": d.original_filename,
        "mime_type": d.mime_type,
        "file_size": d.file_size,
        "uploaded_at": _iso(d.uploaded_at),
        "status": d.status,
    }


def audit_payload(a: VerificationAudit) -> dict[str, Any]:
    return {
        "audit_id": str(a.audit_id),
        "property_id": a.property_id,
        "verification_id": None if a.verification_id is None else str(a.verification_id),
        "verification_type": a.verification_type,
        "previous_status": a.previous_status,
        "new_status": a.new_status,
        "action": a.action,
        "admin_user_id": None if a.admin_user_id is None else str(a.admin_user_id),
        "reason": a.reason,
        "created_at": _iso(a.created_at),
    }


def verification_row(session: Session, property_id: int) -> PropertyVerification | None:
    return session.exec(
        select(PropertyVerification).where(PropertyVerification.property_id == property_id)
    ).first()


class PropertyVerificationService:
    """Submitter-side operations (the property's owning account)."""

    def __init__(self, session: Session):
        self.session = session

    # -- lookups ------------------------------------------------------------

    def get_property_owned(
        self, property_id: int, user_id: uuid.UUID, is_admin: bool = False
    ) -> RentalProperty:
        prop = self.session.get(RentalProperty, property_id)
        if prop is None:
            raise NotFoundError("Property not found")
        if not is_admin and prop.user_id != user_id:
            raise ForbiddenError("You can only manage your own property listings.")
        return prop

    def status_for_property(
        self, property_id: int, user_id: uuid.UUID, is_admin: bool = False
    ) -> dict[str, Any]:
        prop = self.get_property_owned(property_id, user_id, is_admin)
        verification = verification_row(self.session, property_id)
        documents = self._document_rows(property_id) if verification else []
        corrections = self._requested_corrections(property_id, verification) if verification else {}
        return {
            "property": property_payload(prop, self.session),
            "verification": None if verification is None else verification_payload(verification),
            "documents": documents,
            "requested_corrections": corrections,
        }

    def document_for_download(
        self, document_id: uuid.UUID, user_id: uuid.UUID, is_admin: bool
    ) -> VerificationDocument:
        doc = self.session.get(VerificationDocument, document_id)
        if doc is None:
            raise NotFoundError("Document not found")
        if is_admin:
            return doc
        prop = self.session.get(RentalProperty, doc.property_id)
        owned = prop is not None and prop.user_id == user_id
        if not owned:
            verification = self.session.get(PropertyVerification, doc.verification_id)
            submitted = verification is not None and verification.submitted_by == user_id
            if not submitted:
                raise ForbiddenError("This document belongs to another submission.")
        return doc

    # -- mutations ----------------------------------------------------------

    def submit(self, property_id: int, submitter_id: uuid.UUID) -> dict[str, Any]:
        self.get_property_owned(property_id, submitter_id)
        verification = verification_row(self.session, property_id)
        if verification is None:
            verification = PropertyVerification(property_id=property_id, submitted_by=submitter_id)
            self.session.add(verification)
            self.session.flush()
            previous: dict[str, str | None] = {
                "listing_status": None,
                "ownership_status": None,
            }
        else:
            if not can_resubmit(verification.listing_status, verification.ownership_status):
                raise ConflictError(
                    "This property is already awaiting or has passed review; "
                    "wait for the administrator's decision."
                )
            previous = {
                "listing_status": verification.listing_status,
                "ownership_status": verification.ownership_status,
            }
        ownership_docs = self.session.exec(
            select(VerificationDocument).where(
                VerificationDocument.property_id == property_id,
                VerificationDocument.verification_type == "ownership",
                VerificationDocument.status == "active",
            )
        ).all()
        if not ownership_docs:
            raise ConflictError(
                "Upload at least one ownership or authorisation document "
                "before submitting for verification."
            )
        if verification.listing_status in RESUBMITTABLE:
            verification.listing_status = "pending"
        if verification.ownership_status in RESUBMITTABLE:
            verification.ownership_status = "pending"
        verification.submitted_by = submitter_id
        verification.latest_note = None
        verification.publication_eligible = False
        verification.updated_at = _now()
        verification.version += 1
        self.session.add(
            VerificationAudit(
                property_id=property_id,
                verification_id=verification.verification_id,
                verification_type=None,
                previous_status=previous["listing_status"],
                new_status=verification.listing_status,
                action="submitted",
            )
        )
        self.session.commit()
        self.session.refresh(verification)
        return verification_payload(verification)

    def add_document(
        self,
        property_id: int,
        uploader_id: uuid.UUID,
        verification_type: str,
        document_type: str,
        original_filename: str,
        content_type: str,
        data: bytes,
    ) -> VerificationDocument:
        self.get_property_owned(property_id, uploader_id)
        if verification_type not in ("listing", "ownership"):
            raise ConflictError("verification_type must be 'listing' or 'ownership'.")
        if not (document_type or "").strip():
            raise ConflictError("A document type is required.")
        verification = verification_row(self.session, property_id)
        if verification is not None and (
            verification.listing_status == "verified"
            and verification.ownership_status == "verified"
        ):
            raise ConflictError(
                "This property is fully verified; no further evidence can be added."
            )
        if verification is None:
            verification = PropertyVerification(property_id=property_id, submitted_by=uploader_id)
            self.session.add(verification)
            self.session.flush()
        ext = storage.validate_upload(original_filename, content_type, len(data))
        key = storage.save_document(data, ext)
        try:
            document = VerificationDocument(
                verification_id=verification.verification_id,
                property_id=property_id,
                verification_type=verification_type,
                document_type=document_type.strip()[:60],
                original_filename=(original_filename or "").strip() or f"document{ext}",
                storage_key=key,
                mime_type=(content_type or "").split(";")[0].strip().lower(),
                file_size=len(data),
                uploaded_by=uploader_id,
            )
            self.session.add(document)
            self.session.add(
                VerificationAudit(
                    property_id=property_id,
                    verification_id=verification.verification_id,
                    verification_type=verification_type,
                    action="evidence_uploaded",
                    reason=document_type.strip()[:60],
                )
            )
            self.session.commit()
        except Exception:
            storage.delete_document(key)
            raise
        self.session.refresh(document)
        return document

    # -- payload helpers ------------------------------------------------------

    def _document_rows(self, property_id: int) -> list[dict[str, Any]]:
        rows = self.session.exec(
            select(VerificationDocument)
            .where(VerificationDocument.property_id == property_id)
            .order_by(VerificationDocument.uploaded_at)  # type: ignore[call-arg]
        ).all()
        return [document_payload(d) for d in rows]

    def _requested_corrections(
        self, property_id: int, verification: PropertyVerification
    ) -> dict[str, str | None]:
        """Latest staff reason/note per dimension, surfaced only while that
        dimension still sits in a note-bearing state (rejected or
        information_requested) — a resubmitted dimension stops nagging."""
        rows = self.session.exec(
            select(VerificationAudit)
            .where(
                VerificationAudit.property_id == property_id,
                VerificationAudit.action.in_(  # type: ignore[attr-defined]
                    [
                        "listing_rejected",
                        "ownership_rejected",
                        "listing_information_requested",
                        "ownership_information_requested",
                    ]
                ),
            )
            .order_by(VerificationAudit.created_at.desc())  # type: ignore[call-arg]
        ).all()
        corrections: dict[str, str | None] = {"listing": None, "ownership": None}
        for row in rows:
            dimension = "listing" if row.action.startswith("listing") else "ownership"
            if corrections[dimension] is None and getattr(verification, f"{dimension}_status") in (
                "rejected",
                "information_requested",
            ):
                corrections[dimension] = row.reason
        return corrections


class AdminPropertyReviewService:
    """Administrator queue, detail and per-dimension decisions."""

    def __init__(self, session: Session):
        self.session = session

    # -- reads --------------------------------------------------------------

    def queue(
        self,
        *,
        q: str | None = None,
        listing_status: str | None = None,
        ownership_status: str | None = None,
        property_type: str | None = None,
        state: str | None = None,
        city: str | None = None,
        submitted_from: datetime | None = None,
        submitted_to: datetime | None = None,
        sort: str = "submitted_at",
        order: str = "desc",
        offset: int = 0,
        limit: int = 20,
    ) -> dict[str, Any]:
        self._validate_statuses(listing_status, ownership_status)
        limit = max(1, min(limit, 100))
        offset = max(0, offset)
        order_dir = "ASC" if order.lower() == "asc" else "DESC"
        sort_column = {
            "submitted_at": "pv.created_at",
            "updated_at": "pv.updated_at",
            "title": "p.title",
            "monthly_rent": "p.price",
        }.get(sort, "pv.created_at")

        where = ["pv.verification_id IS NOT NULL"]
        params: dict[str, Any] = {}
        if q:
            where.append(
                "(p.title ILIKE :q OR p.normalized_address ILIKE :q OR p.company_name ILIKE :q)"
            )
            params["q"] = f"%{q}%"
        if listing_status:
            where.append("pv.listing_status = :listing_status")
            params["listing_status"] = listing_status
        if ownership_status:
            where.append("pv.ownership_status = :ownership_status")
            params["ownership_status"] = ownership_status
        if property_type:
            where.append("p.property_type_normalized = :property_type")
            params["property_type"] = property_type
        if state:
            where.append("a.state = :state")
            params["state"] = state
        if city:
            where.append("a.city = :city")
            params["city"] = city
        if submitted_from:
            where.append("pv.created_at >= :submitted_from")
            params["submitted_from"] = submitted_from
        if submitted_to:
            where.append("pv.created_at < :submitted_to")
            params["submitted_to"] = submitted_to
        where_sql = " AND ".join(where)
        base_from = (
            " FROM property_verification pv"
            " JOIN property p ON p.property_id = pv.property_id"
            " LEFT JOIN address a ON a.address_id = p.address_id"
        )

        count = self.session.execute(
            text(f"SELECT count(*){base_from} WHERE {where_sql}"), params
        ).scalar_one()

        rows = (
            self.session.execute(
                text(
                    "SELECT pv.verification_id, pv.property_id, pv.listing_status, "
                    "pv.ownership_status, pv.publication_eligible, pv.latest_note, "
                    "pv.created_at AS submitted_at, pv.updated_at, "
                    "p.title, p.normalized_address, p.property_type_normalized, "
                    "p.price, p.built_up_area_sqft, p.status AS property_status, "
                    "p.company_name, a.city, a.state "
                    f"{base_from} WHERE {where_sql} "
                    f"ORDER BY {sort_column} {order_dir} NULLS LAST "
                    "LIMIT :limit OFFSET :offset"
                ),
                {**params, "limit": limit, "offset": offset},
            )
            .mappings()
            .all()
        )

        return {
            "items": [dict(row) for row in rows],
            "total": count,
            "offset": offset,
            "limit": limit,
            "counts": {
                "listing": self._facet_counts(base_from, where_sql, params, "listing_status"),
                "ownership": self._facet_counts(base_from, where_sql, params, "ownership_status"),
            },
        }

    def _facet_counts(
        self, base_from: str, where_sql: str, params: dict[str, Any], column: str
    ) -> dict[str, int]:
        """Counts per status of one dimension over the rows matching every
        filter EXCEPT that dimension's own filter (faceted counts)."""
        kept = " AND ".join(
            clause for clause in where_sql.split(" AND ") if not clause.endswith(f"= :{column}")
        )
        rows = (
            self.session.execute(
                text(
                    f"SELECT pv.{column} AS status, count(*) AS n{base_from} "
                    f"WHERE {kept} GROUP BY pv.{column}"
                ),
                params,
            )
            .mappings()
            .all()
        )
        return {row["status"]: row["n"] for row in rows}

    def detail(self, property_id: int) -> dict[str, Any]:
        verification = verification_row(self.session, property_id)
        prop = self.session.get(RentalProperty, property_id)
        if verification is None or prop is None:
            raise NotFoundError("No verification submission for this property.")
        owner = None
        if prop.user_id is not None:
            owner = (
                self.session.execute(
                    text(
                        "SELECT u.user_id, u.full_name, u.email FROM users u WHERE u.user_id = :uid"
                    ),
                    {"uid": prop.user_id},
                )
                .mappings()
                .first()
            )
        documents = self.session.exec(
            select(VerificationDocument)
            .where(VerificationDocument.property_id == property_id)
            .order_by(VerificationDocument.uploaded_at)  # type: ignore[call-arg]
        ).all()
        history = self.session.exec(
            select(VerificationAudit)
            .where(VerificationAudit.property_id == property_id)
            .order_by(VerificationAudit.created_at)  # type: ignore[call-arg]
        ).all()
        return {
            "property": property_payload(prop, self.session),
            "owner": dict(owner) if owner else None,
            "verification": verification_payload(verification),
            "documents": [document_payload(d) for d in documents],
            "history": [audit_payload(a) for a in history],
        }

    # -- decisions ----------------------------------------------------------

    def start_review(self, property_id: int, dimension: str, admin_id: uuid.UUID) -> dict[str, Any]:
        return self._decide(
            property_id,
            dimension,
            admin_id,
            allowed_from=("pending",),
            new_status="under_review",
            action=f"{dimension}_review_started",
        )

    def approve(self, property_id: int, dimension: str, admin_id: uuid.UUID) -> dict[str, Any]:
        return self._decide(
            property_id,
            dimension,
            admin_id,
            allowed_from=DECISIONABLE,
            new_status="verified",
            action=f"{dimension}_approved",
        )

    def reject(
        self, property_id: int, dimension: str, admin_id: uuid.UUID, reason: str
    ) -> dict[str, Any]:
        if not (reason or "").strip():
            raise ConflictError("A rejection reason is required.")
        return self._decide(
            property_id,
            dimension,
            admin_id,
            allowed_from=DECISIONABLE,
            new_status="rejected",
            action=f"{dimension}_rejected",
            reason=reason.strip(),
        )

    def request_information(
        self, property_id: int, dimension: str, admin_id: uuid.UUID, note: str
    ) -> dict[str, Any]:
        if not (note or "").strip():
            raise ConflictError("Describe what information is required.")
        return self._decide(
            property_id,
            dimension,
            admin_id,
            allowed_from=DECISIONABLE,
            new_status="information_requested",
            action=f"{dimension}_information_requested",
            reason=note.strip(),
        )

    def _decide(
        self,
        property_id: int,
        dimension: str,
        admin_id: uuid.UUID,
        *,
        allowed_from: tuple[str, ...],
        new_status: str,
        action: str,
        reason: str | None = None,
    ) -> dict[str, Any]:
        if dimension not in ("listing", "ownership"):
            raise NotFoundError("Unknown verification dimension.")
        if new_status not in LISTING_STATUSES:
            raise ConflictError(f"Unknown verification status '{new_status}'.")
        prop = self.session.get(RentalProperty, property_id)
        if prop is None:
            raise NotFoundError("Property not found")
        # Row lock: two administrators deciding at the same moment serialize
        # here; the second one sees the first one's committed status.
        verification = self.session.exec(
            select(PropertyVerification)
            .where(PropertyVerification.property_id == property_id)
            .with_for_update()
        ).first()
        if verification is None:
            raise NotFoundError("No verification submission for this property.")
        current = (
            verification.listing_status if dimension == "listing" else verification.ownership_status
        )
        if current not in allowed_from:
            raise ConflictError(
                f"The {dimension} verification is '{current}'; this decision "
                "is not valid from that state."
            )
        if dimension == "listing":
            verification.listing_status = new_status
        else:
            verification.ownership_status = new_status
        verification.reviewed_by = admin_id
        if reason is not None:
            verification.latest_note = reason
        verification.updated_at = _now()
        verification.version += 1
        verification.publication_eligible = (
            verification.listing_status == "verified"
            and verification.ownership_status == "verified"
        )
        self.session.add(
            VerificationAudit(
                property_id=property_id,
                verification_id=verification.verification_id,
                verification_type=dimension,
                previous_status=current,
                new_status=new_status,
                action=action,
                admin_user_id=admin_id,
                reason=reason,
            )
        )
        # Single atomic commit: status, note, audit and eligibility land
        # together or not at all.
        self.session.commit()
        self.session.refresh(verification)
        return verification_payload(verification)

    # -- validation ---------------------------------------------------------

    def _validate_statuses(self, *statuses: str | None) -> None:
        for value in (s for s in statuses if s):
            if value not in LISTING_STATUSES:
                raise ConflictError(f"Unknown verification status '{value}'.")
