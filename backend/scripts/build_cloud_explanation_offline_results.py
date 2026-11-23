"""Generate PROJECT1_CLOUD_EXPLANATION_OFFLINE_RESULTS.json from a real test run.

Groups are read from the test file's own section headers rather than guessed from
test names, so the counts cannot drift from what the file actually contains.

Run from ``backend`` after the test run:

    ./.venv/Scripts/python.exe scripts/build_cloud_explanation_offline_results.py
"""
from __future__ import annotations

import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
DELIVERABLES = BACKEND.parent / 'deliverables'
TEST_FILE = BACKEND / 'tests' / 'project1' / 'test_cloud_explanation_prompt.py'
JUNIT = BACKEND / 'var' / 'evidence' / 'p1_offline_junit.xml'

SECTION_RE = re.compile(r'^# (\d)\. (.+)$')
TEST_RE = re.compile(r'^def (test_\w+)')


def sections() -> dict[str, str]:
    """Map each test function name to the numbered section it sits under."""
    mapping: dict[str, str] = {}
    current = 'ungrouped'
    for line in TEST_FILE.read_text(encoding='utf-8').splitlines():
        header = SECTION_RE.match(line.strip())
        if header:
            current = f'{header.group(1)}. {header.group(2).strip()}'
            continue
        test = TEST_RE.match(line)
        if test:
            mapping[test.group(1)] = current
    return mapping


def main() -> None:
    mapping = sections()
    tree = ET.parse(JUNIT)
    cases = list(tree.iter('testcase'))
    failures = [tc for tc in cases
                if tc.find('failure') is not None or tc.find('error') is not None]

    groups: dict[str, list[dict]] = {}
    ungrouped = []
    for tc in cases:
        name = tc.get('name').split('[')[0]
        group = mapping.get(name)
        entry = {'test': tc.get('name'),
                 'outcome': 'FAILED' if tc in failures else 'PASSED'}
        if group is None:
            ungrouped.append(entry)
            continue
        groups.setdefault(group, []).append(entry)

    ordered = {key: groups[key] for key in sorted(groups)}
    payload = {
        '_note': ('Offline validation only. Nothing here contacted a provider, so no '
                  'result in this file is evidence of explanation quality. A live call '
                  'is refused structurally: the EXPLANATION stage is absent from '
                  'ledger._ALLOWED_STAGES and has no disclosure adapter.'),
        'prompt_version': 'EE01-EXPLANATION-2-CAND',
        'output_schema_version': 'ee01-explanation/1',
        'verdict': {
            'offline_validation': 'PASS' if not failures else 'FAIL',
            'genuine_provider_execution': 'NOT_RUN',
            'explanation_quality': 'NOT_ASSESSED',
            'integration_readiness': 'PARTIAL',
            'production_authorization': 'BLOCKED',
        },
        'verdict_notes': {
            'offline_validation': ('every guard, contract and fallback case below passes '
                                   'against the real validator and the real service'),
            'genuine_provider_execution': ('no provider was contacted; the stage is not '
                                           'registered and has no disclosure adapter'),
            'explanation_quality': ('cannot be assessed without a genuine response; a '
                                    'model self-assessment would not be evidence'),
            'integration_readiness': ('the prompt and request are ready, but the service '
                                      'still reports prompt_version null and dispatches '
                                      'nothing'),
            'production_authorization': ('A10 report admission remains BLOCKED: 19 gates '
                                         'pending, grants NONE'),
        },
        'totals': {
            'collected': len(cases),
            'passed': len(cases) - len(failures),
            'failed': len(failures),
            'sections': len(ordered),
        },
        'groups': ordered,
        'ungrouped': ungrouped,
    }
    out = DELIVERABLES / 'PROJECT1_CLOUD_EXPLANATION_OFFLINE_RESULTS.json'
    out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + '\n',
                   encoding='utf-8')
    import hashlib
    raw = out.read_bytes()
    print(f'{out.name}  {len(raw)} bytes  {hashlib.sha256(raw).hexdigest()}')
    print(f'collected={len(cases)} passed={len(cases)-len(failures)} '
          f'failed={len(failures)} sections={len(ordered)} ungrouped={len(ungrouped)}')
    for key, items in ordered.items():
        print(f'  {key}: {len(items)}')


if __name__ == '__main__':
    main()
