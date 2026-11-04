import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from fastapi.testclient import TestClient
from sitewise.main import app


def test_health():
    client = TestClient(app)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_openapi():
    client = TestClient(app)
    resp = client.get("/openapi.json")
    assert resp.status_code == 200
    assert "/api/v1/properties/" in resp.json()["paths"]
