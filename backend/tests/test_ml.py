"""ML integration behaviour tests (spec 15 - suitability and ML tests).

Verified precondition: no trained model artifact exists in the repository.
These tests prove the HONEST path - explicit unavailability, feature-contract
validation when an artifact IS present (via a joblib-serialized dummy model),
and no fabricated predictions.
"""

import json

import joblib
import pytest

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.pu_learning import PULearning
from sitewise.ml.shap_explainer import ShapExplainer


class _DummyClassifier:
    """A sklearn-free stand-in exposing the sklearn predict interface."""

    feature_names_in_ = ["feature_a", "feature_b"]

    def predict_proba(self, X):
        return [[0.25, 0.75] for _ in X]

    def predict(self, X):
        return [1 for _ in X]


def _write_artifacts(tmp_path, features=("feature_a", "feature_b")):
    joblib.dump(_DummyClassifier(), tmp_path / "pu_model.pkl")
    (tmp_path / "pu_model_features.json").write_text(
        json.dumps({"features": list(features)})
    )
    (tmp_path / "pu_model_meta.json").write_text(json.dumps({"version": "test-1"}))


def test_load_without_artifact_raises_unavailable(tmp_path):
    loader = ModelLoader(tmp_path)
    with pytest.raises(ModelUnavailableError, match="No trained model artifact"):
        loader.load("pu_model")


def test_artifact_without_feature_contract_is_rejected(tmp_path):
    joblib.dump(_DummyClassifier(), tmp_path / "pu_model.pkl")
    with pytest.raises(ModelUnavailableError, match="feature contract"):
        ModelLoader(tmp_path).load("pu_model")


def test_load_and_predict_with_valid_artifact(tmp_path):
    _write_artifacts(tmp_path)
    pu = PULearning(loader=ModelLoader(tmp_path))
    result = pu.predict_or_report(42, {"feature_a": 1.0, "feature_b": 2.0})
    assert result["available"] is True
    assert result["score"] == pytest.approx(0.75)
    assert result["label"] == 1
    assert result["model_version"] == "test-1"


def test_missing_feature_is_reported_not_imputed(tmp_path):
    _write_artifacts(tmp_path)
    pu = PULearning(loader=ModelLoader(tmp_path))
    with pytest.raises(ModelUnavailableError, match="missing geospatial features"):
        pu.predict(42, {"feature_a": 1.0})  # feature_b missing


def test_extra_feature_is_rejected_by_contract(tmp_path):
    _write_artifacts(tmp_path)
    # The contract declares a column the model was never trained with: the
    # loader must refuse rather than feed the model an unexpected column.
    (tmp_path / "pu_model_features.json").write_text(
        json.dumps({"features": ["feature_a", "feature_b", "feature_c"]})
    )
    with pytest.raises(ModelUnavailableError, match="Feature contract mismatch"):
        ModelLoader(tmp_path).load("pu_model")


def test_recommendation_ranking_orders_by_score():
    from sitewise.domain.ranking import rank

    items = [{"score": 0.2}, {"score": 0.9}, {"score": 0.55}]
    ordered = rank(items)
    assert [i["score"] for i in ordered] == [0.9, 0.55, 0.2]


def test_shap_explainer_reports_unavailability():
    # No artifact exists -> SHAP integration must fail explicitly, never
    # silently produce explanations.
    with pytest.raises(ModelUnavailableError):
        ShapExplainer().explain({"feature_a": 1.0})


def test_suitability_engine_returns_honest_unavailable_envelope():
    from sitewise.domain.suitability_engine import assess_premises

    result = assess_premises(1, {})
    assert result.available is False
    assert result.score is None  # never 0.0 pretending to be a prediction
    assert result.prerequisites
