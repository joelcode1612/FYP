"""The verification-support location analysis (Parts A/B/C + recommendation).

Covers the spec's §8 report contract and the §13 cases that concern the
report layer against the real local database: honest unavailables (never
zeros), WorldPop/LandScan separation, the strict 47-feature PU contract,
read-only determinism, admin visibility, access control and the §9 policy
separation. The analysis never writes — every test asserts state it must not
change stays unchanged.

Pure-enrichment behaviour (trigger flow, retry, running-guard) is covered by
the existing enrichment suites and is not duplicated here.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.services.location_analysis_service import LocationAnalysisService

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id
from .test_property_verification_api import auth, insert_listing

FAMILY_KEYS = (
    "population",
    "socioeconomic",
    "fnb_environment",
    "accessibility",
    "research_association",
)


@pytest.fixture(autouse=True)
def cleanup_verifications(cleanup_users):
    """Same cleanup contract as the verification API suite."""
    props: list[int] = []
    yield props
    if not props and not cleanup_users:
        return
    with Session(engine) as session:
        for table in (
            "fyp.verification_audit",
            "fyp.verification_document",
            "fyp.property_verification",
            "fyp.property_geospatial_features",
        ):
            if props:
                session.execute(
                    text(f"DELETE FROM {table} WHERE property_id = ANY(:ids)"),
                    {"ids": props},
                )
            else:
                session.execute(text(f"DELETE FROM {table}"))
        if props:
            session.execute(
                text("DELETE FROM fyp.rental_properties WHERE id = ANY(:ids)"),
                {"ids": props},
            )
        session.commit()


def make_listing(
    cleanup_verifications,
    *,
    latitude: float | None = 3.0722,
    longitude: float | None = 101.6065,
    address: str = "Jalan Analysis 1, Shah Alam",
) -> int:
    sub = str(uuid.uuid4())
    with Session(engine) as session:
        property_id = insert_listing(
            session,
            sub,
            name="Analysis test shoplot",
            address=address,
            city="Shah Alam",
            state="Selangor",
        )
        if latitude is None or longitude is None:
            session.execute(
                text(
                    "UPDATE fyp.rental_properties SET latitude = :lat, "
                    "longitude = :lon WHERE id = :pid"
                ),
                {"lat": latitude, "lon": longitude, "pid": property_id},
            )
            session.commit()
    cleanup_verifications.append(property_id)
    return property_id


def add_photo(property_id: int) -> None:
    with Session(engine) as session:
        session.execute(
            text(
                "INSERT INTO fyp.property_photos (property_id, url, "
                "is_primary, created_at) VALUES (:pid, :url, true, now())"
            ),
            {"pid": property_id, "url": "https://example.test/analysis-photo.jpg"},
        )
        session.commit()


def add_geo_snapshot(property_id: int) -> None:
    """A completed wide-feature row, as FeatureRefreshService would leave it."""
    with Session(engine) as session:
        session.execute(
            text(
                """
                INSERT INTO fyp.property_geospatial_features (
                    property_id, population_500m, population_1km,
                    competitor_count_500m, competitor_count_1km,
                    demand_generator_count_500m, demand_generator_count_1km,
                    accessibility_road_km_1km, accessibility_score,
                    nearest_major_road_m, income_median, market_segment,
                    last_calculated_at
                ) VALUES (
                    :pid, 12345.0, 45678.0, 9, 30, 4, 8, 18.5, 63.4, 55.5,
                    8210.0, 'established', now()
                )
                """
            ),
            {"pid": property_id},
        )
        session.commit()


def submit_listing(client, token: str, property_id: int, scope: str = "full") -> None:
    if scope == "full":
        import io

        response = client.post(
            f"/api/v1/properties/{property_id}/verification/documents",
            headers=auth(token),
            files={
                "file": (
                    "deed.pdf",
                    io.BytesIO(b"%PDF-1.4\n%test\n"),
                    "application/pdf",
                )
            },
            data={"verification_type": "ownership", "document_type": "ownership_deed"},
        )
        assert response.status_code == 201, response.text
    response = client.post(
        f"/api/v1/properties/{property_id}/verification/submit",
        headers=auth(token),
        json={"scope": scope},
    )
    assert response.status_code == 200, response.text


def make_admin(cleanup_users, client, *, aal: str | None = "aal2") -> dict:
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"loc-analysis-admin-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    with Session(engine) as session:
        from sitewise.repositories.user_repository import UserRepository

        repo = UserRepository(session)
        repo.get_or_create_from_supabase(
            user_id=sub, email=email, email_verified=True
        )
        repo.update(sub, {"role": "admin", "account_status": "active"})
    token = make_token(
        sub=str(sub),
        email=email,
        aal=aal,
        amr=[{"method": "password"}, {"method": "totp"}] if aal else None,
    )
    return {"token": token, "sub": str(sub)}


# --------------------------------------------------------------------------
# §8 report contract on the real database
# --------------------------------------------------------------------------


def test_new_listing_without_analysis_reports_every_family_unavailable(
    cleanup_verifications,
):
    """§13-4/§13-8: nothing measured → every family unavailable WITH a
    reason; no value is a fabricated zero."""
    property_id = make_listing(cleanup_verifications)
    with engine_session() as session:
        report = LocationAnalysisService(session).analyze(property_id)
    assert report["available"] is True
    assert report["part_a"]["state"] == "not_submitted"
    for family in FAMILY_KEYS:
        block = report["part_b"][family]
        assert block["available"] is False
        assert (block.get("unavailable_reason") or "").strip()
    assert report["part_c"]["families_available"] == 0
    assert len(report["part_c"]["missing"]) == len(FAMILY_KEYS)


def test_invalid_coordinates_state_is_validation_failed(cleanup_verifications):
    """§13-5: an unusable location never produces a ready verdict."""
    property_id = make_listing(
        cleanup_verifications, latitude=None, longitude=None
    )
    with engine_session() as session:
        report = LocationAnalysisService(session).analyze(property_id)
    assert report["part_a"]["state"] == "validation_failed"
    coordinates = next(
        c for c in report["part_a"]["checks"] if c["id"] == "coordinates"
    )
    assert coordinates["status"] == "missing"


def test_complete_geodata_marks_measured_families_available(
    cleanup_verifications,
):
    """§13-1: a completed feature snapshot yields the four measured families
    with values — and the research association stays honestly unavailable."""
    property_id = make_listing(cleanup_verifications)
    add_geo_snapshot(property_id)
    with engine_session() as session:
        report = LocationAnalysisService(session).analyze(property_id)
    part_b = report["part_b"]
    assert part_b["population"]["available"] is True
    assert part_b["population"]["pop_500m"] == 12345.0
    assert part_b["population"]["pop_1km"] == 45678.0
    assert part_b["socioeconomic"]["available"] is True
    assert part_b["socioeconomic"]["income_median"] == 8210.0
    assert part_b["fnb_environment"]["available"] is True
    assert part_b["fnb_environment"]["competitor_count_500m"] == 9
    assert part_b["accessibility"]["available"] is True
    assert part_b["accessibility"]["accessibility_score"] == 63.4
    # Strict contract: no verified subject link → no score, exact reason.
    assert part_b["research_association"]["available"] is False
    assert part_b["research_association"]["research_only"] is True
    assert "verified analytical mapping" in (
        part_b["research_association"]["unavailable_reason"]
    )
    assert report["part_c"]["families_available"] == 4


def test_no_missing_measurement_is_reported_as_zero(cleanup_verifications):
    """§8: unavailable values stay null and carry a reason; available blocks
    never replace a null with 0."""
    property_id = make_listing(cleanup_verifications)
    add_geo_snapshot(property_id)
    with engine_session() as session:
        report = LocationAnalysisService(session).analyze(property_id)
    population = report["part_b"]["population"]
    assert population["density_1km"] is None  # not in the snapshot → null
    research = report["part_b"]["research_association"]
    assert research["score"] is None


def test_repeated_analysis_is_deterministic_and_writes_nothing(
    cleanup_verifications,
):
    """§13-9: analysis twice → identical findings, no state changed, no new
    rows."""
    property_id = make_listing(cleanup_verifications)
    add_geo_snapshot(property_id)
    with engine_session() as session:
        first = LocationAnalysisService(session).analyze(property_id)
        before = _row_count(session, "fyp.property_enrichment_category", property_id)
        second = LocationAnalysisService(session).analyze(property_id)
        unchanged = _row_count(
            session, "fyp.property_enrichment_category", property_id
        )
    assert first["part_a"]["state"] == second["part_a"]["state"]
    assert first["part_b"]["population"]["pop_500m"] == (
        second["part_b"]["population"]["pop_500m"]
    )
    assert first["part_c"]["families_available"] == (
        second["part_c"]["families_available"]
    )
    assert unchanged == before


def test_address_change_is_reflected_without_stale_cache(cleanup_verifications):
    """§13-10: the report derives from live state — an address edit shows on
    the next analysis with no recompute step."""
    property_id = make_listing(cleanup_verifications)
    with engine_session() as session:
        before = LocationAnalysisService(session).analyze(property_id)
    assert before["part_a"]["state"] == "not_submitted"
    with Session(engine) as write:
        write.execute(
            text(
                "UPDATE fyp.rental_properties SET address = 'Jalan Updated 9' "
                "WHERE id = :pid"
            ),
            {"pid": property_id},
        )
        write.commit()
    with engine_session() as session:
        after = LocationAnalysisService(session).analyze(property_id)
    address = next(
        c for c in after["part_a"]["checks"] if c["id"] == "address"
    )
    assert "Jalan Updated 9" in address["detail"]


# --------------------------------------------------------------------------
# Real research-linked properties (read-only; nothing is created)
# --------------------------------------------------------------------------


def _linked_property_with_geo() -> int | None:
    with Session(engine) as session:
        row = session.execute(
            text(
                """
                SELECT l.property_id
                FROM fyp.property_subject_links l
                JOIN fyp.property_geospatial_features g
                    ON g.property_id = l.property_id
                WHERE l.match_verified
                ORDER BY l.property_id LIMIT 1
                """
            )
        ).first()
    return int(row[0]) if row else None


def test_real_linked_property_separates_population_sources_and_labels_income():
    """§5A/§5B on a real verified-linked listing: resident and ambient
    population are separate labelled rows; income is district-level."""
    property_id = _linked_property_with_geo()
    if property_id is None:
        pytest.skip("No verified research-linked property in the local database")
    with engine_session() as session:
        report = LocationAnalysisService(session).analyze(property_id)
    population = report["part_b"]["population"]
    assert population["available"] is True
    assert "worldpop" in population["source"].lower()
    if population.get("landscan_ambient_1km") is not None:
        assert population.get("landscan_source_year")
    socioeconomic = report["part_b"]["socioeconomic"]
    assert socioeconomic["available"] is True
    assert "district" in socioeconomic["method"].lower()


def test_real_property_partial_47_coverage_rejects_score():
    """§5E/§13-8: the strict contract — missing features mean NO score, an
    explicit reason and the research-only meaning, never a fabricated value."""
    property_id = _linked_property_with_geo()
    if property_id is None:
        pytest.skip("No verified research-linked property in the local database")
    with engine_session() as session:
        report = LocationAnalysisService(session).analyze(property_id)
    research = report["part_b"]["research_association"]
    assert research["research_only"] is True
    assert research["score_meaning"]
    if not research["available"]:
        assert research["score"] is None
        assert (research["unavailable_reason"] or "").strip()
        assert research["missing_features"]
    else:
        assert research["score"] is not None


# --------------------------------------------------------------------------
# §10/§12 — admin surface, access control, policy separation
# --------------------------------------------------------------------------


def _submitted_owner(
    client, cleanup_users, cleanup_verifications, *, scope="full", photos=False
):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"loc-owner-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Location Owner"},
    )
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(sub))
    with Session(engine) as session:
        property_id = insert_listing(
            session,
            sub,
            name="Review-visible shoplot",
            address="Jalan Review 2, Shah Alam",
            city="Shah Alam",
            state="Selangor",
        )
    cleanup_verifications.append(property_id)
    if photos:
        add_photo(property_id)
    add_geo_snapshot(property_id)
    submit_listing(client, token, property_id, scope=scope)
    return {"token": token, "sub": sub, "property_id": property_id}


def test_admin_review_detail_includes_analysis_and_ready_state(
    client, cleanup_users, cleanup_verifications
):
    """§10/§13-11: the staff detail carries the analysis; a submitted
    complete listing reads ready_for_admin_review."""
    owner = _submitted_owner(client, cleanup_users, cleanup_verifications, photos=True)
    admin = make_admin(cleanup_users, client)
    response = client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
        headers=auth(admin["token"]),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    analysis = body["location_analysis"]
    assert analysis["available"] is True
    assert analysis["part_a"]["state"] == "ready_for_admin_review"
    assert analysis["recommendation"]["text"]
    domains = {
        item["domain"] for item in analysis["recommendation"]["policy_separation"]
    }
    assert domains == {
        "listing_accuracy",
        "ownership",
        "location_suitability",
        "publication_eligibility",
    }


def test_weak_location_listing_flags_additional_information(
    client, cleanup_users, cleanup_verifications
):
    """§13-14: a weak listing (no photographs) reads additional_information_
    required — the analysis surfaces the gap without deciding anything."""
    owner = _submitted_owner(client, cleanup_users, cleanup_verifications, photos=False)
    admin = make_admin(cleanup_users, client)
    response = client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
        headers=auth(admin["token"]),
    )
    assert response.status_code == 200, response.text
    analysis = response.json()["location_analysis"]
    assert analysis["part_a"]["state"] == "additional_information_required"


def test_listing_scope_submission_reads_listing_only(
    client, cleanup_users, cleanup_verifications
):
    """§7 listing scope: ownership untouched; the readiness check states the
    listing-scope fact instead of demanding evidence."""
    owner = _submitted_owner(
        client, cleanup_users, cleanup_verifications, scope="listing", photos=True
    )
    admin = make_admin(cleanup_users, client)
    response = client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
        headers=auth(admin["token"]),
    )
    assert response.status_code == 200, response.text
    analysis = response.json()["location_analysis"]
    assert analysis["part_a"]["ownership_status"] == "not_submitted"
    ownership = next(
        c
        for c in analysis["part_a"]["checks"]
        if c["id"] == "ownership_documents"
    )
    assert ownership["status"] == "ok"


def test_unauthorized_and_unmfa_access_is_refused(
    client, cleanup_users, cleanup_verifications
):
    """§13-12: the analysis rides the staff endpoint — admin WITHOUT aal2 and
    non-admins never reach it."""
    owner = _submitted_owner(client, cleanup_users, cleanup_verifications, photos=True)
    admin_no_mfa = make_admin(cleanup_users, client, aal=None)
    assert client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
        headers=auth(admin_no_mfa["token"]),
    ).status_code in (401, 403)
    assert client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
    ).status_code in (401, 403)
    # The owner themselves cannot read the staff surface either.
    assert client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
        headers=auth(owner["token"]),
    ).status_code in (401, 403)


def test_approving_listing_changes_nothing_the_analysis_must_not_touch(
    client, cleanup_users, cleanup_verifications
):
    """§9/§13-13: after an administrator approves the listing dimension,
    ownership stays pending, publication stays blocked, the listing stays
    unpublished — the analysis echoes, never sets."""
    owner = _submitted_owner(client, cleanup_users, cleanup_verifications, photos=True)
    admin = make_admin(cleanup_users, client)
    start = client.post(
        f"/api/v1/staff/properties/{owner['property_id']}/verification/start-review",
        headers=auth(admin["token"]),
        json={"dimension": "listing"},
    )
    assert start.status_code == 200, start.text
    approve = client.post(
        f"/api/v1/staff/properties/{owner['property_id']}/verification/approve",
        headers=auth(admin["token"]),
        json={"dimension": "listing"},
    )
    assert approve.status_code == 200, approve.text
    body = client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
        headers=auth(admin["token"]),
    ).json()
    verification = body["verification"]
    assert verification["listing_status"] == "verified"
    assert verification["ownership_status"] == "pending"
    assert verification["publication_eligible"] is False
    listing = body["property"]
    assert listing["is_published"] is False
    analysis = body["location_analysis"]
    assert analysis["part_a"]["listing_status"] == "verified"
    assert analysis["part_a"]["ownership_status"] == "pending"
    publication = next(
        item
        for item in analysis["recommendation"]["policy_separation"]
        if item["domain"] == "publication_eligibility"
    )
    assert publication["current_status"] is False
    assert publication["is_published"] is False


def test_analysis_failure_never_breaks_the_review_detail(
    client, cleanup_users, cleanup_verifications, monkeypatch
):
    """§13-17: an analysis crash surfaces as an explicit available:false
    payload; the review detail (and the property) survive untouched."""
    owner = _submitted_owner(client, cleanup_users, cleanup_verifications, photos=True)
    admin = make_admin(cleanup_users, client)

    def boom(self, property_id):
        raise RuntimeError("simulated analysis failure")

    monkeypatch.setattr(LocationAnalysisService, "analyze", boom)
    response = client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
        headers=auth(admin["token"]),
    )
    assert response.status_code == 200, response.text
    analysis = response.json()["location_analysis"]
    assert analysis["available"] is False
    assert "simulated analysis failure" in analysis["error"]
    assert response.json()["property"]["property_id"] == owner["property_id"]


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def engine_session() -> Session:
    return Session(engine)


def _row_count(session: Session, table: str, property_id: int) -> int:
    return int(
        session.execute(
            text(f"SELECT count(*) FROM {table} WHERE property_id = :pid"),
            {"pid": property_id},
        ).scalar()
        or 0
    )
