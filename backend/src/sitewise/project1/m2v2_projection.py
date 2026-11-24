"""Version-bound M2 V2 source projection for the BDJ path.

Why a separate projector
------------------------
``projection.M2SourceProjection`` is frozen around the M2 V1 instrument: it
hard-codes ``M2V1-20261114-1``, excludes four ``M2-*`` keys, emits
``project1-m2-projection/1-candidate`` and — decisively — refuses any instrument
whose stored ``approval_state`` is not ``AUTHORIZED``. M2 V2 is
``PROPOSED_NOT_AUTHORIZED`` pending owner approval, and rewriting that column to
make a test pass is forbidden. Extending the V1 projector in place would also
change the historical V1 fingerprint, which several persisted artefacts are
bound to.

So V2 gets its own projector that **reuses** everything it safely can:
``digest``, ``resolve_m2_items``, ``validate_m2_answer`` and the same repository
port. Nothing about the V1 packet changes.

What the model is allowed to see
--------------------------------
The packet is a *detached*, fully self-describing view of one confirmed M2 V2
revision. It carries:

* all 19 registered questions, in registered order, whether answered or not;
* the exact stored structured value (``value``) for each answer, unmodified —
  free text keeps its original whitespace and newlines;
* the registered meaning of every response code the entrepreneur could have
  selected (``response_meanings``), resolved from the instrument's own
  ``option_values`` / ``value_schema``, never from a model or a constant table;
* a readable rendering (``answer_display``) derived only from those meanings.

Consequently the model never needs a database connection and is never given one:
every identifier it may cite is already a literal inside the packet, and every
code it may quote already has its registered label beside it. ``verify_*``
re-derives the fingerprint from the packet alone, so a reader can prove the
packet was not edited after projection.

Authorization
-------------
Usability is decided by the single audited gate in
``services.instrument_authorization``. ``PROPOSED_NOT_AUTHORIZED`` is therefore
usable **only** inside an explicit disposable-target synthetic scope, and the
stored ``approval_state`` is never touched.
"""
from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.modules.decision_engine.domain.m2_rules import (
    resolve_m2_items,
    validate_m2_answer,
)
from sitewise.project1.contracts import digest
from sitewise.services.instrument_authorization import instrument_is_usable

M2V2_VERSION = 'M2V2-20261122-1'
M2V2_ITEMS = frozenset(f'M2V2-{number:02d}' for number in range(1, 20))

SCHEMA_VERSION = 'project1-m2v2-projection/1-candidate'
M2V1_SCHEMA_VERSION = 'project1-m2-projection/1-candidate'

#: Instrument version -> the projection schema that instrument must produce.
#: The disclosure preflight compares the packet's ``schema_version`` against the
#: value registered here, so this map is the single place that decides which
#: schema is acceptable for which instrument. A version that is absent is
#: refused rather than defaulted: defaulting is how an M2V2 packet ended up being
#: validated against the M2V1 schema and refused with
#: ``DISCLOSURE_SOURCE_CLASS_INVALID`` (DD-009).
PROJECTION_SCHEMA_BY_INSTRUMENT = {
    'M2V1-20261114-1': M2V1_SCHEMA_VERSION,
    M2V2_VERSION: SCHEMA_VERSION,
}


def expected_projection_schema(instrument_version) -> str:
    """The projection schema ``instrument_version`` is required to produce.

    Refuses an unregistered instrument instead of falling back to the M2V1
    schema. Callers must compare against this server-side value, never against
    the packet's own ``schema_version`` (which would make the check vacuous).
    """
    try:
        return PROJECTION_SCHEMA_BY_INSTRUMENT[str(instrument_version)]
    except KeyError:
        from sitewise.project1.contracts import WorkflowHeld
        raise WorkflowHeld('BDJ_INSTRUMENT_UNSUPPORTED') from None

#: Prompt keys registered for the V2 adaptations (see ``project1.prompts``).
FINDINGS_PROMPT_KEY = 'BDJ_M2V2'
OBJECTIVE_PROMPT_KEY = 'BDJ_OBJECTIVE_M2V2'

#: Projection-level state for an item with no stored answer row at all. It is
#: deliberately *not* one of the instrument's ``allowed_states``: the instrument
#: describes what an entrepreneur may submit, this describes what the projection
#: observed. A reader must never conflate "not answered yet" with "explicitly
#: recorded as not provided".
NOT_ANSWERED = 'NOT_ANSWERED'


@dataclass(frozen=True)
class SourceContract:
    """Everything that differs between the two M2 source families.

    Kept in one place so a caller never has to branch on a schema string in
    three different modules and get one of them wrong.
    """

    family: str
    schema_version: str
    findings_prompt_key: str
    objective_prompt_key: str


M2V1_CONTRACT = SourceContract(
    family='M2V1',
    schema_version=M2V1_SCHEMA_VERSION,
    findings_prompt_key='BDJ',
    objective_prompt_key='BDJ_OBJECTIVE',
)

M2V2_CONTRACT = SourceContract(
    family='M2V2',
    schema_version=SCHEMA_VERSION,
    findings_prompt_key=FINDINGS_PROMPT_KEY,
    objective_prompt_key=OBJECTIVE_PROMPT_KEY,
)


def resolve_source_contract(schema_version) -> SourceContract:
    """Map a packet's own ``schema_version`` to its contract, or refuse.

    Refusing an unknown schema is what stops a caller from smuggling an
    arbitrary dict through the governed route by claiming it is a projection.
    """
    if schema_version == M2V1_SCHEMA_VERSION:
        return M2V1_CONTRACT
    if schema_version == SCHEMA_VERSION:
        return M2V2_CONTRACT
    raise ConflictError('The M2 source contract is not recognised.')


# --------------------------------------------------------------------------
# Response-code meanings, resolved from the registered instrument
# --------------------------------------------------------------------------
def _registered_options(item: dict) -> dict[str, str]:
    options = (item.get('option_values') or {}).get('options') or []
    return {
        str(option['code']): option.get('label')
        for option in options
        if isinstance(option, dict) and option.get('code')
    }


def _rules(item: dict) -> dict:
    rules = (item.get('option_values') or {}).get('rules')
    return rules if isinstance(rules, dict) else {}


def _value_schema(item: dict) -> dict:
    schema = (item.get('option_values') or {}).get('value_schema')
    return schema if isinstance(schema, dict) else {}


def _meanings_from_choices(item: dict, items_by_key: dict) -> list[dict]:
    """Meanings for a SINGLE / MULTI / GEO item."""
    registered = _registered_options(item)
    rules = _rules(item)
    if registered:
        return [
            {'field': None, 'code': code, 'label': label,
             'label_source': 'REGISTERED_LABEL'}
            for code, label in registered.items()
        ]

    source_key = rules.get('source_item')
    if not source_key:
        return []
    source = items_by_key.get(str(source_key))
    if source is None:
        # A derived item whose source item is absent cannot be explained; an
        # empty list is honest, inventing labels is not.
        return []
    excluded = {str(code) for code in (rules.get('exclude') or [])}
    meanings = []
    for code, label in _registered_options(source).items():
        if code in excluded and not (
                code == 'UNDECIDED' and rules.get('allow_undecided')):
            continue
        meanings.append({'field': None, 'code': code, 'label': label,
                         'label_source': 'DERIVED_SOURCE_ITEM'})
    return meanings


def _meanings_from_schema(item: dict, items_by_key: dict) -> list[dict]:
    """Meanings for a COMPOSITE item, per declared field."""
    schema = _value_schema(item)
    meanings: list[dict] = []
    for field in schema.get('fields') or []:
        if not isinstance(field, dict):
            continue
        name = field.get('name')
        if not name:
            continue
        kind = field.get('type')
        if kind == 'ENUM':
            for code in field.get('values') or []:
                # The instrument registers the code itself and no separate
                # label, so the code *is* the registered meaning. Saying so is
                # more accurate than inventing prose for it.
                meanings.append({'field': name, 'code': str(code),
                                 'label': str(code),
                                 'label_source': 'REGISTERED_ENUM_CODE'})
        elif kind == 'MULTI' and field.get('values'):
            for code in field.get('values') or []:
                meanings.append({'field': name, 'code': str(code),
                                 'label': str(code),
                                 'label_source': 'REGISTERED_ENUM_CODE'})
        elif kind == 'MULTI' and field.get('values_from'):
            source = items_by_key.get(str(field['values_from']))
            if source is None:
                continue
            for code, label in _registered_options(source).items():
                meanings.append({'field': name, 'code': code, 'label': label,
                                 'label_source': 'DERIVED_SOURCE_ITEM'})
        elif kind == 'LIST':
            for sub in field.get('item_fields') or []:
                if not isinstance(sub, dict) or sub.get('type') != 'ENUM':
                    continue
                for code in sub.get('values') or []:
                    meanings.append({'field': f'{name}.{sub.get("name")}',
                                     'code': str(code), 'label': str(code),
                                     'label_source': 'REGISTERED_ENUM_CODE'})
    return meanings


def response_meanings(item: dict, items_by_key: dict) -> list[dict]:
    """Every registered response code this item could carry, with its meaning."""
    meanings = _meanings_from_choices(item, items_by_key)
    if not meanings:
        meanings = _meanings_from_schema(item, items_by_key)
    # Stable order so the fingerprint does not depend on dict iteration.
    return sorted(meanings, key=lambda m: (str(m['field']), m['code']))


# --------------------------------------------------------------------------
# Readable rendering of the stored answer
# --------------------------------------------------------------------------
def _label_index(meanings: list[dict], field: str | None) -> dict[str, str]:
    return {m['code']: (m['label'] or m['code'])
            for m in meanings if m['field'] == field}


def _display(item: dict, state: str, value, meanings: list[dict]) -> dict:
    """Render the stored value using only registered meanings.

    Free text is passed through untouched — no trim, no collapse, no
    re-wrapping — because the findings prompt requires an exact substring quote
    from ``value``, and a normalised rendering would tempt a model to quote
    something the stored value does not contain.
    """
    if state == NOT_ANSWERED:
        return {'kind': 'NOT_ANSWERED', 'text': None, 'fields': []}

    kind = item.get('answer_kind')
    if kind in {'SINGLE', 'GEO'}:
        if isinstance(value, str):
            label = _label_index(meanings, None).get(value)
            return {'kind': 'CODE', 'text': label or value,
                    'fields': [{'field': None, 'code': value, 'label': label}]}
        return {'kind': 'CODE', 'text': None, 'fields': []}

    if kind == 'MULTI':
        if isinstance(value, list):
            index = _label_index(meanings, None)
            fields = [{'field': None, 'code': str(code),
                       'label': index.get(str(code))} for code in value]
            return {'kind': 'CODES',
                    'text': '; '.join(str(f['label'] or f['code']) for f in fields),
                    'fields': fields}
        return {'kind': 'CODES', 'text': None, 'fields': []}

    if kind == 'COMPOSITE' and isinstance(value, dict):
        fields = []
        parts = []
        for name in sorted(value):
            raw = value[name]
            index = _label_index(meanings, name)
            if isinstance(raw, str) and raw in index:
                fields.append({'field': name, 'code': raw, 'label': index[raw]})
                parts.append(f'{name}: {index[raw]}')
            elif isinstance(raw, list) and all(isinstance(v, str) for v in raw):
                codes = [{'field': name, 'code': v, 'label': index.get(v)}
                         for v in raw]
                fields.extend(codes)
                parts.append(f'{name}: ' + ', '.join(
                    str(c['label'] or c['code']) for c in codes))
            elif isinstance(raw, list):
                # A list of sub-objects (products, segments). Rendered as data,
                # never interpreted.
                parts.append(f'{name}: {len(raw)} entr' +
                             ('y' if len(raw) == 1 else 'ies'))
            else:
                parts.append(f'{name}: {raw}')
        return {'kind': 'COMPOSITE', 'text': ' | '.join(parts), 'fields': fields}

    # A free-text or numeric item with no code vocabulary.
    return {'kind': 'VALUE', 'text': None if value is None else str(value),
            'fields': []}


# --------------------------------------------------------------------------
# Projection
# --------------------------------------------------------------------------
class M2V2SourceProjection:
    """Read one confirmed M2 V2 revision as a detached, version-bound packet."""

    def __init__(self, repository):
        self.repo = repository

    def read(self, assessment_id: UUID, actor_id: UUID,
             expected_revision: int) -> dict:
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError('Assessment not found.')
            if assessment['revision'] != expected_revision:
                raise ConflictError(
                    'Your business details changed. Reload before reviewing.')
            instrument = self.repo.get_instrument(assessment['instrument_id'])
            items = self.repo.list_items(assessment['instrument_id'])
            answers = self.repo.get_latest_answers(assessment_id, expected_revision)
            return build_packet(
                assessment=assessment, instrument=instrument, items=items,
                answers=answers, assessment_id=assessment_id,
                expected_revision=expected_revision)
        finally:
            self.repo.rollback()


def build_packet(*, assessment: dict, instrument: dict | None, items: list,
                 answers: dict, assessment_id: UUID,
                 expected_revision: int) -> dict:
    """Build the V2 packet from already-read rows.

    Separated from ``read`` so the single M2 projector can dispatch on the
    instrument version without a second round of repository reads, and so this
    function can be exercised against fixed fixtures.
    """
    if instrument is None or instrument['version_tag'] != M2V2_VERSION:
        raise ConflictError(
            'An M2 V2 instrument version is required for this source.')
    # The single audited gate. Never compares approval_state directly, so
    # PROPOSED_NOT_AUTHORIZED stays stored and unmodified.
    if not instrument_is_usable(instrument):
        raise ConflictError(
            'The M2 V2 instrument version is not usable in this scope.')

    item_map = {item['item_key']: item for item in items}
    if len(item_map) != len(items) or not items:
        raise ConflictError('M2 item definitions could not be verified.')
    if set(item_map) != M2V2_ITEMS:
        # Exactly 19 registered keys: a partial or padded instrument would
        # silently change what the model is asked to review.
        raise ConflictError(
            'The M2 V2 instrument does not contain the registered items.')

    resolved_map = {item['item_key']: item
                    for item in resolve_m2_items(items, answers)}

    declarations = []
    for item in sorted(items, key=lambda i: (i.get('sort_order', 0),
                                             i['item_key'])):
        key = item['item_key']
        if item['lifecycle'] != 'ACTIVE':
            continue
        if item['answer_kind'] == 'ACTION':
            continue
        answer = answers.get(key)
        if answer is None:
            state, value = NOT_ANSWERED, None
            answer_revision_id = None
            answer_revision = None
        else:
            if (answer['assessment_id'] != assessment_id or
                    answer['item_version_id'] != item['id'] or
                    not 0 < answer['assessment_revision'] <= expected_revision):
                raise ConflictError('M2 answer versions could not be verified.')
            state = answer['answer_state']
            value = answer['value_json']
            answer_revision_id = str(answer['id'])
            answer_revision = answer['assessment_revision']
            resolved = resolved_map.get(key, item)
            if resolved.get('applicable') is not False:
                validate_m2_answer(resolved, state, value)

        meanings = response_meanings(item, item_map)
        declarations.append({
            'item_key': key,
            'question': item['question_text'],
            'item_version_id': str(item['id']),
            'definition_digest': digest({
                k: str(v) if isinstance(v, UUID) else v
                for k, v in item.items()}),
            'answer_revision_id': answer_revision_id,
            'answer_revision': answer_revision,
            'answer_state': state,
            'value': value,
            'answer_display': _display(item, state, value, meanings),
            'answer_kind': item['answer_kind'],
            'requiredness': item['requiredness'],
            'response_meanings': meanings,
            'trust_class': 'ENTREPRENEUR_DECLARED',
        })

    answered = sum(1 for d in declarations
                   if d['answer_state'] != NOT_ANSWERED)
    packet = {
        'schema_version': SCHEMA_VERSION,
        'assessment_id': str(assessment_id),
        'assessment_revision': expected_revision,
        'instrument_id': str(instrument['id']),
        'instrument_version': instrument['version_tag'],
        'instrument_digest': instrument['schema_digest'],
        'instrument_authorization': {
            'state': instrument['approval_state'],
            'usable': True,
            'basis': 'SYNTHETIC_SCOPE' if instrument['approval_state']
                     != 'AUTHORIZED' else 'AUTHORIZED',
        },
        'declarations': declarations,
        'declaration_count': len(declarations),
        'answered_count': answered,
        'unanswered_count': len(declarations) - answered,
        'governance_items': [],
        'excluded_items': {},
        'confirmed': assessment['confirmed_revision'] == expected_revision,
        'facts_independently_verified': False,
        # Stated in-band so a model cannot mistake a declaration for verified
        # evidence, and so a reader can see the boundary without consulting
        # another document.
        'evidence_boundary': (
            'Entrepreneur declarations only. No demand, willingness to pay, '
            'profitability, market size or viability is established by this '
            'source.'),
    }
    projection = {**packet, 'source_fingerprint': digest(packet)}
    return _detached(projection)


def _detached(value):
    """Deep copy through JSON so no ORM object can leak into a packet."""
    import json
    return json.loads(json.dumps(value, ensure_ascii=False, allow_nan=False,
                                 default=str))


def verify_m2v2_projection(packet: dict) -> None:
    """Recompute the fingerprint and membership from the packet alone."""
    if not isinstance(packet, dict) or packet.get('schema_version') != SCHEMA_VERSION:
        raise ConflictError('M2 V2 source contract mismatch.')
    content = {k: v for k, v in packet.items() if k != 'source_fingerprint'}
    if digest(content) != packet.get('source_fingerprint'):
        raise ConflictError('M2 V2 source fingerprint mismatch.')
    declarations = packet.get('declarations')
    if not isinstance(declarations, list) or len(declarations) != len(M2V2_ITEMS):
        raise ConflictError('M2 V2 source membership mismatch.')
    keys = [d.get('item_key') for d in declarations]
    if len(set(keys)) != len(keys) or set(keys) != M2V2_ITEMS:
        raise ConflictError('M2 V2 source membership mismatch.')
    for row in declarations:
        if row.get('answer_state') == NOT_ANSWERED:
            if (row.get('answer_revision_id') is not None
                    or row.get('answer_revision') is not None
                    or row.get('value') is not None):
                # An unanswered item may not carry an invented answer.
                raise ConflictError('M2 V2 source contains an invented answer.')
        elif (not isinstance(row.get('answer_revision_id'), str)
              or not isinstance(row.get('answer_revision'), int)):
            raise ConflictError('M2 V2 source is missing an answer revision.')
