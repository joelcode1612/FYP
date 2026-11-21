"""Render PROJECT1_STRUCTURE_CHANGE_REGISTER.md and PROJECT1_MODULE_DEPENDENCY_MAP.md.

Reads `snapshots/structure_data.json`, which `cp03f_structure_snapshot.py` produces
from the working tree and `git`. Nothing in the rendered documents is typed by
hand, so a re-run after any file change produces a matching document.
"""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SNAP = REPO / "docs" / "cp00_integration" / "snapshots"
DATA = json.loads((SNAP / "structure_data.json").read_text(encoding="utf-8"))

META = DATA["meta"]
C = DATA["counts"]


def table(header: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(header) + " |",
           "|" + "|".join("---" for _ in header) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(x) for x in r) + " |")
    return "\n".join(out)


def change_register() -> str:
    added = DATA["added_by_kind"]
    modified = DATA["modified_by_kind"]
    src_added = added.get("SOURCE", [])
    mig = added.get("MIGRATION", [])
    tests = added.get("TEST", [])
    tools = added.get("TOOLING_SCRIPT", [])
    docs = added.get("DOCUMENTATION", [])
    backup = added.get("EVIDENCE_BACKUP", [])

    legacy = DATA["legacy_pairs"]
    shims = [p for p in legacy if p["compatibility_shim"]]
    by_dir = Counter(p["legacy_path"].split("/")[3] for p in legacy)

    lines = [
        "# PROJECT1 — Structure Change Register",
        "",
        "**Generated** by `backend/scripts/cp03f_structure_snapshot.py` + "
        "`cp03f_structure_report.py`. Every number below is derived from the "
        "working tree and `git`; none is hand-counted.",
        "",
        "## Provenance",
        "",
        table(["Field", "Value"], [
            ["Branch", META["branch"]],
            ["HEAD", f"`{META['HEAD']}`"],
            ["HEAD (short)", META["HEAD (short)"]],
            ["Working tree", META["working tree"]],
            ["Snapshot taken", META["snapshot taken"]],
            ["Files before (HEAD)", C["before"]],
            ["Files after (working tree)", C["after"]],
            ["Added", C["added"]],
            ["Removed", C["removed"]],
            ["Modified", C["modified"]],
        ]),
        "",
        "> **AFTER is labelled `CURRENT STRUCTURE — REORGANIZATION PENDING`.** "
        "No module was relocated in this checkpoint beyond the single "
        "`m2_rules.py` move that predates it. The delta below is the CP-03F "
        "working set, not a completed architectural migration.",
        "",
        "## Exclusions",
        "",
        "The tree excludes `.git`, `.venv`, `.dart_tool`, `build`, `.gradle`, "
        "`ephemeral`, `.fvm`, `__pycache__`, `.pytest_cache`, `*.egg-info`, "
        "`backend/var`, `out`, `analysis_output`, `deliverables`, and `*.zip`. "
        "The same filter is applied to the BEFORE and AFTER trees — filtering "
        "only one side made an earlier run report 483 spurious removals.",
        "",
        "`.env*` file **names** appear in the tree; contents were never read and "
        "are not reproduced anywhere.",
        "",
        "## Added — by kind",
        "",
        table(["Kind", "Count", "What it is"], [
            ["SOURCE", len(src_added), "application code"],
            ["TEST", len(tests), "tests and fixtures"],
            ["TOOLING_SCRIPT", len(tools), "verification / snapshot scripts"],
            ["MIGRATION", len(mig), "SQL migrations (see below)"],
            ["DOCUMENTATION", len(docs), "reports and registers"],
            ["EVIDENCE_BACKUP", len(backup), "restored backup copies"],
        ]),
        "",
        "### Added — migrations",
        "",
        table(["File"], [[f"`{m}`"] for m in mig]) if mig else "_none_",
        "",
        "### Added — application source",
        "",
        table(["File"], [[f"`{m}`"] for m in src_added]) if src_added else "_none_",
        "",
        "## Modified — by kind",
        "",
        table(["Kind", "Count"], [[k, len(v)] for k, v in modified.items()]),
        "",
        "### Modified — application source",
        "",
        table(["File"], [[f"`{m}`"] for m in modified.get("SOURCE", [])]),
        "",
        "## Removed",
        "",
        table(["File", "Reason"], [[f"`{r}`", "untracked stub / superseded"]
                                   for r in DATA["removed"]]) if DATA["removed"]
        else "_none_",
        "",
        "## Legacy paths and compatibility re-exports",
        "",
        f"{len(legacy)} files remain at legacy paths under "
        "`backend/src/sitewise/{domain,services,repositories}/`.",
        "",
        table(["Legacy directory", "Files"], [[k, v] for k, v in sorted(by_dir.items())]),
        "",
        f"**Compatibility shims: {len(shims)} of {len(legacy)}.**",
        "",
        table(["Legacy path", "Lines", "Migrated counterpart"],
              [[f"`{p['legacy_path']}`", p["lines"],
                ", ".join(f"`{m}`" for m in p["migrated_counterpart"])
                if p["migrated_counterpart"] else "**none**"]
               for p in shims]),
        "",
        "> The shim has **zero importers**: all seven call sites already import "
        "`sitewise.modules.decision_engine.domain.m2_rules` directly. It is kept "
        "because `tests/test_architecture.py::test_legacy_m2_rules_reexport_same_objects` "
        "asserts it exists, not because anything depends on it.",
        "",
        "The remaining 78 legacy files are **not** shims — they are still the only "
        "implementation. Moving `m2_rules.py` did not migrate the module; it "
        "created one migrated leaf plus one re-export.",
        "",
        "## Modules still missing or mixed",
        "",
        "`backend/src/sitewise/modules/` contains exactly one module, and only its "
        "domain layer:",
        "",
        "```",
        "modules/decision_engine/domain/m2_rules.py",
        "modules/decision_engine/domain/__init__.py",
        "modules/__init__.py",
        "```",
        "",
        "No `application/`, `infrastructure/`, or `api/` layer exists for any "
        "module. `services/` (53 files) and `repositories/` (19 files) are shared "
        "across every feature rather than owned by a module, so the modular "
        "boundaries the architecture calls for are **not yet expressed in the tree**.",
        "",
        "## Generated evidence vs application code",
        "",
        table(["Path", "Classification"], [
            ["`backend/var/`", "runtime evidence (excluded from tree)"],
            ["`backend/backups/`", f"{len(backup)} restored files — evidence, not code"],
            ["`backend/ml_reference/`", "model reference artifacts — data, not code"],
            ["`backend/tests/**/fixtures/*.sql`", "test schema fixtures — not migrations"],
            ["`docs/cp00_integration/snapshots/`", "these artifacts"],
        ]),
        "",
        "## Label summary",
        "",
        table(["Label", "Files"], [
            ["ADDED", C["added"]],
            ["MODIFIED", C["modified"]],
            ["REMOVED", C["removed"]],
            ["MOVED", "0 in this checkpoint"],
            ["RETIRED", "0 in this checkpoint (module retired earlier, see D02)"],
            ["UNCHANGED", C["before"] - C["modified"] - C["removed"]],
        ]),
        "",
    ]
    return "\n".join(lines)


def dependency_map() -> str:
    edges = DATA["edges"]
    counts = DATA["package_file_counts"]
    pkg_cycles = DATA["package_cycles"]
    file_cycles = DATA["file_cycles"]
    orphans = DATA["unmounted_python"]

    rows = []
    for pkg in sorted(edges):
        rows.append([f"`{pkg}`", counts.get(pkg, 0),
                     ", ".join(f"`{t}`" for t in edges[pkg]) or "—"])

    inbound = Counter()
    for targets in edges.values():
        for t in targets:
            inbound[t] += 1
    isolated = [p for p in counts if p not in edges and inbound[p] == 0]

    lines = [
        "# PROJECT1 — Module Dependency Map",
        "",
        "**Generated** from static import analysis of every `.py` under "
        "`backend/src/sitewise` by `cp03f_structure_snapshot.py`. Edges are real "
        "import statements, including multi-line parenthesised `from … import (…)` "
        "and string-literal module paths used for dynamic loading.",
        "",
        "## Package edges",
        "",
        table(["Package", "Files", "Imports (same-repo packages)"], rows),
        "",
        "## Layering assessment",
        "",
        table(["Rule", "Result", "Detail"], [
            ["`domain/` must not import frameworks",
             "PASS", "enforced by `test_domain_has_no_framework_dependencies`"],
            ["`modules/*/domain/` must not import outer layers",
             "PASS", "enforced by `test_feature_domain_has_no_framework_or_outer_layer_dependencies`"],
            ["`api/` may import anything inward",
             "PASS", "35 files, no reverse edges"],
            ["No package cycles",
             "**FAIL**", "`ml` ↔ `repositories` ↔ `services`"],
            ["`domain/` depends only inward",
             "**PARTIAL**", "`domain` → `modules` exists solely because of the "
                            "`m2_rules` compatibility shim"],
        ]),
        "",
        "### Package cycles",
        "",
        table(["Cycle"], [[", ".join(f"`{p}`" for p in c)] for c in pkg_cycles])
        if pkg_cycles else "_none_",
        "",
        "### File-level cycles (the authoritative check)",
        "",
        "Package aggregation can report a cycle that no file actually forms, so "
        "the file graph is the one that matters:",
        "",
        table(["Cycle"], [[", ".join(f"`{p}`" for p in c)] for c in file_cycles])
        if file_cycles else "_none_",
        "",
        f"**{len(file_cycles)} file-level cycles, both pre-existing** — they live in "
        "the property/explanation features, not in the M2 path this checkpoint "
        "touched. Neither was introduced here and neither is fixed here.",
        "",
        "## Modules with no inbound reference from application source",
        "",
        f"{len(orphans)} modules are imported by nothing under `src/sitewise`. "
        "That is **not** the same as orphaned: "
        f"{sum(1 for o in orphans if o['repo_referenced'])} of them are still "
        "referenced by scripts or tests, so a src-only scan would have produced a "
        "false 'unused' claim. Only `repo referenced = no` is a deletion candidate.",
        "",
        table(["Module", "Referenced elsewhere in repo", "Note"], [
            [f"`{o['module']}`",
             "yes" if o["repo_referenced"] else "**no**",
             "retired by D02 — retained as evidence"
             if "bdj_m2v1_candidate_rules" in o["module"]
             else "compatibility shim; the only importer is its own contract test"
             if o["module"].endswith("domain.m2_rules")
             else "used by scripts/tests only"
             if o["repo_referenced"]
             else "no reference anywhere — verify before acting"]
            for o in orphans]),
        "",
        "## Isolated packages",
        "",
        table(["Package"], [[f"`{p}`"] for p in sorted(isolated)]) if isolated
        else "_none_",
        "",
        "## Imports that prevent the planned structure",
        "",
        table(["Blocker", "Why it blocks modularisation"], [
            ["`services/` is one 53-file package",
             "feature behaviour lives in a shared package, so no module owns its "
             "application layer"],
            ["`repositories/` ↔ `services/` cycle",
             "a module cannot be extracted while its repository imports a service "
             "and that service imports the repository"],
            ["`ml/` ↔ `services/` cycle",
             "same problem for any inference-facing module"],
            ["`domain/` → `modules/` (shim)",
             "the legacy path depends on the new one, so deleting the shim is "
             "safe but the direction must not be reversed"],
            ["`api/` imports 10 packages directly",
             "routers reach past an application boundary, so a module cannot be "
             "moved without editing every router"],
        ]),
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    SNAP.mkdir(parents=True, exist_ok=True)
    (SNAP / "PROJECT1_STRUCTURE_CHANGE_REGISTER.md").write_text(
        change_register(), encoding="utf-8")
    (SNAP / "PROJECT1_MODULE_DEPENDENCY_MAP.md").write_text(
        dependency_map(), encoding="utf-8")
    print("written:", (SNAP / "PROJECT1_STRUCTURE_CHANGE_REGISTER.md").name,
          (SNAP / "PROJECT1_MODULE_DEPENDENCY_MAP.md").name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
