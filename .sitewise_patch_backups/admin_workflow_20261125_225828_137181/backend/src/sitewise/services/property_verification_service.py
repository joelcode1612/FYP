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

import json
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import text
from sqlmodel import Session, select

from sitewise.core.exceptions import (
    ConflictError,
    AuthUnavailableError,
    ForbiddenError,
    NotFoundError,
    ModelUnavailableError,
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
from sitewise.services import provider_scope
from sitewise.services import verification_storage as storage
from sitewise.services.agent_inspection_policy import REQUIRED_INSPECTION

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
    "rental_price",
    "size_sqft",
    "availability",
)

REQUIRED_COMMERCIAL_TERMS = (
    "floor_description",
    "furnishing",
    # landlord_fnb_permission is no longer a user input: the server defaults
    # it to 'Yes' on create, so requiring it here would block legacy drafts
    # whose stored value is legitimately NULL.
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
            "size_sqft, psf, availability, floor_level, floor_description, "
            "frontage_ft, furnishing, tenure, unit_position, "
            "CASE WHEN parking_owner_declared IS TRUE THEN has_parking "
            "WHEN parking_owner_declared IS FALSE THEN NULL "
            "WHEN has_parking = 1 THEN 1 ELSE NULL END AS has_parking, "
            "lease_duration_months, lease_duration_negotiable, available_from, "
            "rental_deposit_myr, title_type, landlord_fnb_permission, "
            "is_fnb_suitable, verification_status, "
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
        "floor_description": listing.get("floor_description"),
        "frontage_ft": None if frontage is None else float(frontage),
        "furnishing": listing.get("furnishing"),
        "tenure": listing.get("tenure"),
        "unit_position": listing.get("unit_position"),
        "has_parking": (
            None if listing.get("has_parking") is None
            else bool(listing.get("has_parking"))
        ),
        "lease_duration_months": listing.get("lease_duration_months"),
        "lease_duration_negotiable": listing.get("lease_duration_negotiable"),
        "available_from": (
            listing.get("available_from").isoformat()
            if listing.get("available_from") is not None
            else None
        ),
        "rental_deposit_myr": (
            None if listing.get("rental_deposit_myr") is None
            else float(listing["rental_deposit_myr"])
        ),
        "title_type": listing.get("title_type"),
        "landlord_fnb_permission": listing.get("landlord_fnb_permission"),
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


def listing_completeness_errors(
    listing: dict[str, Any], *, require_availability: bool = True,
    require_commercial_terms: bool = False,
) -> list[str]:
    """Human-readable list of missing required fields for final submission."""
    errors: list[str] = []
    for field in REQUIRED_FOR_SUBMISSION:
        if field == "availability" and not require_availability:
            continue
        value = listing.get(field)
        if value is None or (isinstance(value, str) and not value.strip()):
            errors.append(field.replace("_", " "))
    if require_commercial_terms:
        for field in REQUIRED_COMMERCIAL_TERMS:
            value = listing.get(field)
            if value is None or (isinstance(value, str) and not value.strip()):
                errors.append(field.replace("_", " "))
        months = listing.get("lease_duration_months")
        negotiable = listing.get("lease_duration_negotiable")
        if months is None and negotiable is not True:
            errors.append("minimum rental period")
        if listing.get("availability") == "Available from a specific date" and not listing.get("available_from"):
            errors.append("available-from date")
        floor_description = listing.get("floor_description")
        floor_level = listing.get("floor_level")
        expected_floor = {
            "Basement": -1,
            "Ground floor": 0,
            "First floor": 1,
            "Second floor": 2,
        }.get(floor_description)
        if expected_floor is not None and floor_level is not None:
            if float(floor_level) != expected_floor:
                errors.append("floor level consistent with floor description")
        elif floor_description == "Third floor or above":
            if floor_level is None or float(floor_level) < 3:
                errors.append("specific floor number (3 or above)")
        elif floor_description != "Multiple floors" and floor_level is None:
            errors.append("numeric floor level")
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
        "reason": None if a.action == "property_approved" else a.reason,
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
        self,
        property_id: int,
        user_id: uuid.UUID,
        is_admin: bool = False,
        role: str | None = None,
    ) -> dict[str, Any]:
        """The submitter's rental listing, access checked against the verified
        Supabase identity (``fyp.rental_properties.owner_user_id``) or the
        ``fyp.agent_listing_assignment`` row.

        Agent-created listings carry ``owner_user_id = NULL`` — the creating
        agent is recorded ONLY through the assignment row. Restricting this
        lookup to literal ownership locked those listings out of the entire
        verification workflow (the agent could not submit, document or track
        its own proposal), so the assigned agent holds the same submitter
        rights here. An agent with no assignment manages nothing.
        """
        listing = rental_listing(self.session, property_id)
        if listing is None:
            raise NotFoundError("Property not found")
        if is_admin:
            return listing
        owner = listing.get("owner_user_id")
        if owner is not None and str(owner) == str(user_id):
            return listing
        if provider_scope.is_agent_role(role):
            agent_id = provider_scope.agent_id_for_user(user_id)
            if agent_id is not None and provider_scope.agent_is_assigned(
                self.session, listing_id=property_id, agent_id=agent_id
            ):
                return listing
        raise ForbiddenError("You can only manage your own property listings.")

    def status_for_property(
        self,
        property_id: int,
        user_id: uuid.UUID,
        is_admin: bool = False,
        role: str | None = None,
    ) -> dict[str, Any]:
        listing = self.get_property_owned(property_id, user_id, is_admin, role)
        verification = verification_row(self.session, property_id)
        documents = self._document_rows(property_id) if verification else []
        if not is_admin and str(listing.get("owner_user_id")) != str(user_id):
            documents = [doc for doc in documents if doc["verification_type"] == "listing"]
        corrections = self._requested_corrections(property_id, verification) if verification else {}
        return {
            "property": listing_payload(listing),
            "verification": None if verification is None else verification_payload(verification),
            "documents": documents,
            "requested_corrections": corrections,
        }

    def document_for_download(
        self, document_id: uuid.UUID, user_id: uuid.UUID, is_admin: bool,
        *, agent_role: str | None = None,
    ) -> VerificationDocument:
        doc = self.session.get(VerificationDocument, document_id)
        if doc is None:
            raise NotFoundError("Document not found")
        if is_admin:
            return doc
        listing = rental_listing(self.session, doc.property_id)
        owner = listing.get("owner_user_id") if listing else None
        owned = owner is not None and str(owner) == str(user_id)
        if owned:
            return doc
        # Inspection files may be read by the current MFA-verified assignee.
        # Ownership proof is restricted to the Owner and Admin reviewers.
        if doc.verification_type == "listing" and provider_scope.is_agent_role(agent_role):
            self.get_property_owned(doc.property_id, user_id, role=agent_role)
            return doc
        raise ForbiddenError("You do not have access to this verification document.")

    # -- mutations ----------------------------------------------------------

    def submit(
        self,
        property_id: int,
        submitter_id: uuid.UUID,
        scope: str = "full",
        role: str | None = None,
        panorama_id: str | None = None,
    ) -> dict[str, Any]:
        """Submit one dimension or the legacy combined review."""
        if scope not in ("full", "listing", "ownership"):
            raise ConflictError("Unknown verification submission scope.")
        listing_scope = scope in ("full", "listing")
        ownership_scope = scope in ("full", "ownership")
        listing = self.get_property_owned(property_id, submitter_id, role=role)

        # An incomplete draft can be SAVED but never SUBMITTED: every field
        # the admin review needs must exist before the queue is entered.
        # Agent inspections concern physical evidence; rental availability
        # can remain unreported on the listing sent to Admin for review.
        missing = listing_completeness_errors(
            listing, require_availability=not provider_scope.is_agent_role(role),
            require_commercial_terms=listing_scope,
        )
        if listing_scope and missing:
            raise ConflictError(
                "Complete these fields before submitting for verification: "
                + ", ".join(missing)
                + ". Save the draft and try again once the listing is complete."
            )

        # Address validation was removed from the owner flow: the listing
        # enters the queue with the address as entered, and location truth is
        # established by geospatial enrichment plus admin review.

        self.session.execute(text(
            "SELECT pg_advisory_xact_lock(hashtextextended('property-verification:' || CAST(:pid AS text), 0))"
        ), {"pid": property_id})
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
            elif scope == "ownership":
                if verification.ownership_status not in RESUBMITTABLE:
                    raise ConflictError("Ownership verification is already awaiting or has passed review.")
            elif not can_resubmit(verification.listing_status, verification.ownership_status):
                raise ConflictError(
                    "This property is already awaiting or has passed review; "
                    "wait for the administrator's decision."
                )
            previous = {
                "listing_status": verification.listing_status,
                "ownership_status": verification.ownership_status,
            }
        if ownership_scope:
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
            # SITEWISE_PROOF_FILE_AVAILABLE_V1: document metadata is not
            # evidence if the private file disappeared or moved to another host.
            readable_proof = False
            for proof in ownership_docs:
                try:
                    storage.open_document(proof.storage_key)
                    readable_proof = True
                    break
                except Exception:
                    continue
            if not readable_proof:
                raise ConflictError(
                    "Ownership proof is recorded but its private file cannot "
                    "be opened on this server. Ask the Owner to re-upload it."
                )
        if listing_scope and verification.listing_status in RESUBMITTABLE:
            verification.listing_status = "pending"
        # The listing-only scope NEVER advances ownership: without evidence
        # the dimension must remain not_submitted (or whatever accurate state
        # it already holds) — an approval of listing facts is not proof of
        # ownership and never moves this status.
        if ownership_scope and verification.ownership_status in RESUBMITTABLE:
            verification.ownership_status = "pending"
        verification.submitted_by = submitter_id
        verification.latest_note = None
        verification.publication_eligible = False
        verification.updated_at = _now()
        verification.version += 1
        # The listing row and the verification record move in the SAME
        # transaction: a submission never half-lands.
        if listing_scope:
            FypPropertyRepository(self.session).set_listing_verification_status(
                property_id, "pending"
            )
        self.session.add(
            VerificationAudit(
                property_id=property_id,
                verification_id=verification.verification_id,
                verification_type=None if scope == "full" else scope,
                previous_status=previous["ownership_status" if scope == "ownership" else "listing_status"],
                new_status=verification.ownership_status if scope == "ownership" else verification.listing_status,
                action="submitted" if scope == "full" else f"{scope}_submitted",
            )
        )
        # Agent assignment state changes in this SAME transaction as
        # the property verification submission. No partial handoff.
        #
        # The linked panorama is the verified CANONICAL row itself — the
        # same evidence `completed_agent_panorama` accepted one moment ago.
        # A `panorama_jobs` join here would NULL the link for every
        # device-stitched session (capture_plan_version 2 has no job row:
        # Flutter stitched on the phone and the confirmation endpoint wrote
        # the canonical row), so the job is no longer the proof. Legacy
        # sessions keep the same semantics: their panorama row only exists
        # after the worker completed the stitch.
        if listing_scope and provider_scope.is_agent_role(role):
            # SQLAlchemy's text() parses ':true' inside a JSON string literal
            # as a bind parameter, which made this UPDATE fail with
            # "A value is required for bind parameter 'true'". Bind the whole
            # required-check object instead; the database still enforces that
            # every on-site check was saved before the assignment can submit.
            required_checks = json.dumps({key: True for key in REQUIRED_INSPECTION})
            linked_panorama = self.session.execute(text("""
                UPDATE fyp.agent_listing_assignment a
                   SET workflow_status='submitted', submitted_at=now(), updated_at=now(),
                       panorama_id=(SELECT p.panorama_id
                              FROM fyp.panoramas p
                              JOIN fyp.capture_sessions c ON c.id = p.session_id
                             WHERE p.property_id = CAST(:pid AS text)
                               AND c.property_id = CAST(:pid AS text)
                               AND c.owner_id = :uid
                               AND c.status = 'completed'
                               AND p.verification_status IS DISTINCT FROM 'rejected'
                               AND p.storage_path IS NOT NULL AND btrim(p.storage_path) <> ''
                               AND (CAST(:panorama_id AS text) IS NULL OR CAST(p.panorama_id AS text) = :panorama_id)
                             ORDER BY p.created_at DESC LIMIT 1)
                 WHERE a.listing_id=:pid AND a.workflow_status IN ('accepted','needs_correction')
                   AND a.inspection_data @> CAST(:required_checks AS jsonb)
                RETURNING a.panorama_id
            """), {
                "pid": property_id,
                "uid": str(submitter_id),
                "panorama_id": panorama_id,
                "required_checks": required_checks,
            }).scalar()
            if linked_panorama is None:
                raise ConflictError("Agent assignment changed during submission.")
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
        role: str | None = None,
    ) -> VerificationDocument:
        self.get_property_owned(property_id, uploader_id, role=role)
        if verification_type not in ("listing", "ownership"):
            raise ConflictError("verification_type must be 'listing' or 'ownership'.")
        if not (document_type or "").strip():
            raise ConflictError("A document type is required.")
        ext = storage.validate_upload(original_filename, content_type, data)
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
            f" FROM fyp.property_verification pv"
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

        items = [dict(row) for row in rows]
        # Management responsibility is derived, not stored, so the reviewer sees
        # the same answer the public surfaces show — including the cases where
        # no valid manager exists.
        from sitewise.services.property_management_service import resolve_listings

        management = resolve_listings(
            self.session, [int(item["property_id"]) for item in items]
        )
        for item in items:
            item["management"] = management.get(int(item["property_id"]))

        return {
            "items": items,
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
                        "SELECT u.user_id, u.full_name, u.email "
                        "FROM public.users u "
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
            "management": self._management(property_id),
            **self._location_context(property_id),
            "location_analysis": self._location_analysis(property_id),
        }

    def _location_analysis(self, property_id: int) -> dict[str, Any]:
        """Verification-support location analysis (Parts A/B/C + recommendation).

        Read-only and failure-isolated: a problem assembling the analysis
        reaches the UI as an explicit ``available: false`` payload and never
        breaks the review detail. The analysis never changes verification
        state — decisions stay with the administrator.
        """
        try:
            from sitewise.services.location_analysis_service import (
                LocationAnalysisService,
            )

            return LocationAnalysisService(self.session).analyze(property_id)
        except Exception as exc:  # noqa: BLE001 — the review page must not fail on analysis
            return {
                "analysis_version": None,
                "generated_at": None,
                "available": False,
                "error": f"Location analysis could not be assembled: {exc}",
            }

    def _management(self, property_id: int) -> dict[str, Any]:
        """Derived management state, or an explicit lookup failure."""
        from sitewise.services.property_management_service import resolve_management

        try:
            return resolve_management(self.session, listing_id=property_id)
        except Exception:  # noqa: BLE001 - never guess a manager
            from sitewise.domain.management import unavailable

            return unavailable()

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

    def _final_evidence(self, property_id: int, *, lock: bool = False):
        # Property -> assignment -> verification -> panorama/session -> documents.
        suffix = " FOR UPDATE" if lock else ""
        present = self.session.execute(text(
            "SELECT id FROM fyp.rental_properties WHERE id=:id" + suffix
        ), {"id": property_id}).scalar()
        if present is None:
            raise NotFoundError("Property not found.")
        listing = rental_listing(self.session, property_id)
        assignment = self.session.execute(text("""
            SELECT agent_id, workflow_status, inspection_data, inspection_updated_at,
                   submitted_at, panorama_id
            FROM fyp.agent_listing_assignment WHERE listing_id=:id
        """ + suffix), {"id": property_id}).mappings().first()
        query = select(PropertyVerification).where(PropertyVerification.property_id == property_id)
        verification = self.session.exec(query.with_for_update() if lock else query).first()
        if verification is None:
            raise NotFoundError("No submitted verification for this property.")
        panorama = None
        if assignment and assignment["workflow_status"] == "submitted" and assignment["panorama_id"]:
            panorama = self.session.execute(text("""
                SELECT p.panorama_id, p.session_id, p.storage_path, p.width, p.height,
                       p.verification_status, p.coverage_report, cs.owner_id, cs.capture_plan_version
                FROM fyp.panoramas p JOIN fyp.capture_sessions cs ON cs.id=p.session_id
                WHERE p.panorama_id=:panorama AND p.property_id=CAST(:id AS text)
                  AND cs.property_id=p.property_id AND cs.status='completed'
                  AND p.created_at<=:submitted_at
                  AND (cs.capture_plan_version='2' OR EXISTS (
                    SELECT 1 FROM fyp.panorama_jobs j WHERE j.session_id=cs.id AND j.status='done'
                  ))
                  AND p.storage_path IS NOT NULL AND btrim(p.storage_path)<>''
            """ + (" FOR UPDATE OF p, cs" if lock else "")), {
                "id": property_id, "panorama": assignment["panorama_id"],
                "submitted_at": assignment["submitted_at"],
            }).mappings().first()
        query = select(VerificationDocument).where(
            VerificationDocument.property_id == property_id,
            VerificationDocument.verification_id == verification.verification_id,
            VerificationDocument.verification_type == "ownership",
            VerificationDocument.status == "active",
        ).order_by(VerificationDocument.document_id)
        docs = self.session.exec(query.with_for_update() if lock else query).all()
        return listing, assignment, verification, panorama, docs

    @staticmethod
    def _evidence_digest(evidence) -> str:
        import hashlib

        listing, assignment, _, panorama, docs = evidence
        facts = {key: value for key, value in listing.items() if key not in {
            "verification_status", "is_published", "rejection_reason", "updated_at",
        }}
        capture = dict(panorama) if panorama else {}
        capture.pop("verification_status", None)
        payload = [facts, dict(assignment) if assignment else None, capture,
                   [(d.document_id, d.storage_key, d.uploaded_at) for d in docs]]
        return hashlib.sha256(json.dumps(payload, default=str, sort_keys=True).encode()).hexdigest()

    def _final_blockers(self, evidence) -> list[str]:
        listing, assignment, verification, panorama, docs = evidence
        blockers = listing_completeness_errors(
            listing, require_availability=False, require_commercial_terms=True,
        )
        if any(status not in (*DECISIONABLE, "verified") for status in (
            verification.listing_status, verification.ownership_status,
        )):
            blockers.append("Both listing and ownership must be submitted.")
        if not docs:
            blockers.append("Submit ownership evidence.")
        if (not assignment or assignment["workflow_status"] != "submitted"
                or not assignment["submitted_at"] or not assignment["inspection_updated_at"]
                or any((assignment["inspection_data"] or {}).get(key) is not True
                       for key in REQUIRED_INSPECTION)):
            blockers.append("Submit a completed Agent inspection checklist.")
        if (not panorama or panorama["verification_status"] == "rejected"
                or not panorama["height"] or panorama["width"] != 2 * panorama["height"]
                or not 512 <= panorama["width"] <= 8192):
            blockers.append("Submit a completed 360-degree panorama.")
        return blockers

    def final_review_state(self, property_id: int, *, check_storage: bool = False) -> dict:
        evidence = self._final_evidence(property_id)
        listing, assignment, verification, panorama, _ = evidence
        digest = self._evidence_digest(evidence)
        blockers = self._final_blockers(evidence)
        if check_storage and not blockers:
            try:
                self._verify_final_files(evidence, decode_image=False)
            except ConflictError as exc:
                blockers.append(str(exc))
        approval = self._has_final_approval(verification.verification_id, digest)
        checklist = (assignment["inspection_data"] or {}) if assignment else {}
        return {
            "token": f"{verification.version}:{digest}",
            "panorama_id": str(panorama["panorama_id"]) if panorama else None,
            "inspection": {key: checklist.get(key) is True for key in REQUIRED_INSPECTION}
                          if assignment else {},
            "inspection_notes": {key: checklist[key] for key in
                                 ("condition_notes", "parking_notes", "accessibility_notes")
                                 if isinstance(checklist.get(key), str) and checklist[key].strip()},
            "blockers": blockers,
            "approved": approval and verification.publication_eligible
                        and verification.listing_status == verification.ownership_status == "verified"
                        and listing["verification_status"] == "approved"
                        and bool(panorama and panorama["verification_status"] == "approved"),
            "published": listing["is_published"],
        }

    def _has_final_approval(self, verification_id, digest: str) -> bool:
        latest = self.session.exec(select(VerificationAudit).where(
            VerificationAudit.verification_id == verification_id,
            VerificationAudit.action.in_(("property_approved", "property_rejected", "property_information_requested")),
        ).order_by(VerificationAudit.created_at.desc()).limit(1)).first()
        return bool(latest and latest.action == "property_approved" and latest.reason == digest)

    @staticmethod
    def verify_panorama_agent(agent_id: int, capture_owner_id) -> None:
        from sitewise.core.supabase_admin import SupabaseAdminService, SupabaseAdminError

        try:
            identity = SupabaseAdminService().get_agent_profile_by_id(int(agent_id))
        except (SupabaseAdminError, AuthUnavailableError) as exc:
            raise ConflictError("The assigned Agent identity could not be verified.") from exc
        if not identity or str(identity.get("user_id")) != str(capture_owner_id):
            raise ConflictError("The submitted panorama belongs to another Agent.")

    def _verify_final_files(self, evidence, *, decode_image: bool = True) -> None:
        from sitewise.services import capture_storage
        _, assignment, _, panorama, docs = evidence
        self.verify_panorama_agent(assignment["agent_id"], panorama["owner_id"])
        try:
            for document in docs:
                path, _ = storage.open_document(document.storage_key)
                with path.open("rb") as stream:
                    if not stream.read(1):
                        raise OSError("Empty evidence file")
        except (ModelUnavailableError, NotFoundError, OSError) as exc:
            raise ConflictError("An active ownership document cannot be opened.") from exc
        try:
            if not decode_image:
                if not capture_storage.object_exists(panorama["storage_path"]):
                    raise ConflictError("The submitted panorama image is missing.")
                return
            data = capture_storage.download(panorama["storage_path"])
        except (capture_storage.ObjectMissing, capture_storage.CaptureStorageUnavailable) as exc:
            raise ConflictError("The submitted panorama image cannot be opened.") from exc
        try:
            if capture_storage.decode_panorama(data) != (panorama["width"], panorama["height"]):
                raise ValidationError("Image dimensions changed.")
            report = panorama["coverage_report"] or {}
            coverage = report.get("photo_coverage") or {}
            checksum = report.get("submitted_image_sha256") or coverage.get("panorama_sha256")
            if checksum and not capture_storage.verify_checksum(data, checksum):
                raise ValidationError("The stored panorama differs from the submitted image.")
        except ValidationError as exc:
            raise ConflictError("The submitted panorama image is invalid.") from exc

    def final_decision(self, property_id: int, admin_id, *, action: str, token: str,
                       component: str | None = None, reason: str | None = None) -> dict:
        evidence = self._final_evidence(property_id, lock=True)
        listing, assignment, verification, panorama, _ = evidence
        digest = self._evidence_digest(evidence)
        if token != f"{verification.version}:{digest}":
            raise ConflictError("The evidence changed. Reload and review the current submission.")
        if action in ("approve", "publish"):
            blockers = self._final_blockers(evidence)
            if blockers:
                raise ConflictError(" ".join(blockers))
            self._verify_final_files(evidence)
        now = _now()
        audit = []

        def record(name, dimension=None, previous=None, status=None, note=None):
            audit.append(VerificationAudit(
                property_id=property_id, verification_id=verification.verification_id,
                action=name, verification_type=dimension, previous_status=previous,
                new_status=status, admin_user_id=admin_id, reason=note,
            ))

        if action == "approve":
            if self._has_final_approval(verification.verification_id, digest):
                raise ConflictError("This evidence has already been approved.")
            for dimension in ("listing", "ownership"):
                attr = f"{dimension}_status"
                record(f"{dimension}_approved", dimension, getattr(verification, attr), "verified")
                setattr(verification, attr, "verified")
            self.session.execute(text("""
                UPDATE fyp.panoramas SET verification_status='approved', reviewed_by=:admin,
                    reviewed_at=:now, updated_at=:now, review_reason=NULL
                WHERE panorama_id=:id
            """), {"admin": admin_id, "now": now, "id": panorama["panorama_id"]})
            record("panorama_approved", note=str(panorama["panorama_id"]))
            verification.publication_eligible = True
            FypPropertyRepository(self.session).set_listing_verification_status(property_id, "approved", None)
            # Hash the post-decision evidence, excluding workflow-only fields.
            record("property_approved", note=self._evidence_digest(self._final_evidence(property_id)))
        elif action in ("publish", "unpublish"):
            if action == "publish" and (
                not verification.publication_eligible or listing["verification_status"] != "approved"
                or verification.listing_status != "verified" or verification.ownership_status != "verified"
                or panorama["verification_status"] != "approved"
                or not self._has_final_approval(verification.verification_id, digest)
            ):
                raise ConflictError("Approve the submitted property evidence first.")
            if bool(listing["is_published"]) == (action == "publish"):
                raise ConflictError("The property already has the requested publication state.")
            self._set_final_publication(property_id, panorama if action == "publish" else None, now)
            record("property_published" if action == "publish" else "property_unpublished")
        else:
            dimension = "ownership" if component == "ownership" else "listing"
            attr = f"{dimension}_status"
            previous = getattr(verification, attr)
            if previous not in (*DECISIONABLE, "verified"):
                raise ConflictError("That evidence component is not awaiting a decision.")
            note = f"{component.replace('_', ' ').title()}: {reason.strip()}"
            status = "rejected" if action == "reject" else "information_requested"
            setattr(verification, attr, status)
            verification.latest_note = note
            verification.publication_eligible = False
            if dimension == "listing" and assignment and assignment["workflow_status"] == "submitted":
                self.session.execute(text("""
                    UPDATE fyp.agent_listing_assignment SET workflow_status='needs_correction', updated_at=:now
                    WHERE listing_id=:id
                """), {"id": property_id, "now": now})
            if component == "panorama" and panorama:
                self.session.execute(text("""
                    UPDATE fyp.panoramas SET verification_status='rejected', reviewed_by=:admin,
                        reviewed_at=:now, review_reason=:reason, updated_at=:now
                    WHERE panorama_id=:id
                """), {"id": panorama["panorama_id"], "admin": admin_id, "now": now, "reason": note})
            self._set_final_publication(property_id, None, now)
            aggregate = "rejected" if "rejected" in (verification.listing_status, verification.ownership_status) else "draft"
            FypPropertyRepository(self.session).set_listing_verification_status(
                property_id, aggregate, note if aggregate == "rejected" else None,
            )
            record(f"{dimension}_{status}", dimension, previous, status, note)
            record("property_rejected" if action == "reject" else "property_information_requested", note=note)
        verification.reviewed_by = admin_id
        verification.updated_at = now
        verification.version += 1
        self.session.add_all(audit)
        self.session.flush()
        result = self.final_review_state(property_id)
        self.session.commit()
        return result

    def _set_final_publication(self, property_id: int, panorama, now) -> None:
        # Both rows are changed in the caller's property-locked transaction.
        self.session.execute(text("""
            UPDATE fyp.panoramas SET published_at=NULL, updated_at=:now
            WHERE property_id=CAST(:id AS text) AND published_at IS NOT NULL
        """), {"id": property_id, "now": now})
        if panorama:
            self.session.execute(text("""
                UPDATE fyp.panoramas SET published_at=:now, updated_at=:now WHERE panorama_id=:id
            """), {"id": panorama["panorama_id"], "now": now})
        self.session.execute(text("""
            UPDATE fyp.rental_properties SET is_published=:visible, published_at=:published, updated_at=:now
            WHERE id=:id
        """), {"id": property_id, "visible": panorama is not None,
                "published": now if panorama else None, "now": now})

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
        elif verification.listing_status == "not_submitted":
            mirrored = "draft"
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
