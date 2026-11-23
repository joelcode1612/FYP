"""Export the authoritative ``chart-spec/1`` JSON Schema from the model.

The schema is generated, never hand-maintained, so a field added to
:mod:`sitewise.project1.chart_spec` cannot silently diverge from the published
contract artifact.

    backend/.venv/Scripts/python.exe scripts/export_chart_spec_schema.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / 'src'))

from sitewise.project1.chart_spec import (  # noqa: E402
    CANONICAL_REPORT_SECTIONS,
    ChartSpec,
    DERIVED_CELL_CODES,
    SCHEMA_VERSION,
)

OUT = BACKEND.parent / 'deliverables' / 'PROJECT1_CHARTSPEC_V1_SCHEMA.json'


def build() -> dict:
    schema = ChartSpec.model_json_schema(mode='serialization')
    schema['$id'] = 'https://sitewise.local/project1/chart-spec/1'
    schema['title'] = 'Project1 ChartSpec V1'
    schema['description'] = (
        'Presentation contract for one R03-R08 measurement line. Conveys no '
        'measurement, scientific, privacy or report-admission authority.')
    schema['x-schema-version'] = SCHEMA_VERSION
    schema['x-canonical-report-sections'] = list(CANONICAL_REPORT_SECTIONS)
    schema['x-derived-cell-codes'] = sorted(DERIVED_CELL_CODES)
    schema['x-numeric-policy'] = {
        'percentage': ('decimal string, four decimal places, present only when '
                       'the render state discloses counts — RENDERABLE, or '
                       'SYNTHETIC_PREVIEW_ONLY in a development build; absent '
                       'otherwise, never 0% for V == 0'),
        'count': 'integer',
        'no_float': 'no evidential quantity is serialized as a JSON number with a fraction',
    }
    schema['x-authority'] = 'NONE_GRANTED_BY_THIS_DOCUMENT'
    return schema


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(build(), indent=2, sort_keys=False) + '\n', encoding='utf-8')
    print(f'wrote {OUT}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
