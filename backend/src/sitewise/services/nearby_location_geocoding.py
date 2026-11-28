"""One-shot Malaysian address geocoding for explicit user searches.

Public OSM Nominatim is appropriate for modest FYP traffic only: no live
autocomplete, serialized <=1 request/second/process, 24-hour result cache,
and a project-identifying User-Agent. Replace with a managed provider or
central shared rate limiter before a multi-worker/public deployment.
"""
from __future__ import annotations

import threading
import time
import httpx

_URL = 'https://nominatim.openstreetmap.org/search'
_HEADERS = {'User-Agent': 'SiteWise-FYP-Research/1.0 (https://github.com/joelcode1612/FYP)', 'Accept': 'application/json'}
_lock = threading.Lock()
_cache: dict[str, tuple[float, dict | None]] = {}
_last_request = 0.0


class GeocodingUnavailable(RuntimeError):
    """The geocoding provider did not answer reliably."""


#: Transient failures are retried, because a timeout or a 429 from a public
#: service is usually momentary and losing the lookup forces the owner to retype
#: a perfectly valid address. A malformed query (4xx other than 429) is NOT
#: retried: repeating it would only produce the same rejection three times.
_MAX_ATTEMPTS = 3
_RETRY_BACKOFF_SECONDS = (0.6, 1.8)


def lookup_malaysian_address(
    address: str, *, bypass_cache: bool = False
) -> dict | None:
    """Resolve one submitted address; never runs on typing/autocomplete.

    Returns None if the provider found no Malaysian result. Coordinates are
    approximate and must be confirmed by the user on the map.

    Transient failures (transport errors, timeouts, 429 and 5xx) are retried up
    to :data:`_MAX_ATTEMPTS` times with a short backoff. Nothing is cached on a
    failure, so a later call retries instead of replaying the error.
    """
    key = ' '.join(address.split()).casefold()
    if len(key) < 5 or len(key) > 200:
        raise ValueError('Address must contain 5–200 characters.')
    global _last_request
    with _lock:
        hit = _cache.get(key)
        if not bypass_cache and hit and time.monotonic() < hit[0]:
            return hit[1]
        if len(_cache) >= 256:
            _cache.clear()

        places = None
        last_error: Exception | None = None
        for attempt in range(_MAX_ATTEMPTS):
            # Serialize lookups to respect the OSM public-service limit. One
            # lock across processes is NOT enough for multi-worker production.
            gap = time.monotonic() - _last_request
            if gap < 1.1:
                time.sleep(1.1 - gap)
            _last_request = time.monotonic()
            try:
                response = httpx.get(
                    _URL,
                    params={'q': address, 'format': 'jsonv2', 'limit': 1, 'countrycodes': 'my'},
                    headers=_HEADERS,
                    timeout=12,
                    follow_redirects=False,
                )
            except httpx.HTTPError as exc:  # timeout, DNS, reset
                last_error = exc
            else:
                status = response.status_code
                if status == 429 or status >= 500:
                    last_error = httpx.HTTPStatusError(
                        f'provider returned {status}', request=response.request,
                        response=response,
                    )
                elif status >= 400:
                    # The query itself was refused; retrying cannot help.
                    raise GeocodingUnavailable(
                        'Address lookup is currently unavailable.'
                    ) from httpx.HTTPStatusError(
                        f'provider returned {status}', request=response.request,
                        response=response,
                    )
                else:
                    try:
                        places = response.json()
                    except ValueError as exc:
                        last_error = exc
                    else:
                        last_error = None
                        break
            if attempt + 1 < _MAX_ATTEMPTS:
                time.sleep(_RETRY_BACKOFF_SECONDS[
                    min(attempt, len(_RETRY_BACKOFF_SECONDS) - 1)
                ])

        if last_error is not None:
            raise GeocodingUnavailable(
                'Address lookup is currently unavailable.'
            ) from last_error
        if not isinstance(places, list):
            raise GeocodingUnavailable('Address lookup returned an unexpected response.')
        result = None
        if places:
            place = places[0]
            try:
                lat, lon = float(place['lat']), float(place['lon'])
                if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                    raise ValueError('out of range')
            except (TypeError, KeyError, ValueError) as exc:
                raise GeocodingUnavailable('Address lookup returned invalid coordinates.') from exc
            result = {
                'latitude': lat,
                'longitude': lon,
                'display_name': str(place.get('display_name') or address),
                'source': 'openstreetmap_nominatim',
                'accuracy': 'approximate',
            }
        # Don't keep a no-result response: a later explicit retry should ask
        # Nominatim again in case its index has changed or recovered.
        if result is not None:
            _cache[key] = (time.monotonic() + 86400, result)
        else:
            _cache.pop(key, None)
        return result
