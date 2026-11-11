"""Selected alternate PU model integration (additive Layer-1 research model).

Covers the spec section 10 matrix for the SELECTED model:
both artifacts coexist with their own contracts, predictions are finite and
bounded, missing/malformed features fail closed, SHAP reconstructs the model
output from the REAL supplied reference background (no synthetic rows), the
new routes are authenticated and additive, and the existing default-PU
endpoints are untouched.

The property-level endpoints fail closed on the current analytics database
(see the pre-existing `fyp_features.property_population_spatial` duplication
documented in the integration report); the controlled-error contract is
asserted here.
"""

from __future__ import annotations

import csv
import json
import math
from pathlib import Path

import pytest

from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.pu_learning import PULearning
from sitewise.ml.selected_pu_integration import (
    SELECTED_MODEL_NAME,
    explain_selected_payload,
    predict_selected,
    selected_metadata,
)
from sitewise.core.exceptions import ModelUnavailableError

from ..conftest import TEST_EMAIL_DOMAIN, make_token

BACKEND_DIR = Path(__file__).resolve().parents[2]
REFERENCE_CSV = BACKEND_DIR / "ml_reference" / "shap_background_47.csv"
EXAMPLE_JSON = BACKEND_DIR / "ml_reference" / "example_property_47.json"


def _example_features() -> dict:
    payload = json.loads(EXAMPLE_JSON.read_text(encoding="utf-8"))
    return payload["features"], payload["property_id"]


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Artifacts and contracts
# ---------------------------------------------------------------------------


def test_both_artifacts_load_with_their_own_contracts():
    original = ModelLoader().load("pu_model")
    selected = ModelLoader().load(SELECTED_MODEL_NAME)

    # The original artifact is unchanged and stays the default.
    assert original.meta["artifact_filename"] == "PU_model.joblib"
    assert original.name == "pu_model"
    assert original.feature_names

    # The selected model is a SEPARATE artifact with the 47-feature contract.
    assert selected.name == SELECTED_MODEL_NAME
    assert selected.meta["artifact_filename"] == "sitewise_selected_pu_model.joblib"
    assert len(selected.feature_names) == 47
    assert len(set(selected.feature_names)) == 47
    assert selected.meta.get("feature_set") == "baseline_47"


def test_selected_metadata_reports_research_scope():
    meta = selected_metadata()
    assert meta["name"] == SELECTED_MODEL_NAME
    assert meta["research_only"] is True
    assert len(meta["features"]) == 47


def test_selected_prediction_is_finite_and_bounded():
    features, property_id = _example_features()
    result = predict_selected(property_id, features)
    assert result["available"] is True
    score = result["score"]
    assert score is not None and math.isfinite(score)
    assert 0.0 <= score <= 1.0
    assert result["research_only"] is True
    assert result["model_version"]  # provenance travels with the result


def test_missing_feature_fails_closed_without_zero_fill():
    features, property_id = _example_features()
    incomplete = dict(features)
    incomplete[next(iter(features))] = None  # remove exactly one feature
    with pytest.raises(ModelUnavailableError, match="missing geospatial features"):
        PULearning(model_name=SELECTED_MODEL_NAME).predict(
            property_id, incomplete
        )


def test_malformed_feature_fails_closed():
    features, property_id = _example_features()
    malformed = dict(features)
    malformed[next(iter(features))] = "not-a-number"
    with pytest.raises(ModelUnavailableError, match="must be numeric"):
        PULearning(model_name=SELECTED_MODEL_NAME).predict(property_id, malformed)


# ---------------------------------------------------------------------------
# SHAP over the real supplied reference background
# ---------------------------------------------------------------------------


def _real_background() -> list[dict]:
    with REFERENCE_CSV.open(encoding="utf-8-sig", newline="") as fp:
        return list(csv.DictReader(fp))


def test_shap_reconstruction_with_reference_background():
    features, property_id = _example_features()
    background = _real_background()
    assert 0 < len(background) <= 100

    explanation = explain_selected_payload(features, background)

    score = float(explanation["score"])
    baseline = float(explanation["baseline"])
    contributions = explanation["contributions"]
    assert math.isfinite(score) and 0.0 <= score <= 1.0
    assert math.isfinite(baseline)
    assert len(contributions) == 47

    # Baseline + contributions reconstruct the model output to tolerance.
    reconstruction = baseline + math.fsum(contributions.values())
    assert abs(reconstruction - score) < 1e-6

    # Sorted contribution lists mirror the dictionary.
    positive = explanation["top_positive_features"]
    negative = explanation["top_negative_features"]
    assert all(item["contribution"] > 0 for item in positive)
    assert all(item["contribution"] < 0 for item in negative)
    assert positive == sorted(positive, key=lambda item: -item["contribution"])
    assert negative == sorted(negative, key=lambda item: item["contribution"])

    # The explanation is JSON-serializable without NaN/Infinity placeholders.
    payload = json.dumps(
        {"property_id": property_id, **explanation},
        allow_nan=False,
        ensure_ascii=False,
    )
    assert '"research_only": true' in payload
    assert "positive-label association" in explanation["explanation_scope"]


# ---------------------------------------------------------------------------
# API surface (additive routes, existing routes untouched)
# ---------------------------------------------------------------------------


def test_selected_model_endpoint_requires_authentication(client):
    response = client.get("/api/v1/ml/selected/model")
    assert response.status_code == 401


def test_selected_model_endpoint_returns_metadata(client):
    sub = "11111111-1111-1111-1111-111111111111"
    token = make_token(sub=sub, email=f"ml-sel-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    response = client.get("/api/v1/ml/selected/model", headers=auth(token))
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["name"] == SELECTED_MODEL_NAME
    assert body["research_only"] is True
    assert len(body["features"]) == 47


def test_selected_prediction_fails_closed_on_unresolvable_property(client):
    sub = "22222222-2222-2222-2222-222222222222"
    token = make_token(sub=sub, email=f"ml-sel2-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    headers = auth(token)

    # Unknown catalogue id -> controlled 404 (fail-closed feature resolution).
    unknown = client.get(
        "/api/v1/ml/selected/properties/DOES-NOT-EXIST/prediction", headers=headers
    )
    assert unknown.status_code == 404
    assert "catalogue property does not exist" in unknown.json()["detail"]

    # Rental integer ids are a DIFFERENT id universe for this endpoint.
    rental_style = client.get(
        "/api/v1/ml/selected/properties/999999/prediction", headers=headers
    )
    assert rental_style.status_code == 404

    # Explanation path shares the same fail-closed contract.
    explanation = client.get(
        "/api/v1/ml/selected/properties/DOES-NOT-EXIST/explanation", headers=headers
    )
    assert explanation.status_code == 404


def test_existing_default_ml_routes_unchanged(client):
    sub = "33333333-3333-3333-3333-333333333333"
    token = make_token(sub=sub, email=f"ml-def-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    headers = auth(token)
    response = client.get("/api/v1/ml/model", headers=headers)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["available"] is True
    assert body["model"] == "pu_model"
    assert body["artifact"] == "PU_model.joblib"
    # The selected routes did not displace the default model metadata.
    assert body["model"] != SELECTED_MODEL_NAME
