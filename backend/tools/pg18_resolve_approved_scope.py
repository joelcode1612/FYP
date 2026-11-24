"""Resolve the 8 approved rental_properties rows to their catalogue rows.

Read-only. Establishes, by measurement:

  * the ``listing_id`` for each approved ``fyp.rental_properties.id``;
  * whether a matching ``sitewise_app.properties`` row exists;
  * which keys live in ``source_data`` (personal-data inspection);
  * the exact dependency counts for the approved scope.

Nothing is written; the session is read-only.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import psycopg2

APPROVED_IDS = [646, 2, 35, 51, 799, 550, 120, 300]
SOURCE_DB = "Final_Location_Analysis"


def _password() -> str:
    env_path = Path(__file__).resolve().parents[1] / ".env"
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            creds = line.split("://", 1)[1].split("@", 1)[0]
            return creds.split(":", 1)[1]
    raise SystemExit("DATABASE_URL not found in backend/.env")


def main() -> int:
    conn = psycopg2.connect(
        host="127.0.0.1",
        port=5432,
        dbname=SOURCE_DB,
        user="postgres",
        password=_password(),
        connect_timeout=10,
        options="-c default_transaction_read_only=on",
    )
    out: dict[str, object] = {"approved": [], "source_data_keys": {}}
    with conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, listing_id, property_type, rental_price, name "
            "FROM fyp.rental_properties WHERE id = ANY(%s) ORDER BY id",
            (APPROVED_IDS,),
        )
        rows = cur.fetchall()
        listing_ids = [r[1] for r in rows if r[1]]

        # Catalogue rows for those listing ids.
        cur.execute(
            "SELECT id, title, property_type, rental_rm, source_data "
            "FROM sitewise_app.properties WHERE id = ANY(%s)",
            (listing_ids,),
        )
        catalogue = {r[0]: r for r in cur.fetchall()}

        for pid, listing_id, ptype, rent, name in rows:
            cat = catalogue.get(listing_id)
            sd = cat[4] if cat and isinstance(cat[4], dict) else {}
            entry = {
                "rental_property_id": pid,
                "listing_id": listing_id,
                "property_type": ptype,
                "rental_price": float(rent) if rent is not None else None,
                "catalogue_row": bool(cat),
                "catalogue_title": cat[1] if cat else None,
                "source_data_keys": sorted(sd.keys()),
                "has_phone": "phone" in sd,
                "photo_count": 0,
                "geo": False,
                "source": False,
                "link": False,
            }
            cur.execute(
                "SELECT count(*) FROM fyp.property_photos WHERE property_id=%s", (pid,)
            )
            entry["photo_count"] = cur.fetchone()[0]
            cur.execute(
                "SELECT count(*) FROM fyp.property_geospatial_features WHERE property_id=%s",
                (pid,),
            )
            entry["geo"] = cur.fetchone()[0] > 0
            cur.execute(
                "SELECT count(*) FROM fyp.property_listing_sources WHERE property_id=%s",
                (pid,),
            )
            entry["source"] = cur.fetchone()[0] > 0
            cur.execute(
                "SELECT count(*) FROM fyp.property_subject_links WHERE property_id=%s",
                (pid,),
            )
            entry["link"] = cur.fetchone()[0] > 0
            out["approved"].append(entry)

        # Which personal-data keys appear across the whole catalogue, so the
        # decision to strip or keep is informed rather than guessed.
        cur.execute(
            "SELECT DISTINCT jsonb_object_keys(source_data) AS k "
            "FROM sitewise_app.properties WHERE source_data IS NOT NULL"
        )
        out["source_data_keys"]["catalogue_all"] = sorted(r[0] for r in cur.fetchall())

    # FK/reference shape of the tables being copied.
    with conn, conn.cursor() as cur:
        for table in (
            "fyp.rental_properties",
            "fyp.property_photos",
            "fyp.property_geospatial_features",
            "fyp.property_listing_sources",
            "fyp.property_subject_links",
        ):
            cur.execute(
                "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint "
                "WHERE conrelid = %s::regclass ORDER BY contype, conname",
                (table,),
            )
            out.setdefault("constraints", {})[table] = [
                {"name": r[0], "def": r[1]} for r in cur.fetchall()
            ]

    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
