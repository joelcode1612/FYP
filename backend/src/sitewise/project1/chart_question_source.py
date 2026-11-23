"""Bind a frozen CUST03 item to its draft option labels for chart rendering.

This module is the adapter between two pinned sources and the chart contract:

* the frozen CUST03 instrument supplies the item's wording, response codes,
  substantive classification, display order and ordinal meaning;
* the Q01–Q13 registry supplies the **draft** option labels and the item's
  instrument gate.

Both are hash-pinned. Nothing here approves anything: a label handed to the chart
is marked ``CONTRACT_OPTION_BANK_DRAFT`` and a gate is handed over as a
*restriction* on the render state, never as an authorization.

Why a separate module
---------------------
``chart_spec`` stays a pure presentation contract with no file access, so its
tests can construct payloads directly. This module owns the file reading and the
one mapping that matters: an item whose required stimulus or bank is missing must
be held even when counts exist.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from sitewise.project1.chart_spec import ChartRefused, RenderState
from sitewise.project1.explanation_registry import load_registry

CONTRACT_PATH = (Path(__file__).resolve().parents[1] / 'customer_contracts' / 'reference'
                 / 'CUST_RECOVERY_20261027'
                 / 'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json')

#: Which instrument gate forces which held render state. A gate that only blocks
#: approval (``NOT_AUTHORIZED``) leaves the render state to the snapshot status,
#: because the data outcome is still describable — it simply may not be published,
#: which the admission block already records. A missing stimulus or bank is
#: different: the item cannot be interpreted at all, so it is held outright.
GATE_TO_RENDER_STATE: dict[str, RenderState | None] = {
    'NOT_AUTHORIZED': None,
    'BLOCKED_SOURCE': None,
    'MISSING_APPROVED_STIMULUS': 'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
    'MISSING_APPROVED_BANK': 'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
}

#: Response kinds the chart contract can express. ``ordinal_matrix`` is absent by
#: design — but not for the reason first recorded here. Per-feature denominators
#: *do* exist: ``cq_runtime.route`` expands Q10 into one slot per feature and
#: EE-01 measures one slot, so each feature slot already carries its own ``V``.
#: That retires the premise of D-09 (now ``SUPERSEDED``) and rules out the
#: ``V_feature`` column and migration it asked for. Q10 is still refused, because
#: what is missing is the *rule*, not the denominator: the registry declares no
#: per-feature measurement rule (``Q10-NR-DEFAULT`` names the denominator
#: unsupported), the ordinal scale is ``UNDECLARED``, and the feature bank is
#: unapproved (G06). Flattening the matrix onto one scale would invent the scale
#: and pool denominators the contract forbids pooling.
SUPPORTED_TYPES = frozenset({
    'single_select', 'nominal_single', 'multi_select',
    'multi_select_with_exclusive_terminals', 'ordinal_single',
})


@dataclass(frozen=True)
class QuestionSource:
    question_id: str
    question: dict
    labels: dict[str, str]
    gate: str | None
    render_state_override: RenderState | None
    report_sections: tuple[str, ...]
    template_usable_for_substantive_report: bool
    supported: bool

    def describe(self) -> dict:
        """Provenance of everything the chart was given, for a traceability record."""
        return {
            'question_id': self.question_id,
            'label_source': 'CONTRACT_OPTION_BANK_DRAFT',
            'labels_supplied': len(self.labels),
            'instrument_gate': self.gate,
            'render_state_override': self.render_state_override,
            'report_sections': list(self.report_sections),
            'chart_supported': self.supported,
            'template_usable_for_substantive_report':
                self.template_usable_for_substantive_report,
        }


@lru_cache(maxsize=1)
def _items() -> dict[str, dict]:
    if not CONTRACT_PATH.exists():
        raise ChartRefused('CHART_INSTRUMENT_MISSING', 503)
    payload = json.loads(CONTRACT_PATH.read_text(encoding='utf-8'))
    return {item['id']: item for item in payload['items']}


def source_for(question_id: str) -> QuestionSource:
    """Return the item, its draft labels and its gate. Refuses an unknown item."""
    item = _items().get(question_id)
    if item is None:
        raise ChartRefused('CHART_QUESTION_UNKNOWN', 422)
    entry = load_registry().question(question_id)
    if entry is None:
        raise ChartRefused('CHART_QUESTION_NOT_IN_REGISTRY', 503)

    return QuestionSource(
        question_id=question_id,
        question=item,
        labels=dict(entry.labels),
        gate=entry.instrument_gate,
        render_state_override=GATE_TO_RENDER_STATE.get(entry.instrument_gate or ''),
        report_sections=entry.report_sections,
        template_usable_for_substantive_report=entry.template_usable_for_substantive_report,
        supported=item['type'] in SUPPORTED_TYPES,
    )


def supported_question_ids() -> list[str]:
    """Every item the chart contract can express, in instrument order."""
    return [qid for qid, item in _items().items() if item['type'] in SUPPORTED_TYPES]
