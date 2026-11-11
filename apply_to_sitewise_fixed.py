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

# Self-contained: the Reports page ships inside this script, so copying only
# the installer to the FYP root still works.
REPORTS_PAGE_SOURCE = "import 'package:jaspr/dom.dart';\nimport 'package:jaspr/jaspr.dart';\nimport 'package:shared_logic/shared_logic.dart';\n\nimport '../../components/ui.dart';\nimport '../../data/assessment_api.dart';\nimport '../../layouts/app_layout.dart';\n\n/// Read-only report directory for the signed-in entrepreneur.\n///\n/// The existing `/entrepreneur/report?id=...` is a property-specific report;\n/// a top-level navbar link cannot use that route without a property id.\n/// This page lists only real persisted assessments, and enables the report\n/// link only when the backend says `report_available == true`.\n@client\nclass ReportsPage extends StatefulComponent {\n  const ReportsPage({super.key});\n\n  @override\n  State<ReportsPage> createState() => _ReportsPageState();\n}\n\nclass _ReportsPageState extends State<ReportsPage> {\n  static const _api = AssessmentApi();\n  static const _pageSize = 50;\n\n  int _offset = 0;\n  late Future<ApiResult<AssessmentHistory>> _future = _load(0);\n\n  static Future<ApiResult<AssessmentHistory>> _load(int offset) =>\n      _api.history(limit: _pageSize, offset: offset);\n\n  void _reload([int? offset]) {\n    final target = offset ?? _offset;\n    setState(() {\n      _offset = target;\n      _future = _load(target);\n    });\n  }\n\n  @override\n  Component build(BuildContext context) => AppLayout(\n    role: AppRole.entrepreneur,\n    currentRoute: '/entrepreneur/reports',\n    title: 'Reports',\n    eyebrow: 'Location intelligence',\n    subtitle:\n        'Review reports from your saved property assessments, or continue an assessment to generate one.',\n    actions: const [\n      ActionLink(\n        'Assessment history',\n        href: '/entrepreneur/assessments/history',\n        variant: 'secondary',\n      ),\n    ],\n    child: FutureBuilder<ApiResult<AssessmentHistory>>(\n      future: _future,\n      builder: (context, snapshot) {\n        if (snapshot.connectionState != ConnectionState.done) {\n          return const SectionCard(\n            title: 'Loading assessment reports',\n            child: Skeleton(variant: 'row', count: 5),\n          );\n        }\n        final result = snapshot.data;\n        if (result == null || !result.ok) {\n          final failure = result?.failure;\n          if (failure?.kind == AssessmentFailureKind.unauthorized) {\n            return const EmptyState(\n              title: 'Sign in to view reports',\n              body: 'Only your own saved assessment reports are shown here.',\n              action: ActionLink(\n                'Go to sign in',\n                href: '/login',\n                variant: 'primary',\n              ),\n            );\n          }\n          return EmptyState(\n            title: 'Reports could not be loaded',\n            body: failure?.message ?? 'The assessment service did not respond.',\n            action: ActionButton('Try again', onClick: _reload),\n          );\n        }\n\n        final history = result.value;\n        if (history == null || history.items.isEmpty) {\n          if (_offset > 0) {\n            return EmptyState(\n              title: 'No further assessments',\n              body: 'This page of the report directory is empty.',\n              action: ActionButton('Back to first page', onClick: () => _reload(0)),\n            );\n          }\n          return const EmptyState(\n            title: 'No assessments or reports yet',\n            body: 'Start a property assessment. When its report has been saved, you can open it here.',\n            action: ActionLink(\n              'Start an assessment',\n              href: '/entrepreneur/assessments',\n              variant: 'primary',\n            ),\n          );\n        }\n        return _table(history);\n      },\n    ),\n  );\n\n  Component _table(AssessmentHistory history) {\n    final availableOnPage = history.items.where((x) => x.reportAvailable).length;\n    final remaining = history.total - _offset - history.items.length;\n    return div(classes: 'stack stack--md', [\n      SectionCard(\n        title: '$availableOnPage ready on this page · ${history.total} saved assessments',\n        flush: true,\n        child: div(classes: 'table-scroll', [\n          table(classes: 'audit-table', [\n            thead([\n              tr([\n                th([Component.text('Property')]),\n                th([Component.text('Assessment')]),\n                th([Component.text('Report')]),\n                th([Component.text('Action')]),\n              ]),\n            ]),\n            tbody([for (final assessment in history.items) _row(assessment)]),\n          ]),\n        ]),\n      ),\n      if (remaining > 0)\n        div(classes: 'actions-row', [\n          ActionButton(\n            'Next ${remaining > _pageSize ? _pageSize : remaining} assessments',\n            variant: 'secondary',\n            onClick: () => _reload(_offset + _pageSize),\n          ),\n        ]),\n      p(classes: 'disclaimer', [\n        Component.text(\n          'Reports are not created by opening this page. Availability is read from the saved assessment record. '\n          'If the backend has not generated a report, continue the assessment instead.',\n        ),\n      ]),\n    ]);\n  }\n\n  Component _row(AssessmentRecord record) {\n    final property = record.property;\n    final encodedId = Uri.encodeComponent(record.propertyId);\n    return tr([\n      td([\n        span(classes: 'who', [\n          Component.text(property?.title ?? 'Property ${record.propertyId}'),\n        ]),\n        span(classes: 'sub', [\n          Component.text(property == null\n              ? 'Catalogue property unavailable'\n              : '${property.city}, ${property.state}'),\n        ]),\n      ]),\n      td([\n        StatusBadge(\n          record.isCompleted ? 'Completed' : 'In progress',\n          tone: record.isCompleted ? 'success' : 'action',\n        ),\n      ]),\n      td([\n        if (record.reportAvailable)\n          const StatusBadge('Ready', tone: 'success')\n        else\n          span(classes: 'small asw-muted', [\n            Component.text(\n              record.capabilities.report.reason ?? 'Not generated yet',\n            ),\n          ]),\n      ]),\n      td([\n        if (record.reportAvailable)\n          AppLink(\n            to: '/entrepreneur/report?id=$encodedId',\n            classes: 'text-action',\n            children: [Component.text('View report')],\n          )\n        else\n          AppLink(\n            to: '/entrepreneur/assessments?id=$encodedId',\n            classes: 'text-action',\n            children: [Component.text('Continue assessment')],\n          ),\n      ]),\n    ]);\n  }\n}\n"


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
    parser.add_argument(
        'project_root', nargs='?',
        help=r'Example: C:\Users\Lenovo\AndroidStudioProjects\FYP (optional when run inside FYP)',
    )
    args = parser.parse_args()
    if args.project_root:
        root = Path(args.project_root).expanduser().resolve()
    else:
        # Support both FYP\apply_to_sitewise.py and the extracted ZIP folder.
        candidates = [Path.cwd(), *Path.cwd().parents, SRC, *SRC.parents]
        root = next(
            (candidate for candidate in candidates
             if (candidate / 'fyp_jaspr_web/lib/app.dart').is_file()),
            None,
        )
        if root is None:
            raise RuntimeError(
                'Cannot find FYP project root. Run from FYP or pass its full path.'
            )
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
    # Previously this relied on a sibling file and crashed with Errno 2 when
    # the user copied the installer into FYP. The page is embedded above.
    page_body = REPORTS_PAGE_SOURCE
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
