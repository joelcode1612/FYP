"""Build Report A CSV from the read-only audit dumps. No DB access."""
from __future__ import annotations

import csv
import json
from collections import Counter
from pathlib import Path

BASE = Path(__file__).parent
OUT = BASE / "ownership_audit"


def main() -> None:
    d = json.loads((BASE / "_audit_data.json").read_text(encoding="utf-8"))
    s = json.loads((BASE / "_audit_supabase.json").read_text(encoding="utf-8"))
    OUT.mkdir(exist_ok=True)

    mirror = {str(u["user_id"]): u for u in d["public_users"]}
    agents = {p["agent_id"]: p for p in s["agent_profiles"]}
    assign = {a["listing_id"]: a for a in d["assignments"]}

    mt_counts: Counter = Counter()
    vr_counts: Counter = Counter()
    prov_counts: Counter = Counter()
    rows = []
    for p in d["properties"]:
        pid = p["id"]
        a = assign.get(pid)
        owner_uuid = str(p["owner_user_id"]) if p["owner_user_id"] else ""
        legacy = p["owner_id"]
        mu = mirror.get(owner_uuid) if owner_uuid else None
        agent_id = ""
        assignment_status = "none"
        if a is not None:
            agent_id = a["agent_id"]
            assignment_status = "active"
            ap = agents.get(a["agent_id"])
            if ap is None:
                mt, vr = "INVALID_ASSIGNMENT", "AGENT_ID_UNRESOLVED"
            else:
                mt, vr = "AGENT_MANAGED", "OK"
        elif owner_uuid and mu and mu["account_status"] == "active":
            mt, vr = "OWNER_MANAGED", "OK_OWNER_UUID"
        elif owner_uuid:
            mt, vr = "UNASSIGNED", "OWNER_UUID_UNRESOLVED"
        elif legacy:
            mt, vr = "UNASSIGNED", "LEGACY_OWNER_ONLY"
        else:
            mt = "UNKNOWN_OWNER"
            vr = (
                "NO_OWNER_TEST_ARTIFACT"
                if str(p["name"]).startswith("persist-check-")
                else "NO_OWNER"
            )
        if p["verification_status"] == "draft":
            prov = "owner_draft"
        elif legacy:
            prov = "demo_seed"
        else:
            prov = "research_import"
        mt_counts[mt] += 1
        vr_counts[vr] += 1
        prov_counts[prov] += 1
        rows.append({
            "property_id": pid,
            "property_title": p["name"],
            "owner_uuid": owner_uuid,
            "agent_id": agent_id,
            "management_type": mt,
            "assignment_status": assignment_status,
            "validation_result": vr,
            "legacy_owner_id": legacy if legacy is not None else "",
            "owner_email": mu["email"] if mu else "",
            "owner_account_status": mu["account_status"] if mu else "",
            "verification_status": p["verification_status"],
            "is_published": p["is_published"],
            "catalogue_ref": p["listing_id"] or "",
            "provenance": prov,
            "created_at": p["created_at"],
        })

    csv_path = OUT / "report_a_properties.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    print(f"wrote {csv_path} ({len(rows)} rows)")
    print("management_type:", dict(mt_counts))
    print("validation_result:", dict(vr_counts))
    print("provenance:", dict(prov_counts))
    cross = Counter((r["provenance"], r["verification_status"]) for r in rows)
    print("provenance x status:", dict(cross))


if __name__ == "__main__":
    main()