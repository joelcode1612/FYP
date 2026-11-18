import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from sqlalchemy import text
from sqlmodel import Session, select

from sitewise.core.exceptions import ForbiddenError
from sitewise.db.models.virtual_tour import VirtualTour
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_property_owner
from sitewise.domain import rbac
from sitewise.services import provider_scope
from sitewise.services.virtual_tour_service import VirtualTourService

router = APIRouter()

_MUTABLE_TOUR_FIELDS = frozenset({"url", "status"})
#: Status the capture pipeline stamps on a freshly stitched panorama. It is
#: one of the completed statuses the insights panorama reader accepts.
PANORAMA_READY_STATUS = "ready"
DbSession = Annotated[Session, Depends(get_db)]
OwnerUser = Annotated[AuthenticatedUser, Depends(require_property_owner)]


def _require_owned_listing(
    session: Session, property_id: int, current: AuthenticatedUser
) -> None:
    """Require access to the current listing represented by a tour's id.

    ``virtual_tour.property_id`` is a legacy, unbound integer after the
    retirement of ``public.property``. New tour reads must therefore resolve
    that integer against the canonical operational listing table before a
    tour is returned. Missing or unlinked legacy rows fail closed instead of
    becoming readable by any authenticated user.
    """
    row = session.execute(
        text("SELECT owner_user_id FROM fyp.rental_properties WHERE id = :pid"),
        {"pid": property_id},
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    if rbac.can_administer_users(current.role):
        return
    if row[0] is None or str(row[0]) != str(current.user_id):
        raise ForbiddenError("You can only access tours for your own property listings.")


def _owned_tour_or_error(
    service: VirtualTourService,
    session: Session,
    tour_id: uuid.UUID,
    current: AuthenticatedUser,
) -> VirtualTour:
    """Resolve a tour and enforce ownership before any mutation."""
    tour = service.get(tour_id)
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    _require_owned_listing(session, tour.property_id, current)
    return tour


def _validated_update(data: dict) -> dict:
    """Accept only the two lifecycle fields that can safely change in place.

    A virtual tour must never be reassigned to another listing through PATCH:
    that could turn a legitimate owner update into a cross-property record
    move. Keeping this allow-list next to the endpoint also prevents clients
    from setting primary keys or audit timestamps through the raw dict body.
    """
    unknown = set(data) - _MUTABLE_TOUR_FIELDS
    if unknown:
        fields = ", ".join(sorted(unknown))
        raise HTTPException(
            status_code=422,
            detail=f"Only url and status may be updated (unexpected: {fields}).",
        )
    return {key: data[key] for key in _MUTABLE_TOUR_FIELDS if key in data}


@router.get("/property/{property_id}")
def list_tours_by_property(
    property_id: int,
    session: DbSession,
    current: OwnerUser,
):
    _require_owned_listing(session, property_id, current)
    return VirtualTourService(session).get_by_property(property_id)


@router.get("/{tour_id}")
def get_tour(
    tour_id: uuid.UUID,
    session: DbSession,
    current: OwnerUser,
):
    service = VirtualTourService(session)
    return _owned_tour_or_error(service, session, tour_id, current)


@router.post("/", status_code=201)
def create_tour(
    tour: VirtualTour,
    session: DbSession,
    current: OwnerUser,
):
    _require_owned_listing(session, tour.property_id, current)
    return VirtualTourService(session).create(tour)


@router.patch("/{tour_id}")
def update_tour(
    tour_id: uuid.UUID,
    data: dict,
    session: DbSession,
    current: OwnerUser,
):
    service = VirtualTourService(session)
    _owned_tour_or_error(service, session, tour_id, current)
    return service.update(tour_id, _validated_update(data))


def _panorama_upload_authorized(
    session: Session, property_id: int, current: AuthenticatedUser
) -> None:
    """Record-level access for the capture upload: owner, admin or assigned agent.

    The read endpoints keep [_require_owned_listing]'s owner-only rule. The
    upload is part of the shared Add Property flow, where an assigned agent
    maintains the record on the owner's behalf — so the same
    ``agent_listing_assignment`` check that authorizes the listing routes
    authorizes the panorama's tour row too. An agent with no assignment
    manages nothing.
    """
    row = session.execute(
        text("SELECT owner_user_id FROM fyp.rental_properties WHERE id = :pid"),
        {"pid": property_id},
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    if rbac.can_administer_users(current.role):
        return
    if row[0] is not None and str(row[0]) == str(current.user_id):
        return
    if rbac.has_role(current.role, (rbac.ROLE_AGENT,)):
        agent_id = provider_scope.agent_id_for_user(current.user_id)
        if agent_id is not None:
            assignment = session.execute(
                text(
                    "SELECT 1 FROM agent_listing_assignment "
                    "WHERE listing_id = :lid AND agent_id = :aid"
                ),
                {"lid": property_id, "aid": agent_id},
            ).first()
            if assignment is not None:
                return
    raise ForbiddenError(
        "You can only manage property listings you own or are assigned to."
    )


@router.post("/property/{property_id}/panorama", status_code=201)
async def upload_property_panorama(
    property_id: int,
    file: UploadFile = File(...),  # noqa: B008 - FastAPI dependency idiom
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Store a stitched 360° panorama and connect it to its listing.

    The mobile ARCore capture flow stitches on device and uploads the result
    here. The bytes are uploaded to public storage BEFORE the tour row is
    written, so a failed upload never leaves a row pointing at a dead URL.
    The newest tour row for the property is updated in place when one exists;
    otherwise a row is created with the completed status, which is what the
    insights panorama reader and the property-detail 360° viewer accept.
    """
    from sitewise.services import photo_storage
    from sitewise.services.photo_storage import (
        PhotoRejected,
        PhotoStorageUnavailable,
    )

    _panorama_upload_authorized(session, property_id, current)
    data = await file.read()
    try:
        ext = photo_storage.validate_panorama(
            file.filename or "", file.content_type or "", len(data)
        )
        url = photo_storage.save_panorama(data, ext, file.content_type or "")
    except PhotoRejected as exc:
        raise HTTPException(
            status_code=413 if exc.oversized else 422, detail=str(exc)
        ) from exc
    except PhotoStorageUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    tour = session.exec(
        select(VirtualTour)
        .where(VirtualTour.property_id == property_id)
        .order_by(VirtualTour.updated_at.desc())
    ).first()
    if tour is None:
        tour = VirtualTour(
            property_id=property_id,
            url=url,
            status=PANORAMA_READY_STATUS,
        )
        session.add(tour)
    else:
        tour.url = url
        tour.status = PANORAMA_READY_STATUS
        session.add(tour)
    session.commit()
    session.refresh(tour)
    return {"data": {"tour_id": str(tour.tour_id), "url": tour.url, "status": tour.status}}


@router.delete("/{tour_id}", status_code=204, response_model=None)
def delete_tour(
    tour_id: uuid.UUID,
    session: DbSession,
    current: OwnerUser,
):
    service = VirtualTourService(session)
    _owned_tour_or_error(service, session, tour_id, current)
    # The authorized lookup above makes a second missing-row result a benign
    # race (for example a concurrent admin cleanup), not an authorization
    # bypass.
    service.delete(tour_id)
