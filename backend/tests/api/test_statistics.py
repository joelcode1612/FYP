import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "src"))

from fastapi.testclient import TestClient

from sitewise.main import app


def test_statistics_districts_is_reachable():
    client = TestClient(app)
    resp = client.get("/api/v1/statistics/districts")
    # 200 = analytics DB reachable and returned data; 404/500 would indicate a
    # misconfiguration of the analytics connection.
    assert resp.status_code == 200
    assert isinstance(resp.json(), list)
