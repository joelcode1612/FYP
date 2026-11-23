"""Phase E — live ORIGINAL vs ENHANCED cloud A/B on synthetic data only.

Budget and safety contract
--------------------------
* Exactly 14 dispatches are permitted: 3 BDJ cases x 2 prompt versions, and
  4 QG cases x 2 prompt versions. The counter is checked before every call and
  the script stops rather than exceed it.
* There is NO retry path. ``TokenHarbor.complete`` raises on any non-200 and on
  an unparsable envelope; this script records the failure and moves on.
* Only synthetic declarations and synthetic confirmed facts are sent. No
  entrepreneur data, no database connection, no governed ledger, no disclosure
  gate — this is a diagnostic, exactly like the earlier authorised runs.
* The credential is read from ``backend/.env`` by ``sitewise.core.config``. It is
  never printed, hashed into evidence, or written anywhere.
* Both prompt versions use the same model, temperature, max_tokens, structured
  mode and output schema. Only the instruction text differs.

Usage (from backend/)::

    .venv/Scripts/python.exe tools/phase2_prompt_ab_cloud_20261122.py --dry-run
    .venv/Scripts/python.exe tools/phase2_prompt_ab_cloud_20261122.py --live
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

# The provider is disabled by default in this repository. Enabling it here is an
# explicit, process-scoped decision for this authorised diagnostic; .env is not
# modified. Set before sitewise.core.config is imported.
os.environ.setdefault('TOKENHARBOR_ENABLED', 'true')

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'backend' / 'src'))

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld, digest  # noqa: E402
from sitewise.project1.disclosure import QG_SCHEMA_VERSION  # noqa: E402
from sitewise.project1.objective_proposal import (  # noqa: E402
    CONTRACT_VERSION as BDJ_CONTRACT,
    ObjectiveProposal,
    validate_objective_proposal,
)
from sitewise.project1.prompts import PROMPTS, Prompt  # noqa: E402
from sitewise.project1.provider import ENDPOINT, MODEL, TokenHarbor  # noqa: E402
from sitewise.project1.qg_contract import (  # noqa: E402
    CONTRACT_VERSION as QG_CONTRACT,
    ConfirmedFacts,
    QGCandidate,
    validate_candidate,
)

# Reuse the Phase E offline module so the enhanced prompts and enhanced
# validators are defined in exactly one place.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from phase2_prompt_comparison_20261122 import (  # noqa: E402
    BDJ_ENHANCED,
    QG_ENHANCED,
    validate_candidate_enhanced,
    validate_objective_proposal_enhanced,
)

OUT = ROOT / 'deliverables' / 'phase2' / 'CLOUD_AB_EVALUATION_RESULTS.json'
BUDGET = 14


# ---------------------------------------------------------------------------
# BDJ cases — synthetic declarations only
# ---------------------------------------------------------------------------
#: Deterministic identifier space. Random uuids made the dispatched packet
#: impossible to rebuild in a second process, so the run could not be re-scored
#: or replayed; the ids are now derived from the case and item so the same
#: packet is reproducible byte for byte.
_NS = uuid.UUID('6f1a1f5e-0000-4000-8000-000000000001')


def decl(key, question, value, *, case='shared'):
    return {'item_key': key, 'question': question, 'answer_state': 'ANSWERED',
            'answer_revision_id': str(uuid.uuid5(_NS, f'{case}|{key}|answer')),
            'item_version_id': str(uuid.uuid5(_NS, f'{case}|{key}|version')),
            'value': value}


def packet(declarations, *, case='shared'):
    body = {
        'schema_version': 'project1-m2-projection/1-candidate',
        'instrument_version': 'M2V1-20261114-1',
        'instrument_id': str(uuid.uuid5(_NS, f'{case}|instrument')),
        'assessment_id': str(uuid.uuid5(_NS, f'{case}|assessment')),
        'assessment_revision': 7,
        'confirmed': True,
        'declarations': declarations,
    }
    body['source_fingerprint'] = digest(body)
    return body


BDJ_CASES = [
    {
        'case': 'clear_confirmed_uncertainty',
        'intent': 'One UNDECIDED answer. A correct response names it as a source-confirmed gap.',
        'packet': packet([
            decl('M2V1-01', 'Which area are you currently considering for your proposed cafe?', 'UNDECIDED', case='bdj1'),
            decl('M2V1-02', 'How do you currently plan to serve customers?', 'DINE_IN', case='bdj1'),
            decl('M2V1-03', 'Which product categories do you currently intend to offer?', ['COFFEE', 'BAKED_GOODS'], case='bdj1'),
        ], case='bdj1'),
    },
    {
        'case': 'multiple_supported_uncertainties',
        'intent': 'Two uncertain answers. A correct response may propose two independent gaps.',
        'packet': packet([
            decl('M2V1-01', 'Which area are you currently considering for your proposed cafe?', 'UNDECIDED', case='bdj2'),
            decl('M2V1-08', 'Which sources of information have you used to form your current expectations?', 'UNKNOWN', case='bdj2'),
            decl('M2V1-02', 'How do you currently plan to serve customers?', 'DINE_IN', case='bdj2'),
        ], case='bdj2'),
    },
    {
        'case': 'no_supported_uncertainty',
        'intent': 'All answers definite. A correct response must not invent a gap; SUGGESTED or empty is expected.',
        'packet': packet([
            decl('M2V1-01', 'Which area are you currently considering for your proposed cafe?', 'SUBANG_JAYA', case='bdj3'),
            decl('M2V1-02', 'How do you currently plan to serve customers?', 'DINE_IN', case='bdj3'),
            decl('M2V1-05', 'Among the customer groups you selected, which one is your primary intended group?', 'STUDENTS', case='bdj3'),
        ], case='bdj3'),
    },
]


# ---------------------------------------------------------------------------
# QG cases — synthetic confirmed facts only
# ---------------------------------------------------------------------------
def facts(**over) -> ConfirmedFacts:
    base = dict(
        assessment_id='e0124bfd-e54b-4d57-bc19-2023c8e7a5e6',
        objective_id='AB-OBJ-01',
        objective_text='To explore factors that prospective customers consider when choosing a cafe.',
        uncertainty_id='u-1',
        uncertainty_version='u-1@v1',
        uncertainty_text='Would eligible customers find RM13 acceptable for a 12 oz takeaway iced latte?',
        bcb_version='business-context-package/1.1',
        context_hash='a' * 64,
        m2_answer_revision_ids=['a-1'],
        source_refs=['u-1', 'a-1@v1'],
        confirmed_numbers=['12', '13'],
        confirmed_currency=['RM13'],
        confirmed_offers=['12 oz', 'takeaway', 'iced'],
    )
    base.update(over)
    return ConfirmedFacts(**base)


QG_CASES = [
    {
        'case': 'complete_offer_single_choice',
        'intent': 'Every mandatory fact is present. A DRAFT single-select question is expected.',
        'facts': facts(),
    },
    {
        'case': 'missing_price',
        'intent': 'The offer states size and format but no price. An abstention naming PRICE is expected.',
        'facts': facts(
            objective_text='To test whether customers would accept the intended price for a 12 oz takeaway latte.',
            uncertainty_text='Would eligible customers accept the price of a 12 oz takeaway iced latte?',
            confirmed_numbers=['12'],
            confirmed_currency=[],
        ),
    },
    {
        'case': 'single_choice_acceptability',
        'intent': 'One fixed hypothetical offer; one selection expected.',
        'facts': facts(
            objective_text='To test stated acceptability of a single fixed offer.',
            uncertainty_text='Would eligible customers find RM13 acceptable for a 12 oz takeaway iced latte?',
        ),
    },
    {
        'case': 'multiple_choice_factors',
        'intent': 'An open factor question with several selectable options and an escape choice.',
        'facts': facts(
            objective_text='To explore which factors prospective customers consider when choosing a cafe.',
            uncertainty_text='Which factors matter to prospective customers when choosing a cafe?',
            confirmed_numbers=[],
            confirmed_currency=[],
            confirmed_offers=[],
        ),
    },
]


# ---------------------------------------------------------------------------
# request builders — identical shape for both versions
# ---------------------------------------------------------------------------
def bdj_messages(prompt: Prompt, pack: dict) -> list[dict]:
    return prompt.messages(pack, ObjectiveProposal.model_json_schema())


def qg_input(f: ConfirmedFacts) -> dict:
    return {
        'contract_version': QG_CONTRACT,
        'schema_version': QG_SCHEMA_VERSION,
        'source_fingerprint': f.fingerprint,
        'confirmed_facts': f.model_dump(),
        'field_authority': {'proposed_fields_are_candidates': True,
                            'confirmed_fields_are_facts': True,
                            'scientifically_adopted': False,
                            'fielding_authorized': False},
    }


def qg_messages(prompt: Prompt, f: ConfirmedFacts) -> list[dict]:
    return prompt.messages(qg_input(f), QGCandidate.model_json_schema())


def reconstruct_packet(case: dict, output: dict) -> dict:
    """Rebuild the declarations an output cites, for a run whose input was lost.

    Values come from the case definition (deterministic); identifiers come from
    the output's own citations, because those are the ids the model was actually
    given. A cited item absent from the case definition gets ``value: None``, so
    a hallucinated citation still fails validation rather than being excused.
    """
    values = {d['item_key']: d['value'] for d in case['packet']['declarations']}
    seen, declarations = set(), []
    for row in output.get('recommendations', []):
        for ref in row.get('source_refs', []):
            key = ref['item_key']
            if key in seen:
                continue
            seen.add(key)
            declarations.append({
                'item_key': key,
                'answer_state': 'ANSWERED',
                'value': values.get(key),
                'answer_revision_id': ref['answer_revision_id'],
                'item_version_id': ref['item_version_id'],
            })
    return {'declarations': declarations}


def rescore() -> int:
    """Re-apply the current validators to outputs already recorded.

    This makes no network call and changes no model output. It exists because
    the live run exposed a defect in the enhanced validator: its option-overlap
    rule refused two legitimate ordinal scales. The dispatch-time verdicts stay
    in the file untouched under ``original_validation`` / ``enhanced_validation``;
    the corrected verdicts are added beside them under ``rescored_validation``.
    """
    if not OUT.exists():
        print(f'no evidence at {OUT}')
        return 1
    doc = json.loads(OUT.read_text(encoding='utf-8'))

    cases = {c['case']: c for c in BDJ_CASES}
    qg_cases = {c['case']: c for c in QG_CASES}

    changed = 0
    for kind in ('bdj', 'qg'):
        for record in doc['results'][kind]:
            if record.get('status') != 'RETURNED':
                continue
            case = (cases if kind == 'bdj' else qg_cases)[record['case_id']]
            arg = record.get('input')
            if arg is None and kind == 'bdj':
                arg = reconstruct_packet(case, record['output'])
                record['input_fidelity'] = 'RECONSTRUCTED_FROM_OUTPUT_CITATIONS'
            elif arg is None:
                arg = case['facts']
            validator = (validate_objective_proposal if kind == 'bdj'
                         else validate_candidate)
            enhanced = (validate_objective_proposal_enhanced if kind == 'bdj'
                        else validate_candidate_enhanced)
            before = record.get('enhanced_validation', {}).get('outcome')
            rescored = {}
            for name, fn in (('original', validator), ('enhanced', enhanced)):
                try:
                    fn(record['output'], arg)
                    rescored[name] = {'outcome': 'ACCEPT', 'code': None}
                except WorkflowHeld as held:
                    rescored[name] = {'outcome': 'REJECT', 'code': str(held)}
            record['rescored_validation'] = rescored
            if rescored['enhanced']['outcome'] != before:
                changed += 1
                print(f'  CHANGED {record["case"]:44s} {before} -> '
                      f'{rescored["enhanced"]["outcome"]}')

    doc['rescoring'] = {
        'rescored_at': datetime.now(timezone.utc).isoformat(),
        'network_calls': 0,
        'reason': (
            'The live run showed the enhanced option-overlap rule refusing two '
            'legitimate ordinal scales ("Very low"/"Low", "Very acceptable"/'
            '"Acceptable"). The rule was corrected to exempt intensifier-only '
            'differences, and every recorded output was re-scored offline. '
            'Dispatch-time verdicts are preserved under '
            'original_validation/enhanced_validation.'
        ),
        'records_changed': changed,
    }
    OUT.write_text(json.dumps(doc, indent=1), encoding='utf-8')
    print(f'rescored {sum(len(doc["results"][k]) for k in ("bdj", "qg"))} records, '
          f'{changed} verdict(s) changed; 0 network calls')
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--live', action='store_true', help='actually dispatch to the provider')
    ap.add_argument('--rescore', action='store_true',
                    help='re-apply the current validators to the recorded outputs; '
                         'no network call is made')
    args = ap.parse_args()

    if args.rescore:
        return rescore()

    key = settings.tokenharbor_api_key.get_secret_value()
    print('=' * 78)
    print('PHASE E — LIVE A/B DIAGNOSTIC (synthetic data only)')
    print('=' * 78)
    print(f'endpoint        : {ENDPOINT}')
    print(f'model requested : {MODEL}')
    print(f'structured mode : {settings.tokenharbor_structured_mode}')
    print(f'credential      : present={bool(key)} source=backend/.env')
    print(f'provider enabled: {settings.tokenharbor_enabled}')
    print(f'budget          : {BUDGET} dispatches (3 BDJ x 2) + (4 QG x 2)')
    print(f'BDJ original    : {PROMPTS["BDJ_OBJECTIVE"].version} '
          f'({PROMPTS["BDJ_OBJECTIVE"].fingerprint[:16]})')
    print(f'BDJ enhanced    : {BDJ_ENHANCED.version} ({BDJ_ENHANCED.fingerprint[:16]})')
    print(f'QG  original    : {PROMPTS["QG_PROPOSAL"].version} '
          f'({PROMPTS["QG_PROPOSAL"].fingerprint[:16]})')
    print(f'QG  enhanced    : {QG_ENHANCED.version} ({QG_ENHANCED.fingerprint[:16]})')

    if not args.live:
        print('\nDRY RUN — nothing sent. Add --live to dispatch.')
        for c in BDJ_CASES:
            m = bdj_messages(PROMPTS['BDJ_OBJECTIVE'], c['packet'])
            print(f'  BDJ {c["case"]:34s} messages={len(m):2d} '
                  f'bytes={len(json.dumps(m).encode()):6d}')
        for c in QG_CASES:
            m = qg_messages(PROMPTS['QG_PROPOSAL'], c['facts'])
            print(f'  QG  {c["case"]:34s} messages={len(m):2d} '
                  f'bytes={len(json.dumps(m).encode()):6d}')
        return 2

    if not key or not settings.tokenharbor_enabled:
        print('\nREFUSED: no credential or provider disabled. Nothing sent.')
        return 2

    provider = TokenHarbor(
        settings.tokenharbor_api_key,
        enabled=settings.tokenharbor_enabled,
        structured_mode=settings.tokenharbor_structured_mode,
        timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
        identity_exception=settings.tokenharbor_model_identity_exception,
        model=MODEL,
    )

    dispatched = 0
    results = {'bdj': [], 'qg': []}

    def call(label, messages, output_type, validator, enhanced, arg, contract):
        nonlocal dispatched
        if dispatched >= BUDGET:
            raise SystemExit(f'BUDGET EXHAUSTED at {dispatched}; refusing to dispatch {label}.')
        dispatched += 1
        started = time.monotonic()
        record = {'case': label, 'dispatch_index': dispatched,
                  'prompt_version': None, 'prompt_fingerprint': None}
        try:
            output = provider.complete(messages, output_type)
        except WorkflowHeld as held:
            record.update(status='HELD', code=str(held),
                          execution=provider.last_execution,
                          identity=provider.last_identity,
                          latency_ms=round((time.monotonic() - started) * 1000))
            return record
        record.update(status='RETURNED', output=output,
                      execution=provider.last_execution,
                      identity=provider.last_identity,
                      latency_ms=round((time.monotonic() - started) * 1000),
                      contract=contract)
        for name, fn in (('original', validator), ('enhanced', enhanced)):
            try:
                fn(output, arg)
                record[f'{name}_validation'] = {'outcome': 'ACCEPT', 'code': None}
            except WorkflowHeld as held:
                record[f'{name}_validation'] = {'outcome': 'REJECT', 'code': str(held)}
            except Exception as exc:
                record[f'{name}_validation'] = {
                    'outcome': 'REJECT', 'code': f'{type(exc).__name__}: {str(exc)[:160]}'}
        return record

    plan = []
    for case in BDJ_CASES:
        for version, prompt in (('original', PROMPTS['BDJ_OBJECTIVE']), ('enhanced', BDJ_ENHANCED)):
            plan.append(('bdj', case, version, prompt))
    for case in QG_CASES:
        for version, prompt in (('original', PROMPTS['QG_PROPOSAL']), ('enhanced', QG_ENHANCED)):
            plan.append(('qg', case, version, prompt))

    assert len(plan) == BUDGET, f'plan is {len(plan)}, budget is {BUDGET}'

    print('\n--- dispatch ---')
    for kind, case, version, prompt in plan:
        if kind == 'bdj':
            messages = bdj_messages(prompt, case['packet'])
            record = call(f'{case["case"]}::{version}', messages, ObjectiveProposal,
                          validate_objective_proposal, validate_objective_proposal_enhanced,
                          case['packet'], BDJ_CONTRACT)
        else:
            messages = qg_messages(prompt, case['facts'])
            record = call(f'{case["case"]}::{version}', messages, QGCandidate,
                          validate_candidate, validate_candidate_enhanced,
                          case['facts'], QG_CONTRACT)
        record['prompt_version'] = prompt.version
        record['prompt_fingerprint'] = prompt.fingerprint
        record['variant'] = version
        record['case_id'] = case['case']
        record['intent'] = case['intent']
        # The exact input is persisted with the output. Without it the run cannot
        # be re-scored or replayed in a second process, which is the defect the
        # first attempt of this harness hit.
        record['input'] = case['packet'] if kind == 'bdj' else case['facts'].model_dump()
        results[kind].append(record)
        ex = record.get('execution') or {}
        print(f'  [{record["dispatch_index"]:02d}/{BUDGET}] {record["case"]:44s} '
              f'{record["status"]:9s} http={ex.get("http_status")} '
              f'orig={record.get("original_validation", {}).get("outcome", "-")} '
              f'enh={record.get("enhanced_validation", {}).get("outcome", "-")}')

    evidence = {
        'checkpoint': 'BDJ_QG_PROMPT_CLOUD_AB',
        'executed_at': datetime.now(timezone.utc).isoformat(),
        'mode': 'LIVE_CLOUD_SYNTHETIC_AB',
        'endpoint': ENDPOINT,
        'model_requested': MODEL,
        'structured_mode': settings.tokenharbor_structured_mode,
        'generation_settings': {'temperature': 0, 'max_tokens': 4000, 'stream': False},
        'credential_source': 'backend/.env',
        'credential_present': True,
        'persistent_env_modified': False,
        'budget': BUDGET,
        'dispatched': dispatched,
        'retries': 0,
        'data_classification': 'SYNTHETIC_ONLY',
        'prompts': {
            'bdj_original': {'version': PROMPTS['BDJ_OBJECTIVE'].version,
                             'fingerprint': PROMPTS['BDJ_OBJECTIVE'].fingerprint},
            'bdj_enhanced': {'version': BDJ_ENHANCED.version,
                             'fingerprint': BDJ_ENHANCED.fingerprint},
            'qg_original': {'version': PROMPTS['QG_PROPOSAL'].version,
                            'fingerprint': PROMPTS['QG_PROPOSAL'].fingerprint},
            'qg_enhanced': {'version': QG_ENHANCED.version,
                            'fingerprint': QG_ENHANCED.fingerprint},
        },
        'results': results,
    }
    OUT.write_text(json.dumps(evidence, indent=1), encoding='utf-8')
    print(f'\n  dispatched {dispatched}/{BUDGET} · evidence -> {OUT.relative_to(ROOT)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
