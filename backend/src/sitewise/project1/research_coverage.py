"""What the assessment already covers, in one shape both generation arms share.

Why this module exists
----------------------
Both generation arms are told not to duplicate what the assessment already
covers, and neither was ever shown that material. ``BDJ_OBJECTIVE`` says "never
propose an objective that a permanent objective already covers" while the six
permanent objectives stayed outside the packet; the QG arm is asked not to
restate an existing question while the Section A catalogue stayed outside its
input. A model cannot honour either instruction without the text.

One field, two buckets
----------------------
The field name, the bucket names, the entry keys, the ordering rule and the
compaction rule are defined here once, so the BDJ packet and the QG packet carry
the *same shape*. A difference between the two packets is then a difference in
the assessment, never a difference in the arm. ``required`` holds what the
assessment asks unconditionally (the six permanent objectives; the ESSENTIAL
Section A questions); ``optional`` holds what it may ask, or has already taken
up (the optional objectives recorded for the assessment; the Section A
questions that may be skipped).

What this is not
----------------
* It is not a duplication verdict. It states what is already covered; whether a
  candidate overlaps is still decided by the server's own checks
  (``issue_resolution.resolve_candidate`` construct matching for objectives, the
  QG validation path for questions). Identical text is the crudest overlap and
  is not sufficient alone, which is exactly why the model is given the
  constructs rather than a hash of them.
* It is not an approval, an admission or a measurement. Every text is read from
  the registry or catalogue that already owns it; nothing here is approved.
* It is not inside a governed fingerprint. It is added to the *model-facing*
  packet only, after ``source_fingerprint`` / ``packet_hash`` have been computed
  and carried as values — the same position ``rule_catalogue`` already occupies.
"""
from __future__ import annotations

import json
from pathlib import Path

from sitewise.project1.contracts import WorkflowHeld

COVERAGE_FIELD = 'research_coverage'
COVERAGE_CONTRACT_VERSION = 'P1-RESEARCH-COVERAGE-1.0'

REQUIRED = 'required'
OPTIONAL = 'optional'

#: Stated in-band so the model reads the field as material for a judgement, not
#: as a verdict it may repeat. Kept to one sentence pair: this text is paid for
#: in every call of both arms.
NOTE = ('What this assessment already covers. An entry is not a verdict: the '
        'server also compares a proposal against the source, so overlap is not '
        'decided by this list alone. Do not restate an entry; justify any overlap.')

#: Section A classes every admitted unit must answer. The same taxonomy
#: ``services.cq_release_builder`` reads off the catalogue for
#: ``required_for_answer``, so coverage and answering requirement cannot drift.
_ESSENTIAL_PREFIX = 'ESSENTIAL'
#: Section A classes that may be skipped.
MAY_BE_SKIPPED = frozenset({'CONDITIONAL_R07', 'OPTIONAL_CONTEXT'})

#: The governed Section A catalogue. Same artifact ``section_a_measurement``
#: annotates and ``cq_successor.preview_catalogue`` renders; read, never copied.
CATALOGUE_PATH = (Path(__file__).resolve().parents[1] / 'cq_successor' / 'data'
                  / 'governed_q01_q13_preview.json')


def one_line(text) -> str:
    """Collapse a construct onto one line. Never reworded, never truncated."""
    return ' '.join(str(text if text is not None else '').split())


def entry(identifier, construct) -> dict:
    """One compact coverage entry: a stable id and its one-line construct."""
    key = str(identifier if identifier is not None else '').strip()
    text = one_line(construct)
    if not key or not text:
        # A nameless or textless entry would silently reduce coverage to
        # "nothing to compare", which is the state this field exists to end.
        raise WorkflowHeld('RESEARCH_COVERAGE_ENTRY_INVALID')
    return {'id': key, 'construct': text}


def _ordered(entries) -> list[dict]:
    """Normalise and sort by id, so the field never depends on dict order."""
    rows = [entry(row['id'], row['construct']) for row in entries]
    return sorted(rows, key=lambda row: row['id'])


def build(*, required, optional) -> dict:
    """The one shape both arms carry."""
    return {
        'contract_version': COVERAGE_CONTRACT_VERSION,
        REQUIRED: _ordered(required),
        OPTIONAL: _ordered(optional),
        'note': NOTE,
    }


def permanent_objectives() -> list[dict]:
    """The six permanent objectives, read from the registry that owns them."""
    from sitewise.project1.objective_registry import OBJECTIVES
    return [entry(o.objective_id, o.construct) for o in OBJECTIVES]


def section_a(path=None) -> tuple[list[dict], list[dict]]:
    """The governed Section A questions, split by answering requirement.

    A class this module does not recognise is refused rather than assigned to a
    bucket: guessing would misreport what the questionnaire already covers.
    """
    catalogue = Path(path) if path is not None else CATALOGUE_PATH
    try:
        payload = json.loads(catalogue.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise WorkflowHeld('RESEARCH_COVERAGE_CATALOGUE_UNAVAILABLE') from None
    records = payload.get('questions') if isinstance(payload, dict) else None
    if not isinstance(records, list) or not records:
        raise WorkflowHeld('RESEARCH_COVERAGE_CATALOGUE_INVALID')

    required: list[dict] = []
    optional: list[dict] = []
    for record in records:
        if not isinstance(record, dict):
            raise WorkflowHeld('RESEARCH_COVERAGE_CATALOGUE_INVALID')
        klass = str(record.get('class') or '')
        row = entry(record.get('question_id'), record.get('construct'))
        if klass.startswith(_ESSENTIAL_PREFIX):
            required.append(row)
        elif klass in MAY_BE_SKIPPED:
            optional.append(row)
        else:
            raise WorkflowHeld('RESEARCH_COVERAGE_CATALOGUE_INVALID')
    return required, optional


def for_objective_arm(optional=()) -> dict:
    """Coverage for the BDJ objective arm.

    ``optional`` is the optional-objective coverage that already exists for the
    assessment (``{'id', 'construct'}`` entries). Empty is a valid and truthful
    answer: it means no optional objective has been taken up yet.
    """
    return build(required=permanent_objectives(), optional=list(optional))


def for_question_arm(path=None) -> dict:
    """Coverage for the QG arm: the Section A catalogue, split by requirement."""
    required, optional = section_a(path)
    return build(required=required, optional=optional)


__all__ = ['CATALOGUE_PATH', 'COVERAGE_CONTRACT_VERSION', 'COVERAGE_FIELD',
           'MAY_BE_SKIPPED', 'NOTE', 'OPTIONAL', 'REQUIRED', 'build', 'entry',
           'for_objective_arm', 'for_question_arm', 'one_line',
           'permanent_objectives', 'section_a']
