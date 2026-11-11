"""Layer 1 feature-contract verification (Phase 2 deliverable).

Covers the three evidence-based fixes:

1. ``fyp_features.property_population_spatial`` holds TWO rows per catalogue
   id. The single-property resolver used to abort with "Ambiguous ... 2
   records matched" for EVERY property; it now resolves one row
   deterministically and prefers the SITEWISE_U_PROPERTY extract, which is
   byte-identical to the PU model's training record (proven against the
   supplied example_property_47.json for MD-00510).
2. The four DB-absent training features (pop_2000m and the three LandScan
   rasters) resolve from the committed original-training bridge file
   ``ml_reference/training_population_bridge_1849.csv``.
3. ``worldpop_walk_reachable_10min`` is unrecoverable from every available
   source, so live 47-feature inference is reported as EXPLICITLY
   UNAVAILABLE - never zero-filled, never fabricated.

All assertions run against the real analytics database and real artifacts.
"""
from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.ml.feature_bridge import (
    BRIDGE_FEATURES,
    UNRECOVERABLE_FEATURES,
    bridge_row_for,
)
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import (
    FeatureResolutionError,
    PropertyFeatureRepository,
)
from sitewise.ml.selected_pu_integration import feature_coverage, predict_live
from sitewise.repositories.recommendation_candidate_repository import (
    RecommendationCandidateRepository,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token

BACKEND_DIR = Path(__file__).resolve().parents[2]
EXAMPLE_JSON = BACKEND_DIR / "ml_reference" / "example_property_47.json"
BRIDGE_CSV = BACKEND_DIR / "ml_reference" / "training_population_bridge_1849.csv"

SAMPLE_IDS = ("MD-00510", "EP-01877", "MD-01514")


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def analytics_session():
    with Session(analytics_engine) as session:
        yield session


def test_bridge_dataset_is_the_original_training_population():
    assert BRIDGE_CSV.is_file()
    with BRIDGE_CSV.open(encoding="utf-8", newline="") as fp:
        rows = list(csv.DictReader(fp))
    assert len(rows) == 1849  # 894 P + 955 U, the exact training rows
    classes = {r["sample_class"].strip().upper() for r in rows}
    assert classes == {"P", "U"}
    u_rows = [r for r in rows if r["sample_class"].strip().upper() == "U"]
    assert all(r["canonical_property_id"].strip() for r in u_rows)
    # The reference property's bridge values are byte-identical to the
    # supplied training reference vector.
    reference = json.loads(EXAMPLE_JSON.read_text(encoding="utf-8"))
    row = bridge_row_for(reference["property_id"], None)
    assert row is not None
    for name in BRIDGE_FEATURES:
        assert row.values[name] == pytest.approx(reference["features"][name], abs=1e-9)


def test_population_duplication_is_resolved_deterministically(analytics_session):
    loaded = ModelLoader().load("sitewise_selected_pu_model")
    for property_id in SAMPLE_IDS:
        bundle = PropertyFeatureRepository(analytics_session).get(
            property_id, loaded.feature_names, source="catalog"
        )
        # The historic failure mode was FeatureResolutionError("Ambiguous ...").
        assert "pop_500m" in bundle.values
        assert bundle.value_sources.get("pop_500m") is not None
        assert any(
            "source_record_type=SITEWISE_U_PROPERTY" in flag for flag in bundle.flags
        ), bundle.flags


def test_bridge_yields_46_of_47_with_one_documented_unrecoverable(analytics_session):
    for property_id in SAMPLE_IDS:
        report = feature_coverage(analytics_session, property_id)
        assert report["available_features"] == 46
        assert report["feature_count"] == 47
        assert report["complete"] is False
        assert report["missing_features"] == ["worldpop_walk_reachable_10min"]
        assert report["unrecoverable_features"] == list(UNRECOVERABLE_FEATURES)
        # Exactly the four DB-absent features come from the bridge file.
        bridge_sourced = [
            name
            for name, source in report["value_sources"].items()
            if "training_population_bridge_1849.csv" in source
        ]
        assert sorted(bridge_sourced) == sorted(BRIDGE_FEATURES)
        assert report["inference_state"] == "unavailable_missing_training_features"


def test_resolved_values_byte_match_the_training_reference_vector(analytics_session):
    reference = json.loads(EXAMPLE_JSON.read_text(encoding="utf-8"))
    assert reference["property_id"] == "MD-00510"
    report = feature_coverage(analytics_session, "MD-00510")
    mismatches = {
        name: (expected, report["values"].get(name))
        for name, expected in reference["features"].items()
        if name != "worldpop_walk_reachable_10min"
        and report["values"].get(name) != expected
    }
    assert mismatches == {}, "live+bridge vector diverged from training inputs"


def test_landscan_licence_status_is_surfaced(analytics_session):
    report = feature_coverage(analytics_session, "MD-00510")
    assert any("NO_PENDING_LICENCE" in flag for flag in report["flags"])


def test_live_prediction_is_explicitly_unavailable_and_never_fabricated(
    analytics_session,
):
    result = predict_live(analytics_session, "EP-01877")
    assert result["available"] is False
    assert result["score"] is None
    assert result["inference_state"] == "unavailable_missing_training_features"
    assert result["feature_coverage"]["missing_features"] == [
        "worldpop_walk_reachable_10min"
    ]
    assert "fabricated" in result["policy"]
    # The unavailable feature is explicitly None in the reported vector.
    assert result["feature_coverage"]["value_sources"].get(
        "worldpop_walk_reachable_10min"
    ) is None


def test_unknown_catalogue_property_fails_closed(analytics_session):
    with pytest.raises(FeatureResolutionError, match="does not exist"):
        feature_coverage(analytics_session, "DOES-NOT-EXIST")


def test_candidate_repository_prefers_the_training_parity_row(analytics_session):
    """The Layer 2 candidate feed and the model resolver agree on one row."""
    rows = RecommendationCandidateRepository(analytics_session).list_candidates(
        limit=None
    )
    target = next(r for r in rows if r["property_id"] == "MD-00510")
    # SITEWISE_U_PROPERTY value (the training record), not the 1071.595... twin.
    assert target["population_500m"] == pytest.approx(1071.6, abs=1e-9)


# ---------------------------------------------------------------------------
# API surface
# ---------------------------------------------------------------------------


@pytest.fixture()
def headers() -> dict:
    token = make_token(
        sub="44444444-4444-4444-4444-444444444444",
        email=f"l1-cov-44444444@{TEST_EMAIL_DOMAIN}",
    )
    return auth(token)


def test_coverage_endpoint_reports_full_contract(client, headers):
    response = client.get(
        "/api/v1/ml/selected/properties/MD-00510/coverage", headers=headers
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["feature_count"] == 47
    assert body["available_features"] == 46
    assert body["missing_features"] == ["worldpop_walk_reachable_10min"]
    assert body["inference_state"] == "unavailable_missing_training_features"
    assert set(body["value_sources"]) >= set(BRIDGE_FEATURES)


def test_prediction_endpoint_returns_controlled_unavailable_state(client, headers):
    response = client.get(
        "/api/v1/ml/selected/properties/MD-00510/prediction", headers=headers
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["available"] is False
    assert body["score"] is None
    assert "worldpop_walk_reachable_10min" in body["reason"]
    assert "fabricated" in body["policy"]
    assert body["feature_coverage"]["available_features"] == 46


def test_coverage_endpoint_404_for_unknown_property(client, headers):
    response = client.get(
        "/api/v1/ml/selected/properties/DOES-NOT-EXIST/coverage", headers=headers
    )
    assert response.status_code == 404


def test_ml_routes_require_authentication(client):
    for path in (
        "/api/v1/ml/selected/properties/MD-00510/coverage",
        "/api/v1/ml/selected/properties/MD-00510/prediction",
    ):
        assert client.get(path).status_code == 401
