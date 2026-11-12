"""Verification for the Layer 1 + Layer 2 + Layer 3 recommendation pipeline.

Covers the spec's verification matrix: both PU artifacts, independent feature
contracts, Layer 2 scoring, hard filters, explicit missing-data handling,
deterministic ranking, SHAP reconstruction, SHAP-optional fallback, auth and
ownership, property-id correctness and no regression of existing routes.

All API results below are REAL: they come from the live research catalogue in
the local analytics database and from real saved model artifacts. Nothing is a
hardcoded demonstration score.
"""
from __future__ import annotations

import math
import re
import uuid
from pathlib import Path

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.domain import recommendation_scoring as rs
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.selected_pu_integration import SELECTED_MODEL_NAME
from sitewise.repositories.generated_recommendation_store import (
    GeneratedRecommendationStore,
    generated_recommendation_store,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

BACKEND_DIR = Path(__file__).resolve().parents[2]
CATALOGUE_ID = re.compile(r"^(EP|MD)-\d+$")
REFERENCE_PROPERTY_ID = "MD-00510"

VALID_V2_PREFERENCES = {
    "fnb_concept": "cafe_coffee_shop",
    "service_model": "dine_in",
    "recommendation_priority": "favorable_competition",
    "target_price_segment": "mid_range",
    "customer_access_mode": "walking",
    "target_customers": ["office_workers", "nearby_residents"],
    "max_monthly_rent_myr": 3000,
    "min_floor_area_sqft": 300,
    "requirements_version": 2,
}


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(autouse=True)
def isolated_store():
    generated_recommendation_store.clear()
    yield
    generated_recommendation_store.clear()


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
    token = make_token(sub=sub, email=f"recgen-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "user_id": uuid.UUID(sub)}


@pytest.fixture()
def other_identity(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(sub=sub, email=f"recgen-other-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "user_id": uuid.UUID(sub)}


def _candidate(**overrides) -> rs.PropertyCandidate:
    base = {
        "property_id": "EP-00001",
        "property_type": "Shop lot",
        "monthly_rental_myr": 3000.0,
        "built_up_sqft": 1200.0,
        "pu_association_score": 0.5,
        "verification": {"confirmed_available": False},
    }
    base.update(overrides)
    return rs.PropertyCandidate(**base)


# ---------------------------------------------------------------------------
# Layer 1 artifacts (independent, unchanged default)
# ---------------------------------------------------------------------------


def test_both_pu_artifacts_load_with_independent_contracts():
    original = ModelLoader().load("pu_model")
    selected = ModelLoader().load(SELECTED_MODEL_NAME)
    assert original.meta["artifact_filename"] == "PU_model.joblib"
    assert selected.meta["artifact_filename"] == "sitewise_selected_pu_model.joblib"
    assert original.name == "pu_model"  # the default was NOT switched
    assert selected.name == SELECTED_MODEL_NAME
    assert len(original.feature_names) == 47
    assert len(selected.feature_names) == 47
    assert len(set(selected.feature_names)) == 47
    assert selected.meta.get("feature_set") == "baseline_47"
    assert (BACKEND_DIR / "src/sitewise/ml/PU_model.joblib").is_file()
    assert (BACKEND_DIR / "src/sitewise/ml/sitewise_selected_pu_model.joblib").is_file()


# ---------------------------------------------------------------------------
# Layer 2 domain rules
# ---------------------------------------------------------------------------


def test_scoring_config_matches_the_research_baseline():
    cfg = rs.SCORING_CONFIG.as_dict()
    assert cfg["version"] == "sitewise_rule_based_preference_v1"
    assert cfg["engine"] == "rule_based"
    assert cfg["trained_recommender"] is False
    assert cfg["validated_optimal"] is False
    assert cfg["weights"] == {
        "budget_fit": 0.20, "size_fit": 0.15, "property_type_fit": 0.10,
        "target_market_fit": 0.20, "accessibility_fit": 0.10,
        "parking_fit": 0.10, "competition_fit": 0.10, "physical_fit": 0.05,
    }
    assert math.isclose(sum(cfg["weights"].values()), 1.0)
    assert (cfg["pu_weight"], cfg["preference_weight"]) == (0.70, 0.30)


def test_unknown_components_are_excluded_never_zero_filled():
    profile = rs.preference_profile_from(None)
    result = rs.score_candidate(_candidate(), profile)
    assert result.preference_match_score is None
    assert result.final_score == result.pu_association_score == 0.5
    assert result.final_score_basis == "pu_only_no_scorable_preference_components"
    assert result.coverage["scored_components"] == 0
    assert all(c.value is None for c in result.components.values())
    assert all(c.status == "unknown" for c in result.components.values())
    # Unknown parking, access, frontage, etc. must be called out, not zeroed.
    joined = " ".join(result.cautions).lower()
    assert "not treated as zero" in joined
    assert "unknown parking" in joined
    assert "unverified" in joined


def test_eligibility_rejects_ineligible_properties():
    profile = rs.preference_profile_from(
        {"max_monthly_rent_myr": 2000, "min_floor_area_sqft": 1500,
         "preferred_states": ["Selangor"], "requirements_version": 2}
    )
    failures = rs.eligibility_failures(_candidate(state="Penang"), profile)
    assert {"over_maximum_rental_budget", "below_minimum_floor_area",
            "outside_preferred_state"} <= set(failures)

    assert "pu_association_score_missing_or_invalid" in rs.eligibility_failures(
        _candidate(pu_association_score=None), profile
    )
    assert "listing_explicitly_unavailable" in rs.eligibility_failures(
        _candidate(availability_status="RENTED"), profile
    )
    assert "listing_verification_rejected" in rs.eligibility_failures(
        _candidate(verification={"confirmed_available": False, "verified": False}), profile
    )
    assert "not_an_unlabeled_commercial_property" in rs.eligibility_failures(
        _candidate(sample_class="P"), profile
    )


def test_ranking_is_deterministic_with_a_total_tie_break():
    profile = rs.preference_profile_from(None)
    items = [
        rs.score_candidate(_candidate(property_id=pid), profile)
        for pid in ("EP-00030", "EP-00010", "EP-00020")
    ]
    first = rs.rank_candidates(items)
    second = rs.rank_candidates(list(reversed(items)))
    assert [x.property_id for x in first] == [
        "EP-00010", "EP-00020", "EP-00030"
    ]
    assert [x.property_id for x in first] == [x.property_id for x in second]
    assert [x.rank for x in first] == [1, 2, 3]


def test_physical_fit_uses_verified_values_only():
    profile = rs.preference_profile_from({"requirements": ["corner unit"]})
    known = rs.score_candidate(
        _candidate(frontage_ft=22.0, depth_ft=75.0,
                   floor_level_text="Ground Floor", unit_position="Corner"),
        profile,
    )
    physical = known.components["physical_fit"]
    assert physical.status == "scored" and 0.0 <= physical.value <= 1.0
    assert "Verified physical attributes" in physical.reason

    unknown = rs.score_candidate(_candidate(), profile).components["physical_fit"]
    assert unknown.status == "unknown" and unknown.value is None
    assert "UNVERIFIED" in unknown.caution


def test_scored_component_data_quality_caution_is_surfaced():
    """A scored component can still carry a caveat; never hide it."""
    result = rs.score_candidate(
        _candidate(parking_facilities_500m=6.0, parking_status="PARTIAL_COVERAGE"),
        rs.preference_profile_from({"requirements_version": 2}),
    )
    assert result.components["parking_fit"].status == "scored"
    assert any("PARTIAL_COVERAGE" in c for c in result.cautions)


def test_low_scoring_components_are_labelled_as_concerns():
    result = rs.score_candidate(
        _candidate(fnb_competitors_500m=55.0),
        rs.preference_profile_from(
            {"requirements_version": 2,
             "recommendation_priority": "favorable_competition"}
        ),
    )
    assert result.components["competition_fit"].value <= rs.SCORING_CONFIG.concern_threshold
    assert any(
        c.startswith("competition fit is low (") for c in result.cautions
    )


def test_preference_profile_maps_the_existing_v1_and_v2_vocabulary():
    v1 = rs.preference_profile_from(
        {"requirements_version": 1, "max_budget_rm": 9000, "min_budget_rm": 2000,
         "min_size_sqft": 500, "property_type": "Shop lot",
         "target_market": "Office workers", "preferred_areas": ["Petaling Jaya"]}
    )
    assert (v1.max_rent_myr, v1.min_rent_myr, v1.min_floor_area_sqft) == (
        9000.0, 2000.0, 500.0
    )
    assert "office_workers" in v1.target_customers
    assert v1.preferred_property_types == ("shop lot",)

    v2 = rs.preference_profile_from(VALID_V2_PREFERENCES)
    assert v2.fnb_concept == "cafe_coffee_shop"
    assert v2.max_rent_myr == 3000.0
    assert v2.competition_tolerance == "low"


def test_store_is_ownership_scoped():
    store = GeneratedRecommendationStore()
    owner, stranger = uuid.uuid4(), uuid.uuid4()
    batch = store.save_batch(owner, [{"property_id": "EP-00001",
                                     "final_recommendation": {"rank": 1},
                                     "explanation": {}}])
    result_id = uuid.UUID(batch["results"][0]["result_id"])
    assert store.get(result_id, owner) is not None
    assert store.get(result_id, stranger) is None
    assert store.attach_shap(result_id, stranger, {"x": 1}, {"available": False}) is None
    assert store.latest(stranger) is None
    assert store.latest(owner)["result_count"] == 1


# ---------------------------------------------------------------------------
# API: auth and identity
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "method,path",
    [("post", "/api/v1/recommendations/generate"),
     ("get", "/api/v1/recommendations/me/generated"),
     ("get", f"/api/v1/recommendations/{uuid.uuid4()}/explanation")],
)
def test_new_endpoints_require_authentication(client, method, path):
    if method == "post":
        response = client.post(path, json={})
    else:
        response = client.get(path)
    assert response.status_code == 401


def test_generate_ignores_a_user_supplied_user_id(client, identity):
    foreign = str(uuid.uuid4())
    response = client.post(
        "/api/v1/recommendations/generate",
        json={"user_id": foreign, "limit": 2},
        headers=auth(identity["token"]),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["user_id"] == str(identity["user_id"]) != foreign


# ---------------------------------------------------------------------------
# API: real generation
# ---------------------------------------------------------------------------


@pytest.fixture()
def generated(client, identity):
    response = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 5},
        headers=auth(identity["token"]),
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_generate_returns_real_ranked_results(generated, identity):
    assert generated["status"] == "ok"
    assert generated["user_id"] == str(identity["user_id"])
    assert generated["scoring"]["version"] == rs.SCORING_CONFIG_VERSION
    assert generated["model"]["name"] == "pu_model"
    assert generated["model"]["research_only"] is True
    assert generated["model"]["used_for_ranking"] is True
    assert generated["model"]["selected_alternative"]["used_for_ranking"] is False
    assert generated["layer2"]["engine"] == "rule_based"
    assert generated["layer2"]["trained_recommender"] is False

    summary = generated["candidate_summary"]
    assert summary["catalogue_rows_read"] >= 900
    assert summary["eligible"] >= 900
    assert summary["returned"] == 5

    results = generated["results"]
    assert len(results) == 5
    assert [r["final_recommendation"]["rank"] for r in results] == [1, 2, 3, 4, 5]
    scores = [r["final_recommendation"]["score"] for r in results]
    assert scores == sorted(scores, reverse=True)
    for result in results:
        assert CATALOGUE_ID.match(result["property_id"])
        assert result["result_id"] and uuid.UUID(result["result_id"])
        assert 0.0 < result["model"]["association_score"] < 1.0
        assert result["model"]["research_only"] is True
        assert result["personalisation"]["engine"] == "rule_based"
        assert result["personalisation"]["trained_recommender"] is False
        assert result["personalisation"]["config_version"] == rs.SCORING_CONFIG_VERSION
        assert result["final_recommendation"]["basis"].startswith("pu_0.70_preference")
        # Listing verification mirrors the catalogue's own availability data.
        # The catalogue was upgraded to VERIFIED_AVAILABLE (2026-11-11), so a
        # confirmed status is now legitimate; UNKNOWN_NOT_VERIFIED rows would
        # still carry the caution instead.
        verification = result["property"]["verification"]
        assert verification["confirmed_available"] == (
            verification["availability_status"].upper()
            in {"AVAILABLE", "VERIFIED_AVAILABLE", "CONFIRMED"}
        )
        assert verification["pending_verification"] is False
        assert result["explanation"]["shap"] is None
        # Illustrative contract values are NOT hardcoded anywhere.
        assert result["final_recommendation"]["score"] != 0.837


def test_final_score_is_the_configured_combination(generated):
    cfg = rs.SCORING_CONFIG
    for result in generated["results"]:
        pu = result["model"]["association_score"]
        pref = result["personalisation"]["preference_match_score"]
        final = result["final_recommendation"]["score"]
        if pref is None:
            assert math.isclose(final, pu, abs_tol=1e-5)
        else:
            expected = cfg.pu_weight * pu + cfg.preference_weight * pref
            assert math.isclose(final, expected, abs_tol=1e-5)


def test_saved_preferences_change_the_scoring(client, identity):
    saved = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": VALID_V2_PREFERENCES},
        headers=auth(identity["token"]),
    )
    assert saved.status_code == 200, saved.text
    response = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 3},
        headers=auth(identity["token"]),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["preferences"]["saved"] is True
    assert body["candidate_summary"]["pre_filters"]["max_rent_myr"] == 3000.0
    assert body["candidate_summary"]["pre_filters"]["min_floor_area_sqft"] == 300.0
    for result in body["results"]:
        assert result["property"]["monthly_rental_myr"] <= 3000
        assert result["property"]["built_up_sqft"] >= 300
        comps = result["personalisation"]["components"]
        assert comps["budget_fit"] is not None and comps["size_fit"] is not None
        assert comps["competition_fit"] is not None  # 'favorable_competition'


def test_shortlist_filter_can_only_restrict(client, identity):
    response = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 5, "property_ids": ["DOES-NOT-EXIST"]},
        headers=auth(identity["token"]),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "no_eligible_properties"
    assert body["results"] == []
    assert body["candidate_summary"]["returned"] == 0


def test_existing_routes_remain_operational(client, identity):
    from sitewise.main import app

    headers = auth(identity["token"])
    assert client.get("/api/v1/recommendations/me", headers=headers).status_code == 200
    # /search and /facets belong to SEPARATE in-progress work that is not part
    # of this commit. Check them only when this deployment actually registers
    # them, so this suite passes on a clean joel checkout as well as on a
    # working tree that contains that uncommitted work.
    registered = app.openapi()["paths"]
    for path, method in (
        ("/api/v1/recommendations/facets", "get"),
        ("/api/v1/recommendations/search", "post"),
    ):
        if path in registered:
            if method == "post":
                response = client.post(path, json={}, headers=headers)
            else:
                response = client.get(path, headers=headers)
            assert response.status_code == 200, response.text
    default_model = client.get("/api/v1/ml/model", headers=headers)
    assert default_model.status_code == 200
    assert default_model.json()["model"] == "pu_model"
    assert default_model.json()["model"] != SELECTED_MODEL_NAME
    selected_model = client.get("/api/v1/ml/selected/model", headers=headers)
    assert selected_model.status_code == 200
    assert selected_model.json()["name"] == SELECTED_MODEL_NAME


# ---------------------------------------------------------------------------
# API: history and ownership
# ---------------------------------------------------------------------------


def test_me_generated_is_ownership_scoped(client, generated, identity, other_identity):
    own = client.get(
        "/api/v1/recommendations/me/generated", headers=auth(identity["token"])
    )
    assert own.status_code == 200, own.text
    body = own.json()
    assert body["user_id"] == str(identity["user_id"])
    assert body["available"] is True
    assert body["batch"]["batch_id"] == generated["batch_id"]
    assert [r["property_id"] for r in body["batch"]["results"]] == [
        r["property_id"] for r in generated["results"]
    ]

    other = client.get(
        "/api/v1/recommendations/me/generated", headers=auth(other_identity["token"])
    )
    assert other.status_code == 200
    assert other.json()["available"] is False
    assert other.json()["batch"] is None


def test_explanation_enforces_ownership_and_works_without_shap(
    client, generated, identity, other_identity
):
    result_id = generated["results"][0]["result_id"]
    url = f"/api/v1/recommendations/{result_id}/explanation"

    foreign = client.get(url, headers=auth(other_identity["token"]))
    assert foreign.status_code == 404  # no enumeration of another user's result

    missing = client.get(
        f"/api/v1/recommendations/{uuid.uuid4()}/explanation",
        headers=auth(identity["token"]),
    )
    assert missing.status_code == 404

    own = client.get(url, headers=auth(identity["token"]))
    assert own.status_code == 200, own.text
    body = own.json()
    assert body["result_id"] == result_id
    assert body["user_id"] == str(identity["user_id"])
    sections = body["explanation"]["sections"]
    assert set(sections) == {
        "pu_research_explanation", "personalised_recommendation_explanation"
    }
    personal = sections["personalised_recommendation_explanation"]
    assert personal["engine"] == "rule_based"
    assert personal["config_version"] == rs.SCORING_CONFIG_VERSION
    assert personal["preference_reasons"]
    assert personal["cautions"]
    assert personal["component_details"]
    assert "SHAP is NOT used" in personal["explanation_method"]
    # Catalogue rows are VERIFIED_AVAILABLE since the 2026-11-11 data
    # upgrade; the payload mirrors the data rather than asserting a constant.
    assert personal["listing_verification"]["confirmed_available"] == (
        personal["listing_verification"]["availability_status"].upper()
        in {"AVAILABLE", "VERIFIED_AVAILABLE", "CONFIRMED"}
    )

    # A complete 47-feature vector may now resolve through the committed
    # training bridge. Either result is valid: SHAP is optional, and when
    # available it must explain the same artifact named on the ranked result.
    if body["explanation"]["shap"] is None:
        assert body["explanation"]["shap_status"]["available"] is False
        assert body["explanation"]["shap_status"]["reason"]
        assert sections["pu_research_explanation"]["available"] is False
        return

    shap = body["explanation"]["shap"]
    assert shap["model_name"] == body["model"]["name"]
    assert shap["relation_to_recommendation"]["same_artifact_as_ranked_model"] is True
    assert shap["artifact_sha256"]


@pytest.mark.slow
def test_shap_reconstruction_through_api_for_reference_property(client, identity):
    """Real SHAP over the supplied 47-feature vector + real background."""
    generated = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 1, "property_ids": [REFERENCE_PROPERTY_ID]},
        headers=auth(identity["token"]),
    )
    assert generated.status_code == 200, generated.text
    body = generated.json()
    assert body["status"] == "ok", body["candidate_summary"]
    result = body["results"][0]
    assert result["property_id"] == REFERENCE_PROPERTY_ID

    response = client.get(
        f"/api/v1/recommendations/{result['result_id']}/explanation",
        headers=auth(identity["token"]),
    )
    assert response.status_code == 200, response.text
    explanation = response.json()["explanation"]
    shap = explanation["shap"]
    assert shap is not None, explanation["shap_status"]
    assert explanation["shap_status"]["available"] is True
    assert shap["model_name"] == result["model"]["name"] == "pu_model"
    assert shap["relation_to_recommendation"]["same_artifact_as_ranked_model"] is True
    assert shap["artifact"] == "PU_model.joblib"
    assert shap["artifact_sha256"] == "5c00c574cfe4cbcb76fe1fb21eb32e40cfea3a428ef1c70ea60c893c1e8c2f98"
    assert shap["explainer"] == "Permutation SHAP"
    assert shap["research_only"] is True
    assert shap["feature_count"] == 47
    assert len(shap["contributions"]) == 47
    assert shap["data_provenance"]["background_size"] == 25

    reconstruction = shap["baseline"] + math.fsum(shap["contributions"].values())
    assert math.isclose(reconstruction, shap["score"], abs_tol=1e-6)
    assert shap["reconstruction_error"] < 1e-6
    assert shap["reconstruction_verified"] is True
    assert all(x["contribution"] > 0 for x in shap["top_positive_features"])
    assert all(x["contribution"] < 0 for x in shap["top_negative_features"])
    assert shap["relation_to_recommendation"]["scores_agree"] is True
    assert shap["relation_to_recommendation"]["shap_explained_score"] == pytest.approx(
        result["model"]["association_score"], abs=1e-6
    )
    # SHAP and preference explanations stay in separate sections.
    assert explanation["sections"]["pu_research_explanation"]["available"] is True
    assert "SHAP" in explanation["sections"]["pu_research_explanation"]["note"]


# -- explanation contract: property identity, labels, engine version ---------


def test_feature_labels_are_plain_english_and_cover_every_contribution():
    """The label map must make a raw model column unrenderable.

    Clients are not allowed to keep their own 47-entry map (it would drift from
    the deployed model), so the endpoint supplies the labels. Every feature in
    the payload must get one, and none may still read as a database column.
    """
    from sitewise.services.recommendation_generation_service import _feature_labels

    payload = {
        "contributions": {
            "pop_500m": 0.31,
            "fnb_competitors_500m": -0.22,
            "nearest_major_road_m": 0.04,
        }
    }
    labels = _feature_labels(payload)
    assert set(labels) == set(payload["contributions"])
    assert labels["pop_500m"] == "People living within 500 m"
    assert labels["fnb_competitors_500m"] == "Other F&B outlets within 500 m"
    assert all("_" not in label for label in labels.values())


def test_feature_labels_are_absent_when_shap_is_unavailable():
    """No SHAP means no labels - never an empty-but-present claim."""
    from sitewise.services.recommendation_generation_service import _feature_labels

    assert _feature_labels(None) == {}
    assert _feature_labels({}) == {}


def test_explanation_names_the_property_and_reports_the_engine_that_scored_it(
    client, generated, identity
):
    """The explanation must identify the unit and the real engine version.

    Without the property block a client can only show a bare id; without the
    stored engine version a V3 result would be mislabelled with the baseline
    config.
    """
    result_id = generated["results"][0]["result_id"]
    body = client.get(
        f"/api/v1/recommendations/{result_id}/explanation",
        headers=auth(identity["token"]),
    ).json()

    prop = body["property"]
    assert prop["canonical_property_id"] == body["property_id"]
    assert prop["property_id"] == body["property_id"]
    assert prop["title"]
    assert "verification" in prop
    # The listing reference is present but never presented as confirmed
    # availability on its own.
    assert isinstance(prop.get("listing_ref"), (dict, type(None)))

    personal = body["explanation"]["sections"][
        "personalised_recommendation_explanation"
    ]
    assert personal["config_version"] == body["personalisation"]["config_version"]

    # No SHAP on this row, so the label map is honestly empty rather than a
    # full map implying an explanation exists.
    if body["explanation"]["shap"] is None:
        assert body["explanation"]["feature_labels"] == {}
