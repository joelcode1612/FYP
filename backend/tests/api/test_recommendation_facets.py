"""Contextual (interconnected) filter facets for the Recommendations page.

The contract these tests hold:

* every option is counted over the SAME PU-gated population the search ranks,
  with all other selected hard filters applied and only that option's own
  constraint released — never over the current result page;
* the live "N properties match" figure is the search's own total, so the
  dropdowns and the ranking can never disagree;
* rental and size choices are generated from real listing values, are
  non-overlapping, leave no priced listing outside every interval, and send
  back exactly the bounds they were counted with;
* a business type or a target market never removes a property, and the
  response says which field does what instead of letting the UI guess;
* a selection that matches nothing stays visible with a zero count, and the
  caller is told which single filter is responsible and what it would match
  without it.
"""
from __future__ import annotations

import uuid

import pytest

from sitewise.services.recommendation_search_service import (
    PU_ELIGIBILITY_THRESHOLD,
    FILTER_FIELDS,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def user_token(client, cleanup_users) -> str:
    sub = uuid.uuid4()
    token = make_token(sub=str(sub), email=f"facets-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}")
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, sub)
    return token


def _facets(client, token: str, **params) -> dict:
    query = {k: v for k, v in params.items() if v not in (None, "", [])}
    response = client.get("/api/v1/recommendations/facets", params=query, headers=auth(token))
    assert response.status_code == 200, response.text
    return response.json()["data"]


def _search(client, token: str, **body) -> dict:
    response = client.post(
        "/api/v1/recommendations/search",
        json={"page_size": 1, **body},
        headers=auth(token),
    )
    assert response.status_code == 200, response.text
    return response.json()


# -- the counts are the search's own population -------------------------------


@pytest.mark.parametrize(
    "criteria",
    [
        {},
        {"preferred_state": "Johor"},
        {"property_type": "Shop lot"},
        {"preferred_state": "Selangor", "max_rental_rm": 6000.0},
        {"preferred_state": "Pulau Pinang", "min_size_sqft": 1000.0},
        {"preferred_area": "petaling", "max_rental_rm": 9000.0},
        {"query": "ss15"},
    ],
)
def test_matching_total_equals_the_search_total_for_the_same_criteria(
    client, user_token, criteria
):
    """The Python facet predicate and the search SQL cannot drift.

    This is the acceptance criterion stated as a test: the number shown while
    the entrepreneur is still choosing must be the number the ranking produces
    once they commit.
    """
    data = _facets(client, user_token, **criteria)
    assert data["matching_total"] == _search(client, user_token, **criteria)["pagination"][
        "total"
    ], criteria


def test_counts_are_made_before_pagination_and_over_the_gated_population(
    client, user_token
):
    data = _facets(client, user_token)
    browse = _search(client, user_token)
    assert data["universe_total"] == browse["pagination"]["total"]
    assert data["ranges"]["total"] == data["universe_total"]
    # The gate the counts respect is the search's gate, unchanged.
    assert data["pu_eligibility"]["threshold"] == PU_ELIGIBILITY_THRESHOLD
    assert data["pu_eligibility"] == browse["meta"]["pu_eligibility"]


def test_no_option_exceeds_the_eligible_population(client, user_token):
    data = _facets(client, user_token)
    ceiling = data["universe_total"]
    for key in ("states", "property_types"):
        assert sum(option["total"] for option in data[key]) == ceiling, key
    for key in ("rental_ranges", "size_ranges"):
        block = data[key]
        assert sum(option["total"] for option in block["options"]) == block["unbounded_total"]
        assert block["unbounded_total"] <= ceiling


# -- leave-one-out: each facet releases only its own constraint --------------


def test_state_options_are_priced_with_every_other_filter_applied(client, user_token):
    """Selecting a budget restates which states still have listings in it."""
    without = _facets(client, user_token)
    with_budget = _facets(client, user_token, max_rental_rm=3000.0)
    totals = {o["value"]: o["total"] for o in with_budget["states"]}
    for option in without["states"]:
        if option["total"] > 0 and option["value"] != "":
            expected = _search(
                client, user_token, preferred_state=option["value"], max_rental_rm=3000.0
            )["pagination"]["total"]
            assert totals[option["value"]] == expected, option["value"]


def test_changing_the_state_reprices_the_type_size_and_budget_options(client, user_token):
    johor = _facets(client, user_token, preferred_state="Johor")
    penang = _facets(client, user_token, preferred_state="Pulau Pinang")
    assert johor["matching_total"] != penang["matching_total"]
    assert _by_value(johor["property_types"]) != _by_value(penang["property_types"])
    assert johor["rental_ranges"]["options"] != penang["rental_ranges"]["options"]
    assert johor["size_ranges"]["options"] != penang["size_ranges"]["options"]
    # A facet releases only its OWN constraint: the state list under a state
    # selection is the same list as with nothing selected.
    assert _by_value(johor["states"]) == _by_value(_facets(client, user_token)["states"])


def test_type_options_are_priced_with_the_state_selection_applied(client, user_token):
    data = _facets(client, user_token, preferred_state="Johor")
    for option in data["property_types"]:
        expected = _search(
            client, user_token, preferred_state="Johor", property_type=option["value"]
        )["pagination"]["total"]
        assert option["total"] == expected, option["value"]


# -- generated rental / size intervals ---------------------------------------


def test_intervals_are_non_overlapping_and_cover_every_priced_listing(client, user_token):
    data = _facets(client, user_token)
    for key, low, high in (
        ("rental_ranges", "min_rental_rm", "max_rental_rm"),
        ("size_ranges", "min_size_sqft", "max_size_sqft"),
    ):
        options = data[key]["options"]
        assert options, key
        for previous, current in zip(options, options[1:]):
            # Strictly increasing bounds: an interval never shares a listing
            # with the next, and never leaves one outside both.
            assert previous[high] < current[low], (key, previous, current)
        assert options[0][low] == pytest.approx(data["ranges"][low]), key
        assert options[-1][high] == pytest.approx(data["ranges"][high]), key
        assert sum(o["total"] for o in options) == data[key]["unbounded_total"], key
        assert data[key]["selected"] is None, key


def test_each_interval_returns_exactly_what_it_counted(client, user_token):
    """Selecting a bucket cannot disagree with the count printed on it."""
    for key, low, high in (
        ("rental_ranges", "min_rental_rm", "max_rental_rm"),
        ("size_ranges", "min_size_sqft", "max_size_sqft"),
    ):
        options = _facets(client, user_token)[key]["options"]
        for option in [options[0], options[len(options) // 2], options[-1]]:
            total = _search(client, user_token, **{low: option[low], high: option[high]})[
                "pagination"
            ]["total"]
            assert total == option["total"], (key, option, total)


def test_interval_bounds_are_real_listing_values(client, user_token):
    """Nothing is hardcoded and nothing is rounded into existence.

    Every bound must be a rental or floor-area figure some listing in the
    catalogue actually carries — which is what makes the intervals disjoint and
    gapless over the data instead of over a fixed list of example figures. The
    eligible population is whatever the active PU variant gates, so the bound
    is checked against the catalogue itself rather than against one variant's
    score column.
    """
    from sqlalchemy import text
    from sqlmodel import Session

    from sitewise.db.analytics_session import analytics_engine

    data = _facets(client, user_token)
    with Session(analytics_engine) as session:
        rents = {
            float(row[0])
            for row in session.execute(
                text("SELECT DISTINCT rental_rm FROM fyp.catalogue_properties "
                     "WHERE rental_rm IS NOT NULL")
            )
        }
        sizes = {
            float(row[0])
            for row in session.execute(
                text("SELECT DISTINCT size_sqft FROM fyp.catalogue_properties "
                     "WHERE size_sqft IS NOT NULL")
            )
        }
    for option in data["rental_ranges"]["options"]:
        assert option["min_rental_rm"] in rents, option
        assert option["max_rental_rm"] in rents, option
        assert option["min_rental_rm"] <= option["max_rental_rm"], option
    for option in data["size_ranges"]["options"]:
        assert option["min_size_sqft"] in sizes, option
        assert option["max_size_sqft"] in sizes, option
        assert option["min_size_sqft"] <= option["max_size_sqft"], option


def test_intervals_reprice_with_the_other_selections(client, user_token):
    all_rent = _facets(client, user_token)["rental_ranges"]["options"]
    johor_rent = _facets(client, user_token, preferred_state="Johor")["rental_ranges"]["options"]
    assert johor_rent[0]["min_rental_rm"] >= all_rent[0]["min_rental_rm"]
    assert johor_rent[-1]["max_rental_rm"] <= all_rent[-1]["max_rental_rm"]
    assert sum(o["total"] for o in johor_rent) == _search(
        client, user_token, preferred_state="Johor"
    )["pagination"]["total"]


def test_a_selection_outside_the_generated_intervals_stays_reported(client, user_token):
    """Saved preferences can hold bounds the catalogue never offers as a
    bucket; they must be shown and counted, not silently dropped."""
    data = _facets(client, user_token, min_rental_rm=1.0, max_rental_rm=25000.0)
    selected = data["rental_ranges"]["selected"]
    assert selected is not None and selected["generated"] is False
    assert selected["min_rental_rm"] == pytest.approx(1.0)
    assert selected["max_rental_rm"] == pytest.approx(25000.0)
    assert selected["total"] == data["matching_total"]
    assert "Up to" not in selected["label"]

    # A one-sided bound is its own interval, labelled as one.
    half = _facets(client, user_token, max_rental_rm=5300.0)["rental_ranges"]["selected"]
    assert half["min_rental_rm"] is None and half["generated"] is False
    assert half["label"].startswith("Up to ")
    assert half["total"] == _search(client, user_token, max_rental_rm=5300.0)["pagination"][
        "total"
    ]

    # A generated bucket, sent back verbatim, is recognised as itself.
    bucket = data["rental_ranges"]["options"][0]
    bounds = {k: bucket[k] for k in ("min_rental_rm", "max_rental_rm")}
    exact = _facets(client, user_token, **bounds)
    assert exact["rental_ranges"]["selected"] == {
        **bounds,
        "label": bucket["label"],
        "total": bucket["total"],
        "generated": True,
    }


# -- preference fields are not eligibility filters ---------------------------


def test_field_roles_describe_what_each_input_actually_does(client, user_token):
    roles = {field["key"]: field["role"] for field in _facets(client, user_token)["fields"]}
    assert roles["preferred_state"] == "hard_filter"
    assert roles["property_type"] == "hard_filter"
    assert roles["rental_budget"] == "hard_filter"
    assert roles["property_size"] == "hard_filter"
    assert roles["business_type"] == "ranking_only"
    assert roles["target_market"] == "unverified"
    assert {field["key"] for field in FILTER_FIELDS} == set(roles)


def test_business_type_and_target_market_never_remove_a_property(client, user_token):
    plain = _facets(client, user_token)
    with_prefs = _facets(
        client,
        user_token,
        business_type="Cafe / Coffee Shop",
        layout_preferences=["Students", "Nearby Residents"],
    )
    assert with_prefs["matching_total"] == plain["matching_total"]
    assert with_prefs["rental_ranges"] == plain["rental_ranges"]
    assert with_prefs["size_ranges"] == plain["size_ranges"]
    assert with_prefs["states"] == plain["states"]
    assert with_prefs["property_types"] == plain["property_types"]
    # And the ranking agrees: same population, possibly a different order.
    assert _search(
        client,
        user_token,
        business_type="Cafe / Coffee Shop",
        layout_preferences=["Students"],
    )["pagination"]["total"] == plain["matching_total"]


# -- conflicting selections --------------------------------------------------


def test_a_conflicting_selection_stays_visible_with_its_real_count(client, user_token):
    """Nothing is cleared silently, and nothing is counted that is not there.

    A text search that matches no listing empties the combination. The chosen
    state must stay on its dropdown at its true count of zero, every option in
    the other lists must be counted from the same empty intersection, and the
    caller must be told which one filter is responsible — with the real number
    it would match if released.
    """
    data = _facets(client, user_token, preferred_state="Johor", query="qqqzzznope")
    assert data["matching_total"] == 0
    assert _search(
        client, user_token, preferred_state="Johor", query="qqqzzznope"
    )["pagination"]["total"] == 0
    assert _by_value(data["states"]) == {"Johor": 0}
    assert sum(option["total"] for option in data["rental_ranges"]["options"]) == 0
    assert data["rental_ranges"]["unbounded_total"] == 0

    relaxations = {item["field"]: item["total"] for item in data["relaxations"]}
    assert relaxations["query"] == _search(
        client, user_token, preferred_state="Johor"
    )["pagination"]["total"]
    assert relaxations["preferred_state"] == _search(
        client, user_token, query="qqqzzznope"
    )["pagination"]["total"]
    assert relaxations["query"] > 0 >= relaxations["preferred_state"]


def test_relaxations_only_describe_active_filters(client, user_token):
    data = _facets(client, user_token, preferred_state="Johor")
    assert [item["field"] for item in data["relaxations"]] == ["preferred_state"]
    assert data["relaxations"][0]["total"] == data["universe_total"]


# -- request validation and compatibility -----------------------------------


def test_min_greater_than_max_is_rejected_for_both_numeric_fields(client, user_token):
    for params in (
        {"min_rental_rm": 9000.0, "max_rental_rm": 3000.0},
        {"min_size_sqft": 2000.0, "max_size_sqft": 500.0},
    ):
        response = client.get(
            "/api/v1/recommendations/facets", params=params, headers=auth(user_token)
        )
        assert response.status_code == 422, params
        assert response.json()["detail"]["code"] == "invalid_range", params


def test_negative_and_absurd_bounds_are_rejected(client, user_token):
    for params in ({"max_rental_rm": -1.0}, {"min_size_sqft": 2_000_000.0}):
        response = client.get(
            "/api/v1/recommendations/facets", params=params, headers=auth(user_token)
        )
        assert response.status_code == 422, params


def test_facets_without_selections_still_describe_the_population(client, user_token):
    """The parameterless call the existing clients make keeps working."""
    data = _facets(client, user_token)
    assert data["contextual"] is True
    assert data["matching_total"] == data["universe_total"]
    assert data["states"] and data["property_types"] and data["sort_options"]
    assert data["ranges"]["min_rental_rm"] is not None
    assert data["relaxations"] == []
    assert data["rental_ranges"]["selected"] is None


def test_facets_require_authentication(client):
    assert client.get("/api/v1/recommendations/facets").status_code in (401, 403)


def _by_value(options: list[dict]) -> dict[str, int]:
    return {option["value"]: option["total"] for option in options}
