"""Pure policy tests; no database, model file or service needed."""
from sitewise.domain.business_concept_compatibility import FEATURES, evaluate_concepts


def _values():
    return {key: 0.0 for key in FEATURES} | {
        "pop_1000m": 5000.0,
        "office_pois_1000m": 12.0,
        "retail_pois_1000m": 20.0,
        "schools_count_1000m": 3.0,
        "malls_count_1000m": 1.0,
        "nearest_transit_walk_m": 450.0,
        "nearest_major_road_m": 90.0,
        "fnb_competitors_1000m": 10.0,
        "restaurant_count_1000m": 4.0,
        "cafe_count_1000m": 3.0,
        "fast_food_count_1000m": 1.0,
        "bakery_dessert_beverage_count_1000m": 2.0,
    }


def test_complete_evidence_yields_five_provisional_ranks():
    result = evaluate_concepts(_values(), monthly_rental=2700)
    assert result["available"] and result["status"] == "provisional"
    assert len(result["rankings"]) == 5
    assert sorted(item["rank"] for item in result["rankings"]) == [1, 2, 3, 4, 5]
    assert all(item["score"] is not None for item in result["rankings"])
    assert all(item["premises_requirements"][0]["status"] == "unknown" for item in result["rankings"])
    assert result["final_feasibility"] != "approved"


def test_missing_one_category_competitor_count_withholds_all_ranks():
    values = _values()
    values["cafe_count_1000m"] = None
    result = evaluate_concepts(values)
    assert not result["available"]
    assert all(item["rank"] is None and item["score"] is None for item in result["rankings"])
    assert "cafe_count_1000m" in next(item for item in result["rankings"] if item["key"] == "cafe")["missing_features"]


def test_unknown_is_not_a_measured_zero():
    values = _values()
    values["fnb_competitors_1000m"] = None
    assert not evaluate_concepts(values)["available"]
    values["fnb_competitors_1000m"] = 0
    values.update(restaurant_count_1000m=0, cafe_count_1000m=0,
                  fast_food_count_1000m=0, bakery_dessert_beverage_count_1000m=0)
    result = evaluate_concepts(values)
    assert result["available"]
    assert all(item["component_scores"]["competition"] == 50 for item in result["rankings"])


def test_inconsistent_inventory_and_invalid_coordinate_fail_closed():
    values = _values()
    values["restaurant_count_1000m"] = 100
    assert not evaluate_concepts(values)["available"]
    assert not evaluate_concepts(_values(), coordinate_present=False)["available"]


def test_rental_and_budget_do_not_change_category_order():
    first = evaluate_concepts(_values(), monthly_rental=2700, monthly_budget=2000)
    second = evaluate_concepts(_values(), monthly_rental=2700, monthly_budget=4000)
    assert first["budget_check"] == "advertised_above_budget"
    assert second["budget_check"] == "advertised_within_budget"
    assert [item["key"] for item in first["rankings"]] == [item["key"] for item in second["rankings"]]


def test_shared_competitor_bucket_is_disclosed():
    result = evaluate_concepts(_values())
    for name in ("bakery_dessert", "beverage"):
        row = next(item for item in result["rankings"] if item["key"] == name)
        assert any("combined" in note.lower() for note in row["cautions"])
