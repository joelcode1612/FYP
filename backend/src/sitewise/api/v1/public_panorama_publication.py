"""Publication bridge: approved public.pano_jobs → FYP property-detail viewers.

These routes do not create a second tour record or assume two unrelated
property ID sequences coincide. The public.pano_listing_links mapping is a
reviewed, admin-managed relation; entrepreneur reads require the FYP listing
itself to be approved AND published. All Storage URLs are short-lived.
"""
from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import get_db
from sitewise.dependencies import ActiveUser, AdminMfaUser
from sitewise.services import capture_session_service as svc
from sitewise.services import capture_storage
from sitewise.services.public_panorama_bridge import PublicPanoramaBridge, SIGN_TTL

router = APIRouter()
Db = Annotated[Session, Depends(get_db)]


class LinkCaptureProperty(BaseModel):
    listing_id: int = Field(gt=0)
    public_property_id: int = Field(gt=0)


def _listing_exists(db: Session, listing_id: int) -> bool:
    row = db.execute(text("SELECT id FROM fyp.rental_properties WHERE id=:id"),
                     {"id": listing_id}).first()
    return row is not None


def _published_listing_id(db: Session, property_ref: str) -> int | None:
    """Verified resolution of both operational IDs and MD-/EP- catalogue IDs.

    Ambiguity fails closed; never derive a link from address or matching names.
    """
    numeric = property_ref.isdecimal()
    if numeric:
        rows = db.execute(text("""
            SELECT id FROM fyp.rental_properties
            WHERE id=:pid AND is_published IS TRUE
              AND verification_status='approved' LIMIT 2
        """), {"pid": int(property_ref)}).all()
    else:
        rows = db.execute(text("""
            SELECT DISTINCT p.id FROM fyp.rental_properties AS p
            LEFT JOIN fyp.property_subject_links AS s
              ON s.property_id=p.id AND s.match_verified IS TRUE
            WHERE (p.listing_id=:ref OR p.catalogue_id=:ref
                   OR s.sitewise_property_id=:ref)
              AND p.is_published IS TRUE
              AND p.verification_status='approved'
            LIMIT 2
        """), {"ref": property_ref}).all()
    if len(rows) > 1:
        raise HTTPException(409, "Property reference resolves to multiple listings.")
    return int(rows[0][0]) if rows else None


@router.post("/links", status_code=201)
def link_property(body: LinkCaptureProperty, db: Db, admin: AdminMfaUser):
    """Admin-only explicit association; prevents cross-schema ID collisions."""
    if not _listing_exists(db, body.listing_id):
        raise HTTPException(404, "FYP listing does not exist.")
    with PublicPanoramaBridge() as bridge:
        return bridge.create_link(listing_id=body.listing_id,
                                  public_property_id=body.public_property_id,
                                  admin_id=str(admin.user_id))


@router.post("/jobs/{job_id}/publish")
def publish_job(job_id: str, db: Db, admin: AdminMfaUser):
    """Only completed, approved, fully uploaded jobs can be published."""
    with PublicPanoramaBridge() as bridge:
        job = bridge.job(job_id)
        if job is None:
            raise HTTPException(404, "Panorama job does not exist.")
        public_property_id = int(job["property_id"])
        link = bridge.link_by_public_property(public_property_id)
        if not link or not _listing_exists(db, int(link["listing_id"])):
            raise HTTPException(409, "Link this capture property to an FYP listing first.")
        if job.get("status") != "done" or job.get("verification_status") != "approved":
            raise HTTPException(409, "The panorama must be completed and approved.")
        if bridge.uploaded_target_count(str(job["session_id"])) != 38:
            raise HTTPException(409, "All 38 uploaded frames must be present.")
        if not bridge.object_exists(str(job.get("panorama_path") or ""),
                                    public_property_id=public_property_id,
                                    session_id=str(job["session_id"])):
            raise HTTPException(409, "The stitched image is not present in Storage.")
        previous = bridge.published_job(public_property_id)
        if previous and previous["id"] != job_id:
            raise HTTPException(409, "Unpublish the previous tour for this property first.")
        # Stable application route, NOT an expiring Storage signed URL.
        route = f"/entrepreneur/property-detail?id={int(link['listing_id'])}"
        record = bridge.change_publication(job, publish=True, published_url=route)
        return {"jobId": job_id, "listingId": int(link["listing_id"]),
                "publishedTourId": record["published_tour_id"], "publishedUrl": route}


@router.post("/jobs/{job_id}/unpublish")
def unpublish_job(job_id: str, admin: AdminMfaUser):
    with PublicPanoramaBridge() as bridge:
        job = bridge.job(job_id)
        if job is None:
            raise HTTPException(404, "Panorama job does not exist.")
        record = bridge.change_publication(job, publish=False)
        return {"jobId": job_id, "publishedTourId": record.get("published_tour_id")}


@router.get("/properties/{property_ref}")
def published_property_panorama(property_ref: str, response: Response,
                                db: Db, _user: ActiveUser):
    """Same response for Jaspr and Flutter, using their existing sphere views.

    Resolution order — one authoritative record per property, never two
    disagreeing ones:

    1. The CANONICAL ``fyp.panoramas`` row written by the durable backend
       worker (approved + published). This is the record the capture
       pipeline itself produces.
    2. The legacy ``public.pano_jobs`` bridge, for panoramas captured by the
       pre-port client and linked by an administrator. A legacy record is
       used only when no canonical panorama is published for the listing.
    """
    response.headers["Cache-Control"] = "private, no-store"
    if not 1 <= len(property_ref) <= 100:
        raise HTTPException(422, "Invalid property reference.")
    listing_id = _published_listing_id(db, property_ref)
    if listing_id is None:
        raise HTTPException(404, "No available panorama for this property.")
    canonical = svc.published_property_panorama(db, listing_id)
    if canonical is not None:
        url = capture_storage.signed_view_url(canonical.storage_path)
        return {
            "propertyId": listing_id,
            "panoramaId": str(canonical.panorama_id),
            "jobId": None,
            "status": "ready", "available": True,
            "verificationStatus": "approved", "viewUrl": url,
            "expiresInSeconds": capture_storage.VIEW_URL_TTL_SECONDS,
            "publishedUrl": (
                f"/entrepreneur/property-detail?id={listing_id}"
            ),
        }
    with PublicPanoramaBridge() as bridge:
        link = bridge.link_by_listing(listing_id)
        if link is None:
            raise HTTPException(404, "No published panorama for this listing.")
        job = bridge.published_job(int(link["public_property_id"]))
        if job is None:
            raise HTTPException(404, "No published panorama for this listing.")
        url = bridge.sign(job)
        return {
            "propertyId": listing_id, "panoramaId": job.get("published_tour_id"),
            "jobId": job["id"], "status": "ready", "available": True,
            "verificationStatus": "approved", "viewUrl": url,
            "expiresInSeconds": SIGN_TTL, "publishedUrl": job.get("published_url"),
        }
