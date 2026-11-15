"""Export the verified property-management state for every operational listing.

One row per ``fyp.rental_properties`` record, with the manager resolved by the
same rule the API serves (:mod:`sitewise.domain.management`). Nothing is
inferred for presentation: a property with no manager exports an empty
``manager_name`` and the real ``reason``, never a placeholder person.

Usage (from ``backend``)::

    .\\.venv\\Scripts\\python.exe -m scripts.provisioning.export_management
"""

from __future__ import annotations

import argparse
import csv
import sys
from collections import Counter
from pathlib import Path

from sqlalchemy import text
from sqlmodel import Session

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

from sitewise.db.session import engine  # noqa: E402
from sitewise.services.property_management_service import resolve_listings  # noqa: E402

ROW_SQL = """
SELECT p.id AS property_id,
       p.name AS property_name,
       p.owner_user_id,
       u.full_name AS owner_name,
       p.owner_id AS legacy_owner_id,
       lu.full_name AS legacy_owner_name,
       p.listing_id AS catalogue_ref,
       p.verification_status,
       p.is_published
FROM fyp.rental_properties p
LEFT JOIN users u ON u.user_id = p.owner_user_id
LEFT JOIN fyp.users lu ON lu.id = p.owner_id
ORDER BY p.id
"""

FIELDS = [
    "property_id",
    "property_name",
    "owner_user_id",
    "owner_name",
    "manager_type",
    "manager_name",
    "agent_id",
    "assignment_status",
    "verification_status",
    "provenance",
    "ownership_status",
    "steward_role",
    "reason",
    "is_published",
    "catalogue_ref",
    "legacy_owner_id",
    "legacy_owner_name",
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("var/property_management_export.csv"),
    )
    parser.add_argument("--batch", type=int, default=500)
    args = parser.parse_args()

    with Session(engine) as session:
        rows = [dict(r) for r in session.execute(text(ROW_SQL)).mappings().all()]
        ids = [int(r["property_id"]) for r in rows]
        management: dict[int, dict] = {}
        for start in range(0, len(ids), args.batch):
            management.update(resolve_listings(session, ids[start : start + args.batch]))

    types: Counter = Counter()
    agents: Counter = Counter()
    out_rows: list[dict] = []
    for row in rows:
        m = management.get(int(row["property_id"])) or {}
        types[m.get("type", "unavailable")] += 1
        if m.get("type") == "agent":
            agents[m.get("agent_id")] += 1
        out_rows.append(
            {
                "property_id": row["property_id"],
                "property_name": row["property_name"],
                "owner_user_id": row["owner_user_id"] or "",
                "owner_name": row["owner_name"] or "",
                "manager_type": m.get("type", "unavailable"),
                "manager_name": m.get("manager_name") or "",
                "agent_id": m.get("agent_id") or "",
                "assignment_status": m.get("assignment_status", ""),
                "verification_status": row["verification_status"],
                "provenance": m.get("provenance", ""),
                "ownership_status": m.get("ownership_status", ""),
                "steward_role": m.get("steward_role") or "",
                "reason": m.get("reason") or "",
                "is_published": row["is_published"],
                "catalogue_ref": row["catalogue_ref"] or "",
                "legacy_owner_id": row["legacy_owner_id"] or "",
                # A pre-Supabase demo account name, kept separate from
                # owner_name so it is never mistaken for a verified owner.
                "legacy_owner_name": row["legacy_owner_name"] or "",
            }
        )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(out_rows)

    print(f"Rows exported : {len(out_rows)}")
    print(f"File          : {args.out.resolve()}")
    print("Management types:")
    for name, count in types.most_common():
        print(f"  {name:<14} {count}")
    if agents:
        print("Agent-managed distribution:")
        for agent_id, count in sorted(agents.items()):
            print(f"  agent {agent_id}: {count}")
    unresolved = [r for r in out_rows if r["manager_type"] in ("unresolved", "unavailable")]
    if unresolved:
        print(f"Needs remediation: {len(unresolved)}")
        for row in unresolved[:20]:
            print(
                f"  id={row['property_id']} {row['property_name']!r} "
                f"reason={row['reason'] or row['manager_type']}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
