"""Contract tests for the property-scoped insights read model.

These run without a database: the feature repository is stubbed with the
committed reference data (``ml_reference/shap_background_47.csv`` and
``ml_reference/example_property_47.json``), so the SHAP path, the additivity
guard, the friendly-label registry and the five categories are all exercised
against the *real* deployed artifact and a *real* background matrix.

What is asserted here is deliberately narrow but load-bearing:

* every model feature has an entrepreneur-facing label and a category, so no
  raw column name can reach the UI;
* ``base_value + sum(contributions) == output`` for the payload the API
  returns, which is the only proof that the explanation describes that score;
* a property with no background or missing features reports an honest
  ``available: false`` with a reason code and **no** score;
* two different properties get different explanations, so one property's
  factors can never be reused for another;
* the cache is keyed by model version, so a replaced artifact cannot serve a
  stale explanation.
"""

from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest

import sitewise.services.property_insights_service as svc
from sitewise.ml.model_loader import ModelLoader
from sitewise.services.explanation_service import category_of

BACKEND_DIR = Path(__file__).resolve().parents[1]
BACKGROUND_CSV = BACKEND_DIR / "ml_reference" / "shap_background_47.csv"
EXAMPLE_JSON = BACKEND_DIR / "ml_reference" / "example_property_47.json"
FEATURES_JSON = BACKEND_DIR / "src" / "sitewise" / "ml" / "sitewise_pu_47_experimental_features.json"

REFERENCE_PROPERTY_ID = "MD-00510"


# -- fixtures ---------------------------------------------------------------


@pytest.fixture(scope="module")
def feature_names() -> list[str]:
    return json.loads(FEATURES_JSON.read_text())["features"]


@pytest.fixture(scope="module")
def background() -> list[dict[str, float]]:
    with BACKGROUND_CSV.open() as handle:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(handle)]


@pytest.fixture(scope="module")
def reference_features() -> dict[str, float]:
    return json.loads(EXAMPLE_JSON.read_text())["features"]


@pytest.fixture(autouse=True)
def _clear_cache():
    svc.clear_insights_cache()
    yield
    svc.clear_insights_cache()


def _service(monkeypatch, *, features, background_rows, missing=None):
    """An insights service whose repository returns the supplied vectors."""

    class _Bundle:
        values = features
        missing_features = missing or []
        flags: list[str] = []
        value_sources: dict[str, str] = {}

    class _Repo:
        def __init__(self, session):  # noqa: D401 - signature match
            self.session = session

        def get(self, property_id, required, *, source="catalog"):
            return _Bundle()

        def background(self, required, *, limit=50):
            return background_rows

    monkeypatch.setattr(svc, "PropertyFeatureRepository", _Repo)
    return svc.PropertyInsightsService(session=object(), analytics_session=object())


# -- registry ---------------------------------------------------------------


def test_every_model_feature_has_a_label_and_a_category(feature_names):
    assert len(svc.FEATURE_LABELS) == len(feature_names) == 47
    assert [f for f in feature_names if f not in svc.FEATURE_LABELS] == []
    # "other" would mean a contribution silently escapes the five categories.
    assert [f for f in feature_names if category_of(f) == "other"] == []


def test_categories_match_the_documented_baseline_grouping(feature_names):
    counts: dict[str, int] = {}
    for name in feature_names:
        counts[category_of(name)] = counts.get(category_of(name), 0) + 1
    # baseline_47 grouping: 7 population / 14 demand / 13 access / 3 parking / 10 competition
    assert counts == {
        "population": 7,
        "demand_generators": 14,
        "accessibility": 13,
        "parking": 3,
        "competitors": 10,
    }
    assert [spec["label"] for spec in svc.CATEGORY_SPECS] == [
        "People Nearby",
        "Other Food Businesses",
        "Nearby Places",
        "Getting There",
        "Parking Nearby",
    ]


def test_value_formatting_is_truthful_at_small_magnitudes():
    # A tiny isochrone must not collapse to "0".
    assert svc.format_feature_value("walk_isochrone_area_10min_km2", 0.0006) == "0.0006 km²"
    assert svc.format_feature_value("pop_500m", 13656.0) == "13,656 people"
    assert svc.format_feature_value("nearest_major_road_m", 68.0) == "68 m"
    assert svc.format_feature_value("road_length_density_500m_km_km2", 21.1525) == "21.2 km/km²"
    assert svc.format_feature_value("parking_facilities_1km", 10.0) == "10"
    assert svc.format_feature_value("pop_500m", None) == "not measured"


# -- the real explanation ---------------------------------------------------


def test_payload_reconciles_with_the_model_output(monkeypatch, reference_features, background):
    service = _service(monkeypatch, features=reference_features, background_rows=background)
    out = service.insights(REFERENCE_PROPERTY_ID)

    assert out["availability"] == {
        "score": True,
        "explanation": True,
        "factors": True,
        "categories": True,
    }
    score = out["score"]
    explanation = out["explanation"]

    assert score["available"] is True
    assert 0 <= score["value"] <= 100
    # The displayed index is the model output rescaled, nothing else.
    assert score["value"] == round(explanation["output"] * 100)
    assert score["kind"] == "pu_association"
    assert score["research_only"] is True
    assert "NOT a probability" in score["meaning"]

    # Additivity is the guarantee that the explanation describes this score.
    assert explanation["additivity_ok"] is True
    total = sum(f["contribution"] for f in explanation["factors"])
    assert abs(explanation["base_value"] + total - explanation["output"]) < 1e-6
    assert explanation["reconstructed"] == explanation["output"]
    assert explanation["background_size"] == len(background) == 25
    assert explanation["feature_count"] == 47


def test_payload_never_exposes_raw_column_names_as_labels(monkeypatch, reference_features, background):
    service = _service(monkeypatch, features=reference_features, background_rows=background)
    out = service.insights(REFERENCE_PROPERTY_ID)

    factors = out["explanation"]["factors"]
    assert len(factors) == 47
    # The technical key is retained for audit, but the label is prose.
    assert all("_m" not in f["label"] and "pois" not in f["label"] for f in factors)
    assert all(f["technical"] in svc.FEATURE_LABELS for f in factors)
    assert all(f["label"] == svc.FEATURE_LABELS[f["technical"]] for f in factors)


def test_all_five_categories_are_present_and_totals_reconcile(monkeypatch, reference_features, background):
    service = _service(monkeypatch, features=reference_features, background_rows=background)
    out = service.insights(REFERENCE_PROPERTY_ID)

    categories = out["categories"]
    labels = [c["label"] for c in categories]
    assert labels == [
        "People Nearby",
        "Other Food Businesses",
        "Nearby Places",
        "Getting There",
        "Parking Nearby",
    ]
    assert all(c["available"] for c in categories)
    assert all(c["feature_count"] > 0 for c in categories)
    assert all(c["question"] and c["why"] for c in categories)

    # Category totals plus the baseline must reconstruct the output too, or a
    # contribution is being dropped somewhere between the two views.
    grouped = sum(c["contribution"] for c in categories)
    assert abs(out["explanation"]["base_value"] + grouped - out["explanation"]["output"]) < 1e-6


def test_different_properties_get_different_explanations(monkeypatch, reference_features, background):
    """Two distinct feature vectors must not share one explanation."""
    second = dict(background[0])  # a real analysed row, not a synthetic vector

    first_out = _service(
        monkeypatch, features=reference_features, background_rows=background
    ).insights(REFERENCE_PROPERTY_ID)
    second_out = _service(
        monkeypatch, features=second, background_rows=background
    ).insights("MD-99999")

    assert first_out["explanation"]["output"] != second_out["explanation"]["output"]
    assert first_out["score"]["value"] != second_out["score"]["value"]
    assert (
        first_out["explanation"]["factors"][0]["contribution"]
        != second_out["explanation"]["factors"][0]["contribution"]
    )


# -- honest failure modes ---------------------------------------------------


def test_missing_background_withholds_the_score(monkeypatch, reference_features):
    out = _service(monkeypatch, features=reference_features, background_rows=[]).insights(
        REFERENCE_PROPERTY_ID
    )
    assert out["reason"]["code"] == "shap_background_missing"
    assert out["score"]["available"] is False
    assert "value" not in out["score"]
    assert out["explanation"]["available"] is False
    assert all(c["available"] is False for c in out["categories"])


def test_missing_features_withhold_the_score(monkeypatch, reference_features, background):
    out = _service(
        monkeypatch,
        features=reference_features,
        background_rows=background,
        missing=["pop_500m", "parking_facilities_1km"],
    ).insights(REFERENCE_PROPERTY_ID)
    assert out["reason"]["code"] == "features_missing"
    assert out["score"]["available"] is False
    assert out["reason"]["missing_features"] == ["pop_500m", "parking_facilities_1km"]


def test_unavailable_categories_are_reported_not_invented(monkeypatch, reference_features, background):
    """A category with no valid contributions says so instead of showing zeros."""
    trimmed = {
        k: v for k, v in reference_features.items() if category_of(k) != "parking"
    }
    # The model still needs all 47 features, so only the payload's category view
    # is exercised here through the pure grouping helper.
    contributions = {name: 0.01 for name in trimmed}
    payloads = svc._category_payloads(contributions, trimmed)
    parking = next(p for p in payloads if p["key"] == "parking")
    assert parking["available"] is False
    assert parking["factors"] == []
    assert parking["note"]


# -- caching ----------------------------------------------------------------


def test_explanation_is_cached_per_model_version(monkeypatch, reference_features, background):
    calls = {"n": 0}
    real_explain = svc.ShapExplainer.explain

    def counting(self, features, **kwargs):
        calls["n"] += 1
        return real_explain(self, features, **kwargs)

    monkeypatch.setattr(svc.ShapExplainer, "explain", counting)

    service = _service(monkeypatch, features=reference_features, background_rows=background)
    first = service.insights(REFERENCE_PROPERTY_ID)
    second = service.insights(REFERENCE_PROPERTY_ID)

    assert calls["n"] == 1, "the second read must not recompute permutation SHAP"
    assert first["score"] == second["score"]
    assert first["explanation"]["factors"] == second["explanation"]["factors"]

    # Replacing the artifact must invalidate the entry.
    version = str(resolve_version())
    key = (version, REFERENCE_PROPERTY_ID)
    assert key in svc._EXPLANATION_CACHE
    assert svc.clear_insights_cache() == 1
    service.insights(REFERENCE_PROPERTY_ID)
    assert calls["n"] == 2


def resolve_version() -> str:
    variant = svc.PropertyInsightsService(session=None, analytics_session=None)._variant()
    return str(variant.get("version") or variant["layer1_model"])


def test_model_is_the_deployed_legacy_artifact():
    loaded = ModelLoader().load("pu_model")
    assert len(loaded.feature_names) == 47
    # This artifact carries ``feature_set`` and no separate ``version``; the
    # variant resolver falls back to the feature set, which is what the cache
    # key and the payload's ``model_version`` report.
    meta = loaded.meta or {}
    assert (meta.get("version") or meta.get("feature_set")) == "baseline_47"
    assert meta.get("score_meaning") == (
        "research_positive_label_association_NOT_business_success_probability"
    )


# -- map layers -------------------------------------------------------------


def test_map_exposes_the_five_layers_in_display_order(monkeypatch, reference_features, background):
    service = _service(monkeypatch, features=reference_features, background_rows=background)
    out = service.insights(REFERENCE_PROPERTY_ID, origin={"lat": 3.02, "lon": 101.51})

    layers = out["map"]["layers"]
    assert [layer["key"] for layer in layers] == [
        "properties",
        "competitors",
        "demand_generators",
        "accessibility",
        "parking",
    ]
    assert [layer["label"] for layer in layers] == [
        "Properties",
        "Food Businesses",
        "Nearby Places",
        "Transport",
        "Parking",
    ]
    # Only the catalogue has coordinates. Claiming otherwise would put pins on
    # the map that no stored location can justify.
    assert [layer["mapped"] for layer in layers] == [True, False, False, False, False]
    assert out["origin"] == {"lat": 3.02, "lon": 101.51}


def test_map_layer_counts_come_from_the_property_feature_vector(monkeypatch, reference_features, background):
    service = _service(monkeypatch, features=reference_features, background_rows=background)
    out = service.insights(REFERENCE_PROPERTY_ID)
    by_key = {layer["key"]: layer for layer in out["map"]["layers"]}

    # MD-00510 records 1 F&B outlet within 500 m and 5 within 1 km.
    assert by_key["competitors"]["count_500m"] == round(reference_features["fnb_competitors_500m"])
    assert by_key["competitors"]["count_1000m"] == round(reference_features["fnb_competitors_1000m"])

    assert by_key["parking"]["count_500m"] == round(reference_features["parking_facilities_500m"])
    assert by_key["parking"]["count_1000m"] == round(reference_features["parking_facilities_1km"])
    assert by_key["parking"]["nearest_m"] == round(reference_features["nearest_parking_distance_m"], 1)

    assert by_key["accessibility"]["count_500m"] == round(reference_features["transit_stops_500m_walk"])
    assert by_key["accessibility"]["nearest_m"] == round(reference_features["nearest_transit_walk_m"], 1)

    demand = by_key["demand_generators"]
    expected_500 = round(
        reference_features["retail_pois_500m"]
        + reference_features["malls_count_500m"]
        + reference_features["supermarkets_count_500m"]
        + reference_features["office_pois_500m"]
        + reference_features["schools_count_500m"]
        + reference_features["universities_colleges_count_500m"]
        + reference_features["hospitals_count_500m"]
    )
    assert demand["count_500m"] == expected_500


def test_map_layer_metrics_use_friendly_labels(monkeypatch, reference_features, background):
    service = _service(monkeypatch, features=reference_features, background_rows=background)
    out = service.insights(REFERENCE_PROPERTY_ID)

    metrics = [m for layer in out["map"]["layers"] for m in layer["metrics"]]
    assert metrics, "mapped layers must expose their contributing measurements"
    assert all(m["label"] == svc.FEATURE_LABELS[m["technical"]] for m in metrics)
    assert all("_" not in m["label"] for m in metrics)


def test_unmeasured_layers_report_no_counts_rather_than_zero():
    layers = svc._layer_payloads({}, measured=False)
    assert [layer["count_500m"] for layer in layers] == [None] * 5
    assert all(layer["note"] for layer in layers)


def test_panorama_is_withheld_without_a_verified_link():
    service = svc.PropertyInsightsService(session=None, analytics_session=None)
    assert service._panorama(REFERENCE_PROPERTY_ID) == {
        "available": False,
        "status": "unavailable",
        "url": None,
        "reason": "No completed 360° panorama is linked to this property.",
    }


def test_panorama_requires_a_completed_status(monkeypatch):
    class _Result:
        def __init__(self, rows):
            self._rows = rows

        def fetchall(self):
            return self._rows

    class _Session:
        def __init__(self, rows):
            self._rows = rows

        def execute(self, *args, **kwargs):
            return _Result(self._rows)

    service = svc.PropertyInsightsService(session=None, analytics_session=_Session([("https://x/p.jpg", "pending")]))
    out = service._panorama(REFERENCE_PROPERTY_ID)
    assert out["available"] is False
    assert out["status"] == "processing"
    assert out["url"] is None

    service = svc.PropertyInsightsService(session=None, analytics_session=_Session([("https://x/p.jpg", "complete")]))
    out = service._panorama(REFERENCE_PROPERTY_ID)
    assert out == {"available": True, "status": "ready", "url": "https://x/p.jpg", "reason": None}
