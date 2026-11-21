"""DOSM district demographics on the property-detail evidence payload.

The failure these tests pin is the silent one: the demographic blocks joined on
the district label copied out of the source workbook, which for the federal
territory is "Kuala Lumpur" while DOSM publishes the district
"W.P. Kuala Lumpur". The join matched nothing, the panel fell back to "District
data not available", and no error was raised anywhere.

All assertions run against the real analytics database, so a broken import or a
renamed district fails here instead of in the browser.
"""

from __future__ import annotations

import uuid

import pytest
from sqlmodel import Session, text

from sitewise.db.analytics_session import analytics_engine
from sitewise.repositories.catalog_repository import CatalogRepository

from .conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

#: A Kuala Lumpur listing whose workbook labels are both unusable as DOSM keys.
KL_PROPERTY = "EP-01345"
#: A Selangor listing labelled "Hulu Langat" where DOSM publishes "Ulu Langat".
OTHER_PROPERTY = "MD-00296"
#: Matched to W.P. Putrajaya, where DOSM publishes household income but neither
#: the district population estimate nor the age bands.
INCOME_ONLY_PROPERTY = "MD-01734"
#: No matched geometry and no district label at all.
UNRESOLVED_PROPERTY = "EP-03100"

AGE_GROUP_KEYS = ["0-14", "15-24", "25-34", "35-49", "50-64", "65+"]

#: DOSM publishes each five-year band in thousands rounded to one decimal, so a
#: group total may differ from the published overall estimate by up to 50
#: people per band (18 bands) plus the rounding of the total itself.
ROUNDING_TOLERANCE_PEOPLE = 1_000


@pytest.fixture()
def session():
    with Session(analytics_engine) as session:
        yield session


def statistics(session: Session, property_id: str) -> dict:
    evidence = CatalogRepository(session).get_evidence(property_id)
    assert evidence["available"] is True, evidence.get("reason")
    return evidence["district_statistics"]


def metric(session: Session, property_id: str, key: str) -> dict:
    evidence = CatalogRepository(session).get_evidence(property_id)
    for group in evidence["groups"]:
        for item in group["metrics"]:
            if item["key"] == key:
                return item
    raise AssertionError(f"{key} is not part of the evidence payload")


# ---------------------------------------------------------------- KL join ---


def test_kuala_lumpur_property_resolves_to_a_dosm_district(session):
    stats = statistics(session, KL_PROPERTY)
    assert stats["available"] is True, stats["reason"]
    assert stats["district"] == "W.P. Kuala Lumpur"
    assert stats["state"] == "W.P. Kuala Lumpur"
    # The district came from the property's own coordinates, not from a
    # substring of the workbook label.
    assert stats["match_method"] == "VERIFIED_DISTRICT_GEOMETRY"
    assert stats["labelled_district"] == "Kuala Lumpur"


def test_district_population_is_a_real_dosm_record(session):
    stats = statistics(session, KL_PROPERTY)
    assert stats["district_population"] == pytest.approx(2_082_300, abs=1)
    assert stats["population_as_of"] == "2026-01-01"
    row = session.exec(
        text(
            "SELECT population_persons, date FROM public.district_population "
            "WHERE district = 'W.P. Kuala Lumpur' ORDER BY date DESC LIMIT 1"
        )
    ).first()
    assert int(row[0]) == stats["district_population"]
    assert row[1].isoformat() == stats["population_as_of"]


def test_age_groups_aggregate_the_published_bands_without_double_counting(session):
    stats = statistics(session, KL_PROPERTY)
    assert [group["key"] for group in stats["age_groups"]] == AGE_GROUP_KEYS
    assert stats["age_groups_complete"] is True
    assert stats["age_note"] is None
    for group in stats["age_groups"]:
        assert group["persons"] is not None and group["persons"] > 0
        assert group["bands_missing"] == []
    total = sum(group["persons"] for group in stats["age_groups"])
    assert total == pytest.approx(stats["district_population"], abs=ROUNDING_TOLERANCE_PEOPLE)
    assert stats["total_population"] == total
    assert sum(group["share"] for group in stats["age_groups"]) == pytest.approx(1.0, abs=0.005)


def test_the_age_table_holds_only_the_both_sex_overall_ethnicity_series(session):
    """The displayed groups sum 18 bands once each.

    If the import ever stores ``sex=male``/``female`` rows or the ``overall``
    subtotal alongside the bands, the sums above silently double and the chart
    still looks plausible - so the shape of the source is asserted directly.
    """
    rows = session.exec(
        text(
            "SELECT age, count(*) FROM public.district_age_population "
            "WHERE district = 'W.P. Kuala Lumpur' AND date = "
            "(SELECT max(date) FROM public.district_age_population "
            " WHERE district = 'W.P. Kuala Lumpur') GROUP BY age"
        )
    ).all()
    assert len(rows) == 18
    assert {count for _age, count in rows} == {1}
    assert "overall" not in {age for age, _count in rows}


def test_sex_split_is_unavailable_instead_of_inferred_from_the_total(session):
    stats = statistics(session, KL_PROPERTY)
    assert stats["district_population"] == pytest.approx(2_082_300, abs=1)
    assert stats["male_population"] is None
    assert stats["female_population"] is None


def test_income_keeps_its_own_reference_year(session):
    stats = statistics(session, KL_PROPERTY)
    assert stats["income_median_myr"] == pytest.approx(10_234.0)
    assert stats["income_as_of"] == "2022-01-01"
    row = session.exec(
        text(
            "SELECT income_median, date FROM public.hh_income_district "
            "WHERE district = 'W.P. Kuala Lumpur' ORDER BY date DESC LIMIT 1"
        )
    ).first()
    assert float(row[0]) == pytest.approx(stats["income_median_myr"])
    assert row[1].isoformat() == stats["income_as_of"]
    # Different datasets, different years: the payload keeps them apart instead
    # of presenting one "district statistics as of" date.
    assert stats["population_as_of"] != stats["income_as_of"]


def test_the_federal_territory_is_not_named_twice(session):
    note = metric(session, KL_PROPERTY, "district_population")["note"]
    assert note == "W.P. Kuala Lumpur · DOSM estimate for 2026-01-01"


# ------------------------------------------------------------- not KL only ---


def test_a_selangor_property_resolves_through_the_same_join(session):
    stats = statistics(session, OTHER_PROPERTY)
    assert stats["available"] is True, stats["reason"]
    assert stats["district"] == "Ulu Langat"
    assert stats["state"] == "Selangor"
    assert stats["match_method"] == "VERIFIED_DISTRICT_GEOMETRY"
    assert stats["district_population"] not in (None, statistics(session, KL_PROPERTY)["district_population"])
    assert stats["age_groups_complete"] is True
    assert len(stats["age_groups"]) == len(AGE_GROUP_KEYS)
    assert stats["income_median_myr"] is not None


def test_verified_keys_resolve_only_when_a_district_is_unambiguous(session):
    """The verified key is a DOSM district name or the block stays unavailable.

    Resolution is exact-name and requires the name to be published by exactly
    one state, so a duplicated or absent district can never pull in another
    region's demographics.
    """
    rows = session.exec(
        text(
            "SELECT DISTINCT p.dosm_district_key, "
            "  (SELECT count(DISTINCT d.state) FROM ("
            "     SELECT state, district FROM public.district_population "
            "     UNION SELECT state, district FROM public.district_age_population "
            "     UNION SELECT state, district FROM public.hh_income_district"
            "   ) d WHERE d.district = p.dosm_district_key) AS states "
            "FROM fyp_features.property_population_spatial p "
            "WHERE p.source_record_type = 'SITEWISE_U_PROPERTY' "
            "  AND p.geography_match_status = 'MATCHED' "
            "  AND p.dosm_district_key IS NOT NULL"
        )
    ).all()
    assert rows, "the district pipeline produced no matched keys"
    # Every matched key is either an exact DOSM district or a name DOSM does
    # not publish (a GADM spelling with no DOSM counterpart). No name is
    # published by two states, so nothing here resolves ambiguously.
    assert sorted({int(states) for _key, states in rows}) in ([0], [1], [0, 1])
    for key, states in rows:
        if int(states) == 0:
            assert session.exec(
                text(
                    "SELECT count(*) FROM public.district_population WHERE district = :district"
                ),
                {"district": key},
            ).scalar() == 0


# ---------------------------------------------------- per-block honesty -------


def test_unpublished_blocks_are_reported_without_erasing_the_published_ones(session):
    stats = statistics(session, INCOME_ONLY_PROPERTY)
    assert stats["district"] == "W.P. Putrajaya"
    # DOSM publishes no district population or age bands for Putrajaya...
    assert stats["age_groups"] == []
    assert stats["district_population"] is None
    assert stats["male_population"] is None and stats["female_population"] is None
    assert stats["total_population"] == 0
    assert "age bands are published for w.p. putrajaya" in stats["age_note"].lower()
    assert stats["population_note"] is not None
    # ...but the income figure it does publish is still shown, with its year.
    assert stats["available"] is True
    assert stats["income_median_myr"] == pytest.approx(10_056.0)
    assert stats["income_as_of"] == "2022-01-01"
    assert stats["income_note"] is None


def test_an_unmatched_property_reports_nothing_rather_than_a_guess(session):
    stats = statistics(session, UNRESOLVED_PROPERTY)
    assert stats["available"] is False
    assert stats["match_method"] is None
    assert stats["age_groups"] == []
    assert "district_population" not in stats
    assert metric(session, UNRESOLVED_PROPERTY, "district_population")["status"] == "unavailable"
    assert metric(session, UNRESOLVED_PROPERTY, "district_population")["value"] is None


def test_a_district_label_that_is_not_a_dosm_key_does_not_match_by_substring(session):
    """A workbook district that merely resembles a published one stays out."""
    repo = CatalogRepository(session)
    assert repo._dosm_district_keys("EP-DOES-NOT-EXIST", {"district": "Kuala", "state_dosm": "Selangor"}) is None
    assert (
        repo._dosm_district_keys(
            "EP-DOES-NOT-EXIST", {"district": "W.P. Kuala Lumpur", "state_dosm": "W.P. Kuala Lumpur"}
        )
        == ("W.P. Kuala Lumpur", "W.P. Kuala Lumpur", "EXACT_LABEL_PAIR")
    )


# ------------------------------------------------------------- HTTP layer ----


def test_the_evidence_endpoint_carries_the_district_records(client, cleanup_users):
    """The exact request the property-detail page makes, end to end."""
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub, email=f"dosm-evidence-{sub[:8]}@{TEST_EMAIL_DOMAIN}"
    )
    register_user_id(cleanup_users, uuid.UUID(sub))
    headers = {"Authorization": f"Bearer {token}"}

    body = client.get(
        f"/api/v1/catalog/properties/{KL_PROPERTY}/evidence", headers=headers
    ).json()
    stats = body["district_statistics"]
    assert stats["available"] is True, stats["reason"]
    assert stats["district"] == "W.P. Kuala Lumpur"
    assert stats["age_groups"], "the panel needs bars, not an empty list"
    assert stats["district_population"] == 2_082_300
    assert stats["male_population"] is None
    assert stats["female_population"] is None
    assert stats["income_median_myr"] is not None
    assert stats["income_as_of"] != stats["population_as_of"]

    nearby = client.get(
        f"/api/v1/catalog/properties/{OTHER_PROPERTY}/evidence", headers=headers
    ).json()["district_statistics"]
    assert (nearby["district"], nearby["state"]) == ("Ulu Langat", "Selangor")
