"""Capture the real recommendation-search payloads used by the web audit.

`probe_recommendations.js` runs the built client bundle in a headless browser,
but the browser harness holds no Supabase credentials, so it cannot call the
live API. Rather than hand-writing a response shape (which would let the page
pass an audit against a contract the server never sends), this script calls the
real endpoint through an in-process ASGI client with only the auth dependency
overridden, against the real PostgreSQL catalogue, and writes the exact payloads
to `FYP/test/.data/recommendation_search_fixture.json`.

The harness replays them: page 1, the cursor page, the browse response, the
facets vocabulary, and the catalogue detail rows for the ranked ids.

Run from `FYP/backend` (its virtualenv holds FastAPI + SQLModel):

    PYTHONPATH=src .venv/Scripts/python.exe \
      ../fyp_jaspr_web/tool/capture_recommendation_fixture.py

Then audit the page:

    cd ../fyp_jaspr_web
    NODE_PATH=<playwright-core> BASE=http://127.0.0.1:8090 \
      node tool/probe_recommendations.js
"""

from __future__ import annotations

import json
import pathlib
import sys
import uuid

from fastapi.testclient import TestClient

from sitewise.dependencies import AuthenticatedUser, get_current_user
from sitewise.main import app

# Resolved from this file: tool/ -> fyp_jaspr_web/ -> repo root -> test/.data
OUT = (
    pathlib.Path(__file__).resolve().parents[2]
    / "test"
    / ".data"
    / "recommendation_search_fixture.json"
)

CRITERIA = {
    "business_type": "Specialty Café",
    "preferred_state": "Selangor",
    "max_rental_rm": 10000,
    "min_size_sqft": 900,
    "layout_preferences": ["Ground floor"],
    "page_size": 20,
}


class _StubProfile:
    user_id = uuid.UUID("00000000-0000-4000-8000-000000000001")
    role = "entrepreneur"
    email = "harness@sitewise.local"
    display_name = "Harness Entrepreneur"


def _stub_user() -> AuthenticatedUser:
    return AuthenticatedUser(token=None, profile=_StubProfile())


def main() -> int:
    app.dependency_overrides[get_current_user] = _stub_user
    try:
        with TestClient(app) as client:
            first = client.post("/api/v1/recommendations/search", json=CRITERIA)
            first.raise_for_status()
            page_one = first.json()

            cursor = page_one["pagination"]["next_cursor"]
            page_two = None
            if cursor:
                second = client.post(
                    "/api/v1/recommendations/search",
                    json={**CRITERIA, "cursor": cursor},
                )
                second.raise_for_status()
                page_two = second.json()

            facets = client.get("/api/v1/recommendations/facets")
            facets.raise_for_status()

            # Browse (no criteria) — what a brand-new account sees.
            browse = client.post(
                "/api/v1/recommendations/search", json={"page_size": 20}
            )
            browse.raise_for_status()

            # Detail rows for the ranked ids, so "Details" works in the harness.
            details = {}
            for row in page_one["data"][:6]:
                pid = row["property_id"]
                detail = client.get(f"/api/v1/catalog/properties/{pid}")
                if detail.status_code == 200:
                    body = detail.json()
                    # This endpoint returns the row directly (no `data`
                    # envelope), unlike the list endpoint.
                    if body.get("id") == pid:
                        details[pid] = body
    finally:
        app.dependency_overrides.clear()

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(
            {
                "criteria": CRITERIA,
                "page_one": page_one,
                "page_two": page_two,
                "browse": browse.json(),
                "facets": facets.json(),
                "details": details,
            },
            indent=1,
        ),
        encoding="utf-8",
    )
    print(f"wrote {OUT}")
    print("page_one rows:", len(page_one["data"]), "total:", page_one["pagination"]["total"])
    print("page_two rows:", len((page_two or {}).get("data", [])))
    print("model:", page_one["model"])
    print("details:", len(details))
    return 0


if __name__ == "__main__":
    sys.exit(main())
