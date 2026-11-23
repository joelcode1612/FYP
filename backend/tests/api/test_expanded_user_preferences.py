"""Integration checks for account preferences. Uses existing test fixtures."""
from .test_preferences_api import auth, identity, cleanup_preferences, VALID_PREFERENCES


def test_expanded_settings_round_trip_and_partial_merge(client, identity):
    headers = auth(identity["token"])
    path = "/api/v1/preferences/me"
    settings = {"preferred_state": "Selangor", "preferred_city": "Petaling Jaya",
                "search_radius_m": 1000, "default_sort": "rent_asc",
                "transit_max_m": 500, "nearby_parking_min": 1,
                "fnb_competition_max": 10, "use_current_location": False,
                "notification_updates": False}
    criteria = {k: v for k, v in VALID_PREFERENCES.items() if k != "business_type"}
    r = client.patch(path, json={"preferences": {**criteria, "user_settings": settings}}, headers=headers)
    assert r.status_code == 200, r.text
    assert r.json()["preferences"]["user_settings"] == settings
    r = client.patch(path, json={"preferences": {"user_settings": {"default_sort": "size_asc"}}}, headers=headers)
    assert r.status_code == 200, r.text
    settings["default_sort"] = "size_asc"
    stored = client.get(path, headers=headers).json()["preferences"]
    assert stored["user_settings"] == settings
    assert stored["max_budget_rm"] == criteria["max_budget_rm"]
    assert "business_type" not in stored
    r = client.patch(path, json={"preferences": {"user_settings": {"search_radius_m": 123}}}, headers=headers)
    assert r.status_code == 422, r.text
    assert client.get(path, headers=headers).json()["preferences"] == stored
