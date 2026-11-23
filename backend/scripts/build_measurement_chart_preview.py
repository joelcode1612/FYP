"""Emit the RP-04 measurement-chart fixture for the existing report.

Reads the RP-02 mapping record (produced by
``artifacts/cq_fc4d_report_integration_v2/tools/verify_ee01_chart_mapping.py``,
which builds real ``chart-spec/1`` payloads through the production adapter
``sitewise.project1.chart_spec.from_ee01``) and emits the Q05 payload as a Dart
compile-time constant, so the web app needs no backend, database or network to
render the real measurement's withheld state.

This script does not build a chart and does not compute a percentage. It copies
a payload that was already built and validated, and it *refuses* to emit
anything that could pass for an admitted finding.

Usage
-----
    cd backend
    ./.venv/Scripts/python.exe scripts/build_measurement_chart_preview.py
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent

MAPPING = (REPO / 'artifacts' / 'cq_fc4d_report_integration_v2' / 'runs'
           / 'rp02_mapping.json')
DART_OUT = (REPO / 'fyp_jaspr_web' / 'lib' / 'features' / 'assessment' / 'data'
            / 'measurement_chart_fixture.dart')
RECORD_OUT = (REPO / 'artifacts' / 'cq_fc4d_report_integration_v2' / 'runs'
              / 'measurement_chart_fixture.json')

#: Render states the report may present from this fixture. ``RENDERABLE`` is
#: absent by design: no admitted adapter exists, so a renderable payload in this
#: file would be a fabricated finding.
ALLOWED_STATES = {
    'WITHHELD_NOT_AUTHORIZED',
    'NOT_SHOWN',
    'NOT_ESTIMABLE',
    'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
}


def refuse(code: str) -> None:
    raise SystemExit(f'REFUSED: {code}')


def main() -> int:
    if not MAPPING.exists():
        refuse('RP02_MAPPING_RECORD_MISSING')
    raw = MAPPING.read_bytes()
    mapping = json.loads(raw.decode('utf-8'))

    payload = mapping.get('report_payload') or {}
    chart = payload.get('chart')
    if not chart:
        refuse('REPORT_PAYLOAD_MISSING')

    # --- guards: the fixture may never carry an admitted claim ---------------
    state = chart.get('render_state')
    if state not in ALLOWED_STATES:
        refuse(f'RENDER_STATE_NOT_PRESENTABLE:{state}')

    admission = chart.get('admission') or {}
    if admission.get('status') != 'HELD':
        refuse('ADMISSION_NOT_HELD')
    if admission.get('real_reportable'):
        refuse('FIXTURE_MARKED_REPORTABLE')
    if not admission.get('gates'):
        refuse('HELD_WITHOUT_GATE')

    emitted = [o for o in chart.get('options', []) if o.get('percentage') is not None]
    if emitted:
        refuse(f'PERCENTAGE_EMITTED_WITHOUT_AUTHORITY:{len(emitted)}')

    if chart.get('schema_version') != 'chart-spec/1':
        refuse('SCHEMA_VERSION_UNSUPPORTED')
    if chart.get('question_id') != 'Q05':
        refuse(f'UNEXPECTED_QUESTION:{chart.get("question_id")}')
    if chart.get('report_sections') != ['R03']:
        refuse(f'UNEXPECTED_SECTION:{chart.get("report_sections")}')

    measurement = chart.get('measurement') or {}
    V = measurement.get('V')
    if not isinstance(V, int) or V <= 0:
        refuse('DENOMINATOR_NOT_POSITIVE')
    total = sum(int(o.get('count') or 0) for o in chart.get('options', []))
    if chart.get('response_kind') == 'SINGLE_SELECT' and total != V:
        refuse(f'SINGLE_SELECT_SUM_MISMATCH:{total}!={V}')

    # --- provenance ----------------------------------------------------------
    provenance = {
        'source': 'EE-01 persisted measurement snapshot, built by from_ee01',
        'mapping_record': str(MAPPING.relative_to(REPO)).replace('\\', '/'),
        'mapping_record_sha256': hashlib.sha256(raw).hexdigest(),
        'test_run_id': mapping.get('test_run_id'),
        'campaign_id': mapping.get('campaign_id'),
        'assessment_id': mapping.get('assessment_id'),
        'slot': payload.get('slot'),
        'rule': payload.get('rule'),
        # The routing policy the measurement ran under. Deliberately NOT the
        # contract spec version: they are different documents, and the report
        # must name the policy that actually governed the run.
        'policy_version': mapping.get('routing_policy_version'),
        'contract_spec_version': mapping.get('contract_spec_version'),
        'evidence_context_hash': chart.get('evidence_context_hash'),
        'content_hash': None,
        'qualified': measurement.get('Q'),
        'shown': measurement.get('S'),
        'answered': measurement.get('A'),
        'substantive': measurement.get('V'),
        'render_state': state,
        'admission_status': admission.get('status'),
        'gates': admission.get('gates'),
    }

    if not provenance['policy_version']:
        refuse('ROUTING_POLICY_VERSION_MISSING')

    # Deterministic content hash of the chart, mirroring ChartSpec.content_hash    # (canonical JSON of the payload). Recorded so a fixture edit is visible.
    canonical = json.dumps(chart, sort_keys=True, ensure_ascii=True,
                           separators=(',', ':'))
    provenance['content_hash'] = hashlib.sha256(canonical.encode('utf-8')).hexdigest()

    # --- emit ----------------------------------------------------------------
    chart_json = json.dumps(chart, indent=2, ensure_ascii=False)
    prov_json = json.dumps(provenance, indent=2, ensure_ascii=False)
    for name, text in (('chart', chart_json), ('provenance', prov_json)):
        if "'''" in text:
            refuse(f'TRIPLE_QUOTE_IN_{name.upper()}')

    DART_OUT.write_text(
        '// GENERATED FILE — do not edit by hand.\n'
        '//\n'
        '// Regenerate with:\n'
        '//   cd backend && ./.venv/Scripts/python.exe '
        'scripts/build_measurement_chart_preview.py\n'
        '//\n'
        '// The payload below is a real `chart-spec/1` built from the persisted\n'
        '// FC4-D EE-01 measurement snapshot for Q05 by the production adapter\n'
        '// `sitewise.project1.chart_spec.from_ee01`. Its render state is\n'
        '// WITHHELD_NOT_AUTHORIZED and its admission block is HELD, so it\n'
        '// discloses no count and no percentage. It is a diagnostic readback of\n'
        '// a synthetic measurement, never an admitted customer-demand finding.\n'
        'library;\n\n'
        f"/// SHA-256 of the canonical chart payload (content identity).\n"
        f"const String measurementChartContentHash =\n    '{provenance['content_hash']}';\n\n"
        f"/// The `chart-spec/1` payload, verbatim.\n"
        f"const String measurementChartPayloadJson = r'''{chart_json}''';\n\n"
        f"/// Provenance of that payload: which run, campaign, assessment and\n"
        f"/// snapshot produced it, and how many respondents reached each funnel\n"
        f"/// stage.\n"
        f"const String measurementChartProvenanceJson = r'''{prov_json}''';\n",
        encoding='utf-8',
    )

    RECORD_OUT.write_text(
        json.dumps({
            'contract': 'fc4d-report-integration/rp04-fixture/1',
            'generated_from': provenance['mapping_record'],
            'generated_from_sha256': provenance['mapping_record_sha256'],
            'dart_output': str(DART_OUT.relative_to(REPO)).replace('\\', '/'),
            'guards_applied': [
                'render_state in ALLOWED_STATES',
                'admission.status == HELD',
                'admission.real_reportable == false',
                'admission.gates non-empty',
                'no option carries a percentage',
                'schema_version == chart-spec/1',
                'question_id == Q05',
                'report_sections == [R03]',
                'V > 0',
                'single-select option counts sum to V',
            ],
            'provenance': provenance,
        }, indent=2),
        encoding='utf-8',
    )

    print(f'  wrote {DART_OUT.relative_to(REPO)}')
    print(f'  wrote {RECORD_OUT.relative_to(REPO)}')
    print(f'  question        : {chart["question_id"]} -> {chart["report_sections"]}')
    print(f'  render state    : {state}')
    print(f'  admission       : {admission["status"]} ({len(admission["gates"])} gates)')
    print(f'  measurement     : Q={measurement.get("Q")} S={measurement.get("S")} '
          f'A={measurement.get("A")} V={measurement.get("V")}')
    print(f'  percentages     : none emitted')
    print(f'  content hash    : {provenance["content_hash"][:24]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
