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
    ValidationError,
)
from sitewise.db.models.property_verification import (
    LISTING_STATUSES,
    PropertyVerification,
    VerificationAudit,
    VerificationDocument,
    can_resubmit,
)
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services import verification_storage as storage
from sitewise.services.address_validation_service import validate_address

DECISIONABLE = ("pending", "under_review")
RESUBMITTABLE = ("not_submitted", "rejected", "information_requested")

#: The canonical owner-created listings table. The verification tables were
#: REBOUND to it (migration 0004): owner Add-Property submissions live in
#: ``fyp.rental_properties`` and ``property_verification.property_id`` now
#: references ``fyp.rental_properties(id)``. The legacy ``public.property``
#: table is NOT part of this workflow.
_LISTING_TABLE = "fyp.rental_properties"

#: Fields that MUST be complete before a listing may leave the draft state.
#: Google address validation may assist here, but never substitutes for the
#: ownership-evidence requirement enforced separately below.
REQUIRED_FOR_SUBMISSION = (
    "name",
    "property_type",
    "address",
    "city",
    "state",
    "postcode",
    "latitude",
    "longitude",
    "rental_price",
    "size_sqft",
    "availability",
)


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


def rental_listing(session: Session, property_id: int) -> dict[str, Any] | None:
    """One ``fyp.rental_properties`` row (any verification status)."""
    row = session.execute(
        text(
            "SELECT id, owner_user_id, name, property_type, description, "
            "address, city, state, postcode, latitude, longitude, rental_price, "
            "size_sqft, psf, availability, floor_level, frontage_ft, "
            "has_parking, is_fnb_suitable, verification_status, "
            "rejection_reason, is_published, address_validation_status, "
            "address_formatted, address_validated_at, created_at, updated_at "
            f"FROM {_LISTING_TABLE} WHERE id = :pid"
        ),
        {"pid": property_id},
    ).mappings().first()
    return dict(row) if row else None


def listing_payload(listing: dict[str, Any]) -> dict[str, Any]:
    """A rental listing in the verification payload vocabulary.

    Key names are the contract the shared_logic entities and the Admin web
    UI already parse (``title``/``price``/... ) — the aliases keep both
    consumers stable while the storage table is the rental listing.
    """
    price = listing.get("rental_price")
    size = listing.get("size_sqft")
    frontage = listing.get("frontage_ft")
    return {
        "property_id": listing["id"],
        "title": listing.get("name") or "",
        "description": listing.get("description"),
        "property_type": listing.get("property_type"),
        "monthly_rent": None if price is None else float(price),
        "built_up_area_sqft": None if size is None else float(size),
        "land_area_sqft": None,
        "address": listing.get("address"),
        "city": listing.get("city"),
        "state": listing.get("state"),
        "postcode": listing.get("postcode"),
        "latitude": None
        if listing.get("latitude") is None
        else float(listing["latitude"]),
        "longitude": None
        if listing.get("longitude") is None
        else float(listing["longitude"]),
        "availability": listing.get("availability"),
        "floor_level": listing.get("floor_level"),
        "frontage_ft": None if frontage is None else float(frontage),
        "has_parking": bool(listing.get("has_parking")),
        "is_fnb_suitable": bool(listing.get("is_fnb_suitable")),
        "is_published": bool(listing.get("is_published")),
        "address_formatted": listing.get("address_formatted"),
        "address_validation_status": listing.get("address_validation_status"),
        "status": listing.get("verification_status"),
        "company_name": None,
        "user_id": None
        if listing.get("owner_user_id") is None
        else str(listing["owner_user_id"]),
    }


def listing_completeness_errors(listing: dict[str, Any]) -> list[str]:
    """Human-readable list of missing required fields for final submission."""
    errors: list[str] = []
    for field in REQUIRED_FOR_SUBMISSION:
        value = listing.get(field)
        if value is None or (isinstance(value, str) and not value.strip()):
            errors.append(field.replace("_", " "))
    if listing.get("latitude") is not None:
        lat = float(listing["latitude"])
        if not -90 <= lat <= 90:
            errors.append("valid latitude")
    if listing.get("longitude") is not None:
        lon = float(listing["longitude"])
        if not -180 <= lon <= 180:
            errors.append("valid longitude")
    price = listing.get("rental_price")
    if price is not None and float(price) <= 0:
        errors.append("a rental price greater than zero")
    size = listing.get("size_sqft")
    if size is not None and float(size) <= 0:
        errors.append("a built-up area greater than zero")
    return errors


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


def _jsonable(value: Any) -> Any:
    """Normalise one raw row value for a JSON payload.

    ``SELECT *`` projections (``fyp.property_geospatial_features``,
    ``fyp.property_features``) mix numerics, datetimes and decimals; the
    Admin web UI parses this payload defensively, so values are coerced —
    never dropped — and unknown types degrade to strings instead of 500s.
    """
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, datetime):
        return _iso(value)
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    decimal = getattr(value, "as_isoformat", None)
    if callable(decimal):  # datetime.date and decimal-free ISO types
        return str(value)
    try:
        return float(value)  # Decimal and numeric[*,*] columns
    except (TypeError, ValueError):
        return str(value)


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
    ) -> dict[str, Any]:
        """The owner's rental listing, ownership checked against the verified
        Supabase identity (``fyp.rental_properties.owner_user_id``)."""
        listing = rental_listing(self.session, property_id)
        if listing is None:
            raise NotFoundError("Property not found")
        owner = listing.get("owner_user_id")
        if not is_admin and (owner is None or str(owner) != str(user_id)):
            raise ForbiddenError("You can only manage your own property listings.")
        return listing

    def status_for_property(
        self, property_id: int, user_id: uuid.UUID, is_admin: bool = False
    ) -> dict[str, Any]:
        listing = self.get_property_owned(property_id, user_id, is_admin)
        verification = verification_row(self.session, property_id)
        documents = self._document_rows(property_id) if verification else []
        corrections = self._requested_corrections(property_id, verification) if verification else {}
        return {
            "property": listing_payload(listing),
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
        listing = rental_listing(self.session, doc.property_id)
        owner = listing.get("owner_user_id") if listing else None
        owned = owner is not None and str(owner) == str(user_id)
        if not owned:
            verification = self.session.get(PropertyVerification, doc.verification_id)
            submitted = verification is not None and verification.submitted_by == user_id
            if not submitted:
                raise ForbiddenError("This document belongs to another submission.")
        return doc

    # -- mutations ----------------------------------------------------------

    def _ensure_address_validated(self, listing: dict[str, Any]) -> None:
        """Require a provider-confirmed premise address before the queue.

        The verdict is obtained HERE (never read from the request) and written
        to the listing in the same transaction as the lifecycle transition, so
        the admin review can see that the address was actually checked. A
        partial or unconfirmed verdict blocks submission instead of silently
        degrading to "address supplied by the owner".
        """
        if listing.get("address_validation_status") == "validated":
            return
        verdict = validate_address(
            address_lines=[listing["address"]],
            region_code="MY",
            locality=listing.get("city"),
            postal_code=listing.get("postcode"),
            administrative_area=listing.get("state"),
        )
        status = verdict.get("status")
        if status != "validated":
            raise ValidationError(
                "We found the general location, but cannot confirm the exact "
                "property address. Please check the building, unit number or "
                "postcode."
                if status == "partially_validated"
                else "We couldn't verify this address. Please check your "
                "address details and try again."
            )
        FypPropertyRepository(self.session).set_address_validation(
            int(listing["id"]),
            status="validated",
            formatted_address=verdict.get("formatted_address"),
            latitude=verdict.get("latitude"),
            longitude=verdict.get("longitude"),
        )

    def submit(
        self, property_id: int, submitter_id: uuid.UUID, scope: str = "full"
    ) -> dict[str, Any]:
        """Submit (or resubmit) the property for review.

        ``scope`` selects how much is being submitted:

        * ``full`` (default) — the historical behaviour: at least one active
          ownership document is REQUIRED and both dimensions move to
          ``pending`` together.
        * ``listing`` — the listing-information-only workflow: a complete,
          address-validated listing enters the review queue with
          ``listing_status = pending`` while ``ownership_status`` stays
          exactly where it is (``not_submitted`` for a first submission).
          Ownership evidence is NOT required, ownership is never verified by
          this path, and publication eligibility stays ``false`` — approving
          the listing later never publishes the property.

        Completeness and server-side address validation apply to BOTH scopes:
        an incomplete or unconfirmed listing cannot enter the queue either way.
        """
        if scope not in ("full", "listing"):
            raise ConflictError("scope must be 'full' or 'listing'.")
        listing = self.get_property_owned(property_id, submitter_id)

        # An incomplete draft can be SAVED but never SUBMITTED: every field
        # the admin review needs must exist before the queue is entered.
        missing = listing_completeness_errors(listing)
        if missing:
            raise ConflictError(
                "Complete these fields before submitting for verification: "
                + ", ".join(missing)
                + ". Save the draft and try again once the listing is complete."
            )

        # Address validation is a SEPARATE dimension from ownership evidence:
        # it proves the premises exists, never that the submitter owns it.
        self._ensure_address_validated(listing)

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
            if scope == "listing":
                # Only the listing dimension must be open for (re)submission;
                # the ownership dimension is untouched, so its state is not
                # part of this gate.
                if verification.listing_status not in RESUBMITTABLE:
                    raise ConflictError(
                        "This listing is already awaiting or has passed "
                        "review; wait for the administrator's decision."
                    )
            elif not can_resubmit(verification.listing_status, verification.ownership_status):
                raise ConflictError(
                    "This property is already awaiting or has passed review; "
                    "wait for the administrator's decision."
                )
            previous = {
                "listing_status": verification.listing_status,
                "ownership_status": verification.ownership_status,
            }
        if scope == "full":
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
        # The listing-only scope NEVER advances ownership: without evidence
        # the dimension must remain not_submitted (or whatever accurate state
        # it already holds) — an approval of listing facts is not proof of
        # ownership and never moves this status.
        if scope == "full" and verification.ownership_status in RESUBMITTABLE:
            verification.ownership_status = "pending"
        verification.submitted_by = submitter_id
        verification.latest_note = None
        verification.publication_eligible = False
        verification.updated_at = _now()
        verification.version += 1
        # The listing row and the verification record move in the SAME
        # transaction: a submission never half-lands.
        FypPropertyRepository(self.session).set_listing_verification_status(
            property_id, "pending"
        )
        self.session.add(
            VerificationAudit(
                property_id=property_id,
                verification_id=verification.verification_id,
                verification_type=None if scope == "full" else "listing",
                previous_status=previous["listing_status"],
                new_status=verification.listing_status,
                action="submitted" if scope == "full" else "listing_submitted",
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
            "title": "p.name",
            "monthly_rent": "p.rental_price",
        }.get(sort, "pv.created_at")

        where = ["pv.verification_id IS NOT NULL"]
        params: dict[str, Any] = {}
        if q:
            where.append("(p.name ILIKE :q OR p.address ILIKE :q)")
            params["q"] = f"%{q}%"
        if listing_status:
            where.append("pv.listing_status = :listing_status")
            params["listing_status"] = listing_status
        if ownership_status:
            where.append("pv.ownership_status = :ownership_status")
            params["ownership_status"] = ownership_status
        if property_type:
            where.append("p.property_type = :property_type")
            params["property_type"] = property_type
        if state:
            where.append("p.state = :state")
            params["state"] = state
        if city:
            where.append("p.city = :city")
            params["city"] = city
        if submitted_from:
            where.append("pv.created_at >= :submitted_from")
            params["submitted_from"] = submitted_from
        if submitted_to:
            where.append("pv.created_at < :submitted_to")
            params["submitted_to"] = submitted_to
        where_sql = " AND ".join(where)
        # The queue reads the canonical owner-created listing table. The
        # aliases preserve the exact payload contract the Admin web UI and
        # shared_logic entities parse.
        base_from = (
            f" FROM property_verification pv"
            f" JOIN {_LISTING_TABLE} p ON p.id = pv.property_id"
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
                    "p.name AS title, p.address AS normalized_address, "
                    "p.property_type AS property_type_normalized, "
                    "p.rental_price AS price, "
                    "COALESCE(p.built_up_sqft, p.size_sqft) AS built_up_area_sqft, "
                    "p.verification_status AS property_status, "
                    "CAST(NULL AS text) AS company_name, p.city, p.state "
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
        listing = rental_listing(self.session, property_id)
        if verification is None or listing is None:
            raise NotFoundError("No verification submission for this property.")
        owner = None
        owner_id = listing.get("owner_user_id")
        if owner_id is not None:
            owner = (
                self.session.execute(
                    text(
                        "SELECT u.user_id, u.full_name, u.email FROM users u "
                        "WHERE u.user_id = :uid"
                    ),
                    {"uid": owner_id},
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
            "property": listing_payload(listing),
            "owner": dict(owner) if owner else None,
            "verification": verification_payload(verification),
            "documents": [document_payload(d) for d in documents],
            "history": [audit_payload(a) for a in history],
            **self._location_context(property_id),
        }

    def _location_context(self, property_id: int) -> dict[str, Any]:
        """Photos, amenities and geospatial intelligence for the Admin detail.

        Every block is OPTIONAL and reads through the repository's existing
        methods — nothing is computed on the fly, no ML model runs, and a
        missing row reaches the UI as an explicit null so it can render
        "Not calculated for this property" instead of a fabricated number.
        """
        repo = FypPropertyRepository(self.session)
        photos = repo.get_photos(property_id)
        amenities = repo.get_amenities(property_id)
        geo = repo.get_geo_features(property_id)
        demand = repo.list_demand_generators(property_id, radius_m=1000, limit=12)
        population = repo.get_population(property_id)
        # Feature freshness + source provenance (additive). The values are
        # READ from the refresh-state tables; this method never triggers a
        # calculation. An unknown state is explicit, never a zero.
        from sitewise.ingestion.state import RefreshState

        refresh_state = RefreshState(self.session)
        return {
            "photos": [_jsonable(photo) for photo in photos],
            "amenities": None if amenities is None else _jsonable(amenities),
            "geo_features": None if geo is None else _jsonable(geo),
            "demand_generators": [
                _jsonable(row) for row in demand.get("data", [])
            ],
            "population": None if population is None else _jsonable(population),
            "freshness": refresh_state.freshness_payload(property_id),
            "provenance": refresh_state.provenance_summary(),
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
        # Ownership is only ever verified on the strength of evidence that is
        # actually on file. An administrator may reject or request
        # information freely, but "verified" with an empty evidence folder
        # would fabricate an authorization claim the record cannot support.
        if dimension == "ownership" and new_status == "verified":
            evidence = self.session.exec(
                select(VerificationDocument).where(
                    VerificationDocument.property_id == property_id,
                    VerificationDocument.verification_type == "ownership",
                    VerificationDocument.status == "active",
                )
            ).first()
            if evidence is None:
                raise ConflictError(
                    "Ownership cannot be verified without at least one "
                    "active ownership or authorisation document on file."
                )
        listing = rental_listing(self.session, property_id)
        if listing is None:
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
        # Mirror the aggregate state onto the canonical listing row INSIDE
        # the same transaction. Publication stays a separate administrative
        # action — approval never publishes by itself.
        if verification.ownership_status == "rejected" or (
            verification.listing_status == "rejected"
        ):
            mirrored = "rejected"
        elif verification.publication_eligible:
            mirrored = "approved"
        else:
            mirrored = "pending"
        FypPropertyRepository(self.session).set_listing_verification_status(
            property_id,
            mirrored,
            reason if mirrored == "rejected" else None,
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
