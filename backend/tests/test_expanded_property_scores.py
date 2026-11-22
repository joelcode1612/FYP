import uuid
from contextlib import nullcontext
from unittest.mock import Mock

import pytest

from sitewise.ml import pu_expanded
from sitewise.repositories.generated_recommendation_store import GeneratedRecommendationStore
from sitewise.services import recommendation_generation_service as generation
from sitewise.services.recommendation_search_service import (
    RecommendationSearchService,
    SearchCriteria,
    StaleRankingCursor,
)


def test_generation_persists_only_expanded_scores(monkeypatch):
    monkeypatch.setenv("SITEWISE_PU_MODEL_VARIANT", "legacy")
    user_id = uuid.uuid4()
    store = GeneratedRecommendationStore()
    old_batch = store.save_batch(user_id, [{
        "property_id": "EP-00001",
        "model": {
            "name": pu_expanded.EXPANDED_MODEL_NAME,
            "feature_count": 64,
            "score_source_mode": "stored_prediction",
            "association_score": 0.99,
        },
    }])
    service = generation.RecommendationGenerationService(Mock(), Mock(), store)
    monkeypatch.setattr(service.preferences, "payload", lambda _: {"preferences": None})
    monkeypatch.setattr(service.candidates, "list_candidates", lambda **_: [
        {"property_id": pid, "monthly_rental_myr": 2500, "built_up_sqft": 1000,
         "pu_association_score": 0.99}
        for pid in ("EP-00001", "EP-00002")
    ])
    infer = Mock(return_value={
        "EP-00001": {"available": True, "score": 0.64},
        "EP-00002": {"available": False, "score": None},
    })
    monkeypatch.setattr(generation, "expanded_scores_many", infer)

    assert service.latest(user_id)["available"] is False
    old_id = uuid.UUID(old_batch["results"][0]["result_id"])
    assert service.explain(old_id, user_id) is None
    batch = service.generate(user_id)

    infer.assert_called_once_with(service.analytics_session, ["EP-00001", "EP-00002"])
    [result] = batch["results"]
    assert result["property_id"] == "EP-00001"
    assert result["model"]["name"] == pu_expanded.EXPANDED_MODEL_NAME
    assert result["model"]["association_score"] == 0.64
    assert result["model"]["score_source_mode"] == "live_inference"
    assert result["model"]["artifact_sha256"]
    assert batch["candidate_summary"]["rejection_reasons"] == {"expanded64_inference_unavailable": 1}
    assert service.latest(user_id)["batch"]["results"] == [result]
    assert service.generate(user_id)["reused_existing_batch"] is True
    assert infer.call_count == 1
    infer.return_value["EP-00001"]["score"] = 0.73
    regenerated = service.generate(user_id, refresh=True)
    assert regenerated["reused_existing_batch"] is False
    assert regenerated["results"][0]["model"]["association_score"] == 0.73
    infer.assert_called_with(
        service.analytics_session, ["EP-00001", "EP-00002"], refresh=True
    )


def test_pagination_rejects_cursor_from_a_changed_ranking():
    service = RecommendationSearchService(None)
    criteria = SearchCriteria()
    cursor = service._encode_cursor(criteria, 20, "original")
    page = SearchCriteria(cursor=cursor)

    assert service._decode_cursor(page, "original") == 20
    with pytest.raises(StaleRankingCursor):
        service._decode_cursor(page, "changed")


def test_display_scores_keep_zero_and_omit_unavailable(monkeypatch):
    session = Mock()
    session.begin_nested.return_value = nullcontext()
    monkeypatch.setattr(pu_expanded, "expanded_scores_many", lambda *_: {
        "zero": {"available": True, "score": 0.0},
        "scored": {"available": True, "score": 0.642},
        "missing": {"available": False, "score": None},
    })

    assert pu_expanded.expanded_display_scores(session, ["zero", "scored", "missing"]) == pytest.approx({
        "zero": 0.0, "scored": 64.2,
    })
