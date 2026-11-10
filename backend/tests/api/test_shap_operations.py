"""Layer 3 SHAP operational verification: caching, invalidation, latency.

The correctness contract (Permutation SHAP over the exact 47-feature
contract, baseline + sum(contributions) == score within 1e-6, real 25-row
background) is covered by the existing suites. This module verifies the
operational requirements:

* the process-wide verified-SHAP cache returns the identical payload on the
  second call with the model version in the key (safe invalidation when the
  artifact is replaced);
* measured first-call vs cached-call latency is recorded to
  ``ml_reference/recommender_eval/shap_latency.json`` so the documentation
  reports measured numbers, not claims.

Explanation generation stays strictly on-demand (GET .../explanation);
ranking never blocks on SHAP.
"""
from __future__ import annotations

import json
import time
import uuid
from pathlib import Path

import pytest

from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.selected_pu_integration import SELECTED_MODEL_NAME
from sitewise.services.recommendation_generation_service import (
    RecommendationGenerationService,
    _SHAP_CACHE,
    _SHAP_CACHE_LOCK,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

BACKEND_DIR = Path(__file__).resolve().parents[2]
EVAL_DIR = BACKEND_DIR / "ml_reference" / "recommender_eval"
REFERENCE_PROPERTY_ID = "MD-00510"


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def identity(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(sub=sub, email=f"shap-lat-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "user_id": uuid.UUID(sub)}


@pytest.fixture(autouse=True)
def _clean_cache():
    with _SHAP_CACHE_LOCK:
        _SHAP_CACHE.clear()
    yield
    with _SHAP_CACHE_LOCK:
        _SHAP_CACHE.clear()


@pytest.mark.slow
def test_shap_cache_is_version_keyed_and_latency_is_measured(client, identity):
    loaded = ModelLoader().load(SELECTED_MODEL_NAME)
    version = loaded.meta.get("model_version")

    generated = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 1, "property_ids": [REFERENCE_PROPERTY_ID]},
        headers=auth(identity["token"]),
    )
    assert generated.status_code == 200, generated.text
    body = generated.json()
    assert body["status"] == "ok", body["candidate_summary"]
    result_id = body["results"][0]["result_id"]
    url = f"/api/v1/recommendations/{result_id}/explanation"

    t0 = time.perf_counter()
    first = client.get(url, headers=auth(identity["token"]))
    first_latency = time.perf_counter() - t0
    assert first.status_code == 200, first.text
    shap = first.json()["explanation"]["shap"]
    assert shap is not None, first.json()["explanation"]["shap_status"]

    t1 = time.perf_counter()
    second = client.get(url, headers=auth(identity["token"]))
    cached_latency = time.perf_counter() - t1
    assert second.status_code == 200
    cached = second.json()["explanation"]["shap"]
    assert cached == shap

    # The cache key must embed the model version: replacing the artifact
    # invalidates every cached explanation.
    with _SHAP_CACHE_LOCK:
        keys = list(_SHAP_CACHE.keys())
    assert keys and all(str(version) in key for key in keys), keys

    # Cached reads must be materially faster than the first SHAP computation.
    assert cached_latency < max(first_latency / 5.0, 0.05)

    EVAL_DIR.mkdir(parents=True, exist_ok=True)
    (EVAL_DIR / "shap_latency.json").write_text(
        json.dumps(
            {
                "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "property_id": REFERENCE_PROPERTY_ID,
                "model_version": version,
                "first_call_seconds": round(first_latency, 4),
                "cached_call_seconds": round(cached_latency, 4),
                "note": (
                    "First call = live Permutation SHAP over 47 features with "
                    "the real 25-row background; cached call = process-wide "
                    "verified-SHAP cache hit. Results are durable per user "
                    "via recommendation_result.shap."
                ),
            },
            indent=2,
        ),
        encoding="utf-8",
    )


def test_ranking_does_not_block_on_shap(client, identity):
    """Generation completes without resolving SHAP at all."""
    started = time.perf_counter()
    generated = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 3},
        headers=auth(identity["token"]),
    )
    elapsed = time.perf_counter() - started
    assert generated.status_code == 200, generated.text
    assert all(r["explanation"]["shap"] is None for r in generated.json()["results"])
    assert elapsed < 60  # the catalogue scan dominates; no SHAP inside
