"""SiteWise web location geocoder: no provider requests for cached addresses."""
from sitewise.services import nearby_location_geocoding as geo
import pytest


def test_invalid_or_empty_address_fails_without_network():
    with pytest.raises(ValueError):
        geo.lookup_malaysian_address('abc')
    with pytest.raises(ValueError):
        geo.lookup_malaysian_address('x' * 201)


def test_cached_coordinates_are_reused(monkeypatch):
    key = 'taman test demo, selangor'
    monkeypatch.setitem(geo._cache, key, (geo.time.monotonic() + 300, {
        'latitude': 3.0, 'longitude': 101.0, 'source': 'openstreetmap_nominatim',
    }))
    def should_not_run(*args, **kwargs):
        raise AssertionError('Geocoder should have returned its cached result')
    monkeypatch.setattr(geo.httpx, 'get', should_not_run)
    out = geo.lookup_malaysian_address(' Taman Test Demo,  Selangor ')
    assert out['latitude'] == 3.0
    assert out['longitude'] == 101.0
