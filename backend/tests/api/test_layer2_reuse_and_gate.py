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


def test_training_gate_refuses_and_writes_no_artifact(tmp_path):
    """The label inventory on this deployment cannot support training.

    The trainer is a subprocess, so its output directory is redirected with
    ``SITEWISE_ML_EVAL_DIR``. The tracked historical artifact under
    ``ml_reference/recommender_eval/`` must come out byte-identical: a test run
    against disposable data must never rewrite reference numbers.
    """
    import hashlib
    import json
    import os
    import subprocess
    import sys

    tracked_report = EVAL_DIR / "model_selection_report.json"
    before = (
        hashlib.sha256(tracked_report.read_bytes()).hexdigest()
        if tracked_report.is_file()
        else None
    )

    eval_dir = tmp_path / "recommender_eval"
    env = dict(os.environ)
    env["SITEWISE_ML_EVAL_DIR"] = str(eval_dir)

    result = subprocess.run(
        [
            sys.executable,
            str(BACKEND_DIR / "scripts" / "ml" / "train_personalised_recommender.py"),
        ],
        capture_output=True,
        text=True,
        timeout=300,
        cwd=str(BACKEND_DIR),
        env=env,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "REFUSING to train" in result.stderr

    report_path = eval_dir / "model_selection_report.json"
    assert report_path.is_file(), "the run must write its report to the redirected directory"
    report = json.loads(report_path.read_text(encoding="utf-8"))
    assert report["decision"] == "refuse_to_train"
    assert report["blockers"], "the report must name the exact missing data"
    assert any("positives" in b for b in report["blockers"])

    after = (
        hashlib.sha256(tracked_report.read_bytes()).hexdigest()
        if tracked_report.is_file()
        else None
    )
    assert after == before, (
        "the tracked reference artifact was rewritten by a disposable test run: "
        f"{tracked_report}"
    )

    # No NEW trained artifact may be fabricated. ``recommender_v3.joblib`` is a
    # legitimate committed artifact (7a5c07b, 47-feature PU / Recommender V3),
    # so the check is "on-disk set == git-tracked set", not "no joblib exists".
    # The old blanket glob started failing ~18h after it was written, when that
    # artifact was committed, and would have tempted someone to delete a real
    # model to get green.
    ml_dir = BACKEND_DIR / "src" / "sitewise" / "ml"
    on_disk = sorted(p.name for p in ml_dir.glob("recommender*.joblib"))
    tracked = sorted(
        name
        for name in subprocess.run(
            ["git", "ls-files", "--", str(ml_dir.relative_to(BACKEND_DIR))],
            cwd=str(BACKEND_DIR),
            capture_output=True,
            text=True,
            check=True,
        ).stdout.splitlines()
        if name.rsplit("/", 1)[-1].startswith("recommender") and name.endswith(".joblib")
    )
    tracked = sorted(path.rsplit("/", 1)[-1] for path in tracked)
    assert on_disk == tracked, (
        "the trainer fabricated an artifact that git does not track: "
        f"on_disk={on_disk} tracked={tracked}"
    )
