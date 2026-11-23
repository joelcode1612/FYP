"""Prove the workflow cannot be pointed at a production database.

Priority 1 requires that "production and disposable configurations cannot be
confused". The runtime guard is
``sitewise/project1/database_identity.py::configured_target``. This tool feeds
it adversarial configurations and records whether each is refused, so the claim
is evidence rather than a reading of the source.

Every case is a pure in-process call. Nothing connects to a database.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld  # noqa: E402
from sitewise.project1.database_identity import configured_target  # noqa: E402

#: (label, database name, port, m2_expected_database, should_be_accepted)
CASES = [
    ('production database name', 'Final_Location_Analysis', 5433, 'Final_Location_Analysis', False),
    ('production port 5432', 'project1_workflow_tests', 5432, 'project1_workflow_tests', False),
    ('production port with production name', 'Final_Location_Analysis', 5432, 'Final_Location_Analysis', False),
    ('m2 expected database disagrees', 'project1_workflow_tests', 5433, 'Final_Location_Analysis', False),
    ('no project1_ prefix', 'sitesense', 5433, 'sitesense', False),
    ('port below range', 'project1_workflow_tests', 1023, 'project1_workflow_tests', False),
    ('port above range', 'project1_workflow_tests', 70000, 'project1_workflow_tests', False),
    ('suffix _test only', 'project1_scratch_test', 5433, 'project1_scratch_test', True),
    ('suffix _tests', 'project1_workflow_tests', 5433, 'project1_workflow_tests', True),
    ('disposable app database', 'project1_disposable_app', 5433, 'project1_disposable_app', False),
]


def _run_case(name: str, port: int, expected: str) -> dict:
    previous = (
        settings.project1_isolated_database_name,
        settings.project1_isolated_database_port,
        settings.m2_expected_database,
    )
    try:
        settings.project1_isolated_database_name = name
        settings.project1_isolated_database_port = port
        settings.m2_expected_database = expected
        try:
            result = configured_target()
            return {'outcome': 'accepted', 'result': list(result)}
        except WorkflowHeld as exc:
            return {'outcome': 'refused', 'code': str(exc)}
    finally:
        (
            settings.project1_isolated_database_name,
            settings.project1_isolated_database_port,
            settings.m2_expected_database,
        ) = previous


def main() -> int:
    evidence = {
        'checkpoint': 'P1_CONFIG_CONFUSION_GUARD',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'guard': 'sitewise.project1.database_identity.configured_target',
        'note': (
            "The suffix rule accepts _test or _tests. A database named "
            "project1_disposable_app is deliberately NOT accepted: the workflow "
            "target and the test-suite target are separate identities."
        ),
        'cases': [],
    }

    failures = []
    for label, name, port, expected, should_accept in CASES:
        outcome = _run_case(name, port, expected)
        accepted = outcome['outcome'] == 'accepted'
        ok = accepted == should_accept
        evidence['cases'].append(
            {
                'label': label,
                'configured_name': name,
                'configured_port': port,
                'm2_expected_database': expected,
                'expected': 'accepted' if should_accept else 'refused',
                'actual': outcome['outcome'],
                'code': outcome.get('code'),
                'result': outcome.get('result'),
                'pass': ok,
            }
        )
        if not ok:
            failures.append(label)

    evidence['totals'] = {
        'cases': len(CASES),
        'passed': len(CASES) - len(failures),
        'failed': len(failures),
        'failed_labels': failures,
    }
    print(json.dumps(evidence, indent=2))
    return 0 if not failures else 1


if __name__ == '__main__':
    sys.exit(main())
