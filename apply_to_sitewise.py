#!/usr/bin/env python3
"""Add Reports and History to the existing SiteWise entrepreneur navbar.

Safe application: exact markers, automatic backups, no external calls, no
changes to backend, database, agent or owner role. Rerunnable.
"""
from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import shutil
import sys

PROJECT = Path('fyp_jaspr_web')
SRC = Path(__file__).resolve().parent


def edit(path: Path, rules: list[tuple[str, str]], backup: Path):
    before = path.read_text(encoding='utf-8')
    after = before
    for old, new in rules:
        if new in after:
            print(f'  already present: {path.name} rule')
            continue
        if after.count(old) != 1:
            raise RuntimeError(f'Expected one match in {path}: {old[:110]!r}; found {after.count(old)}')
        after = after.replace(old, new, 1)
    if after != before:
        backup_path = backup / path.relative_to(PROJECT)
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup_path)
        path.write_text(after, encoding='utf-8')
        print(f'  modified: {path}')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project_root', help=r'Example: C:\Users\Lenovo\AndroidStudioProjects\FYP')
    args = parser.parse_args()
    root = Path(args.project_root).expanduser().resolve()
    global PROJECT
    PROJECT = root / 'fyp_jaspr_web'
    if not (PROJECT / 'lib/app.dart').is_file():
        raise RuntimeError('Expected fyp_jaspr_web/lib/app.dart at the supplied project root')
    backup = root / f'sitewise_nav_backup_{datetime.now():%Y%m%d_%H%M%S}'
    nav = PROJECT / 'lib/data/navigation.dart'
    routes = PROJECT / 'lib/app.dart'
    crumbs = PROJECT / 'lib/data/breadcrumb_routes.dart'
    page = PROJECT / 'lib/pages/entrepreneur/reports_page.dart'
    for path in [nav, routes, crumbs]:
        if not path.is_file():
            raise RuntimeError(f'Cannot find {path}')

    nav_rules = [
        ("""    WebDestination(\n      route: '/entrepreneur/compare',""",
         """    WebDestination(\n      route: '/entrepreneur/reports',\n      icon: 'description',\n      label: 'Reports',\n    ),\n    WebDestination(\n      route: '/entrepreneur/assessments/history',\n      icon: 'history',\n      label: 'History',\n    ),\n    WebDestination(\n      route: '/entrepreneur/compare',"""),
        ("""    '/entrepreneur/assessments/history': '/entrepreneur/assessments',""",
         """    '/entrepreneur/assessments/history': '/entrepreneur/assessments/history',"""),
        ("""    '/entrepreneur/report': '/entrepreneur/recommendations',""",
         """    '/entrepreneur/report': '/entrepreneur/reports',"""),
        ("""    '/entrepreneur/report': 'Suitability Report',""",
         """    '/entrepreneur/reports': 'Reports',\n    '/entrepreneur/report': 'Suitability Report',"""),
    ]
    app_rules = [
        ("""import 'pages/entrepreneur/report_page.dart' as e_report;""",
         """import 'pages/entrepreneur/report_page.dart' as e_report;\nimport 'pages/entrepreneur/reports_page.dart' as e_reports;"""),
        ("""          Route(\n            path: '/entrepreneur/report',""",
         """          Route(\n            path: '/entrepreneur/reports',\n            builder: (context, state) => _page(\n              const e_reports.ReportsPage(),\n              title: 'Reports — Sitewise',\n              description: 'Your saved property assessment reports.',\n            ),\n          ),\n          Route(\n            path: '/entrepreneur/report',"""),
    ]
    crumb_rules = [
        ("""  '/entrepreneur/assessments/history':\n      _TrailSpec('Assessment history', sectionRoute: '/entrepreneur/assessments'),""",
         """  '/entrepreneur/assessments/history': _TrailSpec('History'),"""),
        ("""  '/entrepreneur/report':\n      _TrailSpec('Suitability report', sectionRoute: '/entrepreneur/recommendations'),""",
         """  '/entrepreneur/reports': _TrailSpec('Reports'),\n  '/entrepreneur/report':\n      _TrailSpec('Suitability report', sectionRoute: '/entrepreneur/reports'),"""),
    ]
    # Validate every expected marker before writing any file.
    for path, rules in [(nav, nav_rules), (routes, app_rules), (crumbs, crumb_rules)]:
        content = path.read_text(encoding='utf-8')
        for old, new in rules:
            if new not in content and content.count(old) != 1:
                raise RuntimeError(f'No unique insertion point in {path}: {old[:100]!r}')
    page_src = SRC / 'fyp_jaspr_web/lib/pages/entrepreneur/reports_page.dart'
    page_body = page_src.read_text(encoding='utf-8')
    if page.exists() and page.read_text(encoding='utf-8') != page_body:
        raise RuntimeError(f'Reports page already exists with different contents: {page}. Refusing overwrite.')
    print('Applying SiteWise entrepreneur navbar update:')
    for path, rules in [(nav, nav_rules), (routes, app_rules), (crumbs, crumb_rules)]:
        edit(path, rules, backup)
    if not page.exists():
        page.parent.mkdir(parents=True, exist_ok=True)
        page.write_text(page_body, encoding='utf-8')
        print(f'  created: {page}')
    print('Complete. Agent and Admin navigation are unchanged.')
    if backup.exists():
        print(f'Original files backed up under: {backup}')
    print('Check: cd fyp_jaspr_web && dart analyze lib/data/navigation.dart lib/data/breadcrumb_routes.dart lib/pages/entrepreneur/reports_page.dart lib/app.dart')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
