"""Read-only persisted-explanation endpoint (Full Analysis page).

Guarantees the page depends on:

* reading never computes SHAP and never confirms a stage
* no persisted explanation is an explicit null, not a fabricated payload
* ownership scoping matches the rest of the assessment API (403/404)
* a stored payload is only returned when its embedded assessment_id matches
"""

import json
import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.db.models.ai_explanation import AiExplanation
from sitewise.db.session import engine
from sitewise.services.explanation_service import ExplanationService

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(scope="module")
def catalog_ids():
    with Session(analytics_engine) as session:
        analysed = session.execute(
            text(
                "SELECT p.id FROM sitewise_app.properties p "
                "JOIN sitewise_analytics.subject_features f "
                "  ON f.canonical_property_id = p.id "
                "ORDER BY p.id LIMIT 1"
            )
        ).scalar_one()
    return {"analysed": analysed}


def _identity(client, cleanup_users, catalog_ids, prefix):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"{prefix}-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Explanation Reader"},
    )
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    saved = client.post(
        "/api/v1/saved-properties/",
        json={"property_ref": catalog_ids["analysed"]},
        headers=auth(token),
    )
    assert saved.status_code in (200, 201), saved.text
    return {"token": token, "sub": sub, "user_id": uuid.UUID(sub)}


@pytest.fixture()
def identity(client, cleanup_users, catalog_ids):
    return _identity(client, cleanup_users, catalog_ids, "expl")


@pytest.fixture()
def other_identity(client, cleanup_users, catalog_ids):
    return _identity(client, cleanup_users, catalog_ids, "other")


@pytest.fixture(autouse=True)
def cleanup_rows(cleanup_users):
    yield
    if not cleanup_users:
        return
    with Session(engine) as session:
        for table in ("ai_explanation", "assessment", "favorite_property"):
            session.execute(
                text(f"DELETE FROM {table} WHERE user_id = ANY(:ids)"),
                {"ids": list(cleanup_users)},
            )
        session.commit()


def _start(client, identity, catalog_ids):
    r = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    assert r.status_code in (200, 201), r.text
    return r.json()["assessment"]


def test_explanation_read_requires_authentication(client):
    r = client.get(f"/api/v1/assessments/{uuid.uuid4()}/explanation")
    assert r.status_code == 401


def test_explanation_read_is_null_before_stage4(client, identity, catalog_ids):
    assessment = _start(client, identity, catalog_ids)
    r = client.get(
        f"/api/v1/assessments/{assessment['assessment_id']}/explanation",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"explanation": None}

    # Reading must not confirm the ai_explanation stage.
    after = client.get(
        f"/api/v1/assessments/{assessment['assessment_id']}",
        headers=auth(identity["token"]),
    ).json()["assessment"]
    stages = {s["key"]: s for s in after["stages"]}
    assert stages["ai_explanation"]["status"] != "complete"


def test_explanation_read_unknown_assessment_is_404(client, identity):
    r = client.get(
        f"/api/v1/assessments/{uuid.uuid4()}/explanation",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 404


def test_explanation_read_rejects_other_account(
    client, identity, other_identity, catalog_ids
):
    assessment = _start(client, identity, catalog_ids)
    r = client.get(
        f"/api/v1/assessments/{assessment['assessment_id']}/explanation",
        headers=auth(other_identity["token"]),
    )
    assert r.status_code == 403


def test_explanation_read_returns_persisted_payload_without_advancing(
    client, identity, catalog_ids
):
    assessment = _start(client, identity, catalog_ids)
    payload = {
        "assessment_id": assessment["assessment_id"],
        "property_id": assessment["property_id"],
        "available": True,
        "base_value": 0.5,
        "output": 0.6,
        "reconstructed": 0.6,
        "additivity_ok": True,
        "contributions": {"pop_500m": 0.1},
        "values": {"pop_500m": 1234.0},
        "groups": [],
        "research_only": True,
    }
    with Session(engine) as session:
        ExplanationService(session).create(
            AiExplanation(
                user_id=identity["user_id"],
                content=json.dumps(payload),
            )
        )

    r = client.get(
        f"/api/v1/assessments/{assessment['assessment_id']}/explanation",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    assert r.json()["explanation"] == payload

    after = client.get(
        f"/api/v1/assessments/{assessment['assessment_id']}",
        headers=auth(identity["token"]),
    ).json()["assessment"]
    stages = {s["key"]: s for s in after["stages"]}
    assert stages["ai_explanation"]["status"] != "complete"


def test_explanation_read_ignores_other_assessments_payload(
    client, identity, catalog_ids
):
    assessment = _start(client, identity, catalog_ids)
    with Session(engine) as session:
        ExplanationService(session).create(
            AiExplanation(
                user_id=identity["user_id"],
                content=json.dumps(
                    {"assessment_id": str(uuid.uuid4()), "output": 0.9}
                ),
            )
        )
    r = client.get(
        f"/api/v1/assessments/{assessment['assessment_id']}/explanation",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"explanation": None}


def test_model_metadata_exposes_the_canonical_47_feature_taxonomy(
    client, identity
):
    """The Full Analysis page groups features from this payload, so the
    backend must publish the approved baseline_47 grouping (7/14/13/3/10)
    rather than leave the UI to keep a second copy of the category rules."""
    r = client.get("/api/v1/ml/model", headers=auth(identity["token"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["available"] is True
    features = body["features"]
    assert len(features) == 47
    assert len({f["name"] for f in features}) == 47
    counts = {}
    for feature in features:
        counts[feature["category"]] = counts.get(feature["category"], 0) + 1
    assert counts == {
        "population": 7,
        "demand_generators": 14,
        "accessibility": 13,
        "parking": 3,
        "competitors": 10,
    }
    # Walk-reachable population is an accessibility measure, not catchment
    # population, in the approved grouping.
    walk = next(
        f for f in features if f["name"] == "worldpop_walk_reachable_10min"
    )
    assert walk["category"] == "accessibility"


def test_category_grouping_matches_the_approved_counts():
    from sitewise.services.explanation_service import category_of, group_contributions

    contributions = {
        "pop_500m": 0.01,
        "worldpop_walk_reachable_10min": -0.02,
        "nearest_transit_walk_m": 0.03,
        "parking_facilities_500m": 0.005,
        "fnb_competitors_500m": -0.01,
        "office_pois_500m": 0.02,
    }
    assert category_of("worldpop_walk_reachable_10min") == "accessibility"
    groups = {g["key"]: g for g in group_contributions(contributions)}
    assert groups["accessibility"]["contribution"] == pytest.approx(0.01)
    assert groups["accessibility"]["feature_count"] == 2
    assert groups["population"]["feature_count"] == 1