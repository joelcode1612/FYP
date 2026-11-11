"""Verification for the experimental 47-feature PU model + five-question V3.

All artifact scores and API results are REAL: they come from the supplied
artifacts, the local analytics database and the committed training bridge.
Nothing is hardcoded or fabricated. The production artifact is never replaced.
"""
from __future__ import annotations

import hashlib
import json
import math
import uuid
from dataclasses import replace
from pathlib import Path

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.core.config import Settings
from sitewise.db.session import engine
from sitewise.domain import recommendation_scoring as rs
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.pu_learning import PULearning
from sitewise.ml.pu_variant import (
    EXPERIMENTAL_MODEL_NAME,
    clear_experimental_cache,
    resolve_variant,
)
from sitewise.ml.shap_explainer import ShapExplainer
from sitewise.ml.sitewise_recommender_v3 import (
    Calibration,
    FiveQuestionRecommender,
    _verify_against_domain,
    load_snapshot,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

BACKEND_DIR = Path(__file__).resolve().parents[2]
ARTIFACT = BACKEND_DIR / "src" / "sitewise" / "ml" / "sitewise_pu_47_experimental.joblib"
REFERENCE_VECTOR = BACKEND_DIR / "ml_reference" / "example_property_47.json"
REFERENCE_PROPERTY_ID = "MD-00510"
SUPPLIED_SHA256 = "1d09cb9a44301d1020bb367a1b3dcb1803935e853c348eccad357f0ede8fd1e2"

V3_PREFERENCES = {
    "fnb_concept": "cafe_coffee_shop",
    "service_model": "dine_in",
    "target_customers": ["nearby_residents", "office_workers"],
    "recommendation_priority": "high_nearby_population",
    "space_size_preference": "standard_business_space",
    "requirements_version": 3,
}


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(autouse=True)
def _clean_experimental_cache():
    clear_experimental_cache()
    yield
    clear_experimental_cache()


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


@pytest.fixture()
def identity(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(sub=sub, email=f"pu47-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "user_id": uuid.UUID(sub)}


def _candidate(**overrides) -> rs.PropertyCandidate:
    base = {
        "property_id": "MD-00510",
        "monthly_rental_myr": 2500.0,
        "built_up_sqft": 1600.0,
        "population_500m": 6000.0,
        "population_1000m": 21000.0,
        "office_pois_500m": 4,
        "schools_count_500m": 3,
        "universities_count_500m": 1,
        "malls_count_500m": 1,
        "bus_stops_500m_walk": 3,
        "rail_stations_1km_walk": 1,
        "parking_facilities_500m": 5,
        "nearest_parking_distance_m": 120.0,
        "fnb_competitors_500m": 12,
        "cafe_count_500m": 2,
        "restaurant_count_500m": 3,
        "fast_food_count_500m": 1,
        "bakery_count_500m": 0,
        "nearest_transit_walk_m": 350.0,
        "walk_isochrone_area_10min_km2": 0.4,
        "nearest_major_road_m": 200.0,
        "pu_association_score": 0.42,
        "sample_class": "U",
        "availability_status": "UNKNOWN_NOT_VERIFIED",
    }
    base.update(overrides)
    return rs.PropertyCandidate(**base)


# ---------------------------------------------------------------------------
# Model A: artifact, checksum, exact feature order, fail-closed inputs
# ---------------------------------------------------------------------------


def test_experimental_artifact_loads_with_verified_checksum_and_order():
    digest = hashlib.sha256(ARTIFACT.read_bytes()).hexdigest()
    assert digest == SUPPLIED_SHA256, "the vendored artifact must be byte-identical"

    loaded = ModelLoader().load(EXPERIMENTAL_MODEL_NAME)
    contract = json.loads(
        (BACKEND_DIR / "src" / "sitewise" / "ml" / "sitewise_pu_47_experimental_features.json")
        .read_text(encoding="utf-8")
    )
    assert loaded.feature_names == contract["features"], "exact 47-feature input order"
    assert len(loaded.feature_names) == 47
    assert loaded.meta["version"] == "hist_gradient_boosting@PU_47_CANDIDATE_2026_11_11"
    assert loaded.meta["artifact_sha256"] == SUPPLIED_SHA256
    assert loaded.meta["production_ready"] is False
    assert loaded.meta["not_a_business_success_probability"] is True
    assert loaded.meta["landscan_provenance"]["status"] == "unresolved"
    # Custom class importable and the model instance carries the snapshot's meaning.
    assert loaded.model.score_meaning


def test_production_artifact_unchanged_and_default_variant_is_legacy():
    original = ModelLoader().load("pu_model")
    assert original.name == "pu_model"
    assert original.meta["artifact_filename"] == "PU_model.joblib"
    assert original.meta["feature_set"] == "baseline_47"
    assert Settings().pu_model_variant == "legacy"  # rollback guarantee


def test_experimental_prediction_is_real_and_versioned():
    vector = json.loads(REFERENCE_VECTOR.read_text(encoding="utf-8"))
    result = PULearning(model_name=EXPERIMENTAL_MODEL_NAME).predict_or_report(
        vector["property_id"], vector["features"], allow_model_imputation=False
    )
    assert result["available"] is True
    assert 0.0 <= result["score"] <= 1.0
    assert result["model_version"] == "hist_gradient_boosting@PU_47_CANDIDATE_2026_11_11"
    assert "NOT" in result["score_meaning"] or "not" in result["score_meaning"]


def test_incomplete_feature_vector_reports_unavailable_with_missing_list():
    vector = json.loads(REFERENCE_VECTOR.read_text(encoding="utf-8"))
    features = dict(vector["features"])
    del features["worldpop_walk_reachable_10min"]
    del features["parking_facilities_1km"]
    result = PULearning(model_name=EXPERIMENTAL_MODEL_NAME).predict_or_report(
        vector["property_id"], features, allow_model_imputation=False
    )
    assert result["available"] is False
    assert result["score"] is None
    assert "worldpop_walk_reachable_10min" in result["reason"]
    assert "parking_facilities_1km" in result["reason"]


def test_invalid_feature_vector_is_rejected_never_zero_filled():
    vector = json.loads(REFERENCE_VECTOR.read_text(encoding="utf-8"))
    features = dict(vector["features"])
    features["pop_500m"] = True  # boolean is not a measurement
    with pytest.raises(ModelUnavailableError, match="must be numeric, not boolean"):
        PULearning(model_name=EXPERIMENTAL_MODEL_NAME).predict(
            vector["property_id"], features
        )
    features["pop_500m"] = -12.0  # nonnegative contract violation
    with pytest.raises(ModelUnavailableError):
        PULearning(model_name=EXPERIMENTAL_MODEL_NAME).predict(
            vector["property_id"], features
        )


# ---------------------------------------------------------------------------
# Model B: calibration snapshot, five questions, arithmetic
# ---------------------------------------------------------------------------


def test_recommender_v3_snapshot_verifies_against_domain_constants():
    recommender = load_snapshot()
    assert recommender.version == "sitewise_rule_based_5q_dosm_v3_2026_11_11"
    assert math.isclose(recommender.pu_weight, 0.70)
    assert math.isclose(recommender.preference_weight, 0.30)
    calibration = recommender.domain_calibration
    assert calibration.rent_p10 == 1600.0
    assert calibration.rent_p90 == 12000.0
    assert calibration.population_count == 955
    drifted = FiveQuestionRecommender(calibration=Calibration(rent_p10=1.0))
    with pytest.raises(ModelUnavailableError, match="rent_p10"):
        _verify_against_domain(drifted)


def test_all_five_q4_priorities_adjust_component_weights():
    profile = rs.preference_profile_from({**V3_PREFERENCES})
    candidate = _candidate()
    finals = {}
    for priority in (
        "high_nearby_population",
        "affordable_operating_location",
        "easy_customer_accessibility",
        "active_commercial_surroundings",
        "balanced_suitability",
    ):
        weights = rs.effective_weights_v3(priority)
        assert math.isclose(sum(weights.as_dict().values()), 1.0, abs_tol=1e-9)
        p = replace(profile, recommendation_priority=priority)
        item = load_snapshot().score_preference(p, candidate)
        assert item.coverage["q4_priority"] == priority
        assert item.coverage["effective_weights_v3"] == weights.as_dict()
        finals[priority] = item.final_score
    # Different priorities genuinely re-weight: the extreme pair must differ.
    assert finals["high_nearby_population"] != finals["affordable_operating_location"]
    assert finals["easy_customer_accessibility"] != finals["balanced_suitability"]


def test_all_four_q5_size_preferences_behave_correctly():
    recommender = load_snapshot()
    profile = rs.preference_profile_from({**V3_PREFERENCES})
    candidate = _candidate(built_up_sqft=1600.0)  # inside standard band (1540-1760)

    standard = recommender.score_preference(
        replace(profile, space_size_preference="standard_business_space"), candidate
    )
    assert standard.components["size_fit"].value == 1.0
    assert standard.components["size_fit"].status == "scored"

    compact = recommender.score_preference(
        replace(profile, space_size_preference="compact_business_space"), candidate
    )
    assert 0.0 < compact.components["size_fit"].value < 1.0  # 1600 is above the band

    spacious = recommender.score_preference(
        replace(profile, space_size_preference="spacious_business_space"), candidate
    )
    assert 0.0 < spacious.components["size_fit"].value < 1.0
    assert spacious.components["size_fit"].value != compact.components["size_fit"].value

    flexible = recommender.score_preference(
        replace(profile, space_size_preference="flexible_no_preference"), candidate
    )
    assert flexible.components["size_fit"].value is None
    assert flexible.components["size_fit"].status == "unknown"
    assert "size_fit" in flexible.coverage["unknown_components"]


def test_null_and_zero_data_remain_distinct():
    recommender = load_snapshot()
    profile = rs.preference_profile_from({**V3_PREFERENCES})
    # No demand-generator measurement at all: component is UNKNOWN (excluded
    # from the weighted mean), never zero.
    bare = _candidate(
        population_500m=None, population_1000m=None, office_pois_500m=None,
        schools_count_500m=None, universities_count_500m=None, malls_count_500m=None,
        bus_stops_500m_walk=None, rail_stations_1km_walk=None,
        cafe_count_500m=None, restaurant_count_500m=None,
        fast_food_count_500m=None, bakery_count_500m=None,
    )
    bare_fit = recommender.score_preference(profile, bare).components["target_market_fit"]
    assert bare_fit.status == "unknown"
    assert bare_fit.value is None
    # A MEASURED zero population is scored as a real (low) value.
    zero = recommender.score_preference(
        profile, replace(bare, population_500m=0.0)
    ).components["target_market_fit"]
    assert zero.status == "scored"
    assert zero.value is not None
    assert any("population_500m=0" in signal for signal in zero.evidence["signals"])


def test_final_score_arithmetic_exact_and_ranking_descending():
    recommender = load_snapshot()
    profile = rs.preference_profile_from({**V3_PREFERENCES})
    a = recommender.score_preference(profile, _candidate(pu_association_score=0.42))
    assert a.preference_match_score is not None
    expected = 0.7 * 0.42 + 0.3 * a.preference_match_score
    assert math.isclose(a.final_score, expected, abs_tol=1e-9)
    payload = a.as_dict()
    assert payload["final_recommendation"]["score_0_100"] == round(expected * 100, 1)
    assert payload["model"]["association_score_0_100"] == 42.0

    b = recommender.score_preference(profile, _candidate(property_id="EP-00002", pu_association_score=0.9))
    ranked = rs.rank_candidates([a, b])
    assert [r.final_score for r in ranked] == sorted(
        (r.final_score for r in ranked), reverse=True
    )
    assert [r.rank for r in ranked] == [1, 2]


def test_deliberately_low_pu_property_loses_ranking_and_warns():
    recommender = load_snapshot()
    profile = rs.preference_profile_from({**V3_PREFERENCES})
    good = recommender.score_preference(profile, _candidate(pu_association_score=0.42))
    low = recommender.score_preference(
        profile, _candidate(property_id="EP-LOW-8", pu_association_score=0.08)
    )
    ranked = rs.rank_candidates([low, good])
    assert ranked[0].property_id == good.property_id
    assert ranked[1].property_id == "EP-LOW-8"
    assert any("PU research association score is low" in c for c in low.cautions)
    # Verified arithmetic for the low-PU property too.
    assert math.isclose(
        low.final_score, 0.7 * 0.08 + 0.3 * low.preference_match_score, abs_tol=1e-9
    )


def test_v1_engine_unchanged_for_pre_v3_preferences():
    profile = rs.preference_profile_from(
        {
            "fnb_concept": "restaurant",
            "service_model": "hybrid",
            "target_customers": ["students"],
            "recommendation_priority": "favorable_competition",
            "max_monthly_rent_myr": 3000,
            "min_floor_area_sqft": 800,
            "requirements_version": 2,
        }
    )
    assert profile.preferences_version == 2
    assert profile.space_size_preference is None
    item = rs.score_candidate(_candidate(property_id="EP-V1-1"), profile)
    assert item.coverage.get("effective_weights_v3") is None
    assert item.layer1_model == "pu_model"


# ---------------------------------------------------------------------------
# SHAP on the bagged Gradient Boosting ensemble (model-agnostic explainer)
# ---------------------------------------------------------------------------


def test_shap_supports_the_custom_ensemble_and_reconstructs_the_score():
    vector = json.loads(REFERENCE_VECTOR.read_text(encoding="utf-8"))
    background_rows = (BACKEND_DIR / "ml_reference" / "shap_background_47.csv").read_text(
        encoding="utf-8-sig"
    ).splitlines()
    import csv as _csv

    reader = _csv.DictReader(background_rows)
    background = [
        {k: float(v) for k, v in row.items() if v not in ("", None)}
        for row in list(reader)[:3]
    ]
    raw = ShapExplainer(model_name=EXPERIMENTAL_MODEL_NAME).explain(
        vector["features"], background=background
    )
    score = float(raw["positive_label_association"])
    reconstruction = raw["baseline_association"] + math.fsum(raw["contributions"].values())
    assert abs(reconstruction - score) < 1e-6, "SHAP must reconstruct the real prediction"
    assert raw["explainer"] == "Permutation SHAP"


# ---------------------------------------------------------------------------
# API: five-question persistence, variants, isolation, cache invalidation
# ---------------------------------------------------------------------------


def test_v3_preferences_validated_and_persisted(client, identity):
    r = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": V3_PREFERENCES},
        headers=auth(identity["token"]),
    )
    assert r.status_code in (200, 201), r.text
    r = client.get("/api/v1/preferences/me", headers=auth(identity["token"]))
    assert r.status_code == 200, r.text
    stored = r.json()
    payload = stored.get("preferences") or stored.get("data") or stored
    assert payload.get("requirements_version") == 3
    assert payload.get("space_size_preference") == "standard_business_space"
    assert payload.get("recommendation_priority") == "high_nearby_population"

    r = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": {**V3_PREFERENCES, "space_size_preference": "huge_villa"}},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 422


def test_legacy_variant_generation_uses_stored_scores_rollback(client, identity):
    r = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": V3_PREFERENCES},
        headers=auth(identity["token"]),
    )
    assert r.status_code in (200, 201), r.text
    r = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 5, "property_ids": [REFERENCE_PROPERTY_ID]},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["model"]["layer1_model"] == "pu_model"
    assert body["model"]["key"] == "legacy"
    assert body["layer2"]["engine"] == "rule_based_5q_v3"  # v3 preferences -> V3 engine
    results = body["results"]
    assert results, "the reference property must be eligible"
    assert all(res["model"]["name"] == "pu_model" for res in results)
    first = results[0]
    expected = 0.7 * first["model"]["association_score"] + 0.3 * first["personalisation"]["preference_match_score"]
    assert math.isclose(first["final_recommendation"]["score"], expected, abs_tol=1e-6)


def test_experimental_variant_end_to_end_never_mixes_models(client, identity, monkeypatch):
    monkeypatch.setenv("SITEWISE_PU_MODEL_VARIANT", "experimental47")
    r = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": V3_PREFERENCES},
        headers=auth(identity["token"]),
    )
    assert r.status_code in (200, 201), r.text
    r = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 5, "property_ids": [REFERENCE_PROPERTY_ID]},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["model"]["key"] == "experimental47"
    assert body["model"]["layer1_model"] == EXPERIMENTAL_MODEL_NAME
    assert body["model"]["production_ready"] is False
    assert body["model"]["notes"], "gating notes must travel with the response"
    results = body["results"]
    assert results, "MD-00510 has a complete verified 47-feature vector"
    names = {res["model"]["name"] for res in results}
    assert names == {EXPERIMENTAL_MODEL_NAME}, "one batch, one variant - never mixed"
    first = results[0]
    expected = 0.7 * first["model"]["association_score"] + 0.3 * first["personalisation"]["preference_match_score"]
    assert math.isclose(first["final_recommendation"]["score"], expected, abs_tol=1e-6)
    summary = body["candidate_summary"]
    assert summary["experimental_coverage"]["scored_live_inference"] >= 1
    assert summary["layer1_variant"] == "experimental47"


def test_inputs_hash_invalidates_cache_on_preference_and_model_change():
    profile_a = rs.preference_profile_from({**V3_PREFERENCES})
    profile_b = rs.preference_profile_from(
        {**V3_PREFERENCES, "space_size_preference": "spacious_business_space"}
    )
    hash_a = rs.preference_profile_from({**V3_PREFERENCES}).as_dict()
    assert hash_a != profile_b.as_dict()
    service = __import__(
        "sitewise.services.recommendation_generation_service",
        fromlist=["RecommendationGenerationService"],
    ).RecommendationGenerationService
    h1 = service._inputs_hash(
        profile_a, 20, None, None, layer1_key="legacy", layer1_version="v1", engine_version="e1"
    )
    h2 = service._inputs_hash(
        profile_b, 20, None, None, layer1_key="legacy", layer1_version="v1", engine_version="e1"
    )
    h3 = service._inputs_hash(
        profile_a, 20, None, None, layer1_key="experimental47", layer1_version="v1", engine_version="e1"
    )
    h4 = service._inputs_hash(
        profile_a, 20, None, None, layer1_key="legacy", layer1_version="v2", engine_version="e1"
    )
    assert len({h1, h2, h3, h4}) == 4, "preference/model/calibration changes must invalidate"


def test_variant_resolver_gating_metadata():
    legacy = resolve_variant(Settings())
    assert legacy.key == "legacy"
    experimental = resolve_variant(Settings(sitewise_pu_model_variant="experimental47"))
    assert experimental.key == "experimental47"
    assert experimental.production_ready is False
    assert any("LandScan" in note for note in experimental.notes)
    with pytest.raises(ValueError):
        Settings(sitewise_pu_model_variant="bogus").pu_model_variant
