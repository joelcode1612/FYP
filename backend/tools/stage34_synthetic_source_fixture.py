"""Regenerate the explicitly synthetic BDJ source packet used by stage 3/4 tests.

Why this script exists
----------------------
``artifacts/stage34_integration_20261119/bdj_v101_synthetic_source.json`` was
never tracked by Git (``git log --all -- <path>`` is empty), so it cannot be
restored from history. It is also *not* recoverable by copying
``backend/var/e2e/src.json``: that file is a real ``ENTREPRENEUR_DECLARED``
packet for assessment ``e0124bfd…`` and writing it under a name that says
``synthetic`` would mislabel entrepreneur data as non-human and cross the
disclosure boundary this project spends most of its effort defending.

So the fixture is rebuilt here from two things that are not entrepreneur data:

* the **instrument definition** (``instruments/m2v1_20261114/definition.json``)
  — product content: item keys, question text, answer kinds, option codes;
* **synthetic answers** — the first option code of each item (the first two for
  multi-select), and a fixed placeholder for the two conditional items that have
  no option set of their own.

Every declaration is stamped ``SYNTHETIC_NONHUMAN`` and every identifier is a
UUIDv5 derived from the item key, so re-running this script produces byte-identical
output and the fixture is reproducible from the repository alone.

The test that consumes it (``tests/project1/test_bdj_source_request_completeness.py``)
asserts a *structural* property: that the real prompt and payload builder project
all eleven declarations back out unchanged. It makes no claim about any
entrepreneur, and this fixture makes none either.

Usage:
    backend/.venv/Scripts/python.exe tools/stage34_synthetic_source_fixture.py
    backend/.venv/Scripts/python.exe tools/stage34_synthetic_source_fixture.py --check
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import uuid
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
INSTRUMENT = BACKEND / 'src/sitewise/instruments/m2v1_20261114/definition.json'
TARGET = (REPO / 'artifacts/stage34_integration_20261119'
          / 'bdj_v101_synthetic_source.json')

#: Fixed namespace so the fixture's identifiers are stable across regenerations.
NAMESPACE = uuid.UUID('5f2a6d1e-0000-4000-8000-000000000000')
TRUST_CLASS = 'SYNTHETIC_NONHUMAN'

#: The eleven declaration items. M2-20/M2-21 are ACTION items, not declarations.
DECLARATION_ITEMS = tuple(f'M2V1-{n:02d}' for n in range(1, 12))

#: Items whose option set is empty in the instrument (they are conditional on
#: M2V1-04 and are answered with a reference, not a code).
PLACEHOLDER_VALUES = {
    'M2V1-05': 'SYNTHETIC_PRIMARY_GROUP',
    'M2V1-10': 'SYNTHETIC_PRIMARY_PRIORITY',
}


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(',', ':'),
                      ensure_ascii=False)


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def _value_for(item: dict) -> object:
    options = ((item.get('option_values') or {}).get('options') or [])
    codes = [str(o['code']) for o in options if o.get('code')]
    if item['item_key'] in PLACEHOLDER_VALUES:
        return PLACEHOLDER_VALUES[item['item_key']]
    if not codes:
        raise SystemExit(f"{item['item_key']} has no options and no placeholder")
    if item['answer_kind'] == 'MULTI':
        return codes[:2]
    return codes[0]


def build() -> dict:
    definition = json.loads(INSTRUMENT.read_text(encoding='utf-8-sig'))
    by_key = {item['item_key']: item for item in definition['items']}
    missing = [k for k in DECLARATION_ITEMS if k not in by_key]
    if missing:
        raise SystemExit(f'instrument is missing declaration items: {missing}')

    declarations = []
    for key in DECLARATION_ITEMS:
        item = by_key[key]
        declarations.append({
            'item_key': key,
            'question': item['question_text'],
            'item_version_id': str(uuid.uuid5(NAMESPACE, f'item-version:{key}')),
            'definition_digest': _sha256(_canonical(item)),
            'answer_revision_id': str(uuid.uuid5(NAMESPACE, f'answer-revision:{key}')),
            'answer_revision': 1,
            'answer_state': 'ANSWERED',
            'value': _value_for(item),
            'trust_class': TRUST_CLASS,
        })

    governance = [k for k, item in by_key.items()
                  if item['requiredness'] == 'ACTION']
    packet = {
        'schema_version': 'project1-m2-projection/1-candidate',
        'assessment_id': str(uuid.uuid5(NAMESPACE, 'assessment')),
        'assessment_revision': 1,
        'instrument_id': str(uuid.uuid5(NAMESPACE, 'instrument')),
        'instrument_version': definition['version_tag'],
        'instrument_digest': _sha256(_canonical(definition)),
        'declarations': declarations,
        'governance_items': governance,
        'excluded_items': [],
        'confirmed': True,
        'facts_independently_verified': False,
    }
    packet['source_fingerprint'] = _sha256(_canonical(packet))
    packet['confirmation'] = {
        'confirmation_id': str(uuid.uuid5(NAMESPACE, 'confirmation')),
        'snapshot_digest': _sha256(_canonical(declarations)),
    }
    return {'packet': packet}


def render() -> str:
    return json.dumps(build(), indent=2, ensure_ascii=False) + '\n'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true',
                        help='exit 1 if the file on disk differs from a rebuild')
    args = parser.parse_args()

    text = render()
    if args.check:
        if not TARGET.exists():
            print(f'MISSING {TARGET}')
            return 1
        current = TARGET.read_text(encoding='utf-8')
        if current != text:
            print(f'STALE   {TARGET}')
            return 1
        print(f'OK      {TARGET} ({len(text)} bytes)')
        return 0

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(text, encoding='utf-8')
    packet = json.loads(text)['packet']
    print(f'wrote {TARGET} ({len(text)} bytes)')
    print(f"  declarations : {len(packet['declarations'])}")
    print(f"  trust_class  : {packet['declarations'][0]['trust_class']}")
    print(f"  fingerprint  : {packet['source_fingerprint']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
