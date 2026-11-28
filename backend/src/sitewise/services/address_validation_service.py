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

import logging
import time

import httpx

from sitewise.core.config import settings

logger = logging.getLogger("sitewise.address_validation")

ADDRESS_VALIDATION_URL = "https://addressvalidation.googleapis.com/v1:validateAddress"

#: Transport errors, 429 and 5xx are retried: they are momentary and a valid
#: address should not be reported as unverifiable because of one blip. A 4xx
#: payload rejection is never retried — the same payload will be rejected again.
_MAX_ATTEMPTS = 3
_RETRY_BACKOFF_SECONDS = (0.5, 1.5)

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

    response = None
    transport_error: httpx.HTTPError | None = None
    for attempt in range(_MAX_ATTEMPTS):
        try:
            response = httpx.post(
                ADDRESS_VALIDATION_URL,
                params={"key": settings.google_maps_api_key},
                json=payload,
                timeout=settings.google_maps_timeout_seconds,
            )
        except httpx.HTTPError as exc:  # transport, DNS, timeout
            transport_error = exc
            response = None
        else:
            transport_error = None
            # Retry only the transient statuses; everything else is final.
            if not (response.status_code == 429 or response.status_code >= 500):
                break
        if attempt + 1 < _MAX_ATTEMPTS:
            time.sleep(_RETRY_BACKOFF_SECONDS[
                min(attempt, len(_RETRY_BACKOFF_SECONDS) - 1)
            ])

    if response is None:
        raise AddressValidationUnavailable(
            "The address validation service is temporarily unavailable."
        ) from transport_error

    if response.status_code in (401, 403):
        # Google uses PERMISSION_DENIED for API-not-enabled, billing, key
        # restrictions and project policy. Classify the provider's own message
        # so the preview can tell the operator which one applies, without ever
        # echoing the request key.
        try:
            body = response.json()
        except ValueError:
            body = {}
        error = body.get("error", {}) if isinstance(body, dict) else {}
        provider_status = error.get("status") if isinstance(error, dict) else None
        provider_message = (
            error.get("message") if isinstance(error, dict) else ""
        ) or ""
        logger.warning(
            "Google Address Validation permission denied "
            "(http_status=%s, provider_status=%s, provider_message=%s)",
            response.status_code,
            provider_status,
            provider_message,
        )
        detail = f"{provider_status or ''} {provider_message}".lower()
        if "billing" in detail:
            cause = "Google Cloud billing is not enabled for the server project."
        elif "api key" in detail or "restricted" in detail or "not valid" in detail:
            cause = "The server key is restricted from calling Address Validation."
        elif provider_status == "SERVICE_DISABLED" or "not enabled" in detail:
            cause = "The Address Validation API is not enabled for the server project."
        else:
            # Google's observed response here is "The caller does not have
            # permission" (PERMISSION_DENIED) on a project whose billing is
            # disabled, so this wording is deliberately not a claim that the
            # key itself is invalid.
            cause = (
                "the server project is not permitted to use Address Validation "
                "(the API is not enabled or billing is disabled)."
            )
        raise AddressValidationUnavailable(
            f"Google Address Validation is unavailable: {cause}"
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

    def _component_text(component_type: str) -> str | None:
        return next(
            (
                c.get("text")
                for c in components
                if (c.get("componentType") or "") == component_type
            ),
            None,
        )

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
        "postal_code": _component_text("postal_code"),
        # Structured component texts the address preview uses to check the
        # typed city/state/postcode against what the provider actually
        # matched. Normalised application fields only — never raw payloads.
        "locality": _component_text("locality"),
        "administrative_area": _component_text("administrative_area_level_1"),
        "country": _component_text("country"),
        "component_count": len(components),
        "provider": "google_address_validation",
        "provider_request_id": body.get("responseId"),
        # The verdict is about the ADDRESS ONLY — it is never an ownership,
        # availability or approval signal.
        "scope": "address_only",
    }
