"""Capture one REAL catalogue evidence payload for headless verification.

Read-only: opens the analytics session the evidence route uses, picks a
catalogue property whose six tile metrics are all present, and dumps the
exact `get_evidence` payload to test/.data/evidence_captured_fixture.json
(the same captured-fixture convention as recommendation_search_fixture.json).

Run from backend/: .venv/Scripts/python.exe scripts/capture_evidence_fixture.py
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, "src")

from sqlalchemy import text  # noqa: E402

from sitewise.db.analytics_session import analytics_engine  # noqa: E402
from sitewise.repositories.catalog_repository import CatalogRepository  # noqa: E402

TILE_KEYS = (
    "pop_1000m",
    "nearest_transit_walk_m",
    "retail_pois_1000m",
    "parking_facilities_500m",
)


def metric_values(payload: dict) -> dict:
    out = {}
    for group in payload.get("groups", []):
        for m in group.get("metrics", []):
            if m.get("key") in TILE_KEYS or m.get("key", "").endswith("_count_500m"):
                out[m["key"]] = m.get("value")
    return out


if __name__ == "__main__":
    from sqlmodel import Session

    with Session(analytics_engine) as session:
        repo = CatalogRepository(session)
        # Candidate ids: rows whose catchment metrics are actually populated.
        rows = session.execute(
            text(
                """
                SELECT canonical_property_id
                FROM sitewise_analytics.subject_features
                WHERE competitor_count_500m IS NOT NULL
                  AND nearest_transit_walk_m IS NOT NULL
                  AND parking_facilities_500m IS NOT NULL
                ORDER BY canonical_property_id
                LIMIT 40
                """
            )
        ).fetchall()
        if not rows:
            print("NO RICH ROWS FOUND — inspect the analytics table name")
            sys.exit(1)

        chosen = None
        for (listing_id,) in rows:
            payload = repo.get_evidence(listing_id)
            if payload.get("available"):
                values = metric_values(payload)
                if all(values.get(k) is not None for k in TILE_KEYS):
                    chosen = (listing_id, payload, values)
                    break

        if chosen is None:
            print("No available evidence payload with all tile metrics")
            sys.exit(1)

        listing_id, payload, values = chosen
        out = Path(__file__).resolve().parents[2] / "test" / ".data"
        out.mkdir(parents=True, exist_ok=True)
        target = out / "evidence_captured_fixture.json"
        target.write_text(json.dumps(payload, indent=1), encoding="utf-8")
        print(f"captured {listing_id} -> {target}")
        print(json.dumps(values, indent=1))
