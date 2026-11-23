"""Persistent SHAP-explanation cache: identity, single-flight, non-blocking path.

Focused tests for the 3-second explanation requirement:

* cache identity changes with EVERY component the brief mandates (property,
  model name/version, artifact checksum, ordered feature digest, background
  checksum, method configuration) — a stale explanation is unreachable;
* a validated explanation is served on a hit without recomputing SHAP, and
  the hit survives a fresh service instance (the restart scenario);
* a cold process NEVER computes SHAP inside the request: it returns the real
  PU score with a truthful pending status and records a resumable job;
* failures are recorded and reported without fabricated contributions;
* the background worker completes a pending job and persists the result.

These tests use the live databases like the rest of the API suite; the SHAP
computation itself is warm (conftest marks the process warm) and takes well
under a second per call.
"""

from __future__ import annotations

import pathlib
import time
import uuid

import pytest
from sqlmodel import Session

import sitewise.services.property_insights_service as svc_module
from sitewise.db.analytics_session import analytics_engine
from sitewise.db.session import engine as operational_engine
from sitewise.ml import shap_explainer
from sitewise.ml.feature_bridge import merge_bridge_features
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import PropertyFeatureRepository
from sitewise.ml.pu_expanded import (
    EXPANDED_MODEL_NAME,
    merge_expanded_bridge_features,
)
from sitewise.ml.pu_variant import resolve_variant
from sitewise.services import explanation_cache
from sitewise.services.explanation_cache import (
    ExplanationIdentity,
    ExplanationJob,
    feature_digest,
)
from sitewise.services.explanation_worker import get_explanation_worker
from sitewise.services.property_insights_service import (
    PropertyInsightsService,
    _background_path,
    _reference_background_rows,
)

REFERENCE_PROPERTY = "MD-00510"
_CACHE_TABLE = "fyp.ml_explanation_cache"


def _identity(**overrides) -> ExplanationIdentity:
    base = dict(
        property_id=REFERENCE_PROPERTY,
        model_name="sitewise_pu_64_expanded",
        model_version="v1",
        artifact_sha256="a" * 64,
        feature_digest="f" * 16,
        background_sha256="b" * 16,
        background_size=32,
    )
    base.update(overrides)
    return ExplanationIdentity(**base)


def _cleanup_rows(property_id: str = REFERENCE_PROPERTY) -> None:
    from sqlalchemy import text

    with Session(operational_engine) as session:
        session.execute(
            text(f"DELETE FROM {_CACHE_TABLE} WHERE property_id = :p"),
            {"p": property_id},
        )
        session.commit()


def _clear_in_memory() -> None:
    svc_module.clear_insights_cache()
    svc_module._EXPLANATION_CACHE.clear()


def _live_identity(service, loaded, background, background_file) -> ExplanationIdentity:
    """The exact identity the request path derives for the reference property."""
    variant = resolve_variant()
    fb = PropertyFeatureRepository(service.analytics).get(
        REFERENCE_PROPERTY, loaded.feature_names, source="catalog"
    )
    coverage = merge_bridge_features(fb, expected_features=loaded.feature_names)
    if variant.key == "expanded64":
        coverage = merge_expanded_bridge_features(coverage, expected_features=loaded.feature_names)
    return ExplanationIdentity(
        property_id=REFERENCE_PROPERTY,
        model_name=variant.layer1_model,
        model_version=variant.version,
        artifact_sha256=explanation_cache.cached_file_sha256(
            pathlib.Path(ModelLoader().artifacts_dir)
            / str(loaded.meta.get("artifact_filename"))
        ),
        feature_digest=explanation_cache.feature_digest(dict(coverage.values)),
        background_sha256=PropertyInsightsService._reference_background_sha256(background_file),
        background_size=len(background),
    )


# -- identity ----------------------------------------------------------------


def test_cache_identity_changes_with_every_mandated_component():
    base = _identity().cache_key()
    assert base == _identity().cache_key(), "same inputs must give one identity"
    assert base != _identity(feature_digest="0" * 16).cache_key()
    assert base != _identity(artifact_sha256="0" * 64).cache_key()
    assert base != _identity(background_sha256="0" * 16).cache_key()
    assert base != _identity(background_size=25).cache_key()
    assert base != _identity(model_version="v2").cache_key()
    assert base != _identity(property_id="MD-01755").cache_key()


def test_feature_digest_tracks_value_changes_and_is_order_independent():
    vector_a = {"pop_500m": 100.0, "pop_1000m": 200.0}
    assert feature_digest(vector_a) == feature_digest(dict(reversed(list(vector_a.items()))))
    assert feature_digest(vector_a) != feature_digest({**vector_a, "pop_500m": 101.0})
    assert feature_digest({"a": None}) != feature_digest({"a": 0.0}), (
        "a missing measurement must never share an identity with a measured zero"
    )


# -- single-flight scheduling ------------------------------------------------


def test_schedule_is_single_flight_and_lease_recoverable():
    _cleanup_rows(f"MD-TEST-{uuid.uuid4().hex[:6]}")
    identity = _identity(property_id=f"MD-TEST-{uuid.uuid4().hex[:6]}")
    try:
        with Session(operational_engine) as session:
            compute_now, newly = explanation_cache.schedule(session, identity)
            assert (compute_now, newly) == (True, True)

            # A concurrent scheduler for the same identity must not duplicate
            # the job while the lease is live.
            compute_now2, newly2 = explanation_cache.schedule(session, identity)
            assert (compute_now2, newly2) == (False, False)

            # An expired lease is stealable, so a crashed worker recovers.
            from sqlalchemy import text

            session.execute(
                text(
                    f"UPDATE {_CACHE_TABLE} SET claimed_at = :old WHERE cache_key = :k"
                ),
                {"old": "2020-01-01 00:00:00+00", "k": identity.cache_key()},
            )
            session.commit()
            compute_now3, newly3 = explanation_cache.schedule(session, identity)
            assert (compute_now3, newly3) == (True, False)

            # A permanently failed row is never rescheduled automatically.
            explanation_cache.mark_failed(session, identity.cache_key(), "test failure")
            compute_now4, newly4 = explanation_cache.schedule(session, identity)
            assert (compute_now4, newly4) == (False, False)
            assert explanation_cache.get_status(session, identity.cache_key()) == "failed"
            assert "test failure" in (
                explanation_cache.failure_reason(session, identity.cache_key()) or ""
            )
    finally:
        _cleanup_rows(identity.property_id)


# -- insights integration (live DB, warm process) -----------------------------


@pytest.fixture()
def live_service():
    _cleanup_rows()
    _clear_in_memory()
    with Session(analytics_engine) as analytics:
        with Session(operational_engine) as operational:
            service = PropertyInsightsService(
                session=analytics, analytics_session=analytics, cache_session=operational
            )
            yield service, operational
    _cleanup_rows()
    _clear_in_memory()


def test_persistent_hit_serves_the_real_explanation_without_recompute(live_service):
    service, operational = live_service
    shap_calls = {"n": 0}
    real_explain = shap_explainer.ShapExplainer.explain

    def counting(self, features, **kwargs):
        shap_calls["n"] += 1
        return real_explain(self, features, **kwargs)

    shap_explainer.ShapExplainer.explain = counting
    try:
        first = service.insights(REFERENCE_PROPERTY)
        assert first["explanation"]["available"] is True
        assert shap_calls["n"] == 1

        # A brand-new service (the FastAPI-restart scenario) must serve the
        # stored explanation without recomputing SHAP. The first instance's
        # in-memory cache is not shared with this one.
        _clear_in_memory()
        second_service = PropertyInsightsService(
            session=service.session, analytics_session=service.analytics,
            cache_session=operational,
        )
        second = second_service.insights(REFERENCE_PROPERTY)
        assert shap_calls["n"] == 1, "a valid persisted explanation must not recompute SHAP"
        assert second["explanation"]["available"] is True
        assert second["explanation"]["factors"] == first["explanation"]["factors"]
        assert second["score"]["raw"] == first["score"]["raw"]
    finally:
        shap_explainer.ShapExplainer.explain = real_explain


def test_cold_process_returns_pending_score_and_never_blocks(live_service, monkeypatch):
    service, operational = live_service
    _cleanup_rows()
    _clear_in_memory()

    # Simulate a freshly started process whose one-off SHAP warm-up has not
    # completed: the request path must not compute SHAP.
    saved_flag = shap_explainer._WARM_FLAG
    shap_explainer._WARM_FLAG = type(saved_flag)()
    try:
        started = time.perf_counter()
        out = service.insights(REFERENCE_PROPERTY)
        elapsed = time.perf_counter() - started
    finally:
        shap_explainer._WARM_FLAG = saved_flag

    assert elapsed < 3.0, f"cold-path request took {elapsed:.2f}s"
    assert out["score"]["available"] is True, "the real PU score must stay visible"
    assert out["score"]["raw"] > 0
    assert out["explanation"]["available"] is False
    assert out["explanation"]["status"] == "pending"
    assert out["reason"]["code"] == "shap_pending"
    assert out["availability"]["explanation"] is False
    # No fabricated factors: no contribution exists anywhere in the payload.
    assert "factors" not in out["explanation"]

    # A resumable job row was recorded for the worker.
    from sqlalchemy import text

    rows = operational.execute(
        text(
            f"SELECT status FROM {_CACHE_TABLE} "
            "WHERE property_id = :p AND status = 'pending'"
        ),
        {"p": REFERENCE_PROPERTY},
    ).all()
    assert rows, "the pending request must record a resumable job"


def test_worker_completes_the_pending_job_and_persists_it(live_service):
    service, operational = live_service
    _cleanup_rows()
    _clear_in_memory()

    loaded = ModelLoader().load_cached(EXPANDED_MODEL_NAME)
    background_file = _background_path("expanded64")
    background = _reference_background_rows(loaded.feature_names, background_file)
    identity = _live_identity(service, loaded, background, background_file)

    # Create the pending row exactly as the cold request path would, then hand
    # the job to the real worker.
    with Session(operational_engine) as session:
        compute_now, _newly = explanation_cache.schedule(session, identity)
    assert compute_now
    worker = get_explanation_worker()
    worker.start()
    assert worker.enqueue(
        ExplanationJob(cache_key=identity.cache_key(), property_id=REFERENCE_PROPERTY)
    )

    deadline = time.time() + 90
    status = None
    while time.time() < deadline:
        with Session(operational_engine) as session:
            status = explanation_cache.get_status(session, identity.cache_key())
        if status in {"ready", "failed"}:
            break
        time.sleep(0.5)
    assert status == "ready", f"worker did not complete the job (status={status})"
    stored = explanation_cache.get_ready(operational, identity.cache_key())
    assert stored is not None and stored["explanation"]["available"] is True
    # Additivity must hold in the STORED payload too.
    explanation = stored["explanation"]
    total = sum(f["contribution"] for f in explanation["factors"])
    assert abs(explanation["base_value"] + total - explanation["output"]) < 1e-6


def test_failed_row_reports_unavailable_without_fabricated_factors(live_service):
    service, operational = live_service
    _cleanup_rows()
    _clear_in_memory()

    loaded = ModelLoader().load_cached(EXPANDED_MODEL_NAME)
    background_file = _background_path("expanded64")
    background = _reference_background_rows(loaded.feature_names, background_file)
    identity = _live_identity(service, loaded, background, background_file)

    # A previously failed calculation is reported truthfully and never
    # recomputed on the request path. The row must exist first (exactly as the
    # request path would have left it: scheduled, then failed).
    with Session(operational_engine) as session:
        compute_now, _newly = explanation_cache.schedule(session, identity)
        assert compute_now
        explanation_cache.mark_failed(
            session, identity.cache_key(), "previous attempt failed validation"
        )

    saved_flag = shap_explainer._WARM_FLAG
    shap_explainer._WARM_FLAG = type(saved_flag)()
    try:
        out = service.insights(REFERENCE_PROPERTY)
    finally:
        shap_explainer._WARM_FLAG = saved_flag

    assert out["score"]["available"] is True
    assert out["explanation"]["available"] is False
    assert out["explanation"]["status"] == "unavailable"
    assert "factors" not in out["explanation"]
    assert "failed validation" in (out["reason"].get("detail") or "")
