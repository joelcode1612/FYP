"""Independent Agent verification policy for the SiteWise operational property.

Do not authorize by client-supplied agent ID or property ID alone: the signed
user is resolved against their active Supabase Agent profile and the existing
fyp.agent_listing_assignment row. Owner/admin/entrepreneur writes fail.

Panorama evidence is the canonical server-side fyp.panoramas row created by
its completed capture/processing job. The old fyp.virtual_tour metadata is
not accepted as proof for NEW Admin submissions.
"""
from __future__ import annotations
from fastapi import HTTPException
from sqlalchemy import text
from sqlmodel import Session
from sitewise.domain import rbac
from sitewise.services import provider_scope

REQUIRED_INSPECTION = (
    "floor_area_verified", "condition_verified", "parking_verified",
    "accessibility_verified",
)


def agent_assignment(session: Session, property_id: int, user, *, writable: bool = False) -> dict:
    if rbac.canonical_role(user.role) != rbac.ROLE_AGENT:
        raise HTTPException(status_code=403, detail="Only the assigned Property Agent may inspect or capture a 360° tour.")
    aid = provider_scope.agent_id_for_user(user.user_id)
    if aid is None:
        raise HTTPException(status_code=403, detail="A verified Agent profile is required.")
    row = session.execute(text("""
        SELECT a.listing_id, a.agent_id, a.workflow_status, a.inspection_data,
               a.inspection_updated_at, a.panorama_id, a.submitted_at,
               p.verification_status, p.is_published
          FROM fyp.agent_listing_assignment a
          JOIN fyp.rental_properties p ON p.id = a.listing_id
         WHERE a.listing_id = :pid AND a.agent_id = :aid
    """), {"pid": int(property_id), "aid": int(aid)}).mappings().first()
    if row is None:
        # Do not disclose whether another Agent has the assignment.
        raise HTTPException(status_code=404, detail="Assigned property not found.")
    result = dict(row)
    if writable:
        if result["workflow_status"] not in ("accepted", "needs_correction"):
            raise HTTPException(status_code=409, detail="Accept the Agent request before inspecting or capturing.")
        if result["is_published"] or result["verification_status"] in ("approved", "pending", "under_review"):
            raise HTTPException(status_code=409, detail="Property is locked for Admin review or publication.")
    return result


def completed_agent_panorama(session: Session, property_id: int, user) -> str | None:
    """Only a genuinely completed pipeline panorama produced by this Agent.

    A client cannot claim its file or flip a 'ready' flag; the backend stitch
    worker creates fyp.panoramas and marks the associated job 'done'.
    """
    record = session.execute(text("""
        SELECT p.panorama_id
          FROM fyp.panoramas p
          JOIN fyp.capture_sessions cs ON cs.id = p.session_id
          JOIN fyp.panorama_jobs j ON j.session_id = cs.id
          JOIN fyp.agent_listing_assignment a ON a.listing_id = :pid
         WHERE p.property_id = CAST(:pid AS text)
           AND cs.property_id = CAST(:pid AS text)
           AND cs.owner_id = :uid
           AND cs.status = 'completed' AND j.status = 'done'
           AND a.workflow_status IN ('accepted', 'needs_correction')
           AND a.inspection_updated_at IS NOT NULL
           AND p.created_at >= a.inspection_updated_at
           AND p.storage_path IS NOT NULL AND btrim(p.storage_path) <> ''
         ORDER BY p.created_at DESC LIMIT 1
    """), {"pid": int(property_id), "uid": str(user.user_id)}).scalar()
    return str(record) if record else None


def require_ready_for_admin(session: Session, property_id: int, user) -> dict:
    row = agent_assignment(session, property_id, user, writable=True)
    data = row["inspection_data"] or {}
    if not row.get("inspection_updated_at") or any(data.get(key) is not True for key in REQUIRED_INSPECTION):
        raise HTTPException(status_code=409, detail="Save the four on-site verification checks before submitting.")
    panorama_id = completed_agent_panorama(session, property_id, user)
    if not panorama_id:
        raise HTTPException(status_code=409, detail="Complete and upload a 360° tour through the Agent capture pipeline before submitting.")
    return {**row, "completed_panorama_id": panorama_id}


def require_owner_published_view(session: Session, property_id: int, user) -> None:
    """Before publication, only assigned Agent/Admin may review the panorama.

    The generic property-scope read check must also run at the endpoint; this
    helper tightens Owner visibility without widening access for any role.
    """
    if rbac.canonical_role(user.role) != rbac.ROLE_OWNER:
        return
    published = session.execute(text("""
        SELECT 1 FROM fyp.rental_properties
         WHERE id = :pid AND owner_user_id = :uid
           AND is_published = TRUE AND verification_status = 'approved'
    """), {"pid": int(property_id), "uid": str(user.user_id)}).scalar()
    if not published:
        raise HTTPException(status_code=403, detail="The 360° tour is viewable after Admin approval and publication.")
