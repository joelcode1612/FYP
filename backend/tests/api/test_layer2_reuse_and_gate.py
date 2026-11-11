"""Phase 3 verification: unchanged-input reuse and the honest training gate.

* ``generate`` skips the whole catalogue scan + scoring pass when nothing
  that can change the output changed (preference profile, request filters,
  scoring config version) and returns the stored batch with
  ``reused_existing_batch: true``; any change regenerates.
* ``scripts/ml/train_personalised_recommender.py`` REFUSES to train on this
  deployment's real (empty) label inventory: exit code 2, no artifact, and a
  report naming exactly which data is missing. The rule-based engine stays.
"""
from __future__ import annotations

import uuid
from pathlib import Path

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

BACKEND_DIR = Path(__file__).resolve().parents[2]
EVAL_DIR = BACKEND_DIR / "ml_reference" / "recommender_eval"


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(autouse=True)
def cleanup_preferences(cleanup_users):
    """Remove preference rows before the dependent user rows are deleted."""
    yield
    if not cleanup_users:
        return
    with Session(engine) as session:
        session.execute(
            text("DELETE FROM entrepreneur_preferences WHERE user_id = ANY(:ids)"),
            {"ids": list(cleanup_users)},
        )
        session.commit()


def _identity(client, cleanup_users, prefix: str):
    sub = str(uuid.uuid4())
    token = make_token(sub=sub, email=f"{prefix}-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    return {"token": token, "user_id": register_user_id(cleanup_users, uuid.UUID(sub))}


def test_unchanged_inputs_reuse_the_stored_batch(client, cleanup_users):
    identity = _identity(client, cleanup_users, "reuse")
    first = client.post(
        "/api/v1/recommendations/generate", json={"limit": 3}, headers=auth(identity["token"])
    )
    assert first.status_code == 200, first.text
    body = first.json()
    assert body["status"] == "ok"
    assert body["reused_existing_batch"] is False

    second = client.post(
        "/api/v1/recommendations/generate", json={"limit": 3}, headers=auth(identity["token"])
    )
    assert second.status_code == 200, second.text
    reused = second.json()
    assert reused["reused_existing_batch"] is True
    assert reused["batch_id"] == body["batch_id"]
    assert [r["result_id"] for r in reused["results"]] == [
        r["result_id"] for r in body["results"]
    ]


def test_changed_inputs_regenerate(client, cleanup_users):
    identity = _identity(client, cleanup_users, "regen")
    first = client.post(
        "/api/v1/recommendations/generate", json={"limit": 3}, headers=auth(identity["token"])
    )
    assert first.status_code == 200, first.text
    assert first.json()["reused_existing_batch"] is False

    # A different limit changes the output contract -> regenerate.
    second = client.post(
        "/api/v1/recommendations/generate", json={"limit": 5}, headers=auth(identity["token"])
    )
    assert second.status_code == 200, second.text
    body = second.json()
    assert body["reused_existing_batch"] is False
    assert body["batch_id"] != first.json()["batch_id"]

    # Saved preferences change the profile -> regenerate.
    saved = client.patch(
        "/api/v1/preferences/me",
        json={
            "preferences": {
                "fnb_concept": "cafe_coffee_shop",
                "service_model": "dine_in",
                "recommendation_priority": "favorable_competition",
                "target_price_segment": "mid_range",
                "customer_access_mode": "walking",
                "target_customers": ["office_workers", "nearby_residents"],
                "max_monthly_rent_myr": 2500,
                "min_floor_area_sqft": 300,
                "requirements_version": 2,
            }
        },
        headers=auth(identity["token"]),
    )
    assert saved.status_code == 200, saved.text
    third = client.post(
        "/api/v1/recommendations/generate", json={"limit": 5}, headers=auth(identity["token"])
    )
    assert third.status_code == 200, third.text
    assert third.json()["reused_existing_batch"] is False


def test_training_gate_refuses_and_writes_no_artifact():
    """The label inventory on this deployment cannot support training."""
    import subprocess
    import sys

    result = subprocess.run(
        [
            sys.executable,
            str(BACKEND_DIR / "scripts" / "ml" / "train_personalised_recommender.py"),
        ],
        capture_output=True,
        text=True,
        timeout=300,
        cwd=str(BACKEND_DIR),
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "REFUSING to train" in result.stderr

    report_path = EVAL_DIR / "model_selection_report.json"
    assert report_path.is_file()
    import json

    report = json.loads(report_path.read_text(encoding="utf-8"))
    assert report["decision"] == "refuse_to_train"
    assert report["blockers"], "the report must name the exact missing data"
    assert any("positives" in b for b in report["blockers"])

    # No trained artifact may exist anywhere in the ml package.
    artifacts = [
        p for p in (BACKEND_DIR / "src" / "sitewise" / "ml").glob("recommender*.joblib")
    ]
    assert artifacts == [], "no trained recommender may be fabricated"
