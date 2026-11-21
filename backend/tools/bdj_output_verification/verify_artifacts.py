"""Independent verification of the BDJ Mode A connected artefacts.

Deliberately does NOT import the project under test, the test module, or any
helper it used. Everything is re-derived here from the four delivered JSON
files, with the canonicalisation and digest reimplemented locally. That way a
disagreement between "the test asserted it" and "the artefact says it" shows up
instead of being hidden by shared code.

Run:
    backend/.venv/Scripts/python.exe -B tools/bdj_output_verification/verify_artifacts.py \
        [evidence_dir]
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

APPROVED = {
    'M2V1_EXPLICIT_PLANNING_UNDECIDED': 'EXPLICIT_UNCERTAINTY',
    'M2V1_EVIDENCE_INVENTORY_UNKNOWN': 'EVIDENCE_LIMITATION',
    'M2V1_RESEARCH_PURPOSE_UNSURE': 'EXPLICIT_UNCERTAINTY',
}
EXPECTED_ITEMS = [f'M2V1-{n:02d}' for n in range(1, 12)]


def canonical(value) -> str:
    """Same canonical form the project uses, reimplemented independently."""
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'), allow_nan=False)


def digest(value) -> str:
    return hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()


class Checks:
    def __init__(self):
        self.rows: list[tuple[str, bool, str]] = []

    def check(self, name: str, ok: bool, detail: str = '') -> None:
        self.rows.append((name, bool(ok), detail))

    def report(self) -> bool:
        width = max(len(n) for n, _, _ in self.rows)
        for name, ok, detail in self.rows:
            print(f'{"PASS" if ok else "FAIL"}  {name.ljust(width)}  {detail}')
        passed = sum(1 for _, ok, _ in self.rows if ok)
        print(f'\n{passed}/{len(self.rows)} checks passed')
        return passed == len(self.rows)


def main(argv: list[str]) -> int:
    here = Path(__file__).resolve()
    default = here.parents[2].parent / 'artifacts/stage34_integration_20261121/g2_output_connected'
    ev = Path(argv[1]).resolve() if len(argv) > 1 else default

    required = ['01_input_packet.json', '02_evaluated_output.json',
                '03_database_evidence.json', '04_readback_comparison.json']
    missing = [f for f in required if not (ev / f).is_file()]
    if missing:
        print('MISSING ARTEFACTS: ' + ', '.join(missing))
        return 2

    packet = json.loads((ev / '01_input_packet.json').read_text(encoding='utf-8'))
    output = json.loads((ev / '02_evaluated_output.json').read_text(encoding='utf-8'))
    db = json.loads((ev / '03_database_evidence.json').read_text(encoding='utf-8'))
    cmp_ = json.loads((ev / '04_readback_comparison.json').read_text(encoding='utf-8'))

    c = Checks()

    # ---- input -----------------------------------------------------------
    decls = {d['item_key']: d for d in packet.get('declarations', [])}
    c.check('input: 11 declarations', len(decls) == 11, str(len(decls)))
    c.check('input: item set is M2V1-01..11', sorted(decls) == EXPECTED_ITEMS)
    c.check('input: instrument version', packet.get('instrument_version') == 'M2V1-20261114-1',
            str(packet.get('instrument_version')))
    c.check('input: confirmed', packet.get('confirmed') is True)
    # The projection deliberately carries no data_class. Synthetic classification
    # is established by the registered disclosure at execution time, not by a
    # field a caller could set. Asserting absence keeps that contract visible.
    c.check('input: no caller-settable data_class', 'data_class' not in packet,
            'classification comes from the registered disclosure')

    # fingerprint re-derived, not read
    content = {k: v for k, v in packet.items() if k != 'source_fingerprint'}
    c.check('input: source fingerprint recomputes',
            digest(content) == packet.get('source_fingerprint'),
            digest(content)[:16] + '…')

    # ---- output ----------------------------------------------------------
    issues = output.get('issues', [])
    c.check('output: contract version',
            output.get('contract_version') == 'bdj-discovery-output/1-candidate',
            str(output.get('contract_version')))
    c.check('output: exactly 3 findings', len(issues) == 3, str(len(issues)))
    c.check('output: rule ids are the three approved',
            sorted(i['rule_id'] for i in issues) == sorted(APPROVED),
            ', '.join(sorted(i['rule_id'] for i in issues)))

    refs_ok, sig_ok, quote_ok, rev_ok = True, True, True, True
    detail_bad = []
    for i in issues:
        refs = i.get('source_refs') or []
        if len(refs) != 1:
            refs_ok = False
            detail_bad.append(f"{i['rule_id']} refs={len(refs)}")
            continue
        ref = refs[0]
        if i.get('discovery_signal') != APPROVED.get(i['rule_id']):
            sig_ok = False
            detail_bad.append(f"{i['rule_id']} signal")
        decl = decls.get(ref['item_key'])
        if decl is None:
            quote_ok = False
            detail_bad.append(f"{i['rule_id']} unknown item")
            continue
        values = decl['value'] if isinstance(decl['value'], list) else [decl['value']]
        if ref.get('quote') not in values:
            quote_ok = False
            detail_bad.append(f"{i['rule_id']} quote")
        if (ref.get('answer_revision_id') != decl.get('answer_revision_id')
                or ref.get('item_version_id') != decl.get('item_version_id')):
            rev_ok = False
            detail_bad.append(f"{i['rule_id']} revision")
    c.check('output: one source ref per finding', refs_ok, '; '.join(detail_bad))
    c.check('output: discovery_signal matches approved mapping', sig_ok)
    c.check('output: quote equals the declared value', quote_ok)
    c.check('output: refs match declaration revisions', rev_ok)

    # ---- database evidence ----------------------------------------------
    result = db.get('result', {})
    c.check('db: validation_status valid', result.get('validation_status') == 'valid',
            str(result.get('validation_status')))
    c.check('db: finding_count is 3', str(result.get('finding_count')) == '3',
            str(result.get('finding_count')))
    c.check('db: source fingerprint matches input',
            result.get('source_fingerprint') == packet.get('source_fingerprint'))
    c.check('db: payload is sealed', db.get('payload_sealed') is True)
    c.check('db: no plaintext findings in payload',
            db.get('payload_has_plaintext_findings') is False)

    srcs = db.get('bdj_result_sources', [])
    c.check('db: 11 source rows', len(srcs) == 11, str(len(srcs)))
    locators = [s.get('locator', '') for s in srcs]
    c.check('db: locators cover M2V1-01..11',
            sorted(x.split('@')[0] for x in locators) == EXPECTED_ITEMS)
    c.check('db: source_id equals declaration answer revision',
            sorted(s['source_id'] for s in srcs) ==
            sorted(d['answer_revision_id'] for d in decls.values()))
    c.check('db: source_version equals declaration item version',
            sorted(s['source_version'] for s in srcs) ==
            sorted(d['item_version_id'] for d in decls.values()))

    links = db.get('bdj_result_findings_count')
    c.check('db: three finding links persisted (D1)', links == 3, str(links))
    adm = db.get('classification') or {}
    ids = (db.get('admission') or {}).get('finding_ids') or []
    c.check('db: three distinct finding ids', len(set(ids)) == 3, str(len(set(ids))))
    c.check('db: authority stays candidate, no verification claimed',
            (db.get('admission') or {}).get('authority', 'candidate') == 'candidate')

    attempts = db.get('attempts', [])
    c.check('db: exactly one attempt', len(attempts) == 1, str(len(attempts)))
    if attempts:
        c.check('db: attempt stage is BDJ', attempts[0].get('stage') == 'BDJ',
                str(attempts[0].get('stage')))

    cls = db.get('classification', {})
    c.check('db: classified deterministic, not a model call',
            cls.get('output_provenance') == 'DETERMINISTIC_RULE_ENGINE'
            and cls.get('model_called') is False
            and cls.get('transport') == 'MOCKED_NO_NETWORK',
            f"{cls.get('output_provenance')} / model_called={cls.get('model_called')}")

    # ---- readback comparison --------------------------------------------
    http = cmp_.get('http_readback', [])
    dbr = cmp_.get('restricted_connection_custody_readback', [])
    c.check('readback: http and restricted connection agree', cmp_.get('match') is True)
    c.check('readback: same number of findings', len(http) == len(dbr) == 3,
            f'{len(http)}/{len(dbr)}')
    c.check('readback: tuples identical', http == dbr)
    c.check('readback: fingerprints match', cmp_.get('source_fingerprint_match') is True)
    c.check('readback: count matches output', cmp_.get('finding_count_match') is True)

    # cross-artefact: readback rule ids must equal the evaluated output
    c.check('cross: readback rule ids equal evaluated output',
            sorted(r['rule_id'] for r in http) == sorted(i['rule_id'] for i in issues))

    ok = c.report()
    print('\nVERDICT: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
