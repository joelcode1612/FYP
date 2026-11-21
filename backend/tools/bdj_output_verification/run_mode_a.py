"""Mode A — deterministic BDJ information-gap output verification (offline).

Purpose
    Produce the serialised input, the evaluated output and the validation
    evidence for ONE complete synthetic M2V1 questionnaire, firing all three
    proposed information-gap rules.

What this does NOT do
    No provider call, no network, no database, no persistence, no approval.
    The confirmation block below is a SYNTHETIC FIXTURE IDENTITY, not a row in
    any confirmation table. ``validate_information_gap_trial_v101`` explicitly
    cannot establish confirmation ownership or existence from a client value,
    so this run proves the rule engine and the output contract, NOT that a real
    confirmed source authorised it. The connected run must establish that
    separately.

Run
    backend/.venv/Scripts/python.exe -B tools/bdj_output_verification/run_mode_a.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from uuid import NAMESPACE_URL, UUID, uuid5

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src'))
sys.path.insert(0, str(ROOT))

from sitewise.project1.bdj import BDJEngine, SYNTHETIC_M2V1_RULESET, SYNTHETIC_M2V1_RULESET_SHA256
from sitewise.project1.bdj_discovery_candidate import (
    DiscoveryOutputCandidate,
    validate_information_gap_trial_v101,
)
from sitewise.project1.contracts import digest
from sitewise.project1.m2v1_inventory_candidate import inventory
from sitewise.project1.projection import M2V1_ITEMS, M2V1_VERSION

# ---------------------------------------------------------------------------
# 1. Registered definition, read from the adopted static artifact (no DB).
# ---------------------------------------------------------------------------
from scripts.register_m2_v1 import definition


def _canonical(item: dict) -> dict:
    """Same canonicalisation the validator applies before hashing an item."""
    return {k: str(v) if isinstance(v, UUID) else v for k, v in item.items()}


def _digest_item(item: dict) -> str:
    return digest(_canonical(item))


# One answer per item. Chosen so that EXACTLY ONE source fires each rule:
#   rule 1 M2V1_EXPLICIT_PLANNING_UNDECIDED  <- M2V1-02 = UNDECIDED
#   rule 2 M2V1_EVIDENCE_INVENTORY_UNKNOWN   <- M2V1-08 = [UNKNOWN]
#   rule 3 M2V1_RESEARCH_PURPOSE_UNSURE      <- M2V1-11 = UNSURE
# Every other item is answered with a definite value so no extra finding
# appears. M2V1-05 and M2V1-10 are derived from M2V1-04 / M2V1-09 and must
# carry a value inside the derived allowance.
ANSWERS = {
    'M2V1-01': 'JOHOR',
    'M2V1-02': 'UNDECIDED',           # fires rule 1
    'M2V1-03': ['COFFEE'],
    'M2V1-04': ['STUDENTS'],
    'M2V1-05': 'STUDENTS',            # derived from 04
    'M2V1-06': 'QUALITY',
    'M2V1-07': 'STUDY_WORK',
    'M2V1-08': ['UNKNOWN'],           # fires rule 2
    'M2V1-09': ['CONCEPT_INTEREST'],
    'M2V1-10': 'CONCEPT_INTEREST',    # derived from 09
    'M2V1-11': 'UNSURE',              # fires rule 3
}

# The validator's required discovery_signal per rule. `propose()` does not emit
# this field, so it is applied here and the omission is recorded as a defect.
RULE_SIGNAL = {
    'M2V1_EXPLICIT_PLANNING_UNDECIDED': 'EXPLICIT_UNCERTAINTY',
    'M2V1_EVIDENCE_INVENTORY_UNKNOWN': 'EVIDENCE_LIMITATION',
    'M2V1_RESEARCH_PURPOSE_UNSURE': 'EXPLICIT_UNCERTAINTY',
}


def build_packet(items: list[dict]) -> tuple[dict, dict]:
    by_key = {item['item_key']: item for item in items if item['item_key'] in M2V1_ITEMS}
    if set(by_key) != M2V1_ITEMS:
        raise SystemExit(f'inventory mismatch: {sorted(M2V1_ITEMS - set(by_key))} missing')

    declarations = []
    for key in sorted(by_key):
        item = by_key[key]
        declarations.append({
            'item_key': key,
            'question': item['question_text'],
            'item_version_id': str(item['id']),
            'definition_digest': _digest_item(item),
            'answer_revision_id': f'answer-{key}-r11',
            'answer_revision': 11,
            'answer_state': 'ANSWERED',
            'value': ANSWERS[key],
            'trust_class': 'ENTREPRENEUR_DECLARED',
        })

    packet = {
        'schema_version': 'project1-m2-projection/1-candidate',
        'assessment_id': str(uuid5(NAMESPACE_URL, 'bdj-mode-a-assessment')),
        'assessment_revision': 11,
        'instrument_id': str(items[0]['instrument_id']),
        'instrument_version': M2V1_VERSION,
        'instrument_digest': '0' * 64,
        'declarations': declarations,
        # SYNTHETIC FIXTURE ONLY. Not a persisted confirmation row. The offline
        # validator cannot verify existence or ownership from these values.
        'confirmation': {
            'confirmation_id': str(uuid5(NAMESPACE_URL, 'bdj-mode-a-confirmation')),
            'snapshot_digest': 'a' * 64,
            'identity_provenance': 'SYNTHETIC_FIXTURE_NOT_A_PERSISTED_CONFIRMATION',
        },
        'confirmed': True,
        'facts_independently_verified': False,
        'data_class': 'SYNTHETIC_NONHUMAN',
        'purpose': 'SYNTHETIC_BDJ_DIAGNOSTIC',
        'governance_items': ['M2-20', 'M2-21'],
        'excluded_items': {},
    }
    packet['source_fingerprint'] = digest(packet)
    return packet, by_key


def main() -> int:
    out = ROOT.parent / 'artifacts/stage34_integration_20261121/bdj_output_mode_a'
    out.mkdir(parents=True, exist_ok=True)

    data, schema_digest, iid, rows = definition()
    packet, by_key = build_packet(rows)

    # ---- 2. Verified 11-item inventory -----------------------------------
    answers_for_inventory = {
        d['item_key']: {'id': d['answer_revision_id'],
                        'answer_state': d['answer_state'],
                        'value_json': d['value'],
                        'assessment_revision': d['answer_revision']}
        for d in packet['declarations']
    }
    inv = inventory(rows, answers_for_inventory)

    # ---- 3. Load the exact proposed artifact and preflight the trial -----
    import importlib.util
    artifact = ROOT / 'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py'
    spec = importlib.util.spec_from_file_location('mode_a_rules', artifact)
    rules = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rules)

    engine = BDJEngine(rules)
    model_packet, _ = engine.prepare_discovery_trial(
        packet,
        item_definitions=rows,
        recheck_current=lambda: packet['source_fingerprint'],
    )
    triggered = sorted(row['rule_id'] for row in model_packet['rule_catalogue'])

    # ---- 4. Evaluate the three rules -------------------------------------
    raw = rules.propose(packet)

    # Defect probe: the proposal's own output is NOT directly admissible.
    probe = {'raw_propose_admissible': False, 'error': None}
    try:
        DiscoveryOutputCandidate.model_validate(
            {**raw, 'contract_version': 'bdj-discovery-output/1-candidate'})
        probe['raw_propose_admissible'] = True
    except Exception as exc:  # noqa: BLE001 - recorded verbatim as evidence
        probe['error'] = f'{type(exc).__name__}: {exc}'

    # ---- 5. Enrich to the candidate contract and validate ----------------
    issues = []
    for issue in raw['issues']:
        issues.append({**issue, 'discovery_signal': RULE_SIGNAL[issue['rule_id']]})
    output = {
        'contract_version': 'bdj-discovery-output/1-candidate',
        'issues': issues,
        'overall_note': raw['overall_note'],
    }
    validated = validate_information_gap_trial_v101(
        output, packet, rows, current_source_fingerprint=packet['source_fingerprint'])

    # ---- 6. Evidence -----------------------------------------------------
    (out / '01_input_packet.json').write_text(
        json.dumps(packet, indent=2, sort_keys=True, ensure_ascii=False), encoding='utf-8')
    (out / '02_evaluated_output.json').write_text(
        json.dumps(output, indent=2, sort_keys=True, ensure_ascii=False), encoding='utf-8')

    evidence = {
        'mode': 'A_DETERMINISTIC_NO_PROVIDER',
        'provider_called': False,
        'network_used': False,
        'database_used': False,
        'persistence_performed': False,
        'ruleset_version': rules.RULE_VERSION,
        'ruleset_sha256_declared': SYNTHETIC_M2V1_RULESET_SHA256,
        'ruleset_status_in_artifact': getattr(rules, 'STATUS', None),
        'ruleset_adopted_flag_in_artifact': getattr(rules, 'ADOPTED', None),
        'instrument_version': data['version_tag'],
        'instrument_schema_digest': schema_digest,
        'instrument_id': str(iid),
        'source_fingerprint': packet['source_fingerprint'],
        'inventory_fingerprint': digest(inv),
        'inventory_item_count': len(inv['items']),
        'inventory_states': {row['item_key']: row['state'] for row in inv['items']},
        'triggered_rules': triggered,
        'triggered_rule_count': len(triggered),
        'finding_count': len(validated.issues),
        'findings_by_rule': [
            {'rule_id': i.rule_id,
             'discovery_signal': i.discovery_signal,
             'source_item_key': i.source_refs[0].item_key,
             'source_answer_revision_id': i.source_refs[0].answer_revision_id,
             'source_item_version_id': i.source_refs[0].item_version_id,
             'quote': i.source_refs[0].quote}
            for i in validated.issues
        ],
        'validation': 'PASS',
        'validator': 'validate_information_gap_trial_v101',
        'defect_probe': {
            'claim': 'bdj_m2v1_information_gap_proposal.propose() emits issues without '
                     'discovery_signal, which DiscoveryFindingCandidate requires.',
            'raw_output_admissible': probe['raw_propose_admissible'],
            'error': probe['error'],
            'consequence': 'The proposal artifact cannot feed the trial contract unmodified; '
                           'a signal mapping must be supplied by the caller.',
        },
        'confirmation_identity_provenance': packet['confirmation']['identity_provenance'],
        'limits': [
            'Confirmation block is a synthetic fixture, not a persisted confirmation row.',
            'No persistence or readback performed; item 4 of the directive is NOT satisfied here.',
            'No model was called; this verifies the rule engine, not a model judgement.',
            'Ruleset adoption status is unresolved; this is a bounded synthetic trial only.',
        ],
    }
    (out / '03_validation_evidence.json').write_text(
        json.dumps(evidence, indent=2, sort_keys=True, ensure_ascii=False), encoding='utf-8')

    print(f'ruleset          : {rules.RULE_VERSION} (STATUS={getattr(rules, "STATUS", None)})')
    print(f'instrument       : {data["version_tag"]}')
    print(f'inventory        : {len(inv["items"])} items')
    print(f'triggered rules  : {len(triggered)} -> {triggered}')
    print(f'findings         : {len(validated.issues)}')
    for i in validated.issues:
        print(f'  - {i.rule_id:38s} {i.discovery_signal:22s} {i.source_refs[0].item_key}')
    print(f'validation       : PASS (validate_information_gap_trial_v101)')
    print(f'defect probe     : raw propose() admissible = {probe["raw_propose_admissible"]}')
    if probe['error']:
        print(f'                   {probe["error"][:150]}')
    print(f'evidence dir     : {out}')
    return 0 if len(triggered) == 3 and len(validated.issues) == 3 else 1


if __name__ == '__main__':
    raise SystemExit(main())
