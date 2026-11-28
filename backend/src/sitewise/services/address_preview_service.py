"""Read-only Malaysian address preview + confirmation evidence.

The Add Property wizards (Flutter mobile, Jaspr web) call
``POST /api/v1/properties/address-preview`` while the owner types. This module
reuses the EXISTING provider chain and never persists anything:

1. Google Address Validation (``address_validation_service``) — the richest
   verdict (granularity, component checks) when the API is enabled;
2. the existing Malaysian geocoder (``nearby_location_geocoding``) — used when
   Google is not configured/enabled, so the preview keeps working and Save
   Draft never depends on Google availability.

The response classifies the match (``precise`` / ``approximate`` /
``ambiguous`` / ``not_found`` / ``service_unavailable``) by comparing the
provider's returned components against the typed city, state and postcode.

User confirmation is bound to the EXACT address through an HMAC-signed
evidence token carrying the server-obtained verdict. The draft endpoints
later verify the signature, the expiry AND that the stored address still
hashes identically, so:

* coordinates stored on a draft are always SERVER-derived (no client
  lat/lng is trusted anywhere);
* evidence whose address was edited afterwards is rejected as outdated
  ("address_changed") while the draft itself still saves;
* Google-derived values are kept as short-lived transient evidence on the
  server (never embedded in client code, no unrestricted key exposure).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import math
import time
from datetime import UTC, datetime

from sitewise.core.config import settings
from sitewise.services import address_validation_service as av
from sitewise.services.nearby_location_geocoding import (
    GeocodingUnavailable,
    lookup_malaysian_address,
)

#: Bump when the canonicalisation changes so previously issued evidence can
#: never be mistaken for evidence about the new canonical form.
CANONICAL_ADDRESS_VERSION = "sw-addr-v1"

#: Evidence lives for one wizard session, not forever: Google-derived values
#: are stored as server-side verdicts, not licensed data assets to hoard.
CONFIRMATION_TOKEN_TTL_SECONDS = 6 * 3600

#: Provider-configuration detail (missing key, disabled API, transport error)
#: is an OPERATOR concern. It must never be returned as an address verdict:
#: the client renders the first note as the verification result, so a missing
#: key made a successful geocode look like a failed verification.
FALLBACK_GOOGLE_NOTE = (
    "Google Address Validation is unavailable."
)


def _google_note(google_error: str | None) -> str | None:
    """One operator note that carries the provider's actual cause.

    The note must not be rendered as the address verdict: a successful
    fallback geocode still supplies coordinates and a signed confirmation.
    """
    if not google_error:
        return None
    if google_error.startswith("Google Address Validation is unavailable"):
        return google_error
    return f"{FALLBACK_GOOGLE_NOTE} {google_error}"

#: Fallback signing secret so a dev environment without SECRET_KEY still
#: produces verifiable (short-lived) tokens instead of silently dropping the
#: whole confirm flow. Production sets SECRET_KEY.
_TOKEN_FALLBACK_SECRET = "sitewise.address-confirmation.fallback-v1"

MATCH_CLASSES = ("precise", "approximate", "ambiguous", "not_found", "service_unavailable")


def _norm(value) -> str:
    return " ".join(str(value or "").split()).casefold()


def canonical_address_hash(
    address: str | None,
    city: str | None,
    state: str | None,
    postcode: str | None,
    *,
    address_line2: str | None = None,
) -> str:
    """Stable identity of the address exactly as the form expresses it."""
    material = "|".join(
        (
            CANONICAL_ADDRESS_VERSION,
            _norm(address),
            _norm(address_line2),
            _norm(city),
            _norm(state),
            _norm(postcode),
        )
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _secret() -> bytes:
    key = settings.secret_key
    return (key or _TOKEN_FALLBACK_SECRET).encode("utf-8")


def _b64u_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _b64u_decode(text: str) -> bytes:
    padding = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + padding)


def issue_confirmation_token(
    *,
    address_hash: str,
    match_class: str,
    status: str,
    formatted_address: str,
    latitude: float,
    longitude: float,
    provider: str,
) -> str:
    """Sign the server-obtained verdict to the exact canonical address."""
    payload = {
        "v": 1,
        "ah": address_hash,
        "mc": match_class,
        "st": status,
        "fa": formatted_address[:500],
        "la": float(latitude),
        "lo": float(longitude),
        "pv": provider,
        "ex": int(time.time()) + CONFIRMATION_TOKEN_TTL_SECONDS,
    }
    body = _b64u_encode(
        json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )
    signature = hmac.new(_secret(), body.encode("ascii"), hashlib.sha256).hexdigest()
    return f"{body}.{signature}"


def verify_confirmation_token(token: str | None) -> dict | None:
    """Returns the evidence payload, or None when absent/tampered/expired."""
    if not token or len(token) > 4096 or token.count(".") != 1:
        return None
    body, _, signature = token.partition(".")
    expected = hmac.new(_secret(), body.encode("ascii"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        return None
    try:
        payload = json.loads(_b64u_decode(body))
    except ValueError:  # includes binascii.Error from bad base64
        return None
    if not isinstance(payload, dict) or payload.get("v") != 1:
        return None
    try:
        if int(payload.get("ex") or 0) < int(time.time()):
            return None
        latitude, longitude = float(payload["la"]), float(payload["lo"])
    except (TypeError, ValueError, KeyError):
        return None
    if not (math.isfinite(latitude) and math.isfinite(longitude)):
        return None
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None
    if not isinstance(payload.get("fa"), str) or not payload["fa"].strip():
        return None
    if payload.get("mc") not in ("precise", "approximate", "ambiguous"):
        return None
    return payload


def binascii_error():
    import binascii

    return binascii.Error


def _component_matches(returned: str | None, typed: str | None) -> bool:
    """Nothing typed cannot contradict; a missing returned part can."""
    typed_norm, returned_norm = _norm(typed), _norm(returned)
    if not typed_norm:
        return True
    if not returned_norm:
        return False
    return typed_norm == returned_norm or typed_norm in returned_norm or returned_norm in typed_norm


def _classify_google(verdict: dict, *, city: str, state: str, postcode: str):
    checks = {
        "postcode_matches": _component_matches(verdict.get("postal_code"), postcode),
        "city_matches": _component_matches(verdict.get("locality"), city),
        "state_matches": _component_matches(verdict.get("administrative_area"), state),
        "country_matches": _norm(verdict.get("country")) in ("my", "malaysia"),
    }
    notes: list[str] = []
    has_location = verdict.get("latitude") is not None and verdict.get("longitude") is not None
    if not has_location or not verdict.get("formatted_address"):
        return "not_found", checks, notes
    if not checks["city_matches"]:
        notes.append("The matched locality name differs from the selected city.")
    if not checks["postcode_matches"]:
        notes.append("The matched postcode differs from the selected postcode.")
    if not checks["state_matches"]:
        notes.append("The matched state differs from the selected state.")
    both_contradict = (
        postcode and not checks["postcode_matches"] and state and not checks["state_matches"]
    )
    precise = (
        verdict.get("status") == "validated"
        and verdict.get("validation_granularity") in av.PREMISE_GRANULARITIES
        and checks["postcode_matches"]
        and checks["state_matches"]
    )
    if precise:
        return "precise", checks, notes
    if both_contradict:
        notes.append("The result may be a different place with a similar street name.")
        return "ambiguous", checks, notes
    return "approximate", checks, notes


def _classify_osm(place: dict, *, city: str, state: str, postcode: str):
    """OSM Nominatim returns display text only, so the checks are heuristic."""
    display = _norm(place.get("display_name"))
    checks = {
        "postcode_matches": _norm(postcode) in display if postcode else True,
        "city_matches": _norm(city) in display if city else True,
        "state_matches": _norm(state) in display if state else True,
        "country_matches": True,  # the geocoder is restricted to countrycodes=my
    }
    notes = [
        "Matched by the fallback geocoder; component agreement is approximate.",
    ]
    if not checks["city_matches"]:
        notes.append("The matched locality differs from the selected city.")
    if not checks["state_matches"]:
        notes.append("The matched state differs from the selected state.")
    if not checks["postcode_matches"]:
        notes.append("The matched postcode differs from the entered postcode.")
    if not all(checks[key] for key in ("city_matches", "state_matches", "postcode_matches")):
        return "ambiguous", checks, notes
    return "approximate", checks, notes


#: Words that carry no locating information on their own. They appear in almost
#: every Malaysian address and in almost every Nominatim result, so accepting a
#: match because it contains one of them would accept anything.
_OSM_GENERIC_TOKENS = frozenset({
    "jalan", "jln", "lorong", "lrg", "taman", "tm", "persiaran", "psn",
    "lebuh", "lebuhraya", "off", "no", "nombor", "lot", "blok", "block",
    "tingkat", "aras", "unit", "bangunan", "menara", "kompleks", "pangsapuri",
    "apartment", "condominium", "the", "and", "dan",
})

#: Federal-territory spellings used by GADM/DOSM that Nominatim does not
#: recognise inside a free-text query. "W.P. Kuala Lumpur" in the query made the
#: fallback return nothing at all for every address in the capital, Putrajaya
#: and Labuan — the three areas where most listings are.
_QUERY_STATE_ALIASES = {
    "w.p. kuala lumpur": "Kuala Lumpur",
    "wp kuala lumpur": "Kuala Lumpur",
    "w.p. labuan": "Labuan",
    "wp labuan": "Labuan",
    "w.p. putrajaya": "Putrajaya",
    "wp putrajaya": "Putrajaya",
    "wilayah persekutuan kuala lumpur": "Kuala Lumpur",
    "wilayah persekutuan labuan": "Labuan",
    "wilayah persekutuan putrajaya": "Putrajaya",
}


def _query_state(state: str) -> str:
    """The state name as a geocoder should receive it."""
    cleaned = " ".join((state or "").split())
    return _QUERY_STATE_ALIASES.get(cleaned.casefold(), cleaned)


def _street_tokens(street: str) -> list[str]:
    """The distinctive words of a street line.

    Generic words and pure house numbers are dropped: they identify nothing.
    What remains is what the provider's answer must actually contain.
    """
    tokens = [
        token
        for token in _norm(street).replace(",", " ").split()
        if len(token) >= 3
        and token not in _OSM_GENERIC_TOKENS
        and not token.isdigit()
    ]
    return tokens


def _osm_result_names_street(street: str, place: dict) -> bool:
    """Whether the provider's answer actually names the street that was asked for.

    Nominatim fuzzes house and lot numbers: asking for ``Jalan SS2/24`` returned
    ``Jalan SS2/72`` — a different street several hundred metres away. Accepting
    that would place a listing, and therefore every one of its measurements, at
    the wrong address. City and state agree in both cases, so the component
    checks cannot catch it; only the street name can.

    A result is accepted when it contains every distinctive token of the street
    line. When the street has no distinctive token (an empty or numeric line)
    there is nothing to verify and the existing component checks stand.
    """
    tokens = _street_tokens(street)
    if not tokens:
        return True
    display = _norm(place.get("display_name"))
    return all(token in display for token in tokens)


def _osm_query_variants(
    address_line1: str,
    address_line2: str,
    city: str,
    state: str,
    postcode: str,
) -> list[str]:
    """Progressively simpler geocoder queries, most specific first.

    Every variant keeps the street line: dropping it would turn the lookup into
    a district search and return a centroid, which is exactly the fabricated
    location this pipeline must never store. Only redundant qualifiers are
    removed, because an over-specified query is the common reason a real street
    is not found at all.
    """
    street = " ".join(part.strip() for part in (address_line1, address_line2) if part and part.strip())
    road = _road_component(address_line1)
    state_q = _query_state(state)
    variants = [
        ", ".join(part for part in (street, postcode.strip(), city.strip(), state_q) if part),
        ", ".join(part for part in (road, city.strip(), state_q) if part)
        if road and _norm(road) != _norm(street)
        else "",
        ", ".join(part for part in (street, city.strip(), state_q) if part),
        ", ".join(part for part in (street, city.strip()) if part),
        ", ".join(part for part in (road, city.strip()) if part)
        if road and _norm(road) != _norm(street)
        else "",
    ]
    seen: list[str] = []
    for variant in variants:
        if variant and variant not in seen:
            seen.append(variant)
    return seen


def _road_component(address: str) -> str:
    """Return the comma-delimited road segment, excluding neighbourhood text."""
    road_prefixes = (
        "jalan ", "jln ", "lorong ", "lrg ", "persiaran ", "psn ",
        "lebuh ", "lebuhraya ",
    )
    for part in (item.strip() for item in (address or "").split(",")):
        normalized = _norm(part)
        if any(normalized.startswith(prefix) for prefix in road_prefixes):
            return part
    return address.strip()


def preview_address(
    *,
    address_line1: str,
    address_line2: str = "",
    city: str,
    state: str,
    postcode: str,
    force_refresh: bool = False,
) -> dict:
    """Resolve one typed address and classify the match. PERSISTS NOTHING."""
    address_hash = canonical_address_hash(
        address_line1, city, state, postcode, address_line2=address_line2
    )
    result: dict = {
        "address_hash": address_hash,
        "entered_address": {"street": address_line1, "city": city, "state": state, "postcode": postcode},
        "normalized_address": ", ".join(" ".join(part.split()) for part in
                                        (address_line1, address_line2, city, state, postcode) if part.strip()),
        "verified_at": None,
        "match_class": None,
        "provider": None,
        "status": None,
        "formatted_address": None,
        "latitude": None,
        "longitude": None,
        "precision": None,
        "components": {},
        "notes": [],
        "confirmation": None,
    }

    google_error: str | None = None
    try:
        verdict = av.validate_address(
            address_lines=[line for line in (address_line1, address_line2) if line and line.strip()],
            region_code="MY",
            locality=city or None,
            postal_code=postcode or None,
            administrative_area=state or None,
        )
    except av.AddressValidationRejected as exc:
        result.update(
            match_class="not_found",
            provider="google_address_validation",
            notes=[f"The address was rejected by the validator: {exc}"],
        )
        return result
    except av.AddressValidationUnavailable as exc:
        google_error = str(exc)
    else:
        match_class, checks, notes = _classify_google(
            verdict, city=city, state=state, postcode=postcode
        )
        result.update(
            match_class=match_class,
            provider="google_address_validation",
            status=verdict.get("status"),
            formatted_address=verdict.get("formatted_address"),
            latitude=verdict.get("latitude"),
            longitude=verdict.get("longitude"),
            precision=verdict.get("validation_granularity") or verdict.get("geocode_granularity"),
            components=checks,
            notes=notes,
        )
        return _attach_confirmation(result)

    # Google is not configured/enabled: keep the preview working through the
    # existing Malaysian fallback geocoder (rate-limited, MY-restricted).
    #
    # The query is tried from most to least specific, and every attempt keeps
    # the street line. An over-specified query is the common reason a real
    # street is not found, while a query without the street would return a
    # district centroid — a fabricated location this pipeline must never store.
    place = None
    rejected: list[str] = []
    unavailable: str | None = None
    road = _road_component(address_line1)
    for query in _osm_query_variants(address_line1, address_line2, city, state, postcode):
        try:
            candidate = lookup_malaysian_address(
                f"{query}, Malaysia", bypass_cache=force_refresh
            )
        except ValueError:
            candidate = None
        except GeocodingUnavailable as exc:
            unavailable = str(exc)
            break
        if candidate is None:
            continue
        if not _osm_result_names_street(road, candidate):
            rejected.append(
                "The fallback geocoder found a different street, so that location "
                "was not used. Check the street name and building number."
            )
            continue
        place = candidate
        break
    if place is None and unavailable is not None:
        result.update(
            match_class="service_unavailable",
            provider=None,
            notes=[
                note
                for note in (
                    _google_note(google_error),
                    unavailable,
                )
                if note
            ],
        )
        return result
    if place is None:
        result.update(
            match_class="not_found",
            provider="openstreetmap_nominatim",
            notes=[
                note
                for note in (
                    _google_note(google_error),
                    *dict.fromkeys(rejected),
                )
                if note
            ],
        )
        if not rejected:
            result["notes"].append(
                "The address could not be located. Check the street, building number and postcode."
            )
        return result
    match_class, checks, notes = _classify_osm(
        place, city=city, state=state, postcode=postcode
    )
    if google_error:
        notes.append(_google_note(google_error))
    notes.append(
        "Located by OpenStreetMap. This is an approximate address match; check the map before saving."
    )
    result.update(
        match_class=match_class,
        provider=place.get("source") or "openstreetmap_nominatim",
        status="partially_validated",
        formatted_address=place.get("display_name"),
        latitude=place.get("latitude"),
        longitude=place.get("longitude"),
        precision=place.get("accuracy"),
        components=checks,
        notes=notes,
    )
    return _attach_confirmation(result)


def _attach_confirmation(result: dict) -> dict:
    eligible = (
        result.get("match_class") in ("precise", "approximate", "ambiguous")
        and result.get("latitude") is not None
        and result.get("longitude") is not None
        and bool(result.get("formatted_address"))
    )
    if not eligible:
        return result
    if result["match_class"] == "precise":
        result["verified_at"] = datetime.now(UTC).isoformat()
    result["confirmation"] = {
        "token": issue_confirmation_token(
            address_hash=result["address_hash"],
            match_class=result["match_class"],
            status=result.get("status") or "partially_validated",
            formatted_address=result["formatted_address"],
            latitude=result["latitude"],
            longitude=result["longitude"],
            provider=result["provider"] or "unknown",
        ),
        "expires_in_seconds": CONFIRMATION_TOKEN_TTL_SECONDS,
        "address_hash": result["address_hash"],
    }
    return result
