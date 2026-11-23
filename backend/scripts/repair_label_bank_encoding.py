"""Repair the recoverable encoding defects in the contract matrix at source.

Two defect classes, both the same mechanical fault
--------------------------------------------------
A UTF-8 byte sequence was decoded as cp1252 and the resulting mojibake was then
stored as UTF-8. Because cp1252 is a single-byte encoding, each byte maps to
exactly one codepoint, so running the mapping backwards recovers the original
bytes and therefore the original character. Nothing is guessed.

* **CX-17 — en dash in option labels.** U+2013 is ``E2 80 93`` in UTF-8; read as
  cp1252 it becomes ``U+00E2 U+20AC U+201C``. Fifteen labels are affected.
* **CX-19 — e-acute in instrument wording.** U+00E9 is ``C3 A9``; read as cp1252
  it becomes ``U+00C3 U+00A9``. Eighteen wording fields are affected.

CX-19 is independently verifiable: the frozen CUST03 instrument
(``CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json``) carries the same
nine stems with ``café`` correctly encoded. The matrix is the corrupted
derivative, so the repair restores fidelity to a frozen source rather than
imposing a reading.

What this script does NOT do
----------------------------
* It does not touch question meaning, answer codes, answer order, display order,
  gate fields, or the ``draft_`` authority prefix on any label.
* It does not reformat, reorder or re-serialise the JSON. The edit is a byte
  substitution, so every byte outside the defects is preserved exactly.
* It refuses to repair a defect that appears outside the fields it understands,
  because guessing there would be unsound.
* It does not touch the frozen CUST03 instrument, the handoff package, or the
  generated registry. The registry is rebuilt afterwards by its own generator.

Usage::

    backend/.venv/Scripts/python.exe scripts/repair_label_bank_encoding.py --check
    backend/.venv/Scripts/python.exe scripts/repair_label_bank_encoding.py --apply
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent

MATRIX_PATH = BACKEND / 'docs' / 'cq_runtime' / 'QUESTION_CONTRACT_MATRIX.json'
CUST_PATH = (BACKEND / 'src' / 'sitewise' / 'customer_contracts' / 'reference'
             / 'CUST_RECOVERY_20261027'
             / 'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json')
PROVENANCE_PATH = (REPO / 'deliverables'
                   / 'PROJECT1_CX17_LABEL_ENCODING_PROVENANCE.json')
#: The preserved pre-repair copy. The provenance record is rebuilt from this.
ORIGINAL_PATH = (REPO / 'var' / 'evidence' / 'cx17_preserved'
                 / 'QUESTION_CONTRACT_MATRIX.ORIGINAL.json')


@dataclass(frozen=True)
class DefectClass:
    """One recoverable encoding defect: what it looks like and where it may live."""

    conflict_id: str
    name: str
    corrupted: str
    recovered: str
    fields: frozenset[str]

    @property
    def corrupted_bytes(self) -> bytes:
        return self.corrupted.encode('utf-8')

    @property
    def recovered_bytes(self) -> bytes:
        return self.recovered.encode('utf-8')

    def verify_premise(self) -> None:
        """The whole repair rests on this, so it is checked before every run."""
        if self.corrupted.encode('cp1252') != self.recovered_bytes:
            raise SystemExit(
                f'PREMISE FAILED ({self.conflict_id}): the corrupted form is not a '
                f'cp1252 mis-decode of {self.recovered!r}')
        if self.recovered_bytes.decode('utf-8') != self.recovered:
            raise SystemExit(
                f'PREMISE FAILED ({self.conflict_id}): the recovered bytes are not '
                f'{self.recovered!r}')


#: En dash in draft option labels (CX-17).
EN_DASH = DefectClass(
    conflict_id='CX-17',
    name='en dash in option labels',
    corrupted='\u00e2\u20ac\u201c',
    recovered='\u2013',
    fields=frozenset({'draft_en_label', 'draft_bm_label'}),
)

#: E-acute in instrument wording (CX-19).
E_ACUTE = DefectClass(
    conflict_id='CX-19',
    name='e-acute in instrument wording',
    corrupted='\u00c3\u00a9',
    recovered='\u00e9',
    fields=frozenset({'wording_source', 'wording_test_EN'}),
)

CLASSES = (EN_DASH, E_ACUTE)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def find_defects(payload, classes=CLASSES) -> list[dict]:
    """Every string field containing a known corruption, with its JSON path."""
    out: list[dict] = []

    def walk(node, path: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, f'{path}/{key}')
        elif isinstance(node, list):
            for i, value in enumerate(node):
                walk(value, f'{path}[{i}]')
        elif isinstance(node, str):
            field = path.rsplit('/', 1)[-1]
            for cls in classes:
                if cls.corrupted in node:
                    out.append({
                        'conflict_id': cls.conflict_id,
                        'class_name': cls.name,
                        'path': path,
                        'field': field,
                        'occurrences': node.count(cls.corrupted),
                        'before': node,
                        'after': node.replace(cls.corrupted, cls.recovered),
                        'recoverable': field in cls.fields,
                    })

    walk(payload, '')
    return out


def structural_diff(before, after) -> list[str]:
    """Every difference between two parsed documents, as dotted paths."""
    diffs: list[str] = []

    def walk(a, b, path: str) -> None:
        if type(a) is not type(b):
            diffs.append(f'{path}: type {type(a).__name__} -> {type(b).__name__}')
            return
        if isinstance(a, dict):
            if list(a.keys()) != list(b.keys()):
                diffs.append(f'{path}: key set or key order changed')
                for key in sorted(set(a) ^ set(b)):
                    diffs.append(f'{path}/{key}: presence changed')
                return
            for key in a:
                walk(a[key], b[key], f'{path}/{key}')
        elif isinstance(a, list):
            if len(a) != len(b):
                diffs.append(f'{path}: length {len(a)} -> {len(b)}')
                return
            for i, (x, y) in enumerate(zip(a, b)):
                walk(x, y, f'{path}[{i}]')
        elif a != b:
            diffs.append(f'{path}: {a!r} -> {b!r}')

    walk(before, after, '')
    return diffs


def verify_roundtrip() -> None:
    for cls in CLASSES:
        cls.verify_premise()


def frozen_wording_check(payload) -> dict:
    """Independent confirmation for CX-19 from the frozen CUST03 instrument.

    The matrix wording is a copy of the CUST03 stem. If CUST03 carries the
    correct character and the matrix carries the mojibake, the matrix is the
    corrupted derivative and the repair restores rather than reinterprets.
    """
    if not CUST_PATH.exists():
        return {'available': False, 'reason': 'CUST03 not present'}
    cust = json.loads(CUST_PATH.read_text(encoding='utf-8'))
    stems = {item['id']: (item.get('stem') or '') for item in cust['items']}

    checked, confirmed, mismatched = 0, 0, []
    for item in payload:
        qid = item.get('question_id')
        stem = stems.get(qid)
        wording = item.get('wording_source')
        if not stem or not isinstance(wording, str):
            continue
        if E_ACUTE.corrupted not in wording:
            continue
        checked += 1
        if E_ACUTE.recovered in stem and E_ACUTE.corrupted not in stem:
            confirmed += 1
        else:
            mismatched.append(qid)

    return {
        'available': True,
        'artifact': str(CUST_PATH.relative_to(REPO)).replace('\\', '/'),
        'fields_checked': checked,
        'confirmed_by_frozen_source': confirmed,
        'mismatched': mismatched,
        'conclusion': ('the frozen instrument carries the correct character, so the '
                       'matrix is the corrupted copy'
                       if checked and confirmed == checked and not mismatched
                       else 'NOT_CONFIRMED'),
    }


def rebuild_provenance() -> int:
    """Replay the repair from the preserved original and rewrite the record.

    A cumulative record is only trustworthy if it can be regenerated. This mode
    replays each defect class in order against the preserved pre-repair copy, so
    the recorded hashes are recomputed rather than remembered.
    """
    verify_roundtrip()
    if not ORIGINAL_PATH.exists():
        print(f'cannot rebuild: {ORIGINAL_PATH} is not present', file=sys.stderr)
        return 5

    baseline = ORIGINAL_PATH.read_bytes()
    baseline_payload = json.loads(baseline.decode('utf-8'))

    steps: list[dict] = []
    current = baseline
    for cls in CLASSES:
        payload = json.loads(current.decode('utf-8'))
        defects = [d for d in find_defects(payload, (cls,))]
        if not defects:
            continue
        repaired = current.replace(cls.corrupted_bytes, cls.recovered_bytes)
        before_hash, after_hash = sha256_bytes(current), sha256_bytes(repaired)
        steps.append({
            'step': len(steps) + 1,
            'conflict_ids': [cls.conflict_id],
            'before': {'sha256': before_hash, 'bytes': len(current)},
            'after': {'sha256': after_hash, 'bytes': len(repaired)},
            'byte_delta': len(repaired) - len(current),
            'defect_count': sum(d['occurrences'] for d in defects),
            'defect_classes': [{
                'conflict_id': cls.conflict_id,
                'name': cls.name,
                'corrupted_codepoints': [f'U+{ord(c):04X}' for c in cls.corrupted],
                'corrupted_utf8_bytes': cls.corrupted_bytes.hex(),
                'intended_codepoint': f'U+{ord(cls.recovered):04X}',
                'intended_utf8_bytes': cls.recovered_bytes.hex(),
                'cp1252_roundtrip': cls.corrupted.encode('cp1252').hex(),
                'fields': sorted({d['field'] for d in defects}),
                'occurrences': sum(d['occurrences'] for d in defects),
            }],
            'fields_repaired': [
                {'conflict_id': cls.conflict_id, 'path': d['path'],
                 'field': d['field'], 'before': d['before'], 'after': d['after']}
                for d in defects
            ],
            'structural_diff': structural_diff(payload, json.loads(repaired.decode('utf-8'))),
        })
        current = repaired

    live = MATRIX_PATH.read_bytes()
    if sha256_bytes(current) != sha256_bytes(live):
        print('REFUSED: replaying the repair does not reproduce the live file; '
              'the record would be false', file=sys.stderr)
        return 6

    all_classes: dict[str, dict] = {}
    for s in steps:
        for c in s['defect_classes']:
            all_classes[c['conflict_id']] = c

    provenance = {
        'artifact': 'PROJECT1_CX17_LABEL_ENCODING_PROVENANCE',
        'target': str(MATRIX_PATH.relative_to(REPO)).replace('\\', '/'),
        'conflict_ids': sorted(all_classes),
        'original': {'sha256': sha256_bytes(baseline), 'bytes': len(baseline)},
        'current': {'sha256': sha256_bytes(live), 'bytes': len(live)},
        'byte_delta_total': len(live) - len(baseline),
        'steps': steps,
        'defect_classes': [all_classes[k] for k in sorted(all_classes)],
        'frozen_wording_confirmation': frozen_wording_check(baseline_payload),
        'preserved_unchanged': [
            'question meaning', 'answer codes', 'answer order', 'display_order',
            'draft_ authority prefix on every label', 'max_selections',
            'exclusive_codes', 'gate fields', 'classification',
            'owner_authorization', 'fielding', 'all non-defective bytes',
        ],
        'authority_unchanged': {
            'labels': 'DRAFT option wording, not approved',
            'wording': 'LANGUAGE-CANDIDATE-01, classification CANDIDATE, '
                       'PRODUCTION_FIELDING_HOLD',
        },
        'rebuildable_by': ('scripts/repair_label_bank_encoding.py '
                           '--rebuild-provenance'),
        'note': ('Repairing an encoding defect changes no meaning and grants no '
                 'approval. The repaired labels remain draft option wording and '
                 'the repaired wording remains a language candidate.'),
    }
    PROVENANCE_PATH.write_text(
        json.dumps(provenance, indent=2, ensure_ascii=False, sort_keys=True) + '\n',
        encoding='utf-8')

    print(f'rebuilt  : {len(steps)} step(s) replayed from the preserved original')
    for s in steps:
        print(f'  step {s["step"]}: {s["conflict_ids"]} '
              f'{s["before"]["sha256"][:12]}… -> {s["after"]["sha256"][:12]}… '
              f'({s["defect_count"]} occurrences, {s["byte_delta"]} bytes)')
    print(f'current  : {sha256_bytes(live)}')
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--check', action='store_true',
                       help='report the defect count and exit non-zero if any remain')
    group.add_argument('--apply', action='store_true',
                       help='rewrite the contract matrix with only the defects repaired')
    group.add_argument('--rebuild-provenance', action='store_true',
                       help='replay the repair from the preserved original and '
                            'rewrite the provenance record')
    args = parser.parse_args(argv)

    if args.rebuild_provenance:
        return rebuild_provenance()

    verify_roundtrip()

    original = MATRIX_PATH.read_bytes()
    before_hash = sha256_bytes(original)
    before = json.loads(original.decode('utf-8'))
    defects = find_defects(before)
    unrecoverable = [d for d in defects if not d['recoverable']]

    if unrecoverable:
        print('REFUSED: a corruption appears outside the fields this script '
              'understands, where it must not guess:', file=sys.stderr)
        for d in unrecoverable:
            print(f'  {d["conflict_id"]} {d["path"]} ({d["field"]})', file=sys.stderr)
        return 2

    total = sum(d['occurrences'] for d in defects)
    by_class: dict[str, int] = {}
    for d in defects:
        by_class[d['conflict_id']] = by_class.get(d['conflict_id'], 0) + d['occurrences']

    print(f'source       : {MATRIX_PATH.relative_to(REPO)}')
    print(f'sha256       : {before_hash}')
    print(f'bytes        : {len(original)}')
    print(f'defect fields: {len(defects)}  occurrences: {total}  by class: {by_class}')
    for d in defects:
        print(f'  {d["conflict_id"]} {d["field"]:16s} {d["path"]:40s} '
              f'{d["before"][:48]!r}')

    wording = frozen_wording_check(before)
    print(f'frozen check : {wording.get("conclusion")} '
          f'({wording.get("confirmed_by_frozen_source", 0)}/'
          f'{wording.get("fields_checked", 0)})')

    if args.check:
        return 0 if total == 0 else 1

    if total == 0:
        print('nothing to repair: the contract matrix is already clean')
        return 0

    repaired_bytes = original
    for cls in CLASSES:
        repaired_bytes = repaired_bytes.replace(cls.corrupted_bytes,
                                                cls.recovered_bytes)
    for cls in CLASSES:
        if repaired_bytes.count(cls.corrupted_bytes) != 0:
            print(f'REFUSED: substitution was incomplete for {cls.conflict_id}',
                  file=sys.stderr)
            return 3

    # The corrupted form is always the longer of the two (the mojibake expands
    # each byte), so the file must shrink by exactly this many bytes.
    expected_shrink = sum(
        d['occurrences'] * (len(c.corrupted_bytes) - len(c.recovered_bytes))
        for d in defects
        for c in CLASSES
        if c.conflict_id == d['conflict_id'])
    if len(original) - len(repaired_bytes) != expected_shrink:
        print(f'REFUSED: byte shrink {len(original) - len(repaired_bytes)} does not '
              f'match the expected {expected_shrink}', file=sys.stderr)
        return 3

    after_hash = sha256_bytes(repaired_bytes)
    after = json.loads(repaired_bytes.decode('utf-8'))
    diffs = structural_diff(before, after)

    expected_paths = {d['path'] for d in defects}
    unexpected = [x for x in diffs if x.split(':')[0] not in expected_paths]
    if unexpected:
        print('REFUSED: the repair changed something it should not have:',
              file=sys.stderr)
        for x in unexpected[:20]:
            print(f'  {x}', file=sys.stderr)
        return 4
    if len(diffs) != len(defects):
        print(f'REFUSED: {len(diffs)} structural changes for {len(defects)} defects',
              file=sys.stderr)
        return 4

    MATRIX_PATH.write_bytes(repaired_bytes)

    classes_record = []
    for cls in CLASSES:
        mine = [d for d in defects if d['conflict_id'] == cls.conflict_id]
        if not mine:
            continue
        classes_record.append({
            'conflict_id': cls.conflict_id,
            'name': cls.name,
            'corrupted_codepoints': [f'U+{ord(c):04X}' for c in cls.corrupted],
            'corrupted_utf8_bytes': cls.corrupted_bytes.hex(),
            'intended_codepoint': f'U+{ord(cls.recovered):04X}',
            'intended_utf8_bytes': cls.recovered_bytes.hex(),
            'cp1252_roundtrip': cls.corrupted.encode('cp1252').hex(),
            'recoverable_because': ('cp1252 is single-byte, so each byte identifies '
                                    'exactly one codepoint; the recovered byte '
                                    'sequence has exactly one UTF-8 reading'),
            'fields': sorted({d['field'] for d in mine}),
            'occurrences': sum(d['occurrences'] for d in mine),
        })

    step = {
        'conflict_ids': sorted({c['conflict_id'] for c in classes_record}),
        'before': {'sha256': before_hash, 'bytes': len(original)},
        'after': {'sha256': after_hash, 'bytes': len(repaired_bytes)},
        'byte_delta': len(repaired_bytes) - len(original),
        'defect_count': total,
        'defect_classes': classes_record,
        'fields_repaired': [
            {'conflict_id': d['conflict_id'], 'path': d['path'],
             'field': d['field'], 'before': d['before'], 'after': d['after']}
            for d in defects
        ],
        'frozen_wording_confirmation': wording,
        'structural_diff': diffs,
    }

    # The record is cumulative: a later repair must not erase the history of an
    # earlier one, or the original baseline hash would be lost.
    previous = {}
    if PROVENANCE_PATH.exists():
        try:
            previous = json.loads(PROVENANCE_PATH.read_text(encoding='utf-8'))
        except (json.JSONDecodeError, OSError):
            previous = {}
    steps = list(previous.get('steps') or [])
    if not steps and previous.get('before') and previous.get('after'):
        # adopt a pre-steps record as step 1 so nothing is silently dropped
        steps = [{'conflict_ids': previous.get('conflict_ids', ['CX-17']),
                  'before': previous['before'], 'after': previous['after'],
                  'byte_delta': previous.get('byte_delta'),
                  'defect_count': previous.get('defect_count'),
                  'defect_classes': previous.get('defect_classes', []),
                  'fields_repaired': previous.get('fields_repaired', []),
                  'frozen_wording_confirmation': previous.get(
                      'frozen_wording_confirmation'),
                  'structural_diff': previous.get('structural_diff', [])}]
    steps.append(step)
    for i, s in enumerate(steps, start=1):
        s['step'] = i

    original_record = previous.get('original') or steps[0]['before']
    all_classes: dict[str, dict] = {}
    for s in steps:
        for c in s.get('defect_classes') or []:
            all_classes[c['conflict_id']] = c

    provenance = {
        'artifact': 'PROJECT1_CX17_LABEL_ENCODING_PROVENANCE',
        'target': str(MATRIX_PATH.relative_to(REPO)).replace('\\', '/'),
        'conflict_ids': sorted(all_classes),
        'original': original_record,
        'current': {'sha256': after_hash, 'bytes': len(repaired_bytes)},
        'byte_delta_total': len(repaired_bytes) - original_record['bytes'],
        'steps': steps,
        'defect_classes': [all_classes[k] for k in sorted(all_classes)],
        'preserved_unchanged': [
            'question meaning', 'answer codes', 'answer order', 'display_order',
            'draft_ authority prefix on every label', 'max_selections',
            'exclusive_codes', 'gate fields', 'classification',
            'owner_authorization', 'fielding', 'all non-defective bytes',
        ],
        'authority_unchanged': {
            'labels': 'DRAFT option wording, not approved',
            'wording': 'LANGUAGE-CANDIDATE-01, classification CANDIDATE, '
                       'PRODUCTION_FIELDING_HOLD',
        },
        'note': ('Repairing an encoding defect changes no meaning and grants no '
                 'approval. The repaired labels remain draft option wording and '
                 'the repaired wording remains a language candidate.'),
    }
    PROVENANCE_PATH.write_text(
        json.dumps(provenance, indent=2, ensure_ascii=False, sort_keys=True) + '\n',
        encoding='utf-8')

    print()
    print(f'repaired     : {total} occurrences in {len(defects)} fields')
    print(f'after sha256 : {after_hash}')
    print(f'byte delta   : {len(repaired_bytes) - len(original)}')
    print(f'provenance   : {PROVENANCE_PATH.relative_to(REPO)}')
    print('remaining    : 0')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
