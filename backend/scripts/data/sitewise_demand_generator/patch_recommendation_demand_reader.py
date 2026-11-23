#!/usr/bin/env python3
"""Optional code integration: read measured FYP demand features in recommendation filters.

Applies strict anchored edits to backend RecommendationSearchService + filters +
API. Requires `generate_demand_generators.py --apply` first to supply fields.
Run --dry-run first. No application logic change outside demand filtering.
"""
from pathlib import Path
import argparse
import shutil
import sys
from datetime import datetime

APPEND_FILTERS = '''

# SiteWise demand-generator bridge — canonical operational fyp measurements.
# Analytics U-class fields remain the fallback for old catalogue records. This
# reads the operational DB on its own session: the two DB URLs can differ.
def merge_operational_demand(
    analytical: dict[str, dict[str, Any]], operational: Session
) -> dict[str, dict[str, Any]]:
    """Overlay verified rental-property POI presence in one batched read.

    A NULL count is unknown, not zero. Non-NULL counts, including measured 0,
    take precedence over old analytical snapshots. Training data is untouched.
    """
    required = {"malls_count_1000m", "office_pois_500m", "universities_colleges_count_500m"}
    try:
        found = set(operational.execute(text("""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema='fyp' AND table_name='property_geospatial_features'
        """)).scalars().all())
        if not required.issubset(found):
            return analytical  # Backfill not applied yet; retain old filter data.
        rows = operational.execute(text("""
            SELECT l.sitewise_property_id AS catalogue_id,
                   g.malls_count_1000m, g.office_pois_500m,
                   g.universities_colleges_count_500m
            FROM fyp.property_subject_links l
            JOIN fyp.property_geospatial_features g ON g.property_id = l.property_id
            WHERE l.match_verified IS TRUE
              AND l.sitewise_property_id IS NOT NULL
        """)).mappings().all()
    except Exception:
        # The optional source must not take the whole recommendation endpoint
        # offline. Roll back the aborted transaction and use analytics fallback.
        operational.rollback()
        return analytical
    if not rows:
        return analytical
    result = dict(analytical)
    for row in rows:
        key = str(row["catalogue_id"])
        if key not in result:
            continue
        updated = dict(result[key]); demand = dict(updated.get("demand") or {})
        mapping = {
            "malls_1000m": row["malls_count_1000m"],
            "offices_500m": row["office_pois_500m"],
            "universities_500m": row["universities_colleges_count_500m"],
        }
        for label, count in mapping.items():
            if count is not None:
                demand[label] = float(count) > 0
        updated["demand"] = demand
        result[key] = updated
    return result
'''

EDITS = {
  "backend/src/sitewise/services/recommendation_search_service.py": [
    (
      "    def __init__(self, session: Session):\n        self.session = session\n",
      "    def __init__(self, session: Session, operational_session: Session | None = None):\n"
      "        self.session = session\n"
      "        self.operational_session = operational_session\n"
    ),
    (
      "        for row in rows:\n            row.advanced = values.get(row.id, {})\n",
      "        # Operational demand measurements override older research snapshots\n"
      "        # when verified. Both databases can be on separate connections.\n"
      "        if self.operational_session is not None:\n"
      "            values = advanced_fields.merge_operational_demand(\n"
      "                values, self.operational_session\n"
      "            )\n"
      "        for row in rows:\n            row.advanced = values.get(row.id, {})\n"
    ),
  ],
  "backend/src/sitewise/api/v1/recommendations.py": [
    (
      "RecommendationSearchService(session).search(criteria)",
      "RecommendationSearchService(session, operational_db).search(criteria)",
    ),
    (
      "RecommendationSearchService(session).facets(criteria)",
      "RecommendationSearchService(session, operational_db).facets(criteria)",
    ),
  ],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="FYP repository root")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = Path(args.root)
    target = root / "backend/src/sitewise/services/recommendation_filter_fields.py"
    changes = {}
    for rel, replacements in EDITS.items():
        path = root / rel
        old = path.read_text(encoding="utf-8")
        new = old
        for anchor, replacement in replacements:
            if replacement in new:
                continue
            if new.count(anchor) != 1:
                raise SystemExit(f"ABORT: {rel} does not contain exactly one expected anchor; no files changed")
            new = new.replace(anchor, replacement)
        changes[path] = new
    current = target.read_text(encoding="utf-8")
    if "def merge_operational_demand(" not in current:
        changes[target] = current.rstrip() + APPEND_FILTERS + "\n"
    else:
        changes[target] = current
    different = [p for p, new in changes.items() if p.read_text(encoding="utf-8") != new]
    for p in different:
        print(f"[change] {p.relative_to(root)}")
    if not different:
        print("[ok] already applied")
        return
    if args.dry_run:
        print(f"[preview] {len(different)} files would be changed. No edits made.")
        return
    backup_root = root / ".sitewise-demand-generator-backup" / datetime.now().strftime("%Y%m%d-%H%M%S")
    for p in different:
        rel = p.relative_to(root)
        dst = backup_root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, dst)
        p.write_text(changes[p], encoding="utf-8")
    print(f"[done] {len(different)} files patched; backups in {backup_root}")
    print("[next] python -m compileall backend/src/sitewise/services backend/src/sitewise/api/v1/recommendations.py")

if __name__ == "__main__":
    main()
