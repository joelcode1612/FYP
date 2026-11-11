"""Address validation tests — provider is always mocked.

No billable Google request is made in this suite: ``httpx.post`` is patched,
so the tests verify our adapter's verdict mapping and error semantics only.
"""

import uuid

import httpx
import pytest

from sitewise.core.config import settings
from sitewise.services import address_validation_service as avs
from tests.conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def owner_token(client, cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    token = make_token(sub=str(sub), email=f"av-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}")
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    return token


class _FakeResponse:
    def __init__(self, status_code: int, payload: dict | None = None, text: str = ""):
        self.status_code = status_code
        self._payload = payload or {}
        self.text = text

    def json(self):
        return self._payload


def _success_payload() -> dict:
    return {
        "responseId": "req-123",
        "result": {
            "verdict": {
                "validationGranularity": "PREMISE",
                "geocodeGranularity": "PREMISE",
                "addressComplete": True,
                "hasUnconfirmedComponents": False,
                "hasInferredComponents": False,
            },
            "address": {"formattedAddress": "1, Jalan SS15/4, 47500 Subang Jaya, Selangor, Malaysia"},
            "geocode": {"location": {"latitude": 3.0733, "longitude": 101.5866}},
            "addressComponents": [
                {"componentType": "postal_code", "text": "47500"},
                {"componentType": "locality", "text": "Subang Jaya"},
            ],
        },
    }


@pytest.fixture()
def with_key(monkeypatch):
    monkeypatch.setattr(settings, "google_maps_api_key", "test-key", raising=False)


def test_validate_maps_a_complete_verdict(monkeypatch, with_key):
    monkeypatch.setattr(avs.httpx, "post", lambda *a, **k: _FakeResponse(200, _success_payload()))
    result = avs.validate_address(address_lines=["1 Jalan SS15/4, 47500 Subang Jaya"])
    assert result["status"] == "validated"
    assert result["formatted_address"].startswith("1, Jalan SS15/4")
    assert result["latitude"] == 3.0733
    assert result["postal_code"] == "47500"
    assert result["scope"] == "address_only"
    assert result["provider"] == "google_address_validation"


def test_validate_reports_partial_and_unconfirmed(monkeypatch, with_key):
    partial = _success_payload()
    partial["result"]["verdict"]["hasUnconfirmedComponents"] = True
    monkeypatch.setattr(avs.httpx, "post", lambda *a, **k: _FakeResponse(200, partial))
    assert avs.validate_address(address_lines=["Jalan SS15"])["status"] == "partially_validated"

    # Google's OTHER = "valid but imprecise": locatable, never confirmed.
    coarse = _success_payload()
    coarse["result"]["verdict"]["validationGranularity"] = "OTHER"
    coarse["result"]["verdict"]["geocodeGranularity"] = "OTHER"
    monkeypatch.setattr(avs.httpx, "post", lambda *a, **k: _FakeResponse(200, coarse))
    assert avs.validate_address(address_lines=["Somewhere"])["status"] == "partially_validated"

    unconfirmed = _success_payload()
    unconfirmed["result"]["verdict"]["validationGranularity"] = None
    unconfirmed["result"]["verdict"]["addressComplete"] = False
    unconfirmed["result"]["geocode"] = {}
    monkeypatch.setattr(avs.httpx, "post", lambda *a, **k: _FakeResponse(200, unconfirmed))
    result = avs.validate_address(address_lines=["Somewhere"])
    assert result["status"] == "unconfirmed"
    assert result["latitude"] is None


def test_permission_denied_is_reported_as_unavailable(monkeypatch, with_key):
    monkeypatch.setattr(
        avs.httpx, "post",
        lambda *a, **k: _FakeResponse(403, {"error": {"status": "PERMISSION_DENIED"}}),
    )
    with pytest.raises(avs.AddressValidationUnavailable) as exc:
        avs.validate_address(address_lines=["1 Jalan SS15/4"])
    assert "not enabled" in str(exc.value)


def test_transport_failure_is_unavailable(monkeypatch, with_key):
    def boom(*a, **k):
        raise httpx.ConnectTimeout("timed out")

    monkeypatch.setattr(avs.httpx, "post", boom)
    with pytest.raises(avs.AddressValidationUnavailable):
        avs.validate_address(address_lines=["1 Jalan SS15/4"])


def test_provider_bad_request_is_rejected(monkeypatch, with_key):
    monkeypatch.setattr(
        avs.httpx, "post",
        lambda *a, **k: _FakeResponse(400, {"error": {"message": "Invalid address lines"}}),
    )
    with pytest.raises(avs.AddressValidationRejected):
        avs.validate_address(address_lines=["x"])


def test_missing_key_fails_closed(monkeypatch):
    monkeypatch.setattr(settings, "google_maps_api_key", "", raising=False)
    with pytest.raises(avs.AddressValidationUnavailable) as exc:
        avs.validate_address(address_lines=["1 Jalan SS15/4"])
    assert "not configured" in str(exc.value)


def test_endpoint_returns_the_verdict(client, owner_token, monkeypatch, with_key):
    monkeypatch.setattr(avs.httpx, "post", lambda *a, **k: _FakeResponse(200, _success_payload()))
    response = client.post(
        "/api/v1/properties/validate-address",
        headers=auth(owner_token),
        json={
            "address_lines": ["1 Jalan SS15/4", "47500 Subang Jaya"],
            "city": "Subang Jaya",
            "state": "Selangor",
            "postcode": "47500",
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["data"]["status"] == "validated"
    assert body["meta"]["verification_status_unchanged"] is True
    assert "does not verify ownership" in body["meta"]["note"]


def test_endpoint_maps_provider_outage_to_503(client, owner_token, monkeypatch, with_key):
    monkeypatch.setattr(
        avs.httpx, "post",
        lambda *a, **k: _FakeResponse(403, {"error": {"status": "PERMISSION_DENIED"}}),
    )
    response = client.post(
        "/api/v1/properties/validate-address",
        headers=auth(owner_token),
        json={"address_lines": ["1 Jalan SS15/4"]},
    )
    assert response.status_code == 503
    detail = response.json()["detail"]
    assert detail["code"] == "address_validation_unavailable"
    assert "not enabled" in detail["message"]


def test_endpoint_requires_auth(client, monkeypatch, with_key):
    monkeypatch.setattr(avs.httpx, "post", lambda *a, **k: _FakeResponse(200, _success_payload()))
    response = client.post(
        "/api/v1/properties/validate-address",
        json={"address_lines": ["1 Jalan SS15/4"]},
    )
    assert response.status_code == 401


def test_endpoint_rejects_empty_lines(client, owner_token, monkeypatch, with_key):
    response = client.post(
        "/api/v1/properties/validate-address",
        headers=auth(owner_token),
        json={"address_lines": ["   "]},
    )
    assert response.status_code == 422
