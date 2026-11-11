"""Phase 5 verification: durable PostgreSQL recommendation persistence.

Replaces the process-local store on the request path. Proven here:

* batches persist across "restarts" (a brand-new session/instance reads the
  same rows - no process memory involved);
* ownership isolation holds in the database;
* the SHAP attachment persists and round-trips;
* the typed columns (score, rank, PU/preference scores, versions, canonical
  TEXT property id) are written alongside the JSONB payload;
* deleting a user removes their generated results (ON DELETE CASCADE), so
  tests and account deletion leave no orphans;
* the legacy ``/recommendations/me`` surface stays operational.

The in-memory store remains available and unchanged for isolated tests.
"""
from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select, text
from sqlmodel import Session

from sitewise.db.models.recommendation_result import RecommendationResult
from sitewise.db.session import engine
from sitewise.repositories.generated_recommendation_store import (
    DatabaseRecommendationStore,
    GeneratedRecommendationStore,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

PAYLOAD = {
    "property_id": "MD-00510",
    "model": {"name": "pu_model", "association_score": 0.8123},
    "personalisation": {
        "preference_match_score": 0.5724,
        "config_version": "sitewise_rule_based_preference_v1",
        "components": {"budget_fit": 1.0},
    },
    "final_recommendation": {"score": 0.7403, "rank": 1},
    "explanation": {"preference_reasons": ["budget ok"], "cautions": []},
}


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def user_id(client, cleanup_users):
    """A real users row: the recommendation FK targets users.user_id."""
    sub = str(uuid.uuid4())
    token = make_token(sub=sub, email=f"recpersist-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    return register_user_id(cleanup_users, uuid.UUID(sub))


def _two_payloads() -> list[dict]:
    second = {
        **PAYLOAD,
        "property_id": "EP-01877",
        "final_recommendation": {"score": 0.6100, "rank": 2},
    }
    return [PAYLOAD, second]


def test_batch_persists_across_restarts(user_id):
    store = DatabaseRecommendationStore(Session(engine))
    batch = store.save_batch(user_id, _two_payloads())
    assert batch["result_count"] == 2

    # A brand-new store on a brand-new session = a restarted backend.
    revived = DatabaseRecommendationStore(Session(engine))
    latest = revived.latest(user_id)
    assert latest is not None
    assert latest["batch_id"] == batch["batch_id"]
    assert [r["property_id"] for r in latest["results"]] == ["MD-00510", "EP-01877"]
    assert [r["final_recommendation"]["rank"] for r in latest["results"]] == [1, 2]


def test_typed_columns_and_canonical_text_id_are_written(user_id):
    store = DatabaseRecommendationStore(Session(engine))
    batch = store.save_batch(user_id, _two_payloads())
    result_id = uuid.UUID(batch["results"][0]["result_id"])

    with Session(engine) as session:
        row = session.execute(
            select(RecommendationResult).where(
                RecommendationResult.result_id == result_id
            )
        ).scalars().first()
        assert row is not None
        assert row.user_id == user_id  # app UUID, never fyp.users' legacy BIGINT
        assert row.property_id == "MD-00510"  # TEXT canonical id, not an int
        assert str(row.batch_id) == batch["batch_id"]
        assert float(row.score) == pytest.approx(0.7403, abs=1e-6)
        assert row.ranking == 1
        assert float(row.pu_association_score) == pytest.approx(0.8123, abs=1e-6)
        assert float(row.preference_match_score) == pytest.approx(0.5724, abs=1e-6)
        assert row.scoring_version == "sitewise_rule_based_preference_v1"
        assert row.model_name == "pu_model"
        # The JSONB payload is the FULL result contract.
        assert row.payload["final_recommendation"]["score"] == pytest.approx(
            0.7403, abs=1e-9
        )
        assert "components" in row.payload["personalisation"]


def test_ownership_isolation_is_enforced_in_the_database(user_id):
    stranger = uuid.uuid4()
    store = DatabaseRecommendationStore(Session(engine))
    batch = store.save_batch(user_id, _two_payloads())
    result_id = uuid.UUID(batch["results"][0]["result_id"])

    assert store.get(result_id, stranger) is None
    assert store.latest(stranger) is None
    assert (
        store.attach_shap(result_id, stranger, {"x": 1}, {"available": False}) is None
    )
    # Foreign result reads through a fresh session too.
    revived = DatabaseRecommendationStore(Session(engine))
    assert revived.get(result_id, stranger) is None


def test_shap_attachment_persists_and_round_trips(user_id):
    store = DatabaseRecommendationStore(Session(engine))
    batch = store.save_batch(user_id, _two_payloads())
    result_id = uuid.UUID(batch["results"][0]["result_id"])

    shap = {"contributions": {"pop_500m": 0.01}, "score": 0.8123}
    status = {"available": True, "source": "test"}
    stored = store.attach_shap(result_id, user_id, shap, status)
    assert stored is not None
    assert stored["explanation"]["shap"]["score"] == pytest.approx(0.8123)

    revived = DatabaseRecommendationStore(Session(engine))
    assert revived.shap_of(result_id, user_id)["score"] == pytest.approx(0.8123)
    payload = revived.get(result_id, user_id)
    assert payload["explanation"]["shap_status"]["source"] == "test"


def test_user_deletion_cascades_generated_results(user_id):
    store = DatabaseRecommendationStore(Session(engine))
    store.save_batch(user_id, _two_payloads())
    with Session(engine) as session:
        count = session.execute(
            text(
                "SELECT count(*) FROM recommendation_result WHERE user_id = :u"
            ),
            {"u": user_id},
        ).scalar_one()
    assert count == 2

    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        UserRepository(session).delete(user_id)

    with Session(engine) as session:
        remaining = session.execute(
            text(
                "SELECT count(*) FROM recommendation_result WHERE user_id = :u"
            ),
            {"u": user_id},
        ).scalar_one()
    assert remaining == 0


def test_in_memory_store_contract_unchanged():
    store = GeneratedRecommendationStore()
    owner = uuid.uuid4()
    batch = store.save_batch(owner, [dict(PAYLOAD)])
    result_id = uuid.UUID(batch["results"][0]["result_id"])
    assert store.get(result_id, owner) is not None
    assert store.latest(owner)["result_count"] == 1
    store.clear()
    assert store.latest(owner) is None


# ---------------------------------------------------------------------------
# API level: generation -> retrieval across a fresh service instance
# ---------------------------------------------------------------------------


def _identity(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(sub=sub, email=f"recpersist-api-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    return {"token": token, "user_id": register_user_id(cleanup_users, uuid.UUID(sub))}


def test_generate_then_retrieve_after_restart(client, cleanup_users):
    identity = _identity(client, cleanup_users)
    generated = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 3},
        headers=auth(identity["token"]),
    )
    assert generated.status_code == 200, generated.text
    body = generated.json()
    assert body["status"] == "ok"
    assert body["results"]

    # Simulate a backend restart: the SAME data must be served because it is
    # durable, not process-local.
    from sitewise.services.recommendation_generation_service import (
        RecommendationGenerationService,
    )

    with Session(engine) as app_session, Session(engine) as analytics_session:
        revived = RecommendationGenerationService(app_session, analytics_session)
        latest = revived.latest(identity["user_id"])
    assert latest["available"] is True
    assert latest["batch"]["batch_id"] == body["batch_id"]
    assert [r["property_id"] for r in latest["batch"]["results"]] == [
        r["property_id"] for r in body["results"]
    ]

    via_api = client.get(
        "/api/v1/recommendations/me/generated", headers=auth(identity["token"])
    )
    assert via_api.status_code == 200, via_api.text
    assert via_api.json()["batch"]["batch_id"] == body["batch_id"]

    result_id = body["results"][0]["result_id"]
    explanation = client.get(
        f"/api/v1/recommendations/{result_id}/explanation",
        headers=auth(identity["token"]),
    )
    assert explanation.status_code == 200, explanation.text
    assert explanation.json()["result_id"] == result_id


def test_legacy_me_endpoint_stays_operational(client, cleanup_users):
    identity = _identity(client, cleanup_users)
    response = client.get("/api/v1/recommendations/me", headers=auth(identity["token"]))
    assert response.status_code == 200, response.text
