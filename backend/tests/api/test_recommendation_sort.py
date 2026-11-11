"""Ordering (sort) support for the recommendation search endpoint.

The search returns ONE eligible set; ``sort`` only re-sequences it. These tests
pin the properties that make that safe to expose in the UI:

* every accepted key is served and produces the documented order;
* an unsupported key is a 422, never a silently unsorted list;
* the eligible SET and its total are identical across orderings — sort can
  never surface a property that failed the PU gate or the filters;
* a pagination cursor issued under one ordering is rejected under another,
  because paging page N of a different sequence would show duplicated or
  missing rows while looking correct;
* the facets payload advertises the same vocabulary the endpoint accepts.
"""
from __future__ import annotations

import uuid

import pytest

from sitewise.services.recommendation_search_service import SORT_OPTIONS

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def user_token(client, cleanup_users) -> str:
    sub = uuid.uuid4()
    token = make_token(sub=str(sub), email=f"sort-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}")
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, sub)
    return token


def _search(client, token: str, **body) -> dict:
    response = client.post(
        "/api/v1/recommendations/search",
        json={"page_size": 20, **body},
        headers=auth(token),
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_every_advertised_sort_key_is_served(client, user_token):
    for key in SORT_OPTIONS:
        payload = _search(client, user_token, sort=key)
        assert payload["data"], f"{key} returned no rows"
        assert payload["meta"]["criteria"]["sort"] == key


def test_unknown_sort_key_is_rejected(client, user_token):
    response = client.post(
        "/api/v1/recommendations/search",
        json={"sort": "most_profitable"},
        headers=auth(user_token),
    )
    assert response.status_code == 422, response.text


def test_sort_never_changes_the_eligible_set(client, user_token):
    totals = {
        key: _search(client, user_token, sort=key)["pagination"]["total"]
        for key in SORT_OPTIONS
    }
    assert len(set(totals.values())) == 1, totals

    # Membership, not just the count: a property returned under one ordering
    # must be returned under every other one. Page 1 differs between
    # orderings by design, so eligibility is compared one property at a time
    # through the query filter, which applies before ordering.
    sample = _search(client, user_token, sort="rent_asc")["data"][0]["property_id"]
    found = {
        key: [row["property_id"] for row in _search(client, user_token, sort=key, query=sample)["data"]]
        for key in SORT_OPTIONS
    }
    for key, ids in found.items():
        assert ids == [sample], f"{key}: {ids}"


def test_rent_ascending_is_ordered(client, user_token):
    rows = _search(client, user_token, sort="rent_asc")["data"]
    rents = [row["rental_rm"] for row in rows]
    assert rents == sorted(rents)


def test_rent_descending_is_ordered(client, user_token):
    rows = _search(client, user_token, sort="rent_desc")["data"]
    rents = [row["rental_rm"] for row in rows]
    assert rents == sorted(rents, reverse=True)


def test_size_ordering_is_ordered(client, user_token):
    largest = [row["size_sqft"] for row in _search(client, user_token, sort="size_desc")["data"]]
    smallest = [row["size_sqft"] for row in _search(client, user_token, sort="size_asc")["data"]]
    assert largest == sorted(largest, reverse=True)
    assert smallest == sorted(smallest)


def test_pu_ordering_is_descending(client, user_token):
    scores = [
        row["research"]["pu_score"]
        for row in _search(client, user_token, sort="pu_desc")["data"]
    ]
    assert scores == sorted(scores, reverse=True)


def test_cursor_from_another_ordering_is_refused(client, user_token):
    first = _search(client, user_token, sort="rent_asc", page_size=1)
    cursor = first["pagination"]["next_cursor"]
    assert cursor, "expected a next page in the live catalogue"

    # Same criteria, different ordering: the cursor must not be honoured.
    response = client.post(
        "/api/v1/recommendations/search",
        json={"sort": "rent_desc", "page_size": 1, "cursor": cursor},
        headers=auth(user_token),
    )
    assert response.status_code == 422, response.text
    assert response.json()["detail"]["code"] == "invalid_cursor"


def test_cursor_is_honoured_within_the_same_ordering(client, user_token):
    first = _search(client, user_token, sort="rent_asc", page_size=1)
    cursor = first["pagination"]["next_cursor"]
    second = client.post(
        "/api/v1/recommendations/search",
        json={"sort": "rent_asc", "page_size": 1, "cursor": cursor},
        headers=auth(user_token),
    )
    assert second.status_code == 200, second.text
    page_two = second.json()
    assert page_two["data"][0]["property_id"] != first["data"][0]["property_id"]
    assert page_two["data"][0]["recommendation"]["rank"] == 2


def test_facets_advertise_the_accepted_vocabulary(client, user_token):
    response = client.get("/api/v1/recommendations/facets", headers=auth(user_token))
    assert response.status_code == 200, response.text
    options = response.json()["data"]["sort_options"]
    assert [entry["value"] for entry in options] == list(SORT_OPTIONS)
    assert options[0]["value"] == "best_match"
    assert all(entry["label"] for entry in options)
