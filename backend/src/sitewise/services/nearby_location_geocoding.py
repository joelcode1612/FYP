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


def lookup_malaysian_address(address: str) -> dict | None:
    """Resolve one submitted address; never runs on typing/autocomplete.

    Returns None if the provider found no Malaysian result. Coordinates are
    approximate and must be confirmed by the user on the map.
    """
    key = ' '.join(address.split()).casefold()
    if len(key) < 5 or len(key) > 200:
        raise ValueError('Address must contain 5–200 characters.')
    global _last_request
    with _lock:
        hit = _cache.get(key)
        if hit and time.monotonic() < hit[0]:
            return hit[1]
        if len(_cache) >= 256:
            _cache.clear()
        # Serialize lookups to respect the OSM public-service limit. One lock
        # across processes is NOT enough for multi-worker production.
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
            response.raise_for_status()
            places = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise GeocodingUnavailable('Address lookup is currently unavailable.') from exc
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
        _cache[key] = (time.monotonic() + 86400, result)
        return result
