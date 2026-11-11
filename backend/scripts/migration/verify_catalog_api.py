"""Verify GET /api/v1/catalog/properties serves the migrated 955-property dataset.

Auth is bypassed with a dependency override so the real route handler, the real
repository and the real SQL run - only the Supabase JWT check is stubbed.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

os.environ.setdefault("NO_PROXY", "localhost,127.0.0.1,::1")
os.environ.setdefault("no_proxy", os.environ["NO_PROXY"])
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import openpyxl  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from sitewise.dependencies import AuthenticatedUser, get_current_user  # noqa: E402
from sitewise.main import app  # noqa: E402

WORKBOOK = Path(
    r"C:/Users/Lenovo/Downloads/Telegram Desktop/"
    r"SiteWise_PU_Property_Image_Scores_Merged (1).xlsx"
)

FAILS: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  [{'ok ' if ok else 'FAIL'}] {name}{(' - ' + detail) if detail else ''}")
    if not ok:
        FAILS.append(name)


def workbook_expectations():
    wb = openpyxl.load_workbook(WORKBOOK, read_only=True, data_only=True)
    ws = wb["PU Properties + Images"]
    it = ws.iter_rows(values_only=True)
    header = list(next(it))
    rows = {}
    for raw in it:
        if not raw or all(v in (None, "") for v in raw):
            continue
        r = dict(zip(header, raw))
        rows[r["canonical_property_id"]] = r
    return rows


def main() -> int:
    expected = workbook_expectations()

    class FakeUser:
        id = "00000000-0000-0000-0000-000000000000"
        email = "migration-probe@sitewise.local"
        role = "admin"
        claims = {}

    app.dependency_overrides[get_current_user] = lambda: FakeUser()
    client = TestClient(app)

    print("[health]")
    r = client.get("/health")
    check("GET /health", r.status_code == 200, str(r.status_code))

    print("[catalogue listing]")
    first = client.get("/api/v1/catalog/properties", params={"limit": 200, "offset": 0})
    check("GET /api/v1/catalog/properties", first.status_code == 200, str(first.status_code))
    body = first.json()
    total = body["meta"]["total"]
    check("catalogue total == 955", total == 955, f"total={total}")
    check("first page size == 200", len(body["data"]) == 200, str(len(body["data"])))

    rows = list(body["data"])
    offset = 200
    while offset < total:
        page = client.get(
            "/api/v1/catalog/properties", params={"limit": 200, "offset": offset}
        ).json()
        rows.extend(page["data"])
        offset += 200
    check("paged fetch returns 955 rows", len(rows) == 955, str(len(rows)))

    ids = [row["id"] for row in rows]
    check("ids are unique", len(set(ids)) == 955, str(len(set(ids))))
    check("ids match workbook exactly", set(ids) == set(expected), "")

    with_image = [r for r in rows if r.get("image_url")]
    check("911 rows carry an image url", len(with_image) == 911, str(len(with_image)))

    bad_geo = [
        r
        for r in rows
        if not (0.5 < float(r["latitude"]) < 8.0 and 99.0 < float(r["longitude"]) < 120.0)
    ]
    check("all coordinates inside Malaysia", not bad_geo, f"{len(bad_geo)} bad")

    coord_mismatch = 0
    for r in rows:
        e = expected[r["id"]]
        if abs(float(r["latitude"]) - float(e["latitude"])) > 1e-6:
            coord_mismatch += 1
        if abs(float(r["longitude"]) - float(e["longitude"])) > 1e-6:
            coord_mismatch += 1
    check("coordinates match workbook", coord_mismatch == 0, str(coord_mismatch))

    rent_mismatch = sum(
        1 for r in rows if abs(float(r["rental_rm"]) - float(expected[r["id"]]["property_monthly_rental_myr"])) > 0.01
    )
    check("rental values match workbook", rent_mismatch == 0, str(rent_mismatch))

    size_mismatch = sum(
        1 for r in rows if abs(float(r["size_sqft"]) - float(expected[r["id"]]["property_built_up_sqft"])) > 0.01
    )
    check("size values match workbook", size_mismatch == 0, str(size_mismatch))

    scores = [float(r["suitability_score"]) for r in rows]
    check(
        "all scores within 0-100",
        all(0 <= s <= 100 for s in scores),
        f"min={min(scores):.2f} max={max(scores):.2f}",
    )
    check("no row is published/approved implicitly", all(r.get("dataset_validation") for r in rows))

    print("[single property + evidence]")
    pid = rows[0]["id"]
    one = client.get(f"/api/v1/catalog/properties/{pid}")
    check(f"GET /properties/{pid}", one.status_code == 200, str(one.status_code))
    check("single row id matches", one.json()["id"] == pid)

    ev = client.get(f"/api/v1/catalog/properties/{pid}/evidence")
    check(f"GET /properties/{pid}/evidence", ev.status_code == 200, str(ev.status_code))
    ev_body = ev.json()
    check("evidence available for imported property", ev_body.get("available") is True, json.dumps(ev_body.get("reason", ""))[:80])

    missing = client.get("/api/v1/catalog/properties/NOPE-99999")
    check("unknown id returns 404", missing.status_code == 404, str(missing.status_code))

    print("[property types filter source]")
    types = client.get("/api/v1/catalog/property-types")
    check("GET /property-types", types.status_code == 200, str(types.status_code))
    tdata = types.json()["data"]
    check("types sum to 955", sum(t["total"] for t in tdata) == 955, str([(t["value"], t["total"]) for t in tdata]))

    print()
    if FAILS:
        print(f"FAILED: {len(FAILS)} checks -> {FAILS}")
        return 1
    print("ALL API CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
