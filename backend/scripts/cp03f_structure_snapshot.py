"""CP-03F structure snapshot: real trees, real deltas, real dependency edges.

Nothing here is hand-written. The BEFORE tree comes from `git ls-tree -r HEAD`, the
AFTER tree from the working directory, and every edge in the dependency map from a
static scan of actual import statements. A structure claim that is not produced by
this script does not belong in the register.

Exclusions are deliberate and listed in EXCLUDED so the snapshot cannot silently
grow or shrink because a build directory appeared:

  * VCS / tool caches      .git .dart_tool build node_modules __pycache__ .venv
  * generated evidence     backend/var  out  analysis_output  deliverables
  * secrets                any .env* file (names are listed, contents never read)

Usage:
    python scripts/cp03f_structure_snapshot.py
"""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "docs" / "cp00_integration" / "snapshots"

EXCLUDED_DIRS = {
    ".git", ".dart_tool", "build", "node_modules", "__pycache__", ".venv",
    "var", "out", "analysis_output", "deliverables", ".idea", ".vscode",
}
# Files whose *names* are recorded but whose contents must never be read.
SECRET_PATTERNS = (".env",)
# Generated evidence rather than application code.
EVIDENCE_DIRS = ("backend/var", "out/", "analysis_output/", "deliverables/")

IMPORT_RE = re.compile(r"^[ \t]*(?:from|import)[ \t]+(sitewise[\w.]*)", re.MULTILINE)
# `from sitewise.api.v1 import m2, auth` — the members are modules, and a scanner
# that ignores them reports every router as unmounted.
FROM_IMPORT_RE = re.compile(
    r"^[ \t]*from[ \t]+(sitewise[\w.]*)[ \t]+import[ \t]*"
    r"(?:\(([^)]*)\)|([^\n(]+))",
    re.MULTILINE | re.DOTALL)
# Archives and tool state that are neither application code nor tracked source.
GENERATED_SEGMENTS = {".pytest_cache", ".gradle", "ephemeral", ".fvm",
                      ".dart_tool", "build", "__pycache__", ".venv"}
ARTIFACT_SUFFIXES = (".zip",)


def excluded(path: str) -> bool:
    parts = Path(path).parts
    if any(p in EXCLUDED_DIRS or p in GENERATED_SEGMENTS for p in parts):
        return True
    if any(p.endswith(".egg-info") for p in parts):
        return True
    return path.lower().endswith(ARTIFACT_SUFFIXES)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True,
                          text=True, check=True).stdout


def tree_from_git() -> list[str]:
    """Committed tree, filtered by the SAME rules as the disk tree.

    Filtering only one side makes every excluded directory look deleted: the
    first run of this script reported 483 removals, of which 376 were `.venv`
    and the rest `.idea`/`out`/`analysis_output`. That is a comparison artifact,
    not a structural change.
    """
    return sorted(f for f in git("ls-tree", "-r", "--name-only", "HEAD").splitlines()
                  if not excluded(f))


def tree_from_disk() -> list[str]:
    """Pruned walk. `rglob` descends into .venv (24k files) before filtering,
    which on a synced volume takes long enough to be killed."""
    import os

    files = []
    for root, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in EXCLUDED_DIRS and d not in GENERATED_SEGMENTS
                       and not d.endswith(".egg-info")]
        for name in filenames:
            rel = Path(root, name).relative_to(REPO).as_posix()
            if not excluded(rel):
                files.append(rel)
    return sorted(files)


def is_secret(path: str) -> bool:
    name = Path(path).name
    return name == ".env" or name.startswith(".env.")


def render_tree(files: list[str], title: str, meta: dict) -> str:
    """Indented tree with per-file annotation, grouped by directory."""
    lines = [title, "=" * len(title), ""]
    for k, v in meta.items():
        lines.append(f"{k}: {v}")
    lines.append("")
    lines.append(f"files: {len(files)}")
    lines.append("")

    by_dir: dict[str, list[str]] = defaultdict(list)
    for f in files:
        by_dir[str(Path(f).parent).replace("\\", "/")].append(Path(f).name)

    for d in sorted(by_dir):
        label = "(repository root)" if d == "." else d
        lines.append(f"{label}/")
        for name in sorted(by_dir[d]):
            full = f"{d}/{name}" if d != "." else name
            tag = "  [SECRET — contents not read]" if is_secret(full) else ""
            lines.append(f"    {name}{tag}")
        lines.append("")
    return "\n".join(lines)


def _module_name(py: Path, src: Path) -> str:
    parts = list(py.relative_to(src).with_suffix("").parts)
    if parts and parts[-1] == "__init__":
        parts = parts[:-1]
    if not parts:
        return "sitewise"
    return "sitewise." + ".".join(parts)


def _imported_modules(text: str, modules: set[str]) -> set[str]:
    """Every sitewise module this source imports.

    Handles `import a.b`, `from a.b import c` and `from a.b import (c, d)`. Member
    names are only counted when they resolve to a real module — a scanner that
    ignores them reports every API router as unmounted, which is what the first
    version of this script did.
    """
    found: set[str] = set()
    for name in IMPORT_RE.findall(text):
        found.add(name)
    for base, paren, plain in FROM_IMPORT_RE.findall(text):
        found.add(base)
        members = paren if paren else plain
        # Re-join continuation lines, then split on commas.
        for member in re.sub(r"[\\\s]+", " ", members).split(","):
            member = member.strip().split(" as ")[0].strip()
            if not member or not member.isidentifier():
                continue
            candidate = f"{base}.{member}"
            if candidate in modules:
                found.add(candidate)
    return found


def module_edges() -> tuple[dict[str, set[str]], dict[str, int], dict[str, set[str]]]:
    """(package edges, files per package, file-level edges)."""
    src = REPO / "backend" / "src" / "sitewise"
    files = [p for p in src.rglob("*.py")]
    modules = {_module_name(p, src) for p in files}
    pkg_edges: dict[str, set[str]] = defaultdict(set)
    file_edges: dict[str, set[str]] = defaultdict(set)
    counts: dict[str, int] = defaultdict(int)

    for py in files:
        rel = py.relative_to(src)
        here = _module_name(py, src)
        # Top-level modules (main.py, dependencies.py) are real importers. The
        # first version skipped them, so `main.py` created no edges and every
        # router it mounts looked unmounted.
        pkg = rel.parts[0] if len(rel.parts) >= 2 else None
        if pkg:
            counts[pkg] += 1
        for target in _imported_modules(py.read_text(encoding="utf-8", errors="replace"),
                                        modules):
            parts = target.split(".")
            if len(parts) < 2:
                continue
            if pkg and parts[1] != pkg:
                pkg_edges[pkg].add(parts[1])
            if target in modules and target != here:
                file_edges[here].add(target)
    return pkg_edges, counts, file_edges


def repo_inbound_refs(src: Path) -> set[str]:
    """Module names referenced from anywhere in backend/ (src, scripts, tests).

    `sitewise.project1.ledger` has no inbound import *inside src/sitewise*, but
    five scripts/tests import it. Calling it an orphan from a src-only scan would
    be a false claim about the repository.
    """
    modules = {_module_name(p, src) for p in src.rglob("*.py")}
    refs: set[str] = set()
    roots = [src, REPO / "backend" / "scripts", REPO / "backend" / "tests"]
    for root in roots:
        if not root.is_dir():
            continue
        for py in root.rglob("*.py"):
            text = py.read_text(encoding="utf-8", errors="replace")
            refs |= _imported_modules(text, modules)
            refs |= set(re.findall(r"['\"](sitewise[\w.]*)['\"]", text))
    return refs


def unmounted_python(modules: set[str], packages: set[str],
                     file_edges: dict[str, set[str]],
                     dynamic_refs: set[str],
                     repo_refs: set[str]) -> list[dict]:
    """Modules with no inbound import from application source, classified.

    `app_reachable` False means nothing under src/sitewise imports it.
    `repo_reachable` False means nothing in backend/ references it at all — only
    then is 'orphan' an accurate word.
    """
    inbound: set[str] = set()
    for targets in file_edges.values():
        inbound |= targets
    inbound |= dynamic_refs
    entry = {"sitewise.main"}
    out = []
    for m in sorted(modules):
        if m in entry or m in packages or m in inbound:
            continue
        out.append({"module": m, "repo_referenced": m in repo_refs})
    return out


def find_cycles(edges: dict[str, set[str]]) -> list[list[str]]:
    """Tarjan SCCs of size > 1, plus self-loops."""
    index: dict[str, int] = {}
    low: dict[str, int] = {}
    on_stack: dict[str, bool] = {}
    stack: list[str] = []
    result: list[list[str]] = []
    counter = [0]

    def strongconnect(v: str):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on_stack[v] = True
        for w in sorted(edges.get(v, ())):
            if w not in index:
                strongconnect(w)
                low[v] = min(low[v], low[w])
            elif on_stack.get(w):
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on_stack[w] = False
                comp.append(w)
                if w == v:
                    break
            if len(comp) > 1:
                result.append(sorted(comp))

    for v in sorted(edges):
        if v not in index:
            strongconnect(v)
    return result


def legacy_pairs() -> list[dict]:
    """A legacy path is 'migrated' when a same-named file exists under modules/."""
    src = REPO / "backend" / "src" / "sitewise"
    pairs = []
    for legacy in ("domain", "services", "repositories"):
        base = src / legacy
        if not base.is_dir():
            continue
        for f in sorted(base.glob("*.py")):
            if f.name == "__init__.py":
                continue
            migrated = list((src / "modules").rglob(f.name))
            text = f.read_text(encoding="utf-8", errors="replace")
            is_shim = bool(re.match(r'^"""Compatibility re-export', text)) or (
                "from sitewise.modules." in text and len(text.splitlines()) < 40)
            pairs.append({
                "legacy_path": f"backend/src/sitewise/{legacy}/{f.name}",
                "lines": len(text.splitlines()),
                "migrated_counterpart": [str(m.relative_to(REPO)).replace("\\", "/")
                                         for m in migrated] or None,
                "compatibility_shim": is_shim,
            })
    return pairs


def classify(path: str) -> str:
    """Kind of artifact. Without this, `.gradle` and `egg-info` inflate 'added code'."""
    p = path.replace("\\", "/")
    if any(seg in p for seg in ("/egg-info/", "/.pytest_cache/", "/.gradle/",
                                "/ephemeral/", "/.fvm/", "/.dart_tool/",
                                "/build/", "/__pycache__/")):
        return "GENERATED_TOOL_STATE"
    if "/migrations/" in p:
        return "MIGRATION"
    if p.startswith("backend/backups/"):
        return "EVIDENCE_BACKUP"
    if p.startswith("docs/"):
        return "DOCUMENTATION"
    if p.startswith("backend/scripts/"):
        return "TOOLING_SCRIPT"
    if ("/tests/" in p or p.startswith("test/") or "/test/" in p):
        return "TEST"
    return "SOURCE"


def _group(paths: list[str]) -> dict[str, list[str]]:
    out: dict[str, list[str]] = defaultdict(list)
    for p in paths:
        out[classify(p)].append(p)
    return out


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    head = git("rev-parse", "HEAD").strip()
    branch = git("rev-parse", "--abbrev-ref", "HEAD").strip()
    status = git("status", "--porcelain").strip()
    changed = len([l for l in status.splitlines() if l.strip()])

    before = tree_from_git()
    after = tree_from_disk()
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))

    # One diff for the whole tree: a per-file `git diff` is ~1000 subprocess
    # launches and is the other reason the first version was killed.
    common = set(before) & set(after)
    diff_names = set(git("diff", "--name-only", "HEAD").splitlines())
    modified = [f for f in sorted(common) if f in diff_names and not is_secret(f)]

    meta = {
        "branch": branch,
        "HEAD": head,
        "HEAD (short)": head[:7],
        "working tree": f"{changed} entries in `git status --porcelain`",
        "snapshot taken": now,
        "generator": "backend/scripts/cp03f_structure_snapshot.py",
    }

    (OUT / "PROJECT1_REPOSITORY_TREE_BEFORE.txt").write_text(
        render_tree(before, "PROJECT1 REPOSITORY TREE — BEFORE (git HEAD)", meta),
        encoding="utf-8")
    (OUT / "PROJECT1_REPOSITORY_TREE_AFTER.txt").write_text(
        render_tree(after, "PROJECT1 REPOSITORY TREE — AFTER\n"
                           "CURRENT STRUCTURE — REORGANIZATION PENDING", meta),
        encoding="utf-8")

    edges, counts, file_edges = module_edges()
    src = REPO / "backend" / "src" / "sitewise"
    all_py = list(src.rglob("*.py"))
    modules = {_module_name(p, src) for p in all_py}
    packages = {_module_name(p, src) for p in all_py if p.name == "__init__.py"}
    pkg_cycles = find_cycles(edges)
    file_cycles = find_cycles(file_edges)
    pairs = legacy_pairs()
    dynamic_refs: set[str] = set()
    for py in all_py:
        dynamic_refs |= set(re.findall(
            r"['\"](sitewise[\w.]*)['\"]",
            py.read_text(encoding="utf-8", errors="replace")))
    orphans = unmounted_python(modules, packages, file_edges, dynamic_refs,
                               repo_inbound_refs(src))

    data = {
        "meta": meta, "counts": {"before": len(before), "after": len(after),
                                 "added": len(added), "removed": len(removed),
                                 "modified": len(modified)},
        "added": added, "removed": removed, "modified": modified,
        "added_by_kind": dict(sorted(
            (k, sorted(v)) for k, v in _group(added).items())),
        "modified_by_kind": dict(sorted(
            (k, sorted(v)) for k, v in _group(modified).items())),
        "edges": {k: sorted(v) for k, v in sorted(edges.items())},
        "package_file_counts": dict(sorted(counts.items())),
        "package_cycles": pkg_cycles,
        "file_cycles": file_cycles,
        "legacy_pairs": pairs, "unmounted_python": orphans,
    }
    (OUT / "structure_data.json").write_text(json.dumps(data, indent=2), encoding="utf-8")

    print(json.dumps({
        "files_before": len(before), "files_after": len(after),
        "added": len(added), "removed": len(removed), "modified": len(modified),
        "packages": dict(sorted(counts.items())),
        "edges": {k: sorted(v) for k, v in sorted(edges.items())},
        "package_cycles": pkg_cycles,
        "file_cycle_count": len(file_cycles),
        "file_cycles_sample": file_cycles[:5],
        "legacy_shims": sum(1 for p in pairs if p["compatibility_shim"]),
        "legacy_files": len(pairs),
        "unmounted_count": len(orphans),
        "unmounted_repo_referenced": sum(1 for o in orphans if o["repo_referenced"]),
        "unmounted_sample": orphans[:12],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
