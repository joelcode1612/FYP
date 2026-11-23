"""Phase F — Jaspr structure and reachability audit.

Read-only. This script never moves, edits or deletes a file. It answers one
question with evidence: for every Dart file under ``lib/``, is it reachable from
an application entry point, reachable only from a test, or reachable from
neither?

Reachability is computed from real ``import``/``export``/``part`` directives,
resolved for both ``package:sitewise_jaspr_web/...`` and relative forms. Files
that no import reaches are *candidates*, never conclusions: a file can still be
used through route registration, a string table, conditional imports or
generated code, so each candidate is cross-checked before it is classified.

Usage (from fyp_jaspr_web/)::

    dart run tool/audit_structure_20261122.py
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'lib'
TEST = ROOT / 'test'
OUT = ROOT.parent / 'deliverables' / 'phase2' / 'JASPR_STRUCTURE_REGRESSION.json'

PACKAGE = 'sitewise_jaspr_web'

#: Application entry points. `app.dart` is imported by both mains; the two
#: mains are the real roots, so all four are seeds to be safe.
ENTRY_POINTS = [
    'lib/main.client.dart',
    'lib/main.server.dart',
    'lib/main.client.options.dart',
    'lib/app.dart',
]

#: A directive may name more than one target: conditional imports are written
#: ``import 'a.dart' if (dart.library.js_interop) 'b.dart';``. Capturing only the
#: first string makes every browser implementation look unreachable, which is
#: exactly the false positive this audit must not produce.
_DIRECTIVE = re.compile(r'^\s*(?:import|export|part)\s+([^;]+);', re.MULTILINE)
_QUOTED = re.compile(r"['\"]([^'\"]+)['\"]")


def dart_files(base: Path) -> list[Path]:
    """Source files plus editor/agent backups, so backups are classified rather
    than silently omitted from the inventory."""
    if not base.exists():
        return []
    found = set(base.rglob('*.dart'))
    found.update(base.rglob('*.bak'))
    found.update(base.rglob('*.orig'))
    return sorted(found)


def resolve(spec: str, source: Path) -> Path | None:
    """Resolve one directive target to a file under the package, or None."""
    if spec.startswith(f'package:{PACKAGE}/'):
        return (LIB / spec[len(f'package:{PACKAGE}/'):]).resolve()
    if spec.startswith('dart:') or spec.startswith('package:'):
        return None  # SDK or another package: outside this audit
    if spec.startswith('/'):
        return None
    return (source.parent / spec).resolve()


def directives(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return []
    targets: list[str] = []
    for body in _DIRECTIVE.findall(text):
        targets.extend(_QUOTED.findall(body))
    return targets


def closure(seeds: list[Path]) -> set[Path]:
    seen: set[Path] = set()
    queue = deque(p.resolve() for p in seeds if p.exists())
    while queue:
        current = queue.popleft()
        if current in seen:
            continue
        seen.add(current)
        for spec in directives(current):
            target = resolve(spec, current)
            if target and target.exists() and target.suffix == '.dart':
                if target not in seen:
                    queue.append(target)
    return seen


def rel(p: Path) -> str:
    try:
        return p.relative_to(ROOT).as_posix()
    except ValueError:
        return p.as_posix()


def main() -> int:
    lib_files = dart_files(LIB)
    test_files = dart_files(TEST)

    app = closure([ROOT / p for p in ENTRY_POINTS])
    tests = closure(test_files)

    # Reverse edges, so a file's dependents can be reported.
    dependents: dict[Path, set[str]] = {p: set() for p in lib_files}
    for source in lib_files + test_files:
        for spec in directives(source):
            target = resolve(spec, source)
            if target and target in dependents:
                dependents[target].add(rel(source))

    # Every string literal in lib/, so a route or registry referenced by name is
    # not mistaken for dead code.
    literals: set[str] = set()
    for source in lib_files:
        try:
            text = source.read_text(encoding='utf-8', errors='replace')
        except OSError:
            continue
        literals.update(re.findall(r"""['"]([A-Za-z0-9_/.-]{4,})['"]""", text))

    rows = []
    for path in lib_files:
        r = rel(path)
        name = path.name
        in_app = path in app
        in_test = path in tests
        if name.endswith(('.bak', '.orig', '~')) or '.before-' in name:
            cls = 'BACKUP'
            reason = 'Editor/agent backup copy; never imported (backups are .bak files).'
        elif in_app:
            cls = 'ACTIVE'
            reason = 'Reachable from an application entry point.'
        elif in_test:
            cls = 'INDIRECT_DEPENDENCY'
            reason = 'Not reached from an entry point; reached from a test.'
        elif not dependents[path]:
            # A dead file whose basename is also live elsewhere is a superseded
            # copy, not merely an unused one. The distinction matters: one is a
            # migration leftover, the other is a never-wired feature.
            live_twin = [p for p in lib_files
                         if p.name == name and p != path and p in app]
            if live_twin:
                rows.append({
                    'path': r, 'classification': 'DUPLICATE',
                    'reason': f'Superseded copy; a live file shares this name: '
                              f'{rel(live_twin[0])}.',
                    'dependents': [], 'reached_from_app': False,
                    'reached_from_test': in_test,
                })
                continue
            stem = path.stem
            referenced = any(stem in lit for lit in literals if lit != stem)
            cls = 'UNUSED_CONFIRMED' if not referenced else 'UNCERTAIN'
            reason = ('No import reaches it and no literal references its name.'
                      if not referenced else
                      'No import reaches it, but a string literal mentions its name.')
        else:
            cls = 'UNCERTAIN'
            reason = 'Imported by something that is itself unreachable.'
        rows.append({
            'path': r,
            'classification': cls,
            'reason': reason,
            'dependents': sorted(dependents[path]),
            'reached_from_app': in_app,
            'reached_from_test': in_test,
        })

    counts: dict[str, int] = {}
    for row in rows:
        counts[row['classification']] = counts.get(row['classification'], 0) + 1

    # Duplicate basenames: two files with the same name in different features is
    # normal; the same name in the same layer is a duplication smell.
    by_name: dict[str, list[str]] = {}
    for row in rows:
        by_name.setdefault(Path(row['path']).name, []).append(row['path'])
    duplicates = {n: p for n, p in by_name.items() if len(p) > 1 and not n.endswith('.bak')}

    payload = {
        'checkpoint': 'JASPR_STRUCTURE_AUDIT',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'read_only': True,
        'entry_points': ENTRY_POINTS,
        'counts': {
            'lib_dart_files': len(lib_files),
            'test_dart_files': len(test_files),
            'reached_from_app': sum(1 for r in rows if r['reached_from_app']),
            'reached_from_test_only': sum(1 for r in rows if r['reached_from_test']
                                          and not r['reached_from_app']),
            'by_classification': counts,
        },
        'files': rows,
        'duplicate_basenames': duplicates,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, indent=1), encoding='utf-8')

    print(f'lib dart files      : {len(lib_files)}')
    print(f'test dart files     : {len(test_files)}')
    print(f'reached from app    : {payload["counts"]["reached_from_app"]}')
    print(f'reached from test   : {payload["counts"]["reached_from_test_only"]}')
    for cls, n in sorted(counts.items()):
        print(f'  {cls:22s} {n}')
    print(f'\nevidence -> {rel(OUT)}')

    interesting = [r for r in rows if r['classification'] in
                   ('UNUSED_CONFIRMED', 'UNCERTAIN', 'INDIRECT_DEPENDENCY')]
    if interesting:
        print('\n--- non-ACTIVE files ---')
        for r in interesting:
            print(f'  {r["classification"]:20s} {r["path"]}')
            print(f'  {"":20s} {r["reason"]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
