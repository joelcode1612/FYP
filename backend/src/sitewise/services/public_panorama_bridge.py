"""Server-only connector for an AR capture backend using public.pano_* tables.

FYP's own fyp.capture_* pipeline remains separate. An explicit public-property
→ FYP-listing link is mandatory; integer identity equality is NEVER assumed.
No service credential or permanent Storage URL reaches a caller.
"""
from __future__ import annotations

import re
from urllib.parse import quote

import httpx
from fastapi import HTTPException
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.db.session import engine

BUCKET = settings.sitewise_public_panorama_bucket
SESSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,149}$")
JOB_ID = re.compile(r"^pano_[A-Za-z0-9][A-Za-z0-9._-]{0,149}$")
SIGN_TTL = 600


def is_safe_panorama_path(path: str | None, *, property_id: int, session_id: str) -> bool:
    """Never sign a path that could point to another user's Storage object."""
    return (
        isinstance(path, str)
        and bool(SESSION.fullmatch(session_id))
        and path == f"properties/{property_id}/sessions/{session_id}/panorama.jpg"
    )


class PublicPanoramaBridge:
    def __init__(self, client: httpx.Client | None = None):
        if not settings.supabase_url or not settings.supabase_secret_key:
            raise HTTPException(status_code=503, detail="Panorama Storage is not configured.")
        self.base = settings.supabase_url.rstrip("/")
        self.key = settings.supabase_secret_key
        self.client = client or httpx.Client(timeout=15, follow_redirects=False)
        self.owned_client = client is None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.owned_client:
            self.client.close()

    def _request(self, method: str, path: str, *, params=None, json=None, storage=False, upsert=False):
        # New sb_secret_* keys are opaque API keys, NOT JWTs. Sending them
        # as Bearer fails with "Invalid JWT". Legacy service_role JWTs may
        # still be passed in both headers (Supabase migration guidance).
        headers = {"apikey": self.key}
        if not self.key.startswith("sb_secret_"):
            headers["Authorization"] = f"Bearer {self.key}"
        if not storage:
            headers["Content-Profile" if method in ("PATCH", "POST", "DELETE") else "Accept-Profile"] = "public"
        if method in ("PATCH", "POST") and not storage:
            headers["Prefer"] = ("resolution=merge-duplicates,return=representation"
                                 if upsert else "return=representation")
        try:
            response = self.client.request(method, f"{self.base}{path}",
                                           params=params, json=json, headers=headers)
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=503, detail="Panorama data source is unavailable.") from exc
        if response.status_code not in (200, 201, 204):
            # Do not expose Supabase error bodies: they may include database details.
            raise HTTPException(status_code=503, detail="Panorama data source rejected the request.")
        if response.status_code == 204 or not response.content:
            return None
        try:
            return response.json()
        except ValueError as exc:
            raise HTTPException(status_code=502, detail="Malformed panorama data response.") from exc

    def _one(self, table: str, *, params: dict):
        rows = self._request("GET", f"/rest/v1/{table}", params={**params, "limit": "2"})
        if not isinstance(rows, list):
            raise HTTPException(502, "Invalid panorama metadata.")
        if len(rows) > 1:
            raise HTTPException(409, "Ambiguous panorama mapping.")
        return rows[0] if rows else None

    def public_property_exists(self, property_id: int) -> bool:
        """The capture catalogue IS the canonical operational table.

        The standalone capture backend's ``public.property`` mirror was folded
        into ``fyp.rental_properties`` by schema migration 03 (verified: 916
        identical rows on both sides pre-migration; ``pano_jobs.property_id``
        now carries a FOREIGN KEY to ``fyp.rental_properties(id)``). The
        ``fyp`` schema is service-role-only and not exposed through PostgREST,
        so the existence check runs against the SAME canonical table through
        the application database connection instead of a REST lookup that
        would target a table that no longer exists.
        """
        with Session(engine) as session:
            return session.execute(
                text("SELECT 1 FROM fyp.rental_properties WHERE id = :pid"),
                {"pid": int(property_id)},
            ).scalar() is not None

    def link_by_listing(self, listing_id: int):
        return self._one("pano_listing_links", params={"select": "listing_id,public_property_id", "listing_id": f"eq.{listing_id}"})

    def link_by_public_property(self, property_id: int):
        return self._one("pano_listing_links", params={"select": "listing_id,public_property_id", "public_property_id": f"eq.{property_id}"})

    def create_link(self, *, listing_id: int, public_property_id: int, admin_id: str):
        existing_listing = self.link_by_listing(listing_id)
        existing_property = self.link_by_public_property(public_property_id)
        if existing_listing or existing_property:
            if (existing_listing and existing_property and
                    int(existing_listing["public_property_id"]) == public_property_id and
                    int(existing_property["listing_id"]) == listing_id):
                return existing_listing
            raise HTTPException(409, "A different property is already linked; resolve the mapping explicitly.")
        if not self.public_property_exists(public_property_id):
            raise HTTPException(404, "Public capture property does not exist.")
        rows = self._request("POST", "/rest/v1/pano_listing_links", json={
            "listing_id": listing_id, "public_property_id": public_property_id,
            "linked_by": admin_id,
        })
        if not isinstance(rows, list) or len(rows) != 1:
            raise HTTPException(409, "Unable to persist the property link.")
        return rows[0]

    def job(self, job_id: str):
        if not JOB_ID.fullmatch(job_id):
            raise HTTPException(422, "Invalid panorama job id.")
        return self._one("pano_jobs", params={"select": "*", "id": f"eq.{job_id}"})

    def published_job(self, public_property_id: int):
        rows = self._request("GET", "/rest/v1/pano_jobs", params={
            "select": "*", "property_id": f"eq.{public_property_id}",
            "status": "eq.done", "verification_status": "eq.approved",
            "published_tour_id": "not.is.null",
            "order": "completed_at.desc", "limit": "2",
        })
        if not isinstance(rows, list):
            raise HTTPException(502, "Invalid panorama metadata.")
        if len(rows) > 1:
            raise HTTPException(409, "Multiple tours are published for this property.")
        return rows[0] if rows else None

    def uploaded_target_count(self, session_id: str) -> int:
        if not SESSION.fullmatch(session_id):
            raise HTTPException(422, "Invalid capture session id.")
        rows = self._request("GET", "/rest/v1/pano_capture_frames", params={
            "select": "target_id", "session_id": f"eq.{session_id}",
            "upload_status": "eq.uploaded", "order": "target_id.asc",
        })
        ids = [r.get("target_id") for r in rows] if isinstance(rows, list) else []
        return 38 if ids == list(range(1, 39)) else len(set(ids))

    def object_exists(self, path: str, *, public_property_id: int, session_id: str):
        if not is_safe_panorama_path(path, property_id=public_property_id, session_id=session_id):
            raise HTTPException(409, "Stored panorama path does not belong to this capture session.")
        try:
            res = self.client.head(
                f"{self.base}/storage/v1/object/{BUCKET}/{quote(path, safe='/')}",
                headers={"apikey": self.key, **(
                    {} if self.key.startswith("sb_secret_")
                    else {"Authorization": f"Bearer {self.key}"}
                )},
                timeout=15,
            )
        except httpx.HTTPError as exc:
            raise HTTPException(503, "Panorama Storage is unavailable.") from exc
        return res.status_code == 200

    def sign(self, job: dict) -> str:
        path = job.get("panorama_path")
        property_id = int(job["property_id"])
        session_id = str(job["session_id"])
        if not is_safe_panorama_path(path, property_id=property_id, session_id=session_id):
            raise HTTPException(409, "Panorama job points to an invalid Storage object.")
        response = self._request(
            "POST", f"/storage/v1/object/sign/{BUCKET}/{quote(path, safe='/')}",
            json={"expiresIn": SIGN_TTL}, storage=True,
        )
        signed = response.get("signedURL") or response.get("signedUrl") if isinstance(response, dict) else None
        if not isinstance(signed, str) or not signed:
            raise HTTPException(502, "No signed panorama URL returned.")
        # Supabase returns /object/sign/... or /storage/v1/object/sign/...
        if signed.startswith("https://") or signed.startswith("http://"):
            if not signed.startswith(self.base + "/"):
                raise HTTPException(502, "Unexpected signed Storage host.")
            return signed
        if signed.startswith("/storage/v1/"):
            return self.base + signed
        return self.base + "/storage/v1" + (signed if signed.startswith("/") else "/" + signed)

    def change_publication(self, job: dict, *, publish: bool, published_url: str | None = None):
        jid = str(job["id"])
        if publish:
            if job.get("status") != "done" or job.get("verification_status") != "approved":
                raise HTTPException(409, "The job must be stitched and administrator-approved.")
            if job.get("published_tour_id"):
                return job
            import uuid
            new_id = str(uuid.uuid4())
            body = {"published_tour_id": new_id, "published_url": published_url}
            params = {"id": f"eq.{jid}", "status": "eq.done",
                      "verification_status": "eq.approved", "published_tour_id": "is.null"}
        else:
            body = {"published_tour_id": None, "published_url": None}
            params = {"id": f"eq.{jid}"}
        rows = self._request("PATCH", "/rest/v1/pano_jobs", params=params, json=body)
        if not isinstance(rows, list) or len(rows) != 1:
            raise HTTPException(409, "The panorama publication changed; refresh and retry.")
        return rows[0]
