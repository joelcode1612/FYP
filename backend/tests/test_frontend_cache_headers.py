"""Regression guard for the fixed-filename bundle cache bug.

``jaspr build`` always writes ``main.client.dart.js``. Without a revalidation
header the browser kept the previous bundle after a rebuild, so a shipped fix
appeared not to take effect — the SPA shell reloaded but ran the old code.
These tests pin the headers that make that impossible.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from sitewise.frontend import mount_frontend


@pytest.fixture()
def client(tmp_path: Path) -> TestClient:
    (tmp_path / "index.html").write_text(
        "<!doctype html><title>app</title>", encoding="utf-8"
    )
    (tmp_path / "main.client.dart.js").write_text(
        "console.log('bundle');", encoding="utf-8"
    )
    app = FastAPI()
    assert mount_frontend(app, tmp_path) is True
    return TestClient(app)


def test_bundle_is_revalidated_rather_than_served_stale(client: TestClient) -> None:
    response = client.get("/main.client.dart.js")

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-cache"
    # Revalidation is only cheap because FileResponse supplies a validator.
    assert response.headers.get("etag")


def test_spa_fallback_is_never_cached(client: TestClient) -> None:
    response = client.get("/entrepreneur/recommendations")

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"


def test_missing_asset_still_answers_404(client: TestClient) -> None:
    assert client.get("/assets/nope.png").status_code == 404


def test_api_shaped_path_never_receives_html(client: TestClient) -> None:
    response = client.get("/api/v1/nope")

    assert response.status_code == 404
    assert response.headers["content-type"].startswith("application/json")
