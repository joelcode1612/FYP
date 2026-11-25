"""Preview-only governed questionnaire catalogue (Q01-Q13).

Why this module exists
----------------------
Stage 4 must show the 13 governed core questions. The governed wording lives in
the CQ replay artifact, but **not one of the 13 carries an approval**:

===========================  ==============================
``measurement_status``        questions
===========================  ==============================
``BLOCKED_MEASUREMENT``       Q01 Q04 Q05 Q06 Q07 Q12
``BLOCKED_SOURCE``            Q03 Q08 Q09
``BLOCKED_OWNER``             Q11 Q13
``SCIENTIFIC_APPROVAL_PENDING``  Q02
``G06_APPROVAL_PENDING``      Q10
===========================  ==============================

So the display problem and the authority problem are different problems. This
module solves only the first one. It lets Stage 4 render the governed wording,
populated from the owner's own M2 declarations, while every question stays
labelled with the approval it does not have.

What this module is NOT
-----------------------
* **Not** :class:`sitewise.project1.question_bank.QuestionBank`. That module
  refuses any item whose ``approval_state`` is not ``APPROVED`` and requires a
  non-empty, fully-reviewed snapshot (BD-01 / BD-02). Nothing here is imported
  by it, and nothing here touches ``project1_qgb``. ``lookup()`` exists only to
  raise, so a caller that mistakes this for a bank fails loudly instead of
  silently reusing unapproved wording.
* **Not** a QG bank. It cannot justify drafting a new question, because
  "equivalent already exists" would be a claim about approval this catalogue
  does not have.
* **Not** fielding authority. ``production_fielding_authorized`` is False and
  ``report_release_authorized`` is False, and both are returned in the payload
  so a downstream consumer cannot infer otherwise.

Template population vs respondent lifecycle (R1-R5)
---------------------------------------------------
R1. **Separate concerns.** This module performs *template population* only. It
    never emits a respondent state. ``NOT_SHOWN``, ``SKIPPED``,
    ``PENDING_DEPENDENCY`` and ``BLOCKED`` belong to the routing layer
    (``cq_successor.policy``), which decides per respondent what is asked. A
    question being unpopulated here says nothing about what any respondent sees.
R2. **A missing value stays missing.** When the owner has not declared a value,
    the placeholder is left visible and the slot is reported as unresolved. It is
    never blanked, never guessed, never defaulted, and never turned into a
    respondent-facing absence.
R3. **Only declared slots are substituted.** Substitution happens only for the
    bracketed tokens the governed stem actually contains. No placeholder is
    introduced into a stem that has none, so the seven questions with no slots
    are returned byte-identical to the governed wording.
R4. **Deterministic.** Same M2 values produce the same output. No model, no
    randomness, no clock. The populated digest is a pure function of the inputs.
R5. **Unresolved blocks completeness, not display.** An unresolved required slot
    makes ``population_status`` ``PARTIAL_UNRESOLVED``; the question is still
    returned and still displayed, because hiding it would misrepresent the
    governed questionnaire as shorter than it is.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Mapping

from sitewise.modules.decision_engine.domain.geo_catalogue import (
    area_label as _geo_area_label,
)

#: Authority label carried on every item and in the payload.
PREVIEW_AUTHORITY = 'PREVIEW_ONLY_NON_AUTHORITATIVE'
#: The only catalogue schema this reader understands.
CATALOGUE_VERSION = 'cq-preview-catalogue/1'

DATA_FILE = Path(__file__).with_name('data') / 'governed_q01_q13_preview.json'

COMPLETE = 'COMPLETE'
PARTIAL_UNRESOLVED = 'PARTIAL_UNRESOLVED'
NO_SUBSTITUTION_REQUIRED = 'NO_SUBSTITUTION_REQUIRED'

#: Slot registry. ``source`` names the M2 declaration (or BCB field) that may
#: populate the token. Nothing outside this table is ever substituted, so adding
#: a placeholder to a stem without registering it here fails closed.
SLOT_REGISTRY: dict[str, dict[str, object]] = {
    'named area': {
        'slot': 'named_area',
        'source': 'M2V2-01',
        'required': True,
        'note': (
            'The study area the respondent is being asked about. When the owner '
            'has not decided an area, no area can be shown and the question '
            'cannot be fielded -- but it is still displayed in preview.'
        ),
    },
    'concept_card_version': {
        'slot': 'concept_card_version',
        'source': 'BCB.concept.version',
        'required': True,
        'note': 'Version of the confirmed concept card the stimulus refers to.',
    },
    'exact_rm_price': {
        'slot': 'exact_rm_price',
        'source': 'M2V2-14.amount_myr',
        'required': True,
        'note': "The owner's single exact priced offer, formatted in RM.",
    },
    'one_exact_product_size_quantity_fulfilment_and_charges': {
        'slot': 'product_spec',
        'source': 'M2V2-14',
        'required': True,
        'note': (
            'Product, size, quantity, fulfilment and charges of the exact offer, '
            'so the price is anchored to something the respondent can picture.'
        ),
    },
    'defined item: medium latte, dine-in': {
        'slot': 'defined_item',
        'source': 'M2V2-14.product_ref',
        'required': False,
        'note': (
            'The governed token carries an illustrative example; the owner\'s own '
            'exact product replaces it so the expectation is not anchored to a '
            'product they do not sell. Optional: Q13 is optional context.'
        ),
    },
}


class PreviewCatalogueError(Exception):
    """Raised when the catalogue cannot be read or is misused."""


@dataclass(frozen=True)
class Slot:
    token: str
    slot: str
    source: str
    required: bool
    note: str


@dataclass(frozen=True)
class UnresolvedSlot:
    token: str
    slot: str
    source: str
    required: bool
    reason: str


@dataclass(frozen=True)
class PreviewQuestion:
    question_id: str
    stem_template: str
    response_type: str
    question_class: str
    construct: str
    disposition: str
    measurement_status: str
    codes: tuple[str, ...]
    display_order: tuple[str, ...]
    max_selections: int | None
    exclusive_codes: tuple[str, ...]
    approval_state: str
    authority_to_activate: str
    slots: tuple[Slot, ...]

    def populate(self, values: Mapping[str, str]) -> 'PopulatedQuestion':
        """Substitute registered slots from ``values``. See R1-R5."""
        populated = self.stem_template
        resolved: dict[str, str] = {}
        unresolved: list[UnresolvedSlot] = []

        for slot in self.slots:
            raw = values.get(slot.slot)
            text = raw.strip() if isinstance(raw, str) else ''
            if text:
                populated = populated.replace(slot.token, text)
                resolved[slot.slot] = text
            else:
                unresolved.append(
                    UnresolvedSlot(
                        token=slot.token,
                        slot=slot.slot,
                        source=slot.source,
                        required=slot.required,
                        reason=(
                            'The owner has not declared a value for this M2 item, '
                            'so the placeholder is left visible.'
                            if slot.required
                            else 'Optional slot; no owner value available.'
                        ),
                    )
                )

        if not self.slots:
            status = NO_SUBSTITUTION_REQUIRED
        elif any(u.required for u in unresolved):
            status = PARTIAL_UNRESOLVED
        else:
            status = COMPLETE

        return PopulatedQuestion(
            question=self,
            populated_stem=populated,
            resolved=resolved,
            unresolved=tuple(unresolved),
            population_status=status,
        )


@dataclass(frozen=True)
class PopulatedQuestion:
    question: PreviewQuestion
    populated_stem: str
    resolved: dict[str, str]
    unresolved: tuple[UnresolvedSlot, ...]
    population_status: str

    def as_dict(self) -> dict[str, object]:
        q = self.question
        return {
            'question_id': q.question_id,
            'stem_template': q.stem_template,
            'populated_stem': self.populated_stem,
            'response_type': q.response_type,
            'question_class': q.question_class,
            'construct': q.construct,
            'disposition': q.disposition,
            'measurement_status': q.measurement_status,
            'approval_state': q.approval_state,
            'authority_to_activate': q.authority_to_activate,
            'codes': list(q.codes),
            'display_order': list(q.display_order),
            'max_selections': q.max_selections,
            'exclusive_codes': list(q.exclusive_codes),
            'population_status': self.population_status,
            'resolved_slots': dict(self.resolved),
            'unresolved_slots': [
                {
                    'token': u.token,
                    'slot': u.slot,
                    'source': u.source,
                    'required': u.required,
                    'reason': u.reason,
                }
                for u in self.unresolved
            ],
            'review_controls': 'NONE',
            'fielding_authorized': False,
        }


@dataclass(frozen=True)
class PopulatedCatalogue:
    questions: tuple[PopulatedQuestion, ...]
    provenance: dict[str, object] = field(default_factory=dict)

    @property
    def digest(self) -> str:
        """Content address of the populated catalogue (R4)."""
        body = [q.as_dict() for q in self.questions]
        canonical = json.dumps(body, sort_keys=True, separators=(',', ':'))
        return hashlib.sha256(canonical.encode('utf-8')).hexdigest()

    def as_payload(self) -> dict[str, object]:
        unresolved_required = sum(
            1
            for q in self.questions
            for u in q.unresolved
            if u.required
        )
        return {
            'catalogue_version': CATALOGUE_VERSION,
            'authority': PREVIEW_AUTHORITY,
            'is_question_bank': False,
            'is_qg_bank': False,
            'production_fielding_authorized': False,
            'report_release_authorized': False,
            'review_controls': 'NONE',
            'question_count': len(self.questions),
            'approved_question_count': sum(
                1 for q in self.questions
                if q.question.approval_state == 'APPROVED'
            ),
            'unresolved_required_slot_count': unresolved_required,
            'population_status': (
                PARTIAL_UNRESOLVED if unresolved_required else COMPLETE
            ),
            'populated_digest': self.digest,
            'provenance': dict(self.provenance),
            'questions': [q.as_dict() for q in self.questions],
        }


class PreviewQuestionCatalogue:
    """Read-only preview reader over the governed Q01-Q13 wording.

    Construct with :meth:`load`. The catalogue is immutable once built, so a
    request cannot mutate shared wording.
    """

    def __init__(self, questions: tuple[PreviewQuestion, ...],
                 provenance: dict[str, object]) -> None:
        self._questions = questions
        self._by_id = {q.question_id: q for q in questions}
        self._provenance = provenance

    # ---------------------------------------------------------------- loading
    @classmethod
    def load(cls, path: Path | None = None) -> 'PreviewQuestionCatalogue':
        source = path or DATA_FILE
        try:
            payload = json.loads(source.read_text(encoding='utf-8'))
        except FileNotFoundError as exc:
            raise PreviewCatalogueError(
                'PREVIEW_CATALOGUE_UNAVAILABLE'
            ) from exc
        except json.JSONDecodeError as exc:
            raise PreviewCatalogueError(
                'PREVIEW_CATALOGUE_MALFORMED'
            ) from exc

        if payload.get('schema_version') != CATALOGUE_VERSION:
            raise PreviewCatalogueError('PREVIEW_CATALOGUE_VERSION_UNSUPPORTED')
        if payload.get('authority') != PREVIEW_AUTHORITY:
            raise PreviewCatalogueError('PREVIEW_CATALOGUE_AUTHORITY_INVALID')
        # A file that claims to be a bank is not a preview file. Refuse rather
        # than let a mislabelled payload widen its own authority.
        if payload.get('not_a_qg_bank') is not True:
            raise PreviewCatalogueError('PREVIEW_CATALOGUE_AUTHORITY_INVALID')
        if payload.get('production_fielding_authorized') is not False:
            raise PreviewCatalogueError('PREVIEW_CATALOGUE_AUTHORITY_INVALID')

        raw_questions = payload.get('questions')
        if not isinstance(raw_questions, list) or len(raw_questions) != 13:
            raise PreviewCatalogueError('PREVIEW_CATALOGUE_INCOMPLETE')

        expected = [f'Q{i:02d}' for i in range(1, 14)]
        seen: list[str] = []
        questions: list[PreviewQuestion] = []
        for row in raw_questions:
            qid = row.get('question_id')
            if qid not in expected:
                raise PreviewCatalogueError('PREVIEW_CATALOGUE_ID_OUT_OF_RANGE')
            if qid in seen:
                raise PreviewCatalogueError('PREVIEW_CATALOGUE_DUPLICATE_ID')
            seen.append(qid)

            stem = row.get('stem')
            if not isinstance(stem, str) or not stem.strip():
                raise PreviewCatalogueError('PREVIEW_CATALOGUE_STEM_MISSING')

            # Never accept an approval the artifact did not grant.
            if row.get('approval_state') == 'APPROVED':
                raise PreviewCatalogueError(
                    'PREVIEW_CATALOGUE_CANNOT_ASSERT_APPROVAL'
                )

            slots = _slots_for(stem)
            questions.append(
                PreviewQuestion(
                    question_id=qid,
                    stem_template=stem,
                    response_type=str(row.get('type') or ''),
                    question_class=str(row.get('class') or ''),
                    construct=str(row.get('construct') or ''),
                    disposition=str(row.get('disposition') or ''),
                    measurement_status=str(row.get('measurement_status') or ''),
                    codes=tuple(row.get('codes') or ()),
                    display_order=tuple(row.get('display_order') or ()),
                    max_selections=row.get('max_selections'),
                    exclusive_codes=tuple(row.get('exclusive_codes') or ()),
                    approval_state=str(row.get('approval_state') or 'NOT_APPROVED'),
                    authority_to_activate=str(
                        row.get('authority_to_activate')
                        or 'NONE_GRANTED_BY_THIS_DOCUMENT'
                    ),
                    slots=slots,
                )
            )

        if seen != expected:
            raise PreviewCatalogueError('PREVIEW_CATALOGUE_INCOMPLETE')

        return cls(
            questions=tuple(questions),
            provenance=dict(payload.get('provenance') or {}),
        )

    # ------------------------------------------------------------------ read
    def questions(self) -> tuple[PreviewQuestion, ...]:
        return self._questions

    def get(self, question_id: str) -> PreviewQuestion:
        try:
            return self._by_id[question_id]
        except KeyError as exc:
            raise PreviewCatalogueError('PREVIEW_CATALOGUE_UNKNOWN_QUESTION') from exc

    def populate(self, values: Mapping[str, str]) -> PopulatedCatalogue:
        return PopulatedCatalogue(
            questions=tuple(q.populate(values) for q in self._questions),
            provenance=self._provenance,
        )

    # ------------------------------------------------------- misuse guardrail
    def lookup(self, *_args: object, **_kwargs: object) -> None:
        """Refuse to behave like :class:`QuestionBank`.

        BD-01 reuse and BD-02 no-equivalent are claims about *approval*. A
        preview catalogue cannot make them, so it must not answer.
        """
        raise PreviewCatalogueError('PREVIEW_CATALOGUE_IS_NOT_A_QUESTION_BANK')


def _slots_for(stem: str) -> tuple[Slot, ...]:
    """Registered slots actually present in ``stem``, in first-appearance order."""
    found: list[Slot] = []
    for token, spec in SLOT_REGISTRY.items():
        if f'[{token}]' not in stem:
            continue
        found.append(
            Slot(
                token=f'[{token}]',
                slot=str(spec['slot']),
                source=str(spec['source']),
                required=bool(spec['required']),
                note=str(spec['note']),
            )
        )
    found.sort(key=lambda s: stem.index(s.token))
    return tuple(found)


#: Values that mean "the owner has not decided", not "the area is called this".
#: Treating the literal token ``UNDECIDED`` as a value would print
#: "your connection to UNDECIDED", which is worse than showing the placeholder.
_UNDECIDED = frozenset({'', 'UNDECIDED', 'NOT_DECIDED', 'UNKNOWN', 'NONE'})

#: The exact shape ``validate_m2_answer`` accepts for a ``GEO`` item. A mapping
#: carrying all three keys is the owner's answer itself, never a BCB wrapper.
_GEO_KEYS = frozenset({'jurisdiction', 'area_ref', 'catalogue_version'})


def _amount_myr(value: object) -> float | None:
    """Read an ``AMOUNT_MYR`` declaration as a number, or refuse.

    ``M2V2-14.amount_myr`` is declared ``type: AMOUNT_MYR`` and the item
    validator accepts it as a **string** (``"16.00"``), which is what the
    questionnaire UI writes and what every stored row contains. Requiring
    ``isinstance(value, (int, float))`` therefore rejected the owner's own
    declared price and left ``[exact_rm_price]`` unresolved on Q07 — the price
    was declared and the slot still reported "the owner has not declared a
    value".

    A numeric string is read exactly (via ``Decimal``, so no float rounding is
    introduced for a currency), and anything else stays unresolved rather than
    becoming a number this module guessed.
    """
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float, Decimal)):
        try:
            return float(value)
        except (TypeError, ValueError, InvalidOperation):
            return None
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            return float(Decimal(text))
        except (InvalidOperation, ValueError):
            return None
    return None


def build_slot_values(
    *,
    study_area: object,
    concept_version: object,
    priced_offer: object,
) -> dict[str, str]:
    """Derive the slot map from the owner's own declarations.

    Pure: no I/O, no clock, no model. Returns only slots it can fill; every
    other slot is simply absent, which ``PreviewQuestion.populate`` reports as
    unresolved rather than inventing a value (R2).

    ``study_area`` accepts either the BCB shape ``{'value': ..., 'label': ...}``
    or the bare M2 answer value.
    """
    values: dict[str, str] = {}

    area_value = study_area
    area_label = None
    if isinstance(study_area, Mapping) and not _GEO_KEYS <= set(study_area):
        # The BCB shape wraps a bare code; a GEO answer does not. Only unwrap
        # the wrapper, or the GEO answer's own keys are discarded and a decided
        # area reads as undecided.
        area_value = study_area.get('value')
        area_label = study_area.get('label')

    area_text = ''
    if isinstance(area_value, Mapping) and _GEO_KEYS <= set(area_value):
        # DD-063/DD-072: M2V2-01 is a GEO item. Once the approved catalogue is
        # connected the owner's answer is the structured
        # ``{jurisdiction, area_ref, catalogue_version}`` object, not a string.
        # The name comes from the catalogue itself, so a value it does not
        # register yields no name rather than a fabricated one.
        area_text = _geo_area_label(area_value) or ''
    elif isinstance(area_value, str) and area_value.strip().upper() not in _UNDECIDED:
        area_text = area_value.strip()
    elif isinstance(area_label, str) and area_label.strip():
        # A decided area may carry only a human label; accept it, but never
        # accept the "I have not decided" label as an area name.
        if area_label.strip().lower() not in {
            'i have not decided on an area',
            'not decided',
        }:
            area_text = area_label.strip()
    if area_text:
        values['named_area'] = area_text

    if isinstance(concept_version, str) and concept_version.strip():
        values['concept_card_version'] = concept_version.strip()

    if isinstance(priced_offer, Mapping):
        decision = str(priced_offer.get('decision') or '').strip().upper()
        amount = priced_offer.get('amount_myr')
        product = priced_offer.get('product_ref')
        size = priced_offer.get('size_quantity')
        details = priced_offer.get('total_price_details')

        # Only a PRICED offer anchors a price. An UNPRICED or ABSENT decision
        # leaves the price slots empty rather than borrowing a number.
        amount_value = _amount_myr(amount)
        if decision == 'PRICED' and amount_value is not None:
            values['exact_rm_price'] = f'RM {amount_value:,.2f}'

        parts = [
            str(part).strip()
            for part in (product, size)
            if isinstance(part, str) and part.strip()
        ]
        if parts:
            spec = ', '.join(parts)
            if isinstance(details, str) and details.strip():
                spec = f'{spec} ({details.strip()})'
            values['product_spec'] = spec
            values['defined_item'] = ', '.join(parts)

    return values


__all__ = [
    'CATALOGUE_VERSION',
    'COMPLETE',
    'NO_SUBSTITUTION_REQUIRED',
    'PARTIAL_UNRESOLVED',
    'PREVIEW_AUTHORITY',
    'PopulatedCatalogue',
    'PopulatedQuestion',
    'PreviewCatalogueError',
    'PreviewQuestion',
    'PreviewQuestionCatalogue',
    'SLOT_REGISTRY',
    'Slot',
    'UnresolvedSlot',
    'build_slot_values',
]
