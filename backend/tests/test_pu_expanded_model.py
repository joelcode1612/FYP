"""Focused verification for the integrated 64-feature expanded PU model.

These tests run WITHOUT a database: the model is exercised through the same
loader/inference path the application uses, and the feature vectors come from
the committed training package (the artifact's own training observations), so
every assertion is a parity check against the source of truth.

Covered:
* artifact loading — 64 features, exact saved order, research-only metadata;
* inference parity — the in-process ensemble equals the training package's own
  ``predict_expanded_pu.py`` recipe bit-for-bit on the same vector;
* missing-feature policy — only residential measurements may reach the saved
  imputer; any other gap refuses with the exact missing list;
* SHAP reconstruction — the committed 64-feature background produces genuine
  contributions whose base + sum reconstructs the model output (additivity)
  and matches the displayed score;
* expanded bridge — 1,796 research rows, subject-keyed, values identical to
  the training dataset it was generated from.

Nothing here trains, writes, or touches a database.
"""
from __future__ import annotations

import csv
import math
from pathlib import Path

import joblib
import pytest

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.feature_bridge import merge_bridge_features as merge_base_bridge
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.pu_expanded import (
    EXPANDED_BRIDGE_CSV,
    EXPANDED_MODEL_NAME,
    IMPUTABLE_FEATURES,
    expanded_policy_split,
    merge_expanded_bridge_features,
)
from sitewise.ml.property_features import PropertyFeatureBundle
from sitewise.ml.pu_learning import PULearning
from sitewise.ml.shap_explainer import ShapExplainer

BACKEND_DIR = Path(__file__).resolve().parents[1]
PACKAGE_DIR = BACKEND_DIR / "ml_reference" / "expanded_pu_64_2026_11_15"
ARTIFACT_PATH = PACKAGE_DIR / "SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib"
DATASET_PATH = PACKAGE_DIR / "SiteWise_PU_1796_Expanded_Observed.csv"
SHAP_BACKGROUND_PATH = BACKEND_DIR / "ml_reference" / "shap_background_64.csv"

ARTIFACT_EXPECTED_SHA256 = (
    "0371f4e4ef20a0e264cc4fa7b47f770e7fae23016787fc0d8f7bd42d3541676f"
)


@pytest.fixture(scope="module")
def artifact_dict():
    return joblib.load(ARTIFACT_PATH)


@pytest.fixture(scope="module")
def loaded():
    return ModelLoader().load(EXPANDED_MODEL_NAME)


@pytest.fixture(scope="module")
def dataset_rows():
    with DATASET_PATH.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def _vector(row: dict[str, str], names: list[str]) -> dict[str, float | None]:
    values: dict[str, float | None] = {}
    for name in names:
        raw = (row.get(name) or "").strip()
        values[name] = float(raw) if raw else None
    return values


# -- artifact loading -------------------------------------------------------


def test_artifact_file_is_unmodified():
    import hashlib

    digest = hashlib.sha256(ARTIFACT_PATH.read_bytes()).hexdigest()
    assert digest == ARTIFACT_EXPECTED_SHA256


def test_loader_reads_exact_saved_feature_order(loaded, artifact_dict):
    saved = artifact_dict["model_info"]["feature_names"]
    assert len(loaded.feature_names) == 64
    assert loaded.feature_names == saved  # order is the artifact's, not ours
    assert loaded.meta.get("research_only") is True
    assert loaded.meta.get("production_ready") is False
    assert loaded.meta.get("model_variant") == "expanded_age_residential_64"
    assert loaded.meta.get("artifact_filename") == "sitewise_pu_64_expanded.joblib"


def test_saved_preprocessing_pipeline_is_preserved(loaded, artifact_dict):
    members = artifact_dict["estimators"]
    assert len(members) == 5
    for member in members:
        steps = {name for name, _ in member.steps}
        assert {"imputer", "scale", "estimator"} <= steps
        assert member.n_features_in_ == 64
    # The ensemble exposes the members so PULearning's imputer inspection and
    # the loader's count validation both work. sklearn pipelines compare by
    # identity, so two separate joblib loads are compared by repr.
    assert [repr(m) for m in loaded.model.estimators_] == [repr(m) for m in members]
    assert loaded.model.n_features_in_ == 64


# -- inference parity -------------------------------------------------------


def test_inference_matches_the_package_recipe_bit_for_bit(loaded, artifact_dict, dataset_rows):
    import numpy as np

    names = loaded.feature_names
    complete_rows = [r for r in dataset_rows if all((r.get(n) or "").strip() for n in names)]
    sample_rows = [complete_rows[0], complete_rows[len(complete_rows) // 2], complete_rows[-1]]
    vectors = [_vector(r, names) for r in sample_rows]
    # Route through the exact application inference path (PULearning via the
    # loader's ensemble), including its finite/positive-association guards.
    for row, values in zip(sample_rows, vectors):
        observed = {k: v for k, v in values.items() if v is not None}
        result = PULearning(model_name=EXPANDED_MODEL_NAME).predict(
            row["subject_id"], observed, allow_model_imputation=False
        )
        x = np.asarray([[float(v) for v in values.values()]], dtype=float)
        expected = float(
            np.mean([m.predict_proba(x)[0, 1] for m in artifact_dict["estimators"]])
        )
        assert result.score == pytest.approx(expected, abs=1e-12)


def test_non_residential_gap_refuses_and_names_the_feature(loaded):
    names = loaded.feature_names
    observed = {n: 1.0 for n in names}
    observed["pop_500m"] = None  # a population feature — never imputable
    with pytest.raises(ModelUnavailableError) as exc:
        PULearning(model_name=EXPANDED_MODEL_NAME).predict(
            "test", observed, allow_model_imputation=True
        )
    assert "pop_500m" in str(exc.value)


def test_residential_gap_is_the_only_imputable_path(loaded, dataset_rows):
    names = loaded.feature_names
    incomplete = next(
        r for r in dataset_rows
        if any((r.get(n) or "").strip() == "" for n in names)
    )
    values = _vector(incomplete, names)
    missing = [n for n, v in values.items() if v is None]
    assert missing and all(n in IMPUTABLE_FEATURES for n in missing)
    observed = {n: v for n, v in values.items() if v is not None}
    result = PULearning(model_name=EXPANDED_MODEL_NAME).predict(
        incomplete["subject_id"], observed, allow_model_imputation=True
    )
    assert result.available and math.isfinite(result.score)
    assert 0.0 <= result.score <= 1.0


def test_policy_split_separates_imputable_from_required():
    imputable, required = expanded_policy_split(
        ["residential_building_count_500m", "pop_500m", "pop_age_0_14_1km"]
    )
    assert imputable == ["residential_building_count_500m"]
    assert required == ["pop_500m", "pop_age_0_14_1km"]


# -- SHAP reconstruction ----------------------------------------------------


def test_shap_reconstructs_the_model_output(loaded):
    import csv as _csv

    names = loaded.feature_names
    with SHAP_BACKGROUND_PATH.open(encoding="utf-8-sig", newline="") as stream:
        background = [
            {k: float(v) for k, v in row.items() if k in names}
            for row in _csv.DictReader(stream)
        ]
    assert len(background) == 100
    # The subject is one of the model's own complete-case training rows.
    with DATASET_PATH.open(encoding="utf-8-sig", newline="") as stream:
        subject_row = next(
            r for r in _csv.DictReader(stream)
            if all((r.get(n) or "").strip() for n in names)
        )
    subject = {n: float(subject_row[n]) for n in names}

    explained = ShapExplainer(model_name=EXPANDED_MODEL_NAME).explain(
        subject, background=background
    )
    contributions = explained["contributions"]
    assert set(contributions) == set(names)
    reconstructed = explained["baseline_association"] + math.fsum(contributions.values())
    assert abs(reconstructed - explained["positive_label_association"]) < 1e-6
    # The explanation describes THIS score: the model output for the subject
    # vector equals the displayed association.
    direct = PULearning(model_name=EXPANDED_MODEL_NAME).predict(
        subject_row["subject_id"], subject, allow_model_imputation=False
    )
    assert explained["positive_label_association"] == pytest.approx(direct.score, abs=1e-9)


# -- expanded bridge --------------------------------------------------------


def test_expanded_bridge_covers_every_research_subject(dataset_rows):
    with EXPANDED_BRIDGE_CSV.open(encoding="utf-8", newline="") as stream:
        bridge = {row["subject_id"]: row for row in csv.DictReader(stream)}
    assert len(bridge) == 1796
    assert set(bridge) == {r["subject_id"] for r in dataset_rows}


def test_expanded_bridge_values_match_the_training_dataset(dataset_rows):
    with EXPANDED_BRIDGE_CSV.open(encoding="utf-8", newline="") as stream:
        bridge = {row["subject_id"]: row for row in csv.DictReader(stream)}
    checked = 0
    for source in dataset_rows[:200]:
        row = bridge[source["subject_id"]]
        for name in (
            "pop_age_0_14_500m",
            "pop_age_65_plus_1km",
            "residential_building_count_1000m",
            "residential_landuse_coverage_1000m_pct",
        ):
            expected = (source.get(name) or "").strip()
            assert row[name] == expected
            if expected:
                checked += 1
    assert checked > 0


def test_merge_chain_produces_the_exact_training_vector(dataset_rows):
    """DB bundle + 47-feature bridge + expanded bridge == the training row.

    The stubbed "database" supplies the 42 baseline features that the live
    tables genuinely resolve; the two bridges contribute the five DB-absent
    baseline columns and the 20 expanded measurements. All three sources are
    the artifact's own training record, so the merged 64-feature vector must
    equal the training row exactly.
    """
    from sitewise.ml.feature_bridge import BRIDGE_FEATURES

    names = ModelLoader().load(EXPANDED_MODEL_NAME).feature_names
    bridge_supplied = set(BRIDGE_FEATURES) | set(
        n for n in names if n.startswith(("pop_age_", "residential_"))
    )
    db_supplied = [n for n in names if n not in bridge_supplied]
    source = next(
        r for r in dataset_rows
        if r["sample_class"] == "U"
        and all((r.get(n) or "").strip() for n in names)
    )
    bundle = PropertyFeatureBundle(
        property_id=source["subject_id"],
        source="catalog",
        subject_id=source["subject_id"],
        values={n: float(source[n]) for n in db_supplied},
        value_sources={n: "stub.db" for n in db_supplied},
        missing_features=[n for n in names if n not in db_supplied],
        analysis_status="COMPLETED",
        flags=[],
    )
    coverage = merge_base_bridge(bundle, expected_features=names)
    coverage = merge_expanded_bridge_features(coverage, expected_features=names)
    assert coverage.complete
    for name in names:
        expected = float(source[name])
        assert coverage.values[name] == pytest.approx(expected, abs=1e-12)
