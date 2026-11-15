"""Focused verification for the integrated 54-feature F&B category model.

Runs WITHOUT a database. Every vector comes from the supplied training package
(the artifact's own training observations), so each assertion is a parity
check against the source of truth:

* artifact loading — 54 features in the saved order, four canonical classes,
  research-only metadata;
* leakage control — none of the ten F&B competitor-count columns is in the
  category contract;
* inference parity — the integrated module reproduces the package's own
  ``Example_MD-00510_Prediction.json`` scores exactly;
* policy — only residential measurements may reach the saved median imputer;
* batch parity — the vectorised batch equals the single-row path;
* SHAP — real permutation contributions reconstruct the model probability
  within the package tolerance (2e-3);
* label provenance — 880 KNOWN_FNB_CATEGORY P rows, 916 unlabelled U rows, the
  documented four-category distribution.

Nothing here trains, writes, or touches a database.
"""
from __future__ import annotations

import csv
import json
import math
from pathlib import Path

import pytest

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.fnb_category import (
    CANONICAL_CATEGORIES,
    CATEGORY_BACKGROUND_CSV,
    CATEGORY_MODEL_NAME,
    COMPETITOR_CONTEXT_FEATURES,
    category_explanation,
    category_feature_names,
    match_business_type,
    predict_categories,
    predict_categories_many,
)
from sitewise.ml.model_loader import ModelLoader

BACKEND_DIR = Path(__file__).resolve().parents[1]
PACKAGE = BACKEND_DIR / "ml_reference" / "fnb_category_pu_2026_11_15"
DATASET = PACKAGE / "SiteWise_PU_1796_Expanded_Observed.csv"
EXAMPLE = PACKAGE / "Example_MD-00510_Prediction.json"
LABELS_XLSX = PACKAGE / "SiteWise_PU_1796_With_Known_Business_Types.xlsx"

REFERENCE_SUBJECT = "MD-00510"


@pytest.fixture(scope="module")
def rows() -> dict[str, dict[str, str]]:
    with DATASET.open(encoding="utf-8-sig", newline="") as stream:
        return {row["subject_id"]: row for row in csv.DictReader(stream)}


@pytest.fixture(scope="module")
def loaded():
    return ModelLoader().load(CATEGORY_MODEL_NAME)


def _vector(row: dict[str, str], names: list[str]) -> dict[str, float | None]:
    values: dict[str, float | None] = {}
    for name in names:
        raw = (row.get(name) or "").strip()
        values[name] = float(raw) if raw else None
    return values


# -- artifact contract ------------------------------------------------------


def test_loader_reads_the_saved_54_feature_contract(loaded):
    assert len(loaded.feature_names) == 54
    assert loaded.meta.get("version") == "fnb_category_pu_v1_20261115"
    assert loaded.meta.get("selected_model") == "histboost_expanded54"
    assert loaded.meta.get("n_P") == 880 and loaded.meta.get("n_U") == 916
    assert list(loaded.model.classes_) == list(CANONICAL_CATEGORIES)


def test_competitor_counts_are_excluded_from_the_category_contract(loaded):
    leaked = [n for n in loaded.feature_names if n in COMPETITOR_CONTEXT_FEATURES]
    assert leaked == [], (
        "competitor counts must stay out of category training (self-inclusion)"
    )
    # The context columns still exist for display.
    assert len(COMPETITOR_CONTEXT_FEATURES) == 10


def test_pu_contract_is_not_the_category_contract(loaded):
    pu = ModelLoader().load("sitewise_pu_64_expanded")
    assert len(pu.feature_names) == 64
    assert set(loaded.feature_names) < set(pu.feature_names)
    assert set(pu.feature_names) - set(loaded.feature_names) == set(
        COMPETITOR_CONTEXT_FEATURES
    )


# -- inference parity -------------------------------------------------------


def test_inference_matches_the_package_example(rows):
    example = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    result = predict_categories(_vector(rows[REFERENCE_SUBJECT], category_feature_names()))
    assert result["available"] is True
    expected = {
        item["business_type"]: item["category_resemblance_score"]
        for item in example["category_rankings_exploratory"]
    }
    assert set(expected) == set(CANONICAL_CATEGORIES)
    for ranking in result["rankings"]:
        assert ranking["score"] == pytest.approx(
            expected[ranking["business_type"]], abs=1e-6
        )
    assert result["top_category"] == "Restaurant"


def test_batch_matches_the_single_row_path(rows):
    names = category_feature_names()
    subjects = [REFERENCE_SUBJECT, "MD-04816", "MD-00057"]
    vectors = {s: _vector(rows[s], names) for s in subjects}
    batch = predict_categories_many(vectors)
    for subject in subjects:
        single = predict_categories(vectors[subject])
        assert batch[subject]["available"] is True
        assert batch[subject]["top_score"] == pytest.approx(
            single["top_score"], abs=0
        )
        assert batch[subject]["top_category"] == single["top_category"]


# -- missing-value policy ---------------------------------------------------


def test_missing_non_residential_feature_refuses_to_score(rows):
    values = _vector(rows[REFERENCE_SUBJECT], category_feature_names())
    values["pop_500m"] = None
    with pytest.raises(ModelUnavailableError) as exc:
        predict_categories(values)
    assert "pop_500m" in str(exc.value)


def test_missing_residential_value_is_imputed(rows):
    # Find a real training row with a missing residential measurement.
    names = category_feature_names()
    incomplete = next(
        (row for row in rows.values()
         if any((row.get(n) or "").strip() == "" for n in names)),
        None,
    )
    assert incomplete is not None, "expected at least one incomplete residential row"
    values = _vector(incomplete, names)
    missing = [n for n, v in values.items() if v is None]
    assert missing and all(n.startswith("residential_") for n in missing)
    result = predict_categories(values)
    assert result["available"] is True
    assert set(result["imputed_features"]) == set(missing)
    assert all(math.isfinite(r["score"]) for r in result["rankings"])


# -- SHAP -------------------------------------------------------------------


def test_category_shap_reconstructs_the_model_output(rows):
    values = _vector(rows[REFERENCE_SUBJECT], category_feature_names())
    explained = category_explanation(values)
    assert explained["explained_output"]["business_type"] == "Restaurant"
    assert explained["reconstruction_error"] <= 2e-3
    assert explained["background_size"] == 32
    assert len(explained["contributions"]) == 54
    assert CATEGORY_BACKGROUND_CSV.is_file()


def test_category_shap_is_refused_for_imputed_rows(rows):
    names = category_feature_names()
    incomplete = next(
        (row for row in rows.values()
         if any((row.get(n) or "").strip() == "" for n in names)),
        None,
    )
    assert incomplete is not None
    with pytest.raises(ModelUnavailableError):
        category_explanation(_vector(incomplete, names))


# -- label provenance -------------------------------------------------------


def test_category_labels_are_verified_known_outlets_only():
    import openpyxl

    wb = openpyxl.load_workbook(LABELS_XLSX, read_only=True, data_only=True)
    ws = wb["Complete PU 1796"]
    header = list(next(ws.iter_rows(min_row=1, max_row=1, values_only=True)))
    idx = {name: i for i, name in enumerate(header)}
    counts: dict[str, int] = {}
    statuses: dict[str, int] = {}
    classes: dict[str, int] = {}
    for row in ws.iter_rows(min_row=2, values_only=True):
        if row[0] is None:
            continue
        classes[row[idx["sample_class"]]] = classes.get(row[idx["sample_class"]], 0) + 1
        status = str(row[idx["business_type_status"]])
        statuses[status] = statuses.get(status, 0) + 1
        if row[idx["business_type"]]:
            counts[row[idx["business_type"]]] = counts.get(row[idx["business_type"]], 0) + 1
    wb.close()
    assert classes == {"P": 880, "U": 916}
    assert statuses == {"KNOWN_FNB_CATEGORY": 880, "UNKNOWN_UNLABELLED": 916}
    assert counts == {
        "Cafe / Coffee": 253,
        "Restaurant": 327,
        "Bakery / Dessert / Beverage": 183,
        "Fast Food / Takeaway": 117,
    }
    # U rows carry no category label: they are unlabelled, never negatives.
    assert sum(counts.values()) == 880


def test_business_type_mapping_is_explicit():
    assert match_business_type("Café / Coffee Shop") == "Cafe / Coffee"
    assert match_business_type("Restaurant") == "Restaurant"
    assert match_business_type("Bakery") == "Bakery / Dessert / Beverage"
    assert match_business_type("Fast Food / Takeaway") == "Fast Food / Takeaway"
    assert match_business_type("Retail space") is None
    assert match_business_type(None) is None
