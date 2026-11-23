"""Standalone diagnostic for the current cloud Explanation Module prompt.

What this script is
-------------------
A single, self-contained way to inspect and (optionally) exercise
``EE01-EXPLANATION-2-CAND`` — the prompt that ``explanation_prompt.py`` actually
defines today — without starting the backend, without a database, and without
touching a real respondent record.

What it is not
--------------
It is not a report. Every result it produces is labelled
``SYNTHETIC_DIAGNOSTIC_NOT_REPORT_ADMITTED``, because a synthetic fixture is not
evidence and a model's prose is not an admitted claim. Passing every case here
proves the prompt and the guards behave; it does not prove explanation quality
for real respondents, and it does not unblock any A10 gate.

Usage
-----
Offline (default, no network, no credentials)::

    py backend/scripts/project1_ee01_explanation_live_test.py --self-test
    py backend/scripts/project1_ee01_explanation_live_test.py --case q06 --show-prompt
    py backend/scripts/project1_ee01_explanation_live_test.py --case q06 --show-cloud-request
    py backend/scripts/project1_ee01_explanation_live_test.py --list-cases

Live (deliberate, one request, no retry)::

    py backend/scripts/project1_ee01_explanation_live_test.py --case q06 --live

``--live`` asks for typed confirmation on a terminal and refuses without it. It
reads ``TOKENHARBOR_API_KEY`` from the environment, requires an HTTPS endpoint,
and never prints the key. It sends only the hardcoded synthetic fixture below.

Safety properties
-----------------
* no database import, no ``.env`` read, no backup credential file;
* no customer, respondent or assessment data — every fact is a literal here;
* one POST per invocation, no automatic retry, bounded timeout and body size;
* the request is built by ``explanation_prompt.build_request``, so what is sent
  is exactly what the governed path would send, not a copy that can drift.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# Importable without installation: this file lives at backend/scripts/.
_BACKEND = Path(__file__).resolve().parents[1]
_SRC = _BACKEND / 'src'
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

from sitewise.project1 import explanation_prompt as P  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld, canonical  # noqa: E402
from sitewise.project1.explanation_contracts import (  # noqa: E402
    SCHEMA_VERSION,
    ExplanationOutput,
    insufficient_evidence_output,
    validate_candidate,
)
from sitewise.project1.explanation_registry import (  # noqa: E402
    load_registry,
    raw_question,
)

#: Every result carries this. Nothing this script produces is report-admitted.
RESULT_CLASS = 'SYNTHETIC_DIAGNOSTIC_NOT_REPORT_ADMITTED'
PROMPT_VERSION = P.PROMPT_VERSION

# ---------------------------------------------------------------------------
# Synthetic fixtures
#
# One per item, each stating the situation it is meant to exercise. The counts
# are literals chosen to make a specific guard reachable — a zero denominator, a
# tie, a missing stimulus — not to look plausible.
# ---------------------------------------------------------------------------

CASES: dict[str, dict] = {
    'q01': {'question': 'Q01', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'self-reported area affiliation, multi-select',
            'v': 30, 'a': 34, 's': 36, 'q': 40,
            'facts': [{'code': 'LIVES_HERE', 'count': 18},
                      {'code': 'WORKS_HERE', 'count': 9}],
            'tie': False,
            'tests': 'multi-select counts are not a partition of V'},
    'q02': {'question': 'Q02', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'stated presence frequency, ordinal bands',
            'v': 28, 'a': 30, 's': 33, 'q': 36,
            'facts': [{'code': 'DAYS_1_3', 'count': 11},
                      {'code': 'DAYS_4_10', 'count': 9},
                      {'code': 'DAYS_GT_20', 'count': 8}],
            'tie': False,
            'tests': 'ordinal bands are described, never averaged'},
    'q03': {'question': 'Q03', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'origin type under a hypothetical stem',
            'v': 26, 'a': 28, 's': 31, 'q': 34,
            'facts': [{'code': 'LOCAL', 'count': 15},
                      {'code': 'VISITOR', 'count': 11}],
            'tie': False,
            'tests': 'hypothetical framing must survive into the prose'},
    'q04': {'question': 'Q04', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'visit occasion bands, ordinal',
            'v': 27, 'a': 29, 's': 32, 'q': 35,
            'facts': [{'code': 'WEEKDAY_MORNING', 'count': 10},
                      {'code': 'WEEKEND', 'count': 9},
                      {'code': 'EVENING', 'count': 8}],
            'tie': False,
            'tests': 'occasion bands are ordered categories, not a scale'},
    'q05': {'question': 'Q05', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'stated visit intention, five-category ordinal',
            'v': 30, 'a': 36, 's': 38, 'q': 42,
            'facts': [{'code': 'DEF_YES', 'count': 9},
                      {'code': 'PROB_YES', 'count': 8},
                      {'code': 'NEUTRAL', 'count': 6},
                      {'code': 'PROB_NO', 'count': 4},
                      {'code': 'DEF_NO', 'count': 3}],
            'tie': False,
            'tests': 'stated intention is not a calibrated probability'},
    'q06': {'question': 'Q06', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'overlapping product interest, multi-select, tied leaders',
            'v': 32, 'a': 35, 's': 38, 'q': 41,
            'facts': [{'code': 'LATTE', 'count': 14},
                      {'code': 'AMERICANO', 'count': 14},
                      {'code': 'COLD_BREW', 'count': 7}],
            'tie': True,
            'tests': 'a tie is reported as a tie; option counts may exceed V'},
    'q07': {'question': 'Q07', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'price expectation with no approved stimulus',
            'v': 0, 'a': 12, 's': 30, 'q': 33,
            'facts': [],
            'tie': False,
            'tests': 'V == 0 must abstain; never 0%, never a willingness-to-pay band'},
    'q08': {'question': 'Q08', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'transport mode, source unresolved',
            'v': 24, 'a': 26, 's': 29, 'q': 31,
            'facts': [{'code': 'WALK', 'count': 12},
                      {'code': 'DRIVE', 'count': 7}],
            'tie': False,
            'tests': 'an unresolved source is named as unresolved'},
    'q09': {'question': 'Q09', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'route-dependent item with an unresolved gate',
            'v': 20, 'a': 22, 's': 25, 'q': 28,
            'facts': [{'code': 'YES', 'count': 12},
                      {'code': 'NO', 'count': 8}],
            'tie': False,
            'tests': 'unknown routing is not silently treated as shown'},
    'q10': {'question': 'Q10', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'feature importance, one synthetic feature slot',
            'v': 22, 'a': 24, 's': 27, 'q': 30,
            'facts': [{'code': 'SYNTH_FEATURE_A', 'count': 13},
                      {'code': 'SYNTH_FEATURE_B', 'count': 9}],
            'tie': False,
            'tests': 'one feature slot only; no questionnaire-wide denominator'},
    'q11': {'question': 'Q11', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'unregistered item with no report section',
            'v': 15, 'a': 17, 's': 20, 'q': 22,
            'facts': [{'code': 'OPT_A', 'count': 9},
                      {'code': 'OPT_B', 'count': 6}],
            'tie': False,
            'tests': 'no section means no admissible claim at all'},
    'q12': {'question': 'Q12', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'limited-context item in R08',
            'v': 18, 'a': 20, 's': 23, 'q': 25,
            'facts': [{'code': 'ALONE', 'count': 10},
                      {'code': 'WITH_OTHERS', 'count': 8}],
            'tie': False,
            'tests': 'the limited-context qualifier is carried into the prose'},
    'q13': {'question': 'Q13', 'task_mode': 'CLAIM_EXPLANATION',
            'situation': 'separate construct with no report section',
            'v': 16, 'a': 18, 's': 21, 'q': 23,
            'facts': [{'code': 'HIGH', 'count': 9},
                      {'code': 'LOW', 'count': 7}],
            'tie': False,
            'tests': 'Q13 is not a Q07 substitute and maps to no section'},
}

#: Adversarial probes. Each one is a *narrative* that must be rejected, paired
#: with the guard expected to reject it. These are what make the offline run more
#: than a smoke test.
ADVERSARIAL = (
    ('invented_percentage',
     'About 47% of respondents said they would visit.',
     'a percentage the request never supplied'),
    ('invented_count',
     'Exactly 231 respondents selected the first option.',
     'a count the request never supplied'),
    ('unsupported_demand',
     'This proves high market demand for the cafe.',
     'a banned demand claim'),
    ('invented_quantity_word',
     'Three quarters of the sample chose the leading option.',
     'a derived quantity expressed in words'),
)


def _entry(question_id: str) -> dict:
    entry = raw_question(question_id)
    if entry is None:
        raise SystemExit(f'registry has no entry for {question_id}')
    return entry


def _labels(question_id: str) -> dict[str, str]:
    entry = _entry(question_id)
    return {c['code']: c['label_en'] for c in entry['codes'] if c.get('label_en')}


def packet_for(case_id: str) -> dict:
    """A server-shaped packet built from the literal fixture, not from a table."""
    case = CASES[case_id]
    qid = case['question']
    entry = _entry(qid)
    gate = entry.get('instrument_gate')
    refs = ['EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED', 'REPORT_ADMISSION_REQUIRED', qid]
    return {
        'task_mode': case['task_mode'],
        'context_id': f'synthetic-context-{qid}',
        'assessment_id': 'synthetic-assessment',
        'campaign_id': 'synthetic-campaign',
        'cohort_id': None,
        'snapshot_id': f'synthetic-snapshot-{qid}',
        'snapshot_hash': 'f' * 64,
        'measurement_ruleset_id': f'{qid.lower()}-v1',
        'measurement_ruleset_version': entry['instrument_version'],
        'qualification_policy_version': ['synthetic-qual-v1'],
        'privacy_policy_version': 'WITHHOLD_ALL_FINDINGS',
        'report_admission_references': refs,
        'authorized_claims': [],
        'question_versions': {'instrument_version': entry['instrument_version'],
                              'bank_version': 'synthetic-bank-v1',
                              'routing_version': 'synthetic-routing-v1',
                              'consent_version': 'synthetic-consent-v1'},
        'approved_response_labels': [],
        'measurement_definitions': {'rule': 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC',
                                    'selection': 'LATEST_ACCEPTED',
                                    'cutoff_basis': 'COMMITTED_BUILD_SNAPSHOT',
                                    'scope': 'ISOLATED_TEST'},
        'limitations': ['A_DEFINITION_UNRESOLVED', 'MEASUREMENT_CLAIM_UNAUTHORIZED'],
        'allowed_report_destinations': [],
        'question': {
            'question_id': qid,
            'resolution_basis': 'EXPLICIT_QUESTION_ID',
            'instrument_gate': gate,
            'evidence_state': 'VALID_APPROVED',
            'effective_state': gate or 'VALID_APPROVED',
            'routing_resolved': bool(entry.get('routing_resolved')),
            'report_sections': list(entry['report_sections']),
            'template_usable_for_substantive_report': False,
            'registry_version': 'q01-q13-explanation/1',
            'registry_sha256': 'a' * 64,
            'counts': {'q': case['q'], 's': case['s'], 'a': case['a'],
                       'v': case['v'], 'refused': 2, 'invalid': 4,
                       'excluded': 0, 'total_units': case['q']},
        },
        'reference_universe': refs,
    }


def request_for(case_id: str) -> tuple[dict, dict, dict]:
    """(entry, request, messages) for one case, built by the production builder."""
    case = CASES[case_id]
    qid = case['question']
    entry = _entry(qid)
    packet = packet_for(case_id)
    labels = _labels(qid)
    facts = [{'code': f['code'], 'label': labels.get(f['code']), 'count': f['count']}
             for f in case['facts']]
    highest = [f for f in facts if f['count'] == max((x['count'] for x in facts),
                                                     default=0)]
    request = P.build_request(
        entry, packet, facts=facts, highest_options=highest,
        tie=case['tie'], labels=labels,
        display_order=list(entry.get('display_order') or []))
    return entry, request, P.messages(request, entry)


# ---------------------------------------------------------------------------
# Offline checks
# ---------------------------------------------------------------------------

def _allowed_numbers(request: dict) -> set[str]:
    """Numbers the model may legitimately emit: those the request supplies.

    The request minus its ``output_schema``. The schema is excluded because its
    ``maxLength: 2000`` and similar limits are not evidence figures, and admitting
    them would let a narrative cite 2000 as if it were a count. Everything else —
    including ``verified_facts`` counts — is legitimately quotable.
    """
    from sitewise.services.ee01_explanation_service import _numbers_in
    return _numbers_in({k: v for k, v in request.items() if k != 'output_schema'})


def _narrative(text: str) -> dict:
    """Apply one sentence to every prose field of a candidate."""
    return {field: text for field in (
        'headline', 'observation_interpretation', 'research_interpretation',
        'planning_implication', 'limitations', 'summary')}


def _restatement(case: dict) -> str | None:
    """A faithful sentence naming a supplied code and its exact count.

    Built from the fixture, so it contains no figure the packet lacks. If this is
    rejected the guard is too strict, which is its own defect: an over-strict
    validator silently withholds legitimate explanations.
    """
    facts = case.get('facts') or []
    if not facts:
        return None
    top = max(facts, key=lambda f: f['count'])
    return f"{top['count']} respondents selected {top['code']}."


def offline_case(case_id: str) -> dict:
    """Everything decidable without a provider, for one case."""
    entry, request, messages = request_for(case_id)
    result = {
        'case': case_id,
        'question': CASES[case_id]['question'],
        'situation': CASES[case_id]['situation'],
        'tests': CASES[case_id]['tests'],
        'result_class': RESULT_CLASS,
        'prompt_version': PROMPT_VERSION,
        'prompt_sha256': P.prompt_fingerprint(entry),
        'request_sha256': P.request_digest(request),
        'messages': len(messages),
        'authority': request['authority'],
        'instrument_gate': entry.get('instrument_gate'),
        'report_sections': list(entry['report_sections']),
        'checks': {},
    }
    checks = result['checks']
    # Declared early so the positive-control check can report NOT_RUN rather than
    # raising if the fallback itself failed.
    fallback = None

    # 1. the request contract accepts it and forbids percentages.
    try:
        P.validate_request(request)
        checks['request_contract'] = 'PASS'
    except WorkflowHeld as exc:
        checks['request_contract'] = f'FAIL:{exc}'
    checks['no_permitted_percentages'] = (
        'PASS' if request['permitted_percentages'] == [] else 'FAIL')

    # 2. no row-level field leaked into the packet.
    blob = canonical(request)
    checks['no_row_level_field'] = (
        'PASS' if not any(f'"{m}"' in blob for m in
                          ('respondent_id', 'consent_token', 'raw_value', 'email'))
        else 'FAIL')

    allowed = _allowed_numbers(request)

    # 3. the deterministic fallback renders and is itself valid.
    try:
        fallback = insufficient_evidence_output(
            context_id=request['evidence_context_hash'],
            snapshot_id=request['snapshot_id'],
            task_mode=request['task_mode'],
            missing=list(request['report_admission_references']))
        validate_candidate(fallback, packet=packet_for(case_id),
                           allowed_claim_ids=set(request['permitted_claim_ids']),
                           allowed_numbers=allowed)
        checks['fallback_template'] = 'PASS'
    except Exception as exc:  # noqa: BLE001 - a fallback failure is a finding
        checks['fallback_template'] = f'FAIL:{type(exc).__name__}:{exc}'

    # 4. V == 0 must abstain rather than report a zero percentage.
    if CASES[case_id]['v'] == 0:
        checks['zero_denominator_abstains'] = (
            'PASS' if fallback is not None and fallback.insufficient_evidence
            else 'FAIL')

    # 5. A guard that rejects everything proves nothing. A narrative that
    # restates a supplied count exactly must be *accepted*; only then does the
    # rejection of the invented ones below mean anything.
    restatement = _restatement(CASES[case_id])
    if restatement is None:
        checks['legitimate_restatement'] = 'NOT_APPLICABLE:no_facts'
    elif fallback is None:
        checks['legitimate_restatement'] = 'NOT_RUN:baseline_unavailable'
    else:
        try:
            validate_candidate(
                fallback.model_copy(update=_narrative(restatement)),
                packet=packet_for(case_id),
                allowed_claim_ids=set(request['permitted_claim_ids']),
                allowed_numbers=allowed)
            checks['legitimate_restatement'] = 'PASS'
        except WorkflowHeld as exc:
            checks['legitimate_restatement'] = f'FAIL:over_strict:{exc}'

    # 6. the adversarial narratives are all rejected. Without a valid baseline
    # there is nothing to mutate, so the probe is reported as not run rather
    # than silently passing.
    if fallback is None:
        checks['adversarial'] = 'NOT_RUN:baseline_unavailable'
        result['adversarial_detail'] = []
        return result
    rejected = []
    for name, narrative, why in ADVERSARIAL:
        candidate = fallback.model_copy(update={
            'headline': narrative,
            'observation_interpretation': narrative,
            'research_interpretation': narrative,
            'planning_implication': narrative,
            'limitations': narrative,
            'summary': narrative,
        })
        try:
            validate_candidate(candidate, packet=packet_for(case_id),
                               allowed_claim_ids=set(request['permitted_claim_ids']),
                               allowed_numbers=allowed)
            rejected.append(f'{name}:ACCEPTED({why})')
        except WorkflowHeld:
            rejected.append(f'{name}:REFUSED')
    checks['adversarial'] = ('PASS' if all(r.endswith('REFUSED') for r in rejected)
                             else 'FAIL')
    result['adversarial_detail'] = rejected
    return result


def self_test() -> int:
    print(f'PROMPT {PROMPT_VERSION}  schema {SCHEMA_VERSION}  class {RESULT_CLASS}')
    reg = load_registry()
    print(f'registry {reg.registry_version} {reg.sha256[:16]}…')
    print()
    failures = 0
    for case_id in CASES:
        result = offline_case(case_id)
        bad = [k for k, v in result['checks'].items() if str(v).startswith('FAIL')]
        failures += len(bad)
        status = 'ok' if not bad else 'FAIL'
        print(f'  {case_id:4} {result["question"]:4} {status:4} '
              f'gate={str(result["instrument_gate"]):26} '
              f'sections={",".join(result["report_sections"]) or "-"}')
        for key in bad:
            print(f'        {key}: {result["checks"][key]}')
    print()
    print(f'{len(CASES)} cases, {failures} failing check(s)')
    print('OFFLINE ONLY — no provider was contacted.')
    return 1 if failures else 0


# ---------------------------------------------------------------------------
# Live diagnostics
# ---------------------------------------------------------------------------

def _require_live_confirmation() -> bool:
    if not sys.stdin.isatty():
        print('--live needs a terminal, or pass --yes in a scripted run.',
              file=sys.stderr)
        return False
    print('This will send ONE synthetic request to the configured provider.')
    print('It is a diagnostic, not a report. Nothing is admitted by it.')
    typed = input(f'Type {PROMPT_VERSION} to continue: ').strip()
    return typed == PROMPT_VERSION


def live_case(case_id: str, *, assume_yes: bool) -> dict:
    if not assume_yes and not _require_live_confirmation():
        raise SystemExit('live run not confirmed')

    key = os.environ.get('TOKENHARBOR_API_KEY', '').strip()
    if not key:
        raise SystemExit('TOKENHARBOR_API_KEY is not set in the environment.')
    endpoint = os.environ.get('PROJECT1_EXPLANATION_ENDPOINT',
                              'https://tokenharbor.ai/v1/chat/completions').strip()
    if not endpoint.startswith('https://'):
        raise SystemExit('the endpoint must be HTTPS.')
    model = os.environ.get('PROJECT1_EXPLANATION_MODEL', '').strip() or None

    from pydantic import SecretStr
    from sitewise.project1.provider import ENDPOINT, MODEL, TokenHarbor

    requested = model or MODEL
    provider = TokenHarbor(SecretStr(key), enabled=True, timeout=45,
                           model=requested, endpoint=endpoint)
    entry, request, messages = request_for(case_id)

    result = {
        'case': case_id,
        'question': CASES[case_id]['question'],
        'result_class': RESULT_CLASS,
        'prompt_version': PROMPT_VERSION,
        'prompt_sha256': P.prompt_fingerprint(entry),
        'request_sha256': P.request_digest(request),
        'endpoint': endpoint,
        'model_requested': requested,
        'dispatched': False,
        'outcome': None,
        'fallback_used': False,
    }
    try:
        output = provider.complete(messages, ExplanationOutput)
        result['dispatched'] = True
        execution = provider.last_execution or {}
        result['model_returned'] = execution.get('model_returned')
        result['identity'] = (provider.last_identity or {}).get('identity_verified')
        result['http_status'] = execution.get('http_status')
        result['schema_validation'] = execution.get('schema_validation')
        result['usage'] = execution.get('usage')
        candidate = ExplanationOutput.model_validate(output)
        # Independent factual fidelity: the same guard the governed path uses.
        validate_candidate(candidate, packet=packet_for(case_id),
                           allowed_claim_ids=set(request['permitted_claim_ids']),
                           allowed_numbers=_allowed_numbers(request))
        result['outcome'] = 'CANDIDATE_VALIDATED'
        result['candidate'] = candidate.model_dump()
    except WorkflowHeld as exc:
        result['outcome'] = f'HELD:{exc}'
        result['fallback_used'] = True
        result['candidate'] = insufficient_evidence_output(
            context_id=request['evidence_context_hash'],
            snapshot_id=request['snapshot_id'],
            task_mode=request['task_mode'],
            missing=list(request['report_admission_references'])).model_dump()
    except Exception as exc:  # noqa: BLE001 - report the type, never the payload
        result['outcome'] = f'ERROR:{type(exc).__name__}'
        result['fallback_used'] = True
    return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Standalone diagnostic for the cloud Explanation prompt '
                    f'({PROMPT_VERSION}). Offline unless --live is given.')
    parser.add_argument('--case', choices=sorted(CASES),
                        help='one synthetic case, e.g. q06')
    parser.add_argument('--list-cases', action='store_true',
                        help='show the synthetic fixtures and what each exercises')
    parser.add_argument('--self-test', action='store_true',
                        help='run every offline check (default action)')
    parser.add_argument('--show-prompt', action='store_true',
                        help='print the exact system prompt and its fingerprint')
    parser.add_argument('--show-cloud-request', action='store_true',
                        help='print the exact JSON payload that would be POSTed')
    parser.add_argument('--live', action='store_true',
                        help='send ONE synthetic request to the provider')
    parser.add_argument('--yes', action='store_true',
                        help='skip the interactive confirmation (scripted use)')
    parser.add_argument('--json', action='store_true',
                        help='emit machine-readable JSON instead of text')
    args = parser.parse_args(argv)

    if args.list_cases:
        for case_id, case in CASES.items():
            print(f'{case_id:4} {case["question"]:4} {case["situation"]}')
            print(f'     exercises: {case["tests"]}')
        return 0

    if args.case is None:
        if args.live:
            parser.error('--live requires --case')
        return self_test()

    if args.show_prompt:
        entry, request, messages = request_for(args.case)
        print(messages[0]['content'])
        print()
        print(f'--- prompt_sha256 {P.prompt_fingerprint(entry)}')
        print(f'--- prompt_version {PROMPT_VERSION}')
        return 0

    if args.show_cloud_request:
        entry, request, messages = request_for(args.case)
        from sitewise.project1.provider import MODEL, TokenHarbor
        from pydantic import SecretStr
        payload = TokenHarbor(SecretStr(''), enabled=False).prepare_payload(
            messages, ExplanationOutput)
        if args.json:
            print(json.dumps(payload, indent=2, ensure_ascii=False))
        else:
            print(json.dumps(payload, indent=2, ensure_ascii=False))
            print()
            print(f'--- model {MODEL}')
            print(f'--- prompt_sha256 {P.prompt_fingerprint(entry)}')
            print(f'--- request_sha256 {P.request_digest(request)}')
            print('--- Authorization header omitted (never printed)')
        return 0

    if args.live:
        result = live_case(args.case, assume_yes=args.yes)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        print()
        print(f'RESULT CLASS: {RESULT_CLASS}')
        return 0 if result['outcome'] == 'CANDIDATE_VALIDATED' else 1

    result = offline_case(args.case)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if not any(str(v).startswith('FAIL')
                        for v in result['checks'].values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
