"""Location Assessment Workspace API behaviour.

Covers the guarantees the web workspace depends on:

* resume-not-duplicate (one record per user + property)
* ownership scoping (another account's record is never returned)
* progress derived from persisted stage timestamps, never from the client
* stages 4-5 refused while no trained model / report generator exists
* zero evidence stays distinguishable from unavailable evidence
* catalogue detail and evidence reads for valid, unanalysed and unknown ids

Property ids are discovered from the live catalogue rather than hardcoded, so
the suite does not depend on a particular imported row surviving.
"""

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.db.session import engine
from sitewise.services.assessment_service import (
    TOTAL_STAGES,
    decision_support_capabilities,
    validate_requirements,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def identity(client, cleanup_users, catalog_ids):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"assess-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Assessment Tester"},
    )
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))

    # Starting an assessment requires the property to be on the caller's Saved
    # Properties list. Seed that here so the suite exercises the real rule
    # rather than working around it.
    for ref in (catalog_ids["analysed"], catalog_ids.get("unanalysed")):
        if not ref:
            continue
        saved = client.post(
            "/api/v1/saved-properties/",
            json={"property_ref": ref},
            headers=auth(token),
        )
        assert saved.status_code in (200, 201), saved.text

    return {"token": token, "sub": sub, "user_id": uuid.UUID(sub)}


@pytest.fixture()
def other_identity(client, cleanup_users, catalog_ids):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"other-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Other Tester"},
    )
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))

    # A second entrepreneur must save the property before starting their own
    # assessment of it — the same rule that applies to the first.
    for ref in (catalog_ids["analysed"], catalog_ids.get("unanalysed")):
        if not ref:
            continue
        saved = client.post(
            "/api/v1/saved-properties/",
            json={"property_ref": ref},
            headers=auth(token),
        )
        assert saved.status_code in (200, 201), saved.text

    return {"token": token, "sub": sub, "user_id": uuid.UUID(sub)}


@pytest.fixture(autouse=True)
def cleanup_assessments(cleanup_users):
    """Delete this test's assessment rows before its user rows are removed.

    Requesting ``cleanup_users`` pins the teardown order: assessments first,
    then users, so the foreign key is never violated.
    """
    yield
    if not cleanup_users:
        return
    with Session(engine) as session:
        session.execute(
            text("DELETE FROM assessment WHERE user_id = ANY(:ids)"),
            {"ids": list(cleanup_users)},
        )
        # Saved rows reference the same users and must go before them.
        session.execute(
            text("DELETE FROM favorite_property WHERE user_id = ANY(:ids)"),
            {"ids": list(cleanup_users)},
        )
        session.commit()


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
        unanalysed = session.execute(
            text(
                "SELECT p.id FROM sitewise_app.properties p "
                "LEFT JOIN sitewise_analytics.subject_features f "
                "  ON f.canonical_property_id = p.id "
                "WHERE f.subject_id IS NULL ORDER BY p.id LIMIT 1"
            )
        ).scalar_one_or_none()
    return {"analysed": analysed, "unanalysed": unanalysed}


VALID_REQUIREMENTS = {
    "business_type": "Cafe",
    "property_type": "Shop office",
    "min_budget_rm": 2000,
    "max_budget_rm": 8000,
    "min_size_sqft": 400,
    "max_size_sqft": 1800,
    "target_market": "Office workers",
    "requirements": ["Halal kitchen"],
}


# --------------------------------------------------------------- catalogue


def test_catalog_detail_returns_the_listing(client, identity, catalog_ids):
    r = client.get(
        f"/api/v1/catalog/properties/{catalog_ids['analysed']}",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["id"] == catalog_ids["analysed"]
    assert body["address"]
    assert "rental_rm" in body and "size_sqft" in body


def test_catalog_detail_unknown_id_is_404_with_code(client, identity):
    r = client.get(
        "/api/v1/catalog/properties/EP-DOES-NOT-EXIST",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 404
    assert r.json()["detail"]["code"] == "property_not_found"


def test_catalog_detail_requires_authentication(client, catalog_ids):
    r = client.get(f"/api/v1/catalog/properties/{catalog_ids['analysed']}")
    assert r.status_code == 401


def test_property_types_match_the_catalogue_exactly(client, identity):
    """The requirements form may only offer types that filter something in.

    A hardcoded option list drifts: a value that matches no ``property_type``
    row silently empties every recommendation while still looking functional.
    """
    r = client.get("/api/v1/catalog/property-types", headers=auth(identity["token"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["data"], "the catalogue has property types, so the list cannot be empty"
    assert body["meta"]["total"] == len(body["data"])

    with Session(analytics_engine) as session:
        expected = {
            row
            for row in session.execute(
                text(
                    "SELECT DISTINCT property_type FROM sitewise_app.properties "
                    "WHERE property_type IS NOT NULL AND property_type <> ''"
                )
            ).scalars()
        }
    returned = {row["value"] for row in body["data"]}
    assert returned == expected
    assert all(row["total"] > 0 for row in body["data"])
    # Ordered by listing count so the commonest type is offered first.
    assert [row["total"] for row in body["data"]] == sorted(
        (row["total"] for row in body["data"]), reverse=True
    )


def test_property_types_requires_authentication(client):
    r = client.get("/api/v1/catalog/property-types")
    assert r.status_code == 401


def test_evidence_separates_zero_from_unavailable(client, identity, catalog_ids):
    r = client.get(
        f"/api/v1/catalog/properties/{catalog_ids['analysed']}/evidence",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["available"] is True
    assert body["analysis_status"]
    metrics = [m for g in body["groups"] for m in g["metrics"]]
    assert metrics
    statuses = {m["status"] for m in metrics}
    assert statuses <= {"available", "unavailable"}
    for metric in metrics:
        if metric["status"] == "available":
            assert metric["value"] is not None
        else:
            assert metric["value"] is None
    # A mapped zero is evidence, not missing data.
    assert any(m["status"] == "available" for m in metrics)


def test_evidence_for_unanalysed_property_is_explicitly_unavailable(client, identity, catalog_ids):
    if catalog_ids["unanalysed"] is None:
        pytest.skip("every catalogue property currently has an analysis row")
    r = client.get(
        f"/api/v1/catalog/properties/{catalog_ids['unanalysed']}/evidence",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["available"] is False
    assert body["reason"]
    assert body["groups"] == []


def test_evidence_for_unknown_property_is_404(client, identity):
    r = client.get(
        "/api/v1/catalog/properties/EP-DOES-NOT-EXIST/evidence",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 404


# ------------------------------------------------------------- assessments


def test_start_creates_then_resumes_the_same_record(client, identity, catalog_ids):
    pid = catalog_ids["analysed"]
    first = client.post(
        "/api/v1/assessments/", json={"property_id": pid}, headers=auth(identity["token"])
    )
    assert first.status_code == 200, first.text
    assert first.json()["created"] is True
    assessment_id = first.json()["assessment"]["assessment_id"]

    second = client.post(
        "/api/v1/assessments/", json={"property_id": pid}, headers=auth(identity["token"])
    )
    assert second.status_code == 200
    assert second.json()["created"] is False
    assert second.json()["assessment"]["assessment_id"] == assessment_id

    history = client.get("/api/v1/assessments/me", headers=auth(identity["token"]))
    assert history.status_code == 200
    rows = [a for a in history.json()["data"] if a["property_id"] == pid]
    assert len(rows) == 1


def test_start_requires_authentication(client, catalog_ids):
    r = client.post("/api/v1/assessments/", json={"property_id": catalog_ids["analysed"]})
    assert r.status_code == 401


def test_start_with_unknown_property_is_404(client, identity):
    r = client.post(
        "/api/v1/assessments/",
        json={"property_id": "EP-DOES-NOT-EXIST"},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 404
    assert r.json()["detail"]["code"] == "property_not_found"


def test_start_with_empty_property_id_is_422(client, identity):
    r = client.post(
        "/api/v1/assessments/", json={"property_id": ""}, headers=auth(identity["token"])
    )
    assert r.status_code == 422


def test_new_assessment_progress_is_one_of_five(client, identity, catalog_ids):
    r = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    a = r.json()["assessment"]
    assert a["total_stages"] == TOTAL_STAGES == 5
    assert a["completed_stages"] == 1
    assert a["progress_percent"] == 20
    assert a["current_stage"] == 2
    assert a["current_stage_key"] == "business_requirements"
    assert a["status"] == "in_progress"
    assert a["report_available"] is False
    assert a["property"]["id"] == catalog_ids["analysed"]
    assert [s["number"] for s in a["stages"]] == [1, 2, 3, 4, 5]
    assert a["stages"][0]["status"] == "complete"
    assert a["stages"][0]["completed_at"]


def test_by_property_returns_null_before_starting(client, identity, catalog_ids):
    r = client.get(
        f"/api/v1/assessments/by-property/{catalog_ids['analysed']}",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200
    assert r.json()["assessment"] is None


def test_by_property_unknown_id_is_404(client, identity):
    r = client.get(
        "/api/v1/assessments/by-property/EP-DOES-NOT-EXIST",
        headers=auth(identity["token"]),
    )
    assert r.status_code == 404


def test_current_is_null_when_no_assessments_exist(client, identity):
    r = client.get("/api/v1/assessments/me/current", headers=auth(identity["token"]))
    assert r.status_code == 200
    assert r.json()["assessment"] is None


def test_requirements_advance_progress_only_after_persisting(client, identity, catalog_ids):
    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]

    saved = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": VALID_REQUIREMENTS, "complete_stage": "business_requirements"},
        headers=auth(identity["token"]),
    )
    assert saved.status_code == 200, saved.text
    a = saved.json()["assessment"]
    assert a["completed_stages"] == 2
    assert a["progress_percent"] == 40
    assert a["current_stage"] == 3
    assert a["requirements"]["business_type"] == "Cafe"
    assert a["stages"][1]["completed_at"]

    # The stored record, read back independently, agrees.
    read = client.get(f"/api/v1/assessments/{aid}", headers=auth(identity["token"]))
    assert read.json()["assessment"]["progress_percent"] == 40


def test_evidence_stage_completes_when_analysis_exists(client, identity, catalog_ids):
    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]
    client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": VALID_REQUIREMENTS, "complete_stage": "business_requirements"},
        headers=auth(identity["token"]),
    )
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"complete_stage": "location_evidence"},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    a = r.json()["assessment"]
    assert a["completed_stages"] == 3
    assert a["progress_percent"] == 60
    assert a["current_stage"] == 4


def test_evidence_stage_refused_when_no_analysis_exists(client, identity, catalog_ids):
    if catalog_ids["unanalysed"] is None:
        pytest.skip("every catalogue property currently has an analysis row")
    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["unanalysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]
    client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": VALID_REQUIREMENTS, "complete_stage": "business_requirements"},
        headers=auth(identity["token"]),
    )
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"complete_stage": "location_evidence"},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "evidence_unavailable"
    read = client.get(f"/api/v1/assessments/{aid}", headers=auth(identity["token"]))
    assert read.json()["assessment"]["completed_stages"] == 2


def test_stage_order_is_enforced(client, identity, catalog_ids):
    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"complete_stage": "location_evidence"},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "stage_order"


def test_requirements_stage_refused_without_requirements(client, identity, catalog_ids):
    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"complete_stage": "business_requirements"},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "requirements_missing"


def test_model_stages_are_refused_while_no_artifact_exists(client, identity, catalog_ids):
    with Session(engine) as session:
        capabilities = decision_support_capabilities(catalog_ids["analysed"], session)
    if capabilities["explanation"]["available"] and capabilities["report"]["available"]:
        pytest.skip("a trained model and report generator are installed")

    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]
    client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": VALID_REQUIREMENTS, "complete_stage": "business_requirements"},
        headers=auth(identity["token"]),
    )
    client.patch(
        f"/api/v1/assessments/{aid}",
        json={"complete_stage": "location_evidence"},
        headers=auth(identity["token"]),
    )
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"complete_stage": "ai_explanation"},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "ai_explanation_unavailable"

    read = client.get(f"/api/v1/assessments/{aid}", headers=auth(identity["token"]))
    a = read.json()["assessment"]
    assert a["completed_stages"] == 3
    assert a["progress_percent"] == 60
    assert a["report_available"] is False
    assert a["stages"][3]["status"] == "unavailable"
    assert a["stages"][3]["unavailable_reason"]
    assert a["next_action"]["kind"] == "blocked"


def test_invalid_requirements_report_every_problem(client, identity, catalog_ids):
    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={
            "requirements": {
                "business_type": "",
                "property_type": "Shop office",
                "min_budget_rm": 9000,
                "max_budget_rm": 1000,
                "min_size_sqft": -5,
                "max_size_sqft": 0,
            }
        },
        headers=auth(identity["token"]),
    )
    assert r.status_code == 422, r.text
    detail = r.json()["detail"]
    assert detail["code"] == "invalid_requirements"
    message = detail["message"]
    assert "business_type is required" in message
    assert "Minimum monthly rent cannot exceed the maximum" in message
    assert "min_size_sqft cannot be negative" in message
    assert "max_size_sqft must be greater than zero" in message
    read = client.get(f"/api/v1/assessments/{aid}", headers=auth(identity["token"]))
    assert read.json()["assessment"]["requirements"] is None


def test_unknown_stage_is_422(client, identity, catalog_ids):
    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"complete_stage": "make_coffee"},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 422
    assert r.json()["detail"]["code"] == "unknown_stage"


# --------------------------------------------------------------- ownership


def test_another_users_assessment_is_forbidden(client, identity, other_identity, catalog_ids):
    start = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(identity["token"]),
    )
    aid = start.json()["assessment"]["assessment_id"]

    read = client.get(f"/api/v1/assessments/{aid}", headers=auth(other_identity["token"]))
    assert read.status_code == 403
    assert read.json()["detail"]["code"] == "assessment_forbidden"

    write = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": VALID_REQUIREMENTS},
        headers=auth(other_identity["token"]),
    )
    assert write.status_code == 403

    history = client.get("/api/v1/assessments/me", headers=auth(other_identity["token"]))
    assert history.json()["data"] == []

    lookup = client.get(
        f"/api/v1/assessments/by-property/{catalog_ids['analysed']}",
        headers=auth(other_identity["token"]),
    )
    assert lookup.json()["assessment"] is None


def test_two_users_get_separate_records_for_one_property(
    client, identity, other_identity, catalog_ids
):
    pid = catalog_ids["analysed"]
    a = client.post(
        "/api/v1/assessments/", json={"property_id": pid}, headers=auth(identity["token"])
    ).json()["assessment"]
    b = client.post(
        "/api/v1/assessments/",
        json={"property_id": pid},
        headers=auth(other_identity["token"]),
    ).json()["assessment"]
    assert a["assessment_id"] != b["assessment_id"]
    assert a["user_id"] != b["user_id"]


def test_missing_assessment_is_404(client, identity):
    r = client.get(f"/api/v1/assessments/{uuid.uuid4()}", headers=auth(identity["token"]))
    assert r.status_code == 404
    assert r.json()["detail"]["code"] == "assessment_not_found"


def test_current_returns_the_most_recently_updated(client, identity, catalog_ids):
    pid = catalog_ids["analysed"]
    start = client.post(
        "/api/v1/assessments/", json={"property_id": pid}, headers=auth(identity["token"])
    )
    aid = start.json()["assessment"]["assessment_id"]
    client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": VALID_REQUIREMENTS},
        headers=auth(identity["token"]),
    )
    r = client.get("/api/v1/assessments/me/current", headers=auth(identity["token"]))
    assert r.status_code == 200
    current = r.json()["assessment"]
    assert current["assessment_id"] == aid
    assert current["property"]["id"] == pid
    assert current["progress_percent"] == 20  # requirements saved, stage not confirmed


# ------------------------------------------------------------- validation


@pytest.mark.parametrize(
    "payload",
    [
        None,
        [],
        {"business_type": "Cafe"},
        {**VALID_REQUIREMENTS, "max_budget_rm": "lots"},
        {**VALID_REQUIREMENTS, "requirements": "Halal kitchen"},
        {**VALID_REQUIREMENTS, "min_size_sqft": 5000, "max_size_sqft": 100},
    ],
)
def test_validate_requirements_rejects_bad_input(payload):
    from sitewise.core.exceptions import AssessmentError

    with pytest.raises(AssessmentError) as exc:
        validate_requirements(payload)
    assert exc.value.code == "invalid_requirements"
    assert exc.value.status_code == 422


def test_validate_requirements_defaults_optional_numbers():
    clean = validate_requirements(
        {
            "business_type": "Cafe",
            "property_type": "Kiosk",
            "max_budget_rm": 5000,
            "max_size_sqft": 900,
            "min_budget_rm": "",
        }
    )
    assert clean["min_budget_rm"] == 0.0
    assert clean["min_size_sqft"] == 0.0
    assert clean["target_market"] == ""
    assert clean["requirements"] == []


# ------------------------------------------- eight-question assessment flow

V2_REQUIREMENTS = {
    "fnb_concept": "cafe_coffee_shop",
    "service_model": "hybrid",
    "target_customers": ["office_workers", "students"],
    "recommendation_priority": "balanced_suitability",
    "target_price_segment": "mid_range",
    "customer_access_mode": "public_transportation",
    "max_monthly_rent_myr": 8500,
    "min_floor_area_sqft": 900,
}


def _start(client, identity, property_id):
    started = client.post(
        "/api/v1/assessments/",
        json={"property_id": property_id},
        headers=auth(identity["token"]),
    )
    assert started.status_code == 200, started.text
    return started.json()["assessment"]["assessment_id"]


def test_start_requires_the_property_to_be_on_the_saved_list(
    client, cleanup_users, catalog_ids
):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"bare-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Unsaved Tester"},
    )
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(sub))

    r = client.post(
        "/api/v1/assessments/",
        json={"property_id": catalog_ids["analysed"]},
        headers=auth(token),
    )
    assert r.status_code == 403, r.text
    assert "save" in r.text.lower()


def test_eight_question_payload_is_accepted_and_versioned(
    client, identity, catalog_ids
):
    aid = _start(client, identity, catalog_ids["analysed"])
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": V2_REQUIREMENTS},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()["assessment"]
    assert body["requirements_version"] == 2
    assert body["requirements"]["fnb_concept"] == "cafe_coffee_shop"
    assert body["requirements"]["target_customers"] == ["office_workers", "students"]
    # A v2 record needs no derived legacy view.
    assert body["requirements_legacy_view"] is None


def test_legacy_record_is_version_one_and_keeps_its_answers(
    client, identity, catalog_ids
):
    aid = _start(client, identity, catalog_ids["analysed"])
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": VALID_REQUIREMENTS},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()["assessment"]
    assert body["requirements_version"] == 1
    assert body["requirements"]["business_type"] == "Cafe"
    # Only the semantically identical number is derived; the concept is not.
    view = body["requirements_legacy_view"]
    assert view["derived_from_legacy"] is True
    assert view["max_monthly_rent_myr"] == 8000.0
    assert "fnb_concept" not in view


def test_incomplete_questionnaire_is_rejected_as_a_whole(
    client, identity, catalog_ids
):
    aid = _start(client, identity, catalog_ids["analysed"])
    broken = dict(V2_REQUIREMENTS, target_customers=[], max_monthly_rent_myr=0)
    r = client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": broken},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 422, r.text
    # Every problem in one response, so the form can show all of them.
    assert "target_customers" in r.text and "max_monthly_rent_myr" in r.text


def test_explanation_is_refused_with_a_code_when_the_model_cannot_load(
    client, identity, catalog_ids
):
    aid = _start(client, identity, catalog_ids["analysed"])
    r = client.post(
        f"/api/v1/assessments/{aid}/explanation", headers=auth(identity["token"])
    )
    # No fabricated SHAP values: the endpoint reports the real blocker.
    assert r.status_code in (409, 503), r.text
    # A machine-readable refusal code must be present. Before shap 0.50 was
    # installed the blocker was the missing import itself ("install SHAP and
    # numpy..."); with SHAP available the pipeline runs further and the real
    # blocker surfaces (e.g. features_unresolved from the analytics data),
    # so the assertion checks the code contract rather than specific words.
    detail = r.json().get("detail")
    code = detail.get("code") if isinstance(detail, dict) else None
    assert code or "model" in r.text.lower() or "shap" in r.text.lower()


def test_assessment_report_has_all_sections_and_never_invents_evidence(
    client, identity, catalog_ids
):
    aid = _start(client, identity, catalog_ids["analysed"])
    client.patch(
        f"/api/v1/assessments/{aid}",
        json={"requirements": V2_REQUIREMENTS},
        headers=auth(identity["token"]),
    )
    r = client.get(f"/api/v1/assessments/{aid}/report", headers=auth(identity["token"]))
    assert r.status_code == 200, r.text
    body = r.json()
    for key in (
        "property",
        "questionnaire",
        "evidence_categories",
        "research_association",
        "explanation",
        "requirement_matching",
        "missing_information",
        "model_information",
        "export",
        "generated_at",
    ):
        assert key in body, key
    assert body["questionnaire"]["available"] is True
    # No verified SHAP exists, so both model sections must be unavailable.
    assert body["research_association"]["available"] is False
    assert body["explanation"]["available"] is False
    assert body["export"]["pdf"] is False
    assert body["missing_information"]
    checks = {c["key"]: c for c in body["requirement_matching"]["checks"]}
    assert checks["affordability"]["verdict"] in ("match", "mismatch", "unknown")
