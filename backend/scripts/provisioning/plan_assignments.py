"""Plan and apply Agent management for eligible operational listings.

Scope policy (deliberate, and narrower than "everything without a manager")
---------------------------------------------------------------------------
Only listings whose provenance is ``demo_seed`` are eligible:

* they are published and approved, so an Agent genuinely can manage them;
* their recorded owner is the legacy ``fyp.users`` demo account, which has no
  Supabase identity, so no owner can exercise management today;
* the project holds them as demonstration data, which is the documented
  test-data policy this assignment relies on.

Explicitly NOT eligible:

* ``research_import`` (955) — catalogue research subjects. Assigning them to an
  Agent would expose unpublished records as ordinary rental listings and would
  fabricate a management relationship that does not exist.
* ``owner_draft`` with a real owner (3) — already owner-managed.
* ``owner_draft`` with no owner (2) — defects for the remediation queue, not
  work to be absorbed by an Agent.

Ownership is never written. The legacy ``owner_id`` stays exactly as it was;
only ``agent_listing_assignment`` gains rows, which is the same table the
``POST /api/v1/staff/listings/{id}/assign`` endpoint writes.

Usage (from ``backend``)::

    # 1. Review the proposed mapping. Writes only a CSV manifest.
    .\\.venv\\Scripts\\python.exe -m scripts.provisioning.plan_assignments

    # 2. Apply it, with an audit trail of what changed.
    .\\.venv\\Scripts\\python.exe -m scripts.provisioning.plan_assignments --apply
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

from sitewise.core.config import settings  # noqa: E402
from sitewise.db.session import engine  # noqa: E402

#: The only two Agents in Supabase ``public.agent``. Verified before use.
AGENT_IDS = (2, 3)

ELIGIBLE_SQL = """
SELECT p.id, p.name, p.address, p.city, p.state, p.listing_id,
       p.owner_id, p.owner_user_id, p.verification_status, p.is_published,
       a.agent_id AS current_agent_id
FROM fyp.rental_properties p
LEFT JOIN agent_listing_assignment a ON a.listing_id = p.id
WHERE p.listing_id ~ '^[0-9]+$'
  AND p.is_published IS TRUE
  AND p.verification_status = 'approved'
ORDER BY p.id
"""


def verify_agents(session: Session) -> dict[int, dict]:
    """Prove both Agents exist, are active, and have a Supabase profile.

    A missing profile or an inactive account aborts the run: assigning work to
    an identity that cannot sign in would create the very unmanaged state this
    script exists to remove.
    """
    from sitewise.core.supabase_admin import SupabaseAdminService

    profiles = {int(p["agent_id"]): p for p in SupabaseAdminService().list_agent_profiles()}
    verified: dict[int, dict] = {}
    for agent_id in AGENT_IDS:
        profile = profiles.get(agent_id)
        if profile is None or not profile.get("user_id"):
            raise SystemExit(
                f"ABORT: Supabase has no agent profile for agent_id={agent_id}. "
                "Refusing to assign listings to an unverifiable manager."
            )
        user_id = str(profile["user_id"])
        status = session.execute(
            text("SELECT account_status, role FROM users WHERE user_id = :uid"),
            {"uid": user_id},
        ).mappings().first()
        if status is None:
            raise SystemExit(
                f"ABORT: local mirror has no row for agent {agent_id} ({user_id})."
            )
        if status["account_status"] != "active":
            raise SystemExit(
                f"ABORT: agent {agent_id} is {status['account_status']!r}, not active."
            )
        verified[agent_id] = {
            "user_id": user_id,
            "name": str(profile.get("agent_name") or "").strip(),
            "status": status["account_status"],
        }
    return verified


def plan(session: Session) -> tuple[list[dict], Counter]:
    rows = session.execute(text(ELIGIBLE_SQL)).mappings().all()
    stats: Counter = Counter()
    assignments: list[dict] = []
    for index, row in enumerate(rows):
        # Balanced, deterministic round-robin: reproducible on re-run.
        agent_id = AGENT_IDS[index % len(AGENT_IDS)]
        current = row["current_agent_id"]
        if current is not None and int(current) == agent_id:
            stats["unchanged"] += 1
            action = "unchanged"
        elif current is not None:
            stats["reassign"] += 1
            action = "reassign"
        else:
            stats["assign"] += 1
            action = "assign"
        assignments.append(
            {
                "listing_id": int(row["id"]),
                "property_name": row["name"],
                "city": row["city"],
                "state": row["state"],
                "catalogue_ref": row["listing_id"],
                "legacy_owner_id": row["owner_id"],
                "owner_user_id": row["owner_user_id"],
                "current_agent_id": current,
                "target_agent_id": agent_id,
                "action": action,
            }
        )
    return assignments, stats


def write_manifest(assignments: list[dict], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "listing_id",
                "property_name",
                "city",
                "state",
                "catalogue_ref",
                "legacy_owner_id",
                "owner_user_id",
                "current_agent_id",
                "target_agent_id",
                "action",
            ],
        )
        writer.writeheader()
        writer.writerows(assignments)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="write the assignments")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("var/assignment_manifest.csv"),
        help="reviewable property-to-Agent mapping",
    )
    args = parser.parse_args()

    with Session(engine) as session:
        agents = verify_agents(session)
        assignments, stats = plan(session)

        if not assignments:
            print("No eligible published demo listings were found. Nothing to do.")
            return 0

        per_agent = Counter(a["target_agent_id"] for a in assignments)
        print(f"Database      : {settings.database_url.rsplit('/', 1)[-1]}")
        print("Agents verified:")
        for agent_id, info in agents.items():
            print(f"  agent {agent_id}: {info['name']!r} ({info['user_id']}) active")
        print(f"Eligible      : {len(assignments)} published demo listings")
        print(f"  assign      : {stats['assign']}")
        print(f"  reassign    : {stats['reassign']}")
        print(f"  unchanged   : {stats['unchanged']}")
        for agent_id in AGENT_IDS:
            print(f"  agent {agent_id} total after apply: {per_agent[agent_id]}")

        write_manifest(assignments, args.manifest)
        print(f"Manifest      : {args.manifest.resolve()}")

        if not args.apply:
            print("\nDRY RUN — nothing written. Re-run with --apply to commit.")
            return 0

        from sitewise.repositories.agent_assignment_repository import (
            AgentAssignmentRepository,
        )

        repo = AgentAssignmentRepository(session)
        applied = 0
        for row in assignments:
            if row["action"] == "unchanged":
                continue
            repo.assign(row["listing_id"], row["target_agent_id"], assigned_by=None)
            applied += 1
        print(f"\nApplied       : {applied} assignment rows written")

        final = Counter(
            r[0]
            for r in session.execute(
                text("SELECT agent_id FROM agent_listing_assignment")
            )
        )
        print("Final distribution:")
        for agent_id, count in sorted(final.items()):
            print(f"  agent {agent_id}: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
