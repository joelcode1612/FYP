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
        _require_writable_assignment(result)
    return result


def _require_writable_assignment(assignment: dict) -> None:
    if assignment["workflow_status"] not in ("accepted", "needs_correction"):
        raise HTTPException(status_code=409, detail="Accept the Agent request before inspecting or capturing.")
    if assignment["is_published"] or assignment["verification_status"] in ("approved", "pending", "under_review"):
        raise HTTPException(status_code=409, detail="Property is locked for Admin review or publication.")


def require_frame_backup(session: Session, capture, user) -> bool:
    """Return whether this is append-only backup for the submitted panorama."""
    assignment = agent_assignment(session, int(capture.property_id), user)
    if str(capture.owner_id) != str(user.user_id):
        raise HTTPException(status_code=403, detail="Capture session belongs to a different Agent.")
    if capture.status == "cancelled":
        raise HTTPException(status_code=409, detail="This capture session was cancelled.")
    if assignment["workflow_status"] != "submitted":
        _require_writable_assignment(assignment)
        return False
    pinned = assignment["panorama_id"]
    if pinned is not None and capture.capture_mode == "device_38_panorama" and capture.status == "completed":
        matches = session.execute(text("""
            SELECT EXISTS (
                SELECT 1 FROM fyp.panoramas
                WHERE panorama_id = :panorama_id AND session_id = :session_id
                  AND property_id = :property_id
            )
        """), {
            "panorama_id": str(pinned),
            "session_id": str(capture.id),
            "property_id": str(capture.property_id),
        }).scalar()
        if matches:
            return True
    raise HTTPException(status_code=409, detail="Only originals for the submitted panorama can be backed up.")


def completed_agent_panorama(
    session: Session, property_id: int, user, panorama_id: str | None = None,
) -> str | None:
    """Only a genuinely completed pipeline panorama produced by this Agent.

    A client cannot claim its file or flip a 'ready' flag: the canonical
    fyp.panoramas row is written ONLY by the confirmation endpoint, which
    verifies the stored object, its checksum, its JPEG structure and the 2:1
    geometry first. Legacy sessions additionally carry a 'done' panorama job;
    device-stitched sessions (capture_plan_version 2) have no job row at all,
    so the job is no longer the proof — the verified canonical row is.

    Capture and checklist completion may happen in either order.
    """
    record = session.execute(text("""
        SELECT p.panorama_id
          FROM fyp.panoramas p
          JOIN fyp.capture_sessions cs ON cs.id = p.session_id
          JOIN fyp.agent_listing_assignment a ON a.listing_id = :pid
         WHERE p.property_id = CAST(:pid AS text)
           AND cs.property_id = CAST(:pid AS text)
           AND cs.owner_id = :uid
           AND cs.status = 'completed'
           AND a.workflow_status IN ('accepted', 'needs_correction')
           AND (CAST(:panorama_id AS text) IS NULL OR CAST(p.panorama_id AS text) = :panorama_id)
           AND p.verification_status IS DISTINCT FROM 'rejected'
           AND p.storage_path IS NOT NULL AND btrim(p.storage_path) <> ''
         ORDER BY p.created_at DESC LIMIT 1
    """), {"pid": int(property_id), "uid": str(user.user_id), "panorama_id": panorama_id}).scalar()
    return str(record) if record else None


def require_ready_for_admin(
    session: Session, property_id: int, user, panorama_id: str | None = None
) -> dict:
    row = agent_assignment(session, property_id, user, writable=True)
    data = row["inspection_data"] or {}
    if not row.get("inspection_updated_at") or any(data.get(key) is not True for key in REQUIRED_INSPECTION):
        raise HTTPException(status_code=409, detail="Save the four on-site verification checks before submitting.")
    panorama_id = completed_agent_panorama(session, property_id, user, panorama_id)
    if not panorama_id:
        raise HTTPException(status_code=409, detail="Complete and upload a 360° tour through the Agent capture pipeline before submitting.")
    return {**row, "completed_panorama_id": panorama_id}


def require_owner_published_view(session: Session, property_id: int, user) -> None:
    """Owners preview their own listing's tour; everyone else keeps the rule.

    The owner of the listing may always view its canonical panorama — before
    review, before publication — because it is imagery of their own property
    captured by the agent they assigned. A non-owner keeps the strict rule:
    the generic property-scope read check must also run at the endpoint; this
    helper only tightens visibility for owners of OTHER listings. Public
    visibility for entrepreneurs is unchanged and governed solely by the
    published/approved state of the canonical row.
    """
    if rbac.canonical_role(user.role) != rbac.ROLE_OWNER:
        return
    owned = session.execute(text("""
        SELECT 1 FROM fyp.rental_properties
         WHERE id = :pid AND owner_user_id = :uid
    """), {"pid": int(property_id), "uid": str(user.user_id)}).scalar()
    if not owned:
        raise HTTPException(
            status_code=403,
            detail="The 360° tour is viewable after Admin approval and publication.",
        )


def guard_enrichment_before_submit(
    session: Session, property_id: int, acknowledged: bool
) -> None:
    """Refuse a premature or unacknowledged submission.

    Listings that were never enriched keep their previous behaviour: the guard
    only engages once at least one enrichment category row exists, so the
    existing submission flows (and their tests) are untouched.
    """
    rows = session.execute(
        text(
            """
            SELECT category, status
            FROM fyp.property_enrichment_category
            WHERE property_id = :pid
            """
        ),
        {"pid": property_id},
    ).all()
    if not rows:
        return

    states = {row[0]: row[1] for row in rows}
    running = sorted(c for c, s in states.items() if s == "running")
    if running:
        raise HTTPException(
            status_code=409,
            detail=(
                "Enrichment is still running for: "
                + ", ".join(running)
                + ". Wait for it to finish before submitting."
            ),
        )

    population = states.get("population")
    if population in ("unavailable", "failed", "stale") and not acknowledged:
        raise HTTPException(
            status_code=409,
            detail=(
                "Population could not be measured for these coordinates "
                f"(state: {population}). Confirm that you want to submit "
                "without a population figure."
            ),
        )


def agent_submission_readiness(
    session: Session, property_id: int,
    assignment: dict, listing: dict, panorama_id: str | None,
) -> dict:
    from sitewise.services.property_verification_service import listing_completeness_errors

    inspection = assignment.get('inspection_data') or {}
    missing_checks = [
        key for key in REQUIRED_INSPECTION if inspection.get(key) is not True
    ]
    missing_fields = listing_completeness_errors(listing, require_availability=False)

    # Ownership proof is separate from inspection photos and the 360 tour.
    # Local document storage has to contain the file, not just a stale DB row.
    keys = session.execute(text("""
        SELECT storage_key FROM fyp.verification_document
         WHERE property_id=:pid AND verification_type='ownership'
           AND status='active' ORDER BY uploaded_at DESC
    """), {'pid': property_id}).scalars().all()
    from sitewise.services import verification_storage
    proof_available = False
    for key in keys:
        try:
            verification_storage.open_document(str(key))
            proof_available = True
            break
        except Exception:
            # Preserve evidence metadata; report missing/unreachable storage.
            continue

    enrichment = dict(session.execute(text("""
        SELECT category, status FROM fyp.property_enrichment_category
         WHERE property_id=:pid
    """), {'pid': property_id}).all())
    running = sorted(
        key for key, status in enrichment.items() if status == 'running'
    )
    population_ack = enrichment.get('population') in ('unavailable', 'failed', 'stale')
    blockers: list[str] = []
    if assignment.get('workflow_status') not in ('accepted', 'needs_correction'):
        blockers.append('Agent request must be accepted before submission.')
    if missing_fields:
        blockers.append('Complete property details: ' + ', '.join(missing_fields) + '.')
    if missing_checks:
        labels = {
            'floor_area_verified': 'floor area',
            'condition_verified': 'physical condition',
            'parking_verified': 'parking',
            'accessibility_verified': 'access / entrance',
        }
        blockers.append('Save inspection checks: ' + ', '.join(
            labels.get(key, key) for key in missing_checks
        ) + '.')
    if not panorama_id:
        blockers.append(
            'Finish 360 capture and sync the panorama to SiteWise (server confirmed).'
        )
    if running:
        blockers.append('Wait for geospatial processing: ' + ', '.join(running) + '.')
    return {
        'ready': not blockers,
        'blockers': blockers,
        'missing_property_fields': missing_fields,
        'missing_inspection_checks': missing_checks,
        'ownership_proof_uploaded': proof_available,
        'ownership_proof_record_count': len(keys),
        'panorama_confirmed': bool(panorama_id),
        'enrichment_running': running,
        'population_acknowledgement_required': population_ack,
    }
