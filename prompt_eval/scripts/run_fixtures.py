"""CP-04 — deterministic fixture and schema gate. Makes no network call.

What this proves, and what it does not
--------------------------------------
It proves that the fixtures are internally consistent and that the validators
behave as the fixtures declare:

* every ``golden_output`` passes the contract it claims to satisfy;
* every negative is rejected, with the exact code the fixture names;
* every packet is well formed and every citation resolves.

It does **not** prove that a model produces the golden output. A golden output is
hand-written; it is a specification, not a result. Treating it as evidence of
prompt quality is the mistake this split exists to prevent.

A wrong expected code is a fixture defect, not a validator defect, and is
reported as such -- the run fails rather than silently accepting whichever code
came out.

Usage (from repo root):
    backend/.venv/Scripts/python.exe prompt_eval/scripts/run_fixtures.py [--split dev|heldout|all]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import traceback

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'backend' / 'src'))
sys.path.insert(0, str(ROOT / 'prompt_eval'))

import fixtures  # noqa: E402
from contracts_v5 import validate_objective_proposal_v2  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld  # noqa: E402
from sitewise.project1.qg_contract import ConfirmedFacts  # noqa: E402
from sitewise.project1.qg_fixed_options import validate_fixed_candidate  # noqa: E402

SUPPORTED_FORMATS = frozenset({'SINGLE_CHOICE', 'BINARY_CHOICE', 'ORDERED_SCALE',
                               'NUMERIC_RANGE_OPTIONS', 'MULTIPLE_CHOICE'})
APPROVED_POPULATION = ('Eligible respondents screened by the approved eligibility '
                       'routing.')
OUT_DIR = ROOT / 'prompt_eval' / 'results'


def _code_of(exc: Exception) -> str:
    text = str(exc)
    return text or exc.__class__.__name__


def run_bdj(case: dict) -> dict:
    packet = fixtures.packet(case['declarations'], seed=case['id'])
    record = {'id': case['id'], 'family': 'bdj', 'split': case['split'],
              'intent': case['intent'], 'expected': case['expected'],
              'golden': None, 'negatives': []}

    try:
        validate_objective_proposal_v2(case['golden_output'], packet)
        record['golden'] = {'outcome': 'ACCEPT'}
    except Exception as exc:  # noqa: BLE001 - the code is the result
        record['golden'] = {'outcome': 'REJECT', 'code': _code_of(exc),
                            'trace': traceback.format_exc(limit=3)}

    for negative in case['negatives']:
        entry = {'label': negative['label'], 'expect_code': negative['expect_code']}
        try:
            validate_objective_proposal_v2(negative['output'], packet)
            entry.update(actual_code=None, verdict='FIXTURE_DEFECT_NOT_REJECTED')
        except Exception as exc:  # noqa: BLE001
            actual = _code_of(exc)
            entry.update(actual_code=actual,
                         verdict='PASS' if actual == negative['expect_code']
                                 else 'FIXTURE_DEFECT_WRONG_CODE')
        record['negatives'].append(entry)
    return record


def run_qg(case: dict) -> dict:
    facts = ConfirmedFacts(**case['facts'])
    record = {'id': case['id'], 'family': 'qg', 'split': case['split'],
              'intent': case['intent'], 'expected': case['expected'],
              'golden': None, 'negatives': []}

    def validate(raw: dict):
        return validate_fixed_candidate(
            raw, facts,
            supported_formats=SUPPORTED_FORMATS,
            approved_population=APPROVED_POPULATION,
            period_required=True)

    try:
        validate(case['golden_output'])
        record['golden'] = {'outcome': 'ACCEPT'}
    except Exception as exc:  # noqa: BLE001
        record['golden'] = {'outcome': 'REJECT', 'code': _code_of(exc),
                            'trace': traceback.format_exc(limit=3)}

    for negative in case['negatives']:
        entry = {'label': negative['label'], 'expect_code': negative['expect_code']}
        try:
            validate(negative['output'])
            entry.update(actual_code=None, verdict='FIXTURE_DEFECT_NOT_REJECTED')
        except Exception as exc:  # noqa: BLE001
            actual = _code_of(exc)
            entry.update(actual_code=actual,
                         verdict='PASS' if actual == negative['expect_code']
                                 else 'FIXTURE_DEFECT_WRONG_CODE')
        record['negatives'].append(entry)
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--split', default='all', choices=('dev', 'heldout', 'all'))
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()

    cases = fixtures.all_cases()
    records = []
    for family, items in cases.items():
        for case in items:
            if args.split != 'all' and case['split'] != args.split:
                continue
            records.append((run_bdj if family == 'bdj' else run_qg)(case))

    golden_fail = [r for r in records if r['golden']['outcome'] != 'ACCEPT']
    defects = [n for r in records for n in r['negatives']
               if n['verdict'] != 'PASS']
    negatives_total = sum(len(r['negatives']) for r in records)

    print(f'cases={len(records)}  negatives={negatives_total}  '
          f'golden_failures={len(golden_fail)}  fixture_defects={len(defects)}')
    print(f"  dev={sum(1 for r in records if r['split']=='dev')}  "
          f"heldout={sum(1 for r in records if r['split']=='heldout')}")

    for record in records:
        mark = 'OK  ' if record['golden']['outcome'] == 'ACCEPT' else 'FAIL'
        print(f"  [{mark}] {record['family']:3s} {record['id']:34s} "
              f"{record['split']:7s} golden={record['golden']['outcome']}"
              + (f" ({record['golden']['code']})"
                 if record['golden']['outcome'] != 'ACCEPT' else ''))
        if args.verbose:
            for negative in record['negatives']:
                print(f"         - {negative['verdict']:28s} {negative['label'][:52]:54s}"
                      f" expect={negative['expect_code']} actual={negative['actual_code']}")

    if golden_fail:
        print('\nGOLDEN FAILURES (a golden output must satisfy its own contract):')
        for record in golden_fail:
            print(f"  {record['id']}: {record['golden']['code']}")
            if args.verbose:
                print(record['golden']['trace'])

    if defects:
        print('\nFIXTURE DEFECTS (the expected code does not match the validator):')
        for record in records:
            for negative in record['negatives']:
                if negative['verdict'] != 'PASS':
                    print(f"  {record['id']}: {negative['label']} -> "
                          f"{negative['verdict']} expect={negative['expect_code']} "
                          f"actual={negative['actual_code']}")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        'checkpoint': 'CP-04-DETERMINISTIC-GATE',
        'generated_at': '2026-11-25',
        'network_calls': 0,
        'model_calls': 0,
        'evidence_class': 'SYNTHETIC_FIXTURE',
        'note': ('A golden output is a specification, not a model result. '
                 'Nothing here is evidence of prompt quality.'),
        'summary': {
            'cases': len(records),
            'negatives': negatives_total,
            'golden_failures': len(golden_fail),
            'fixture_defects': len(defects),
            'dev': sum(1 for r in records if r['split'] == 'dev'),
            'heldout': sum(1 for r in records if r['split'] == 'heldout'),
        },
        'records': records,
    }
    (OUT_DIR / 'FIXTURE_GATE_20261125.json').write_text(
        json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(f"\nwrote -> {OUT_DIR / 'FIXTURE_GATE_20261125.json'}")
    return 0 if not golden_fail and not defects else 1


if __name__ == '__main__':
    raise SystemExit(main())
