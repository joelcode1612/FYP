"""Google Address Validation adapter (infrastructure, server-side only).

Scope — deliberately narrow:
* verifies that an address exists and is complete enough to locate;
* reports Google's own verdict, so the UI can distinguish "confirmed" from
  "partially confirmed" and from "could not be validated";
* **never** decides ownership, availability, F&B suitability or property
  verification. Those remain SiteWise decisions.

The API key is read from settings and never leaves this process: no Dart
client and no browser bundle receives it.

Failure semantics:
* no key configured            -> :class:`AddressValidationUnavailable` (503)
* API not enabled / forbidden  -> :class:`AddressValidationUnavailable` (503)
* timeout / transport error    -> :class:`AddressValidationUnavailable` (503)
* provider 4xx on the payload  -> :class:`AddressValidationRejected` (422)
"""

from __future__ import annotations

import httpx

from sitewise.core.config import settings

ADDRESS_VALIDATION_URL = "https://addressvalidation.googleapis.com/v1:validateAddress"

#: Granularities precise enough to be treated as a confirmed location.
PREMISE_GRANULARITIES = {"PREMISE", "SUB_PREMISE"}

#: Granularities that still place the address, but coarsely (street/block).
#: Google's "OTHER" means "valid but imprecise", so it lands here, never in
#: the confirmed bucket.
LOCATABLE_GRANULARITIES = {
    "PREMISE",
    "SUB_PREMISE",
    "PREMISE_PROXIMITY",
    "ROUTE",
    "BLOCK",
    "OTHER",
}


class AddressValidationUnavailable(RuntimeError):
    """The provider cannot be reached, is not enabled, or is not configured."""


class AddressValidationRejected(RuntimeError):
    """The provider rejected the request payload itself (bad input)."""


def _is_usable() -> bool:
    return bool(settings.google_maps_api_key)


def validate_address(
    *,
    address_lines: list[str],
    region_code: str = "MY",
    locality: str | None = None,
    postal_code: str | None = None,
    administrative_area: str | None = None,
) -> dict:
    """Validate one address and return a normalised verdict.

    The raw provider payload is NOT returned: only the fields the application
    needs, so provider internals never leak into the API contract.
    """
    if not _is_usable():
        raise AddressValidationUnavailable(
            "Address validation is not configured: GOOGLE_MAPS_API_KEY is missing."
        )

    payload = {
        "address": {
            "regionCode": region_code,
            "addressLines": [line for line in address_lines if line and line.strip()],
        },
        # Ask for the geocode so the caller can compare the confirmed location
        # with the coordinates the owner typed.
        "enableUspsCass": False,
    }
    if locality:
        payload["address"]["locality"] = locality
    if postal_code:
        payload["address"]["postalCode"] = postal_code
    if administrative_area:
        payload["address"]["administrativeArea"] = administrative_area

    try:
        response = httpx.post(
            ADDRESS_VALIDATION_URL,
            params={"key": settings.google_maps_api_key},
            json=payload,
            timeout=settings.google_maps_timeout_seconds,
        )
    except httpx.HTTPError as exc:  # transport, DNS, timeout
        raise AddressValidationUnavailable(
            "The address validation service is temporarily unavailable."
        ) from exc

    if response.status_code in (401, 403):
        # Confirmed on this project: the key is valid for other Maps APIs, but
        # the Address Validation API itself is not enabled (PERMISSION_DENIED).
        raise AddressValidationUnavailable(
            "Google Address Validation is not enabled for this project. "
            "Enable 'Address Validation API' in Google Cloud and retry."
        )
    if response.status_code == 400:
        detail = ""
        try:
            detail = response.json().get("error", {}).get("message", "")
        except ValueError:
            detail = response.text[:200]
        raise AddressValidationRejected(detail or "The address payload was rejected.")
    if response.status_code >= 500:
        raise AddressValidationUnavailable(
            "The address validation service returned an error; try again later."
        )
    if response.status_code != 200:
        raise AddressValidationUnavailable(
            f"Address validation failed with status {response.status_code}."
        )

    body = response.json()
    result = body.get("result", {}) or {}
    verdict = result.get("verdict", {}) or {}
    geocode = result.get("geocode", {}) or {}
    location = geocode.get("location", {}) or {}
    address = result.get("address", {}) or {}
    components = result.get("addressComponents", []) or []

    granularity = verdict.get("validationGranularity")
    complete = bool(verdict.get("addressComplete"))
    has_unconfirmed = bool(verdict.get("hasUnconfirmedComponents"))
    locatable = granularity in LOCATABLE_GRANULARITIES

    if complete and not has_unconfirmed and granularity in PREMISE_GRANULARITIES:
        status = "validated"
    elif locatable:
        status = "partially_validated"
    else:
        status = "unconfirmed"

    return {
        "status": status,
        "formatted_address": address.get("formattedAddress"),
        "validation_granularity": granularity,
        "geocode_granularity": verdict.get("geocodeGranularity"),
        "address_complete": complete,
        "has_unconfirmed_components": has_unconfirmed,
        "has_inferred_components": bool(verdict.get("hasInferredComponents")),
        "latitude": location.get("latitude"),
        "longitude": location.get("longitude"),
        "postal_code": next(
            (
                c.get("text")
                for c in components
                if "postal_code" in (c.get("componentType") or "").lower()
            ),
            None,
        ),
        "component_count": len(components),
        "provider": "google_address_validation",
        "provider_request_id": body.get("responseId"),
        # The verdict is about the ADDRESS ONLY — it is never an ownership,
        # availability or approval signal.
        "scope": "address_only",
    }
