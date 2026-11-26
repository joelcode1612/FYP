"""Resolve a listing's canonical coordinates from its saved address.

A listing's location is stored on exactly one row — ``fyp.rental_properties`` —
and every Location Intelligence surface reads that row. When the row has no
coordinates, nothing downstream can run: the measurement queue refuses to
enqueue (it will not measure an unknown point), the prediction has no vector,
and the administrator sees "no valid coordinates" with every action disabled.

The missing piece was never a calculation. It was the step between "the owner
saved an address" and "the row has a coordinate", which only happened when the
client happened to supply an address-confirmation token. This module is that
step, and it is deliberately the ONLY one:

* the address is resolved by the existing preview pipeline
  (:func:`sitewise.services.address_preview_service.preview_address`), which is
  Google Address Validation with the Malaysian Nominatim fallback — no second
  geocoder is introduced;
* the result is persisted through the existing repository method
  (:meth:`FypPropertyRepository.set_address_validation`), so the stored verdict
  and coordinates keep the same meaning they have on the owner path;
* the measurement queue is entered through the existing
  :func:`sitewise.services.expanded64_enrichment.enqueue`, so there is still one
  calculation engine.

Nothing here invents a location. If the provider cannot place the address, the
row is left untouched and the caller receives the provider's own reason; a
city-centre or state-centre fallback is never substituted, because a measurement
taken at the wrong point is worse than a missing measurement.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.logging import logger

#: Fields that must be present before an address can be geocoded at all. A
#: postcode is not required: Malaysian rural addresses frequently omit it and
#: Nominatim resolves them from street, city and state.
REQUIRED_ADDRESS_FIELDS = ("address", "city", "state")

#: Match classes the preview pipeline can produce when it actually located the
#: address. ``not_found`` and ``service_unavailable`` carry no coordinates and
#: are reported as failures rather than resolved.
LOCATED_MATCH_CLASSES = ("precise", "approximate", "ambiguous")

#: Resolutions that mean "this listing now has a usable coordinate".
LOCATED_STATUSES = ("already_located", "geocoded")


@dataclass(frozen=True)
class LocationResolution:
    """The outcome of one coordinate-resolution attempt."""

    property_id: int
    #: ``already_located``, ``geocoded``, ``address_incomplete``,
    #: ``not_found``, ``provider_unavailable`` or ``error``.
    status: str
    latitude: float | None
    longitude: float | None
    match_class: str | None
    provider: str | None
    formatted_address: str | None
    #: Exact, human-readable explanation. Present for every non-located status.
    reason: str | None
    #: True when measurements were queued as a consequence of this call.
    queued: bool
    #: Address components that are missing, when ``status`` is
    #: ``address_incomplete``.
    missing_fields: tuple[str, ...] = ()

    @property
    def located(self) -> bool:
        return self.status in LOCATED_STATUSES

    def as_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["located"] = self.located
        return payload


def _row(session: Session, property_id: int) -> Any:
    return session.execute(text("""
        SELECT id, address, city, state, postcode, latitude, longitude,
               address_validation_status
        FROM fyp.rental_properties WHERE id=:id
        """), {"id": property_id}).first()


def _address_reason(missing: tuple[str, ...]) -> str:
    if not missing:
        return "The saved address cannot be geocoded."
    listed = ", ".join(missing)
    return (
        f"The saved address is incomplete ({listed}). Add the missing part on "
        "the listing and retry — a location is never inferred from a partial "
        "address."
    )


def resolve_property_coordinates(
    session: Session,
    property_id: int,
    *,
    queue_measurements: bool = True,
) -> LocationResolution:
    """Give this listing a provider-derived coordinate if it has none.

    Runs inside the caller's transaction and never commits. Callers that want
    the result persisted must commit; callers that are only probing can roll
    back.

    An existing valid coordinate is returned untouched — the function never
    re-geocodes a located listing, so it cannot move a property that an owner or
    administrator already confirmed.
    """
    from sitewise.services.property_enrichment_service import _valid_coordinates

    row = _row(session, property_id)
    if row is None:
        raise LookupError("Property not found")

    (
        _, address, city, state, postcode,
        latitude, longitude, _verdict,
    ) = row

    if _valid_coordinates(latitude, longitude):
        return LocationResolution(
            property_id=property_id,
            status="already_located",
            latitude=float(latitude),
            longitude=float(longitude),
            match_class=None,
            provider=None,
            formatted_address=None,
            reason=None,
            queued=False,
        )

    values = {
        "address": (address or "").strip(),
        "city": (city or "").strip(),
        "state": (state or "").strip(),
    }
    missing = tuple(name for name in REQUIRED_ADDRESS_FIELDS if not values[name])
    if missing:
        return LocationResolution(
            property_id=property_id,
            status="address_incomplete",
            latitude=None,
            longitude=None,
            match_class=None,
            provider=None,
            formatted_address=None,
            reason=_address_reason(missing),
            queued=False,
            missing_fields=missing,
        )

    from sitewise.services.address_preview_service import preview_address

    try:
        preview = preview_address(
            address_line1=values["address"],
            city=values["city"],
            state=values["state"],
            postcode=(postcode or "").strip(),
        )
    except Exception as exc:  # noqa: BLE001 - a provider fault must be reported, not raised
        logger.warning(
            "Address resolution failed for listing %s (%s)",
            property_id, type(exc).__name__,
        )
        return LocationResolution(
            property_id=property_id,
            status="provider_unavailable",
            latitude=None,
            longitude=None,
            match_class=None,
            provider=None,
            formatted_address=None,
            reason=(
                "The geocoding provider could not be reached "
                f"({type(exc).__name__}). Retry when the service is available; "
                "the saved address is unchanged."
            ),
            queued=False,
        )

    match_class = preview.get("match_class")
    new_latitude, new_longitude = preview.get("latitude"), preview.get("longitude")
    # ``preview_address`` reports a missing Google key as a note on every
    # fallback result. That is configuration context, not the reason this
    # address failed, and putting it in front of the reviewer hides the
    # actionable part.
    notes = [
        note for note in (preview.get("notes") or [])
        if note and "not configured" not in note.lower()
    ]

    if match_class not in LOCATED_MATCH_CLASSES or new_latitude is None or new_longitude is None:
        if match_class == "service_unavailable":
            status = "provider_unavailable"
            reason = (
                "The geocoding provider is temporarily unavailable. "
                "Retry shortly; the saved address is unchanged."
            )
        else:
            status = "not_found"
            reason = (
                "The geocoding provider could not place this address. "
                + (" ".join(notes) + " " if notes else "")
                + "Check the street, city and state on the listing, correct "
                "anything wrong, and retry — no location is inferred when the "
                "address cannot be matched."
            )
        return LocationResolution(
            property_id=property_id,
            status=status,
            latitude=None,
            longitude=None,
            match_class=match_class,
            provider=preview.get("provider"),
            formatted_address=preview.get("formatted_address"),
            reason=reason,
            queued=False,
        )

    # A precise premise-level match is a validated location; an approximate or
    # ambiguous match is a provider-derived location the reviewer can still
    # judge. Both are real coordinates and both are recorded as such — the
    # verdict says how confident the match is, never that it is missing.
    status = "validated" if match_class == "precise" else "partially_validated"
    from sitewise.repositories.fyp_property_repository import FypPropertyRepository

    FypPropertyRepository(session).set_address_validation(
        property_id,
        status=status,
        formatted_address=preview.get("formatted_address"),
        latitude=float(new_latitude),
        longitude=float(new_longitude),
    )
    logger.info(
        "Resolved coordinates for listing %s via %s (match=%s, verdict=%s)",
        property_id, preview.get("provider"), match_class, status,
    )

    queued = False
    if queue_measurements:
        # A migration or source failure must not lose the coordinates we just
        # obtained; the measurement queue is a separate, retryable concern.
        try:
            from sitewise.services.expanded64_enrichment import enqueue

            with session.begin_nested():
                queued = enqueue(session, property_id)
        except Exception as exc:  # noqa: BLE001 - reported through the payload
            logger.warning(
                "Coordinates stored for listing %s but measurements were not queued (%s)",
                property_id, type(exc).__name__,
            )

    return LocationResolution(
        property_id=property_id,
        status="geocoded",
        latitude=float(new_latitude),
        longitude=float(new_longitude),
        match_class=match_class,
        provider=preview.get("provider"),
        formatted_address=preview.get("formatted_address"),
        reason=(
            "Location obtained from the saved address via "
            f"{preview.get('provider') or 'the geocoding provider'}"
            + (" (precise premise-level match)." if match_class == "precise"
               else " (approximate match; the reviewer should confirm the pin).")
        ),
        queued=queued,
    )


def address_is_geocodable(session: Session, property_id: int) -> dict[str, Any]:
    """Cheap, read-only check of whether an address exists to geocode.

    Used by the read-only status endpoint so the UI can enable the analysis
    action for a listing that has an address but no coordinates yet. It performs
    no provider call and writes nothing.
    """
    row = session.execute(text("""
        SELECT address, city, state, postcode FROM fyp.rental_properties WHERE id=:id
        """), {"id": property_id}).first()
    if row is None:
        return {"geocodable": False, "missing_fields": list(REQUIRED_ADDRESS_FIELDS)}
    address, city, state, _postcode = row
    missing = [
        name for name, value in (
            ("address", address), ("city", city), ("state", state),
        )
        if not (value or "").strip()
    ]
    return {"geocodable": not missing, "missing_fields": missing}
