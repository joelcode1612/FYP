"""Offline tests. Live Supabase authentication/storage checks are still required."""
from sitewise.services.public_panorama_bridge import is_safe_panorama_path


def test_safe_path():
    assert is_safe_panorama_path("properties/19/sessions/sphere-xyz/panorama.jpg",
                                property_id=19, session_id="sphere-xyz")


def test_wrong_property_rejected():
    assert not is_safe_panorama_path("properties/18/sessions/sphere-xyz/panorama.jpg",
                                    property_id=19, session_id="sphere-xyz")


def test_traversal_rejected():
    assert not is_safe_panorama_path("properties/19/sessions/../panorama.jpg",
                                    property_id=19, session_id="..")


def test_prefix_path_rejected():
    assert not is_safe_panorama_path("properties/19/sessions/sphere-xyz/frames/1.jpg",
                                    property_id=19, session_id="sphere-xyz")


def _bridge(monkeypatch, response):
    """Use a fake Supabase endpoint; never contact a real project in tests."""
    from types import SimpleNamespace

    import httpx
    import sitewise.services.public_panorama_bridge as module

    monkeypatch.setattr(module, "settings", SimpleNamespace(
        supabase_url="https://test.supabase.co", supabase_secret_key="server-only-test",
    ))
    return module.PublicPanoramaBridge(
        httpx.Client(transport=httpx.MockTransport(lambda request: response(request)))
    )


def test_unapproved_job_cannot_be_published(monkeypatch):
    import pytest
    import httpx
    from fastapi import HTTPException

    with _bridge(monkeypatch, lambda _: httpx.Response(500)) as bridge:
        with pytest.raises(HTTPException) as err:
            bridge.change_publication({
                "id": "pano_sphere-1", "status": "done",
                "verification_status": "pending", "published_tour_id": None,
            }, publish=True, published_url="/entrepreneur/property-detail?id=1")
        assert err.value.status_code == 409


def test_storage_path_is_validated_before_signing(monkeypatch):
    import pytest
    import httpx
    from fastapi import HTTPException

    with _bridge(monkeypatch, lambda _: httpx.Response(500)) as bridge:
        with pytest.raises(HTTPException) as err:
            bridge.sign({
                "property_id": 1, "session_id": "sphere-1",
                "panorama_path": "properties/2/sessions/sphere-1/panorama.jpg",
            })
        assert err.value.status_code == 409


def test_signed_url_has_exact_configured_supabase_host(monkeypatch):
    import httpx

    def answer(request):
        assert request.method == "POST"
        assert request.headers["authorization"] == "Bearer server-only-test"
        return httpx.Response(200, json={
            "signedURL": "/object/sign/property-panoramas/properties/1/"
                         "sessions/sphere-1/panorama.jpg?token=short-lived",
        })

    with _bridge(monkeypatch, answer) as bridge:
        url = bridge.sign({
            "property_id": 1, "session_id": "sphere-1",
            "panorama_path": "properties/1/sessions/sphere-1/panorama.jpg",
        })
        assert url.startswith("https://test.supabase.co/storage/v1/object/sign/")


def test_arbitrary_signed_host_is_rejected(monkeypatch):
    import pytest
    import httpx
    from fastapi import HTTPException

    with _bridge(monkeypatch, lambda _: httpx.Response(
        200, json={"signedURL": "https://evil.example.com/view?token=leak"}
    )) as bridge:
        with pytest.raises(HTTPException) as err:
            bridge.sign({
                "property_id": 1, "session_id": "sphere-1",
                "panorama_path": "properties/1/sessions/sphere-1/panorama.jpg",
            })
        assert err.value.status_code == 502


def test_already_published_job_is_idempotent(monkeypatch):
    import httpx

    record = {"id": "pano_sphere-1", "status": "done",
              "verification_status": "approved", "published_tour_id": "existing"}
    with _bridge(monkeypatch, lambda _: httpx.Response(500)) as bridge:
        assert bridge.change_publication(record, publish=True) is record


def test_new_supabase_secret_is_not_sent_as_bearer(monkeypatch):
    from types import SimpleNamespace
    import httpx
    import sitewise.services.public_panorama_bridge as module

    monkeypatch.setattr(module, "settings", SimpleNamespace(
        supabase_url="https://test.supabase.co", supabase_secret_key="sb_secret_testing",
    ))
    def answer(request):
        assert request.headers["apikey"] == "sb_secret_testing"
        assert "authorization" not in request.headers
        return httpx.Response(200, json={"signedURL": "/object/sign/foo?token=x"})
    with module.PublicPanoramaBridge(
        httpx.Client(transport=httpx.MockTransport(answer))
    ) as bridge:
        assert bridge.sign({
            "property_id": 1, "session_id": "sphere-1",
            "panorama_path": "properties/1/sessions/sphere-1/panorama.jpg",
        }).startswith("https://test.supabase.co/")
