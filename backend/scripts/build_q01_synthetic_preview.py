"""Generate the Q01 synthetic-preview artifacts.

Outputs
-------
``deliverables/PROJECT1_Q01_SYNTHETIC_FIXTURE_RESULTS.json``
    The fixture itself: records, derived counts, structural summary, the three
    chart variants, and the deterministic narrative.
``deliverables/PROJECT1_Q01_CHARTSPEC_VERIFICATION.json``
    The verification record: what each variant proves, and the explicit
    assertions that a synthetic preview cannot become a report claim.
``fyp_jaspr_web/lib/features/assessment/data/q01_synthetic_preview_fixture.dart``
    The same payload as a Dart constant, so the web app needs no backend, no
    database and no network to render the preview.

Determinism
-----------
Running this twice produces byte-identical output. ``generated_at`` is the
fixture cutoff, not the wall clock, so a diff always means a real change.

Usage
-----
    cd backend
    ./.venv/Scripts/python.exe scripts/build_q01_synthetic_preview.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
sys.path.insert(0, str(BACKEND / 'src'))

from sitewise.project1 import q01_synthetic_preview as q  # noqa: E402
from sitewise.project1.chart_spec import ChartRefused  # noqa: E402

DELIVERABLES = REPO / 'deliverables'
DART_OUT = (REPO / 'fyp_jaspr_web' / 'lib' / 'features' / 'assessment' / 'data'
            / 'q01_synthetic_preview_fixture.dart')

FIXTURE_RESULTS = DELIVERABLES / 'PROJECT1_Q01_SYNTHETIC_FIXTURE_RESULTS.json'
CHART_VERIFICATION = DELIVERABLES / 'PROJECT1_Q01_CHARTSPEC_VERIFICATION.json'


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + '\n'
    path.write_text(text, encoding='utf-8')
    print(f'  wrote {path.relative_to(REPO)}  ({len(text)} bytes)')


def _dart_string(name: str, value: str) -> str:
    """A raw Dart string. JSON never contains a triple quote, so this is safe."""
    if "'''" in value:
        raise SystemExit('refusing to emit: payload contains a triple quote')
    return f"const String {name} = r'''{value}''';\n"


def _write_dart(payload: dict) -> None:
    pretty = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False)
    variants = payload['chart_variants']
    header = (
        '// GENERATED FILE — do not edit by hand.\n'
        '//\n'
        '// Source: backend/scripts/build_q01_synthetic_preview.py\n'
        '// Fixture: backend/src/sitewise/project1/q01_synthetic_preview.py\n'
        '//\n'
        '// Development-only synthetic Q01 demonstration. No fielded response, no\n'
        '// real person and no authorized measurement is represented. The embedded\n'
        '// chart is in the SYNTHETIC_PREVIEW_ONLY render state: it draws bars, but\n'
        '// its admission block is HELD and it can never enter a report section.\n'
        '//\n'
        '// Regenerate rather than edit. A hand edit here would desynchronise the\n'
        '// fixture from the records that produced it.\n'
        'library;\n\n'
    )
    body = (
        _dart_string('q01SyntheticPreviewPayloadJson', pretty)
        + '\n'
        + _dart_string('q01SyntheticPreviewChartJson',
                       json.dumps(variants['SYNTHETIC_PREVIEW_ONLY'],
                                  indent=2, sort_keys=True, ensure_ascii=False))
        + '\n'
        + _dart_string('q01HeldChartJson',
                       json.dumps(variants['WITHHELD_NOT_AUTHORIZED'],
                                  indent=2, sort_keys=True, ensure_ascii=False))
        + '\n'
        + _dart_string('q01NotEstimableChartJson',
                       json.dumps(variants['NOT_ESTIMABLE'],
                                  indent=2, sort_keys=True, ensure_ascii=False))
    )
    DART_OUT.parent.mkdir(parents=True, exist_ok=True)
    DART_OUT.write_text(header + body, encoding='utf-8')
    print(f'  wrote {DART_OUT.relative_to(REPO)}  ({len(header + body)} bytes)')


def _verification(payload: dict) -> dict:
    """Assert the properties the unlock exists to guarantee, then record them."""
    from sitewise.project1.chart_spec import from_ee01  # local import: keep top light

    variants = payload['chart_variants']
    checks: list[dict] = []

    def check(name: str, ok: bool, detail: str) -> None:
        checks.append({'check': name, 'result': 'PASS' if ok else 'FAIL', 'detail': detail})

    preview = variants['SYNTHETIC_PREVIEW_ONLY']
    held = variants['WITHHELD_NOT_AUTHORIZED']
    missing = variants['NOT_ESTIMABLE']

    check('preview_render_state',
          preview['render_state'] == 'SYNTHETIC_PREVIEW_ONLY',
          f"render_state={preview['render_state']}")
    check('preview_admission_held',
          preview['admission']['status'] == 'HELD',
          f"admission.status={preview['admission']['status']}")
    check('preview_not_real_reportable',
          preview['admission']['real_reportable'] is False,
          f"real_reportable={preview['admission']['real_reportable']}")
    check('preview_discloses_all_counts',
          all(o['percentage'] is not None for o in preview['options']),
          f"{len(preview['options'])} options, all carry a share")
    check('preview_share_status_is_distinct',
          all(o['percentage_status'] == 'SYNTHETIC_PREVIEW_ESTIMABLE'
              for o in preview['options']),
          'no option uses ESTIMABLE, so no share claims production authority')
    check('preview_source_provenance',
          preview['source_provenance'] == 'SYNTHETIC_TEST',
          f"source_provenance={preview['source_provenance']}")
    check('preview_evidence_hash_matches',
          preview['evidence_context_hash'] == payload['evidence_context_hash'],
          'chart joins the fixture readback, not a production context')

    check('held_withholds_counts',
          all(o['percentage'] is None for o in held['options']),
          f"{len(held['options'])} options, none carries a share")
    check('held_render_state',
          held['render_state'] == 'WITHHELD_NOT_AUTHORIZED',
          f"render_state={held['render_state']}")
    check('held_same_counts_as_preview',
          [o['count'] for o in held['options']] == [o['count'] for o in preview['options']],
          'identical measurements, different presentation — the state is the only difference')

    check('missing_zero_denominator',
          missing['measurement']['V'] == 0,
          f"V={missing['measurement']['V']}")
    check('missing_no_shares',
          all(o['percentage'] is None for o in missing['options']),
          'V=0 never yields a share')
    check('missing_no_highest',
          missing['highest_options'] == [],
          'no ordering is claimed without a denominator')

    # --- the negative proofs -------------------------------------------
    # 1. A reportable snapshot cannot be dressed as a preview.
    from sitewise.domain.customer_questionnaire import digest as ee01_digest

    snapshot = q.build_snapshot()
    readback = q.build_readback(snapshot)
    question = q._question()  # noqa: SLF001 - the generator owns this boundary
    labels = {o['code']: o['label'] for o in preview['options'] if o['label']}

    # ``real_reportable`` is read from the readback *context*, so the hash has to
    # be recomputed after flipping it — otherwise the integrity check fires first
    # and the test would prove the wrong refusal.
    reportable_snapshot = json.loads(json.dumps(snapshot))
    reportable_readback = json.loads(json.dumps(readback))
    reportable_readback['context']['real_reportable'] = True
    reportable_readback['context_hash'] = ee01_digest(reportable_readback['context'])
    try:
        from_ee01(reportable_snapshot, reportable_readback, question,
                  title='negative proof', labels=labels,
                  render_state_override='SYNTHETIC_PREVIEW_ONLY')
        refused = False
        code = 'NO_REFUSAL'
    except ChartRefused as exc:
        refused = True
        code = exc.code
    check('reportable_cannot_be_preview', refused and code == 'CHART_SYNTHETIC_PREVIEW_REPORTABLE',
          f'refused with {code}')

    # 2. A caller cannot manufacture RENDERABLE from the override.
    try:
        from_ee01(snapshot, readback, question, title='negative proof', labels=labels,
                  render_state_override='RENDERABLE')
        refused = False
        code = 'NO_REFUSAL'
    except ChartRefused as exc:
        refused = True
        code = exc.code
    check('override_cannot_authorize', refused and code == 'CHART_OVERRIDE_CANNOT_AUTHORIZE',
          f'refused with {code}')

    # 3. A production snapshot cannot be charted at all.
    production_snapshot = json.loads(json.dumps(snapshot))
    production_snapshot['scope'] = 'PRODUCTION'
    production_readback = q.build_readback(production_snapshot)
    try:
        from_ee01(production_snapshot, production_readback, question,
                  title='negative proof', labels=labels)
        refused = False
        code = 'NO_REFUSAL'
    except ChartRefused as exc:
        refused = True
        code = exc.code
    check('production_snapshot_refused',
          refused and code == 'CHART_MEASUREMENT_AUTHORITY_UNVERIFIED',
          f'refused with {code}')

    # 4. The fixture is not enabled unless a caller asks for it.
    try:
        q.build_chart()
        refused = False
        code = 'NO_REFUSAL'
    except ChartRefused as exc:
        refused = True
        code = exc.code
    check('fixture_requires_explicit_opt_in',
          refused and code == 'SYNTHETIC_PREVIEW_NOT_ENABLED',
          f'refused with {code}')

    failed = [c for c in checks if c['result'] != 'PASS']
    return {
        'schema_version': 'q01-chartspec-verification/1',
        'chart_schema_version': preview['schema_version'],
        'fixture_module': q.__name__,
        'generated_at': payload['generated_at'],
        'summary': {
            'checks': len(checks),
            'passed': len(checks) - len(failed),
            'failed': len(failed),
            'verdict': 'PASS' if not failed else 'FAIL',
        },
        'checks': checks,
        'variant_contrast': {
            state: {
                'render_state': v['render_state'],
                'admission': v['admission']['status'],
                'real_reportable': v['admission']['real_reportable'],
                'V': v['measurement']['V'],
                'shares_disclosed': sum(1 for o in v['options'] if o['percentage'] is not None),
                'draws_bars_in_ui': v['render_state'] in ('RENDERABLE', 'SYNTHETIC_PREVIEW_ONLY'),
            }
            for state, v in variants.items()
        },
        'report_admission_untouched': {
            'R02': payload['section_admission']['R02'],
            'R08': payload['section_admission']['R08'],
            'note': ('Section admission is copied from the registry, not decided '
                     'here. R08 remains SPECIFICATION_ONLY and G01/G07/G08 stay '
                     'open; the preview changes nothing about them.'),
        },
    }


def main() -> int:
    print('building Q01 synthetic preview')
    payload = q.build_preview_payload(allow_synthetic=True)
    results = {
        'schema_version': 'q01-synthetic-fixture-results/1',
        'generated_at': payload['generated_at'],
        'fixture_module': q.__name__,
        'records': [
            {'respondent_id': rid, 'selected': list(sel)}
            for rid, sel in q._RECORDS  # noqa: SLF001 - the report must show the source
        ],
        'derived_counts': payload['counts'],
        'expected_counts': q.EXPECTED_COUNTS,
        'counts_match_expectation': payload['counts'] == q.EXPECTED_COUNTS,
        'respondent_summary': payload['respondent_summary'],
        'aggregation_basis': (
            'Counts are derived from the 40 records above, then checked against '
            'EXPECTED_COUNTS. They are not hard-coded.'),
        'provenance': {
            'is_ee01_execution': False,
            'is_fielded_data': False,
            'touches_database': False,
            'note': ('The snapshot is assembled by the fixture module in the shape '
                     'Ee01Service._read returns. It is not produced by an EE-01 run, '
                     'and no EE-01 execution path consumes it.'),
        },
        'payload': payload,
    }
    verification = _verification(payload)

    DELIVERABLES.mkdir(parents=True, exist_ok=True)
    _write_json(FIXTURE_RESULTS, results)
    _write_json(CHART_VERIFICATION, verification)
    _write_dart(payload)

    summary = verification['summary']
    print(f"\nverification: {summary['passed']}/{summary['checks']} PASS "
          f"-> {summary['verdict']}")
    for check in verification['checks']:
        print(f"  [{check['result']}] {check['check']}")
    return 0 if summary['verdict'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
