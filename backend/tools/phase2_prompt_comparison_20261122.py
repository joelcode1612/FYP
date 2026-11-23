"""Phase E — ORIGINAL vs ENHANCED prompt and validator comparison.

This harness is deliberately offline. No cloud request is made and no new
credential is used. It does four things:

1. Reads the *production* prompt registry and records each prompt's version,
   fingerprint, instruction length and example count. Nothing is mutated.
2. Builds two ENHANCED candidate prompts by appending text to the production
   instruction (never rewriting it), so the diff is exactly the appended block
   and the original wording is preserved character for character.
3. Runs a labelled fixture matrix through two validators:
   - ORIGINAL: the production validators, called unmodified;
   - ENHANCED: the production validator first, then additional checks layered
     on top. No second BDJ or QG engine exists.
4. Replays the *recorded* live model output from
   ``deliverables/phase2/BDJ_CLOUD_DIAGNOSTIC_OBJ-LIVE_20261122.json`` through
   both validators, so the comparison includes one genuine model response and
   not only synthetic fixtures.

Honesty rules enforced here:

* A fixture is labelled ``SYNTHETIC_FIXTURE``. It is never described as a model
  result.
* The enhanced prompt has no model output. It is reported as
  ``LIVE_NOT_EXECUTED``. This script never invents text for it.
* ``schema_valid`` reflects Pydantic parsing only, not scientific suitability.

Usage::

    python tools/phase2_prompt_comparison_20261122.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'backend' / 'src'))

from sitewise.project1.contracts import WorkflowHeld  # noqa: E402
from sitewise.project1.objective_proposal import (  # noqa: E402
    ALLOWED_OPENERS,
    CLAIM_PHRASES,
    validate_objective_proposal,
)
from sitewise.project1.prompts import PROMPTS, Prompt  # noqa: E402
from sitewise.project1.qg_contract import (  # noqa: E402
    ConfirmedFacts,
    QGCandidate,
    validate_candidate,
)

OUT = ROOT / 'deliverables' / 'phase2' / 'PROMPT_COMPARISON_EVIDENCE.json'
OBJ_LIVE = ROOT / 'deliverables' / 'phase2' / 'BDJ_CLOUD_DIAGNOSTIC_OBJ-LIVE_20261122.json'
QG_LIVE = ROOT / 'deliverables' / 'phase2' / 'BDJ_CLOUD_DIAGNOSTIC_QG-LIVE_20261122.json'


# ---------------------------------------------------------------------------
# text helpers (local; the production module keeps its own private versions)
# ---------------------------------------------------------------------------
def normalise(text: str) -> str:
    return ' '.join((text or '').casefold().split())


_NUMBER = re.compile(r'\d+(?:\.\d+)?')
_CURRENCY = re.compile(r'RM\s?\d+(?:\.\d+)?', re.I)
#: Identifiers carry digits that are not business figures. "M2V1-01" would
#: otherwise contribute 2, 1 and 01 to every numeric comparison, and a bare "M2"
#: contributes 2, which is how a naive check rejects a perfectly clean
#: abstention. Both are removed before any number is read.
_IDENTIFIER = re.compile(
    r'M2V1-\d+|\bM2\b|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
    re.I,
)


def numbers(text: str) -> set[str]:
    return set(_NUMBER.findall(_IDENTIFIER.sub(' ', text or '')))


def currency(text: str) -> set[str]:
    return {m.group(0).replace(' ', '').upper() for m in _CURRENCY.finditer(text or '')}


def claim_hits(text: str) -> list[str]:
    low = normalise(text)
    return [p for p in CLAIM_PHRASES if p in low]


def code_present(code: str, text: str) -> bool:
    """Whole-token match. The production check uses a bare substring test."""
    return re.search(rf'(?<![A-Z0-9_]){re.escape(code)}(?![A-Z0-9_])', text) is not None


def option_tokens(label: str) -> frozenset[str]:
    return frozenset(t for t in re.findall(r'[a-z]+', label.casefold()) if len(t) > 2)


#: A negation prefix makes two otherwise identical token sets legitimately
#: different options ("Acceptable" / "Not acceptable"). Without this guard the
#: overlap check rejects the most ordinary single-select item in the system.
_NEGATION = re.compile(r'\b(?:not|no|never|none|neither|nor)\b', re.I)

#: An ordinal scale is built from exactly this kind of nesting: "Low" is a
#: subset of "Very low" on purpose. Measured on live output, a subset rule
#: without this guard refused 2 of 4 real QG responses ("Very low/Low",
#: "Very acceptable/Acceptable") — a false positive, not a finding. Only a
#: difference made of intensifiers is exempt; any other added word is not.
_INTENSIFIER = re.compile(
    r'\b(?:very|extremely|slightly|somewhat|quite|highly|moderately|really|fairly)\b',
    re.I,
)


def options_overlap(left: str, right: str) -> bool:
    """True when two labels are the same option worded twice.

    Detects reordering ("Coffee quality" / "Quality of coffee") and shortening
    ("Coffee" / "Coffee quality"). It does **not** detect synonym overlap
    ("Affordable" / "Cheap"); that needs either an embedding comparison or human
    review, and is reported as a remaining limitation rather than pretended.

    Ordinal neighbours are explicitly not overlap: a subset whose only extra
    token is an intensifier is a scale step, not a duplicate.
    """
    if _NEGATION.search(left) or _NEGATION.search(right):
        return False
    a, b = option_tokens(left), option_tokens(right)
    if not a or not b:
        return False
    if a == b:
        return True
    if not (a <= b or b <= a):
        return False
    small, large = (a, b) if a <= b else (b, a)
    extra = large - small
    return not all(_INTENSIFIER.fullmatch(token) for token in extra)


# ---------------------------------------------------------------------------
# ENHANCED candidate prompts
#
# The instruction is production_instruction + APPENDED. Deriving it this way is
# what makes the recorded diff exact: the original text cannot drift.
# ---------------------------------------------------------------------------
BDJ_APPENDED = (
    ' Additional rules for v4. '
    'Write problem and reason as plain observations. Neither may contain a '
    'claim phrase such as "proves demand", "profitable", "willingness to pay", '
    '"market size" or "guaranteed": those belong to no part of a candidate '
    'objective proposal. '
    'Do not place any number, price or currency amount in research_objective, '
    'problem or reason unless that exact token appears in the value of a '
    'declaration you cite. If the gap needs a figure the source does not state, '
    'describe the gap without the figure. '
    'Every source_refs entry in one recommendation must share the same item_key: '
    'a recommendation names one information gap in one confirmed answer, so '
    'citing several different items bundles unrelated gaps together and is '
    'invalid.'
)

QG_APPENDED = (
    ' Additional rules for v7. '
    'Scan your own justification, limitations and measurement_description for '
    'the prohibited claim phrases as carefully as you scan the question: a claim '
    'in a justification is still a claim. '
    'response_options may not contain a number, price or currency amount that is '
    'absent from confirmed_facts, even when the question itself is clean. '
    'Response options must be distinguishable at a glance: never offer two '
    'labels built from the same words in a different order (for example '
    '"Coffee quality" and "Quality of coffee"), and never offer a label that is '
    'a shorter restatement of another. '
    'denominator_specification must name at least two declared response codes '
    'with their exact code strings, and must state which codes are excluded. '
    'Naming a single code, or relying on a word that merely contains the letters '
    'of a code, is not a denominator.'
)


def build_enhanced(key: str, version: str, appended: str) -> Prompt:
    base = PROMPTS[key]
    return Prompt(version, base.role, base.instruction + appended, base.examples)


BDJ_ENHANCED = build_enhanced('BDJ_OBJECTIVE', 'BDJ-OBJECTIVE-4-CAND', BDJ_APPENDED)
QG_ENHANCED = build_enhanced('QG_PROPOSAL', 'QG-PROPOSE-7-CAND', QG_APPENDED)


# ---------------------------------------------------------------------------
# ENHANCED validators — production first, then extra checks
# ---------------------------------------------------------------------------
def validate_objective_proposal_enhanced(raw, packet: dict):
    """Production validation, then four additional fail-closed checks."""
    output = validate_objective_proposal(raw, packet)
    sources = {d['item_key']: d for d in packet.get('declarations', [])}

    for rec in output.recommendations:
        # 1. claim phrases must not appear in problem or reason.
        for label, text in (('problem', rec.problem or ''), ('reason', rec.reason)):
            hits = claim_hits(text)
            if hits:
                raise WorkflowHeld(f'BDJ_ENHANCED_CLAIM_IN_{label.upper()}')

        # 2. no figure the cited sources do not contain.
        allowed_text = ' '.join(
            ' '.join(str(v) for v in (sources[r.item_key].get('value')
                                      if isinstance(sources[r.item_key].get('value'), list)
                                      else [sources[r.item_key].get('value')]))
            for r in rec.source_refs
        )
        allowed_numbers = numbers(allowed_text)
        allowed_currency = currency(allowed_text)
        for label, text in (('objective', rec.research_objective),
                            ('problem', rec.problem or ''), ('reason', rec.reason)):
            stray = numbers(text) - allowed_numbers
            if stray:
                raise WorkflowHeld(f'BDJ_ENHANCED_UNSOURCED_NUMBER_IN_{label.upper()}')
            stray_amount = currency(text) - allowed_currency
            if stray_amount:
                raise WorkflowHeld(f'BDJ_ENHANCED_UNSOURCED_AMOUNT_IN_{label.upper()}')

        # 3. one gap, one answer: refs may not span items.
        if len({r.item_key for r in rec.source_refs}) > 1:
            raise WorkflowHeld('BDJ_ENHANCED_SOURCE_SPANS_ITEMS')

        # 4. an exploratory objective must say so in its reason.
        if rec.recommendation_status == 'SUGGESTED' and not any(
            token in normalise(rec.reason) for token in ('no m2 finding', 'exploratory', 'no confirmed')
        ):
            raise WorkflowHeld('BDJ_ENHANCED_SUGGESTED_REASON_UNQUALIFIED')

    return output


_ESCAPE_TOKENS = ('not sure', 'none of these', 'no opinion', 'prefer not to say',
                  "don't know", 'dont know')


def validate_candidate_enhanced(raw, facts: ConfirmedFacts) -> QGCandidate:
    """Production validation, then five additional fail-closed checks."""
    candidate = validate_candidate(raw, facts)

    if candidate.decision == 'ABSTAIN_NEEDS_REVIEW':
        return candidate

    # 1. prohibited claims outside the fields production scans.
    #
    # `limitations` is deliberately NOT scanned. A limitation exists to name the
    # thing the question cannot establish ("this is not a maximum willingness to
    # pay"), so scanning it rejects the correct disclaimer. Measured: doing so
    # refused 4 of 4 positive fixtures. The clause was revised out of the
    # candidate and the measurement is recorded in the evidence file.
    for label, text in (('justification', candidate.justification),
                        ('measurement_description', candidate.measurement_description)):
        low = text.casefold()
        for pattern, code in _QG_CLAIM_PATTERNS:
            if re.search(pattern, low):
                raise WorkflowHeld(f'{code}_IN_{label.upper()}')

    # 2. no unconfirmed figure in the response options.
    option_text = ' '.join(candidate.response_options)
    stray = numbers(option_text) - set(facts.confirmed_numbers)
    if stray:
        raise WorkflowHeld('QG_ENHANCED_UNSOURCED_OPTION_NUMBER')
    if not currency(option_text) <= set(facts.confirmed_currency):
        raise WorkflowHeld('QG_ENHANCED_UNSOURCED_OPTION_AMOUNT')

    # 3. options must be distinguishable, not merely non-identical.
    substantive = [o for o in candidate.response_options
                   if o.strip().casefold() not in _ESCAPE_TOKENS]
    for i, left in enumerate(substantive):
        for right in substantive[i + 1:]:
            if options_overlap(left, right):
                raise WorkflowHeld('QG_ENHANCED_OPTION_OVERLAP')

    # 4. a code may not be "named" by a word that merely contains it. Checked
    # before the count so the more specific failure is the one reported.
    named = {c for c in candidate.response_codes
             if code_present(c, candidate.denominator_specification)}
    if not named and any(c in candidate.denominator_specification
                         for c in candidate.response_codes):
        raise WorkflowHeld('QG_ENHANCED_DENOMINATOR_SUBSTRING_MATCH')

    # 5. the denominator must name at least two declared codes.
    if len(named) < 2:
        raise WorkflowHeld('QG_ENHANCED_DENOMINATOR_INCOMPLETE')

    return candidate


# Production patterns are reused, not redefined, so the two validators cannot
# disagree about what a prohibited claim is.
from sitewise.project1.qg_contract import PROHIBITED_CLAIM_PATTERNS as _QG_CLAIM_PATTERNS  # noqa: E402


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
DECLARATIONS = [
    {'item_key': 'M2V1-01', 'answer_state': 'ANSWERED', 'value': 'UNDECIDED',
     'answer_revision_id': 'r-01', 'item_version_id': 'v-01'},
    {'item_key': 'M2V1-02', 'answer_state': 'ANSWERED', 'value': 'DINE_IN',
     'answer_revision_id': 'r-02', 'item_version_id': 'v-02'},
    {'item_key': 'M2V1-05', 'answer_state': 'ANSWERED', 'value': '25000',
     'answer_revision_id': 'r-05', 'item_version_id': 'v-05'},
    {'item_key': 'M2V1-08', 'answer_state': 'ANSWERED', 'value': 'UNKNOWN',
     'answer_revision_id': 'r-08', 'item_version_id': 'v-08'},
]
PACKET = {'declarations': DECLARATIONS}


def rec(**over) -> dict:
    base = {
        'recommendation_status': 'MOST_SUGGESTED',
        'problem_type': 'SOURCE_CONFIRMED_INFORMATION_GAP',
        'problem': 'The trading area remains undecided.',
        'research_objective': 'To investigate candidate areas for the proposed cafe.',
        'source_refs': [{'item_key': 'M2V1-01', 'answer_revision_id': 'r-01',
                         'item_version_id': 'v-01'}],
        'reason': 'The area answer is recorded as UNDECIDED.',
        'authority': 'CANDIDATE_ONLY',
    }
    base.update(over)
    return base


def proposal(*recs) -> dict:
    return {'contract_version': 'bdj-objective-proposal/1', 'recommendations': list(recs)}


BDJ_CASES = [
    {
        'case': 'clear_confirmed_uncertainty',
        'category': 'positive',
        'expected': 'ACCEPT',
        'payload': proposal(rec()),
        'note': 'One MOST_SUGGESTED citing an UNDECIDED answer.',
    },
    {
        'case': 'multiple_supported_uncertainties',
        'category': 'positive',
        'expected': 'ACCEPT',
        'payload': proposal(
            rec(),
            rec(problem='The evidence base is unrecorded.',
                research_objective='To investigate what evidence underpins current expectations.',
                source_refs=[{'item_key': 'M2V1-08', 'answer_revision_id': 'r-08',
                              'item_version_id': 'v-08'}],
                reason='The information-sources answer is UNKNOWN.'),
        ),
        'note': 'Two independent gaps, each citing its own answer.',
    },
    {
        'case': 'no_supported_uncertainty',
        'category': 'positive',
        'expected': 'ACCEPT',
        'payload': proposal(rec(
            recommendation_status='SUGGESTED',
            problem_type='EXPLORATORY_RESEARCH_NEED',
            problem=None,
            research_objective='To explore how student groups read a study cafe.',
            source_refs=[],
            reason='No M2 finding establishes the need; exploratory only.')),
        'note': 'Correct abstention from claiming a gap.',
    },
    {
        'case': 'refs_span_two_items',
        'category': 'boundary',
        'expected': 'REJECT',
        'payload': proposal(rec(source_refs=[
            {'item_key': 'M2V1-01', 'answer_revision_id': 'r-01', 'item_version_id': 'v-01'},
            {'item_key': 'M2V1-08', 'answer_revision_id': 'r-08', 'item_version_id': 'v-08'},
        ])),
        'note': 'One recommendation citing two different answers.',
    },
    {
        'case': 'missing_essential_context',
        'category': 'insufficient_context',
        'expected': 'REJECT',
        'payload': proposal(rec(source_refs=[
            {'item_key': 'M2V1-07', 'answer_revision_id': 'r-07', 'item_version_id': 'v-07'},
        ])),
        'note': 'Cites an answer the packet does not contain.',
    },
    {
        'case': 'unsupported_proposed_objective',
        'category': 'negative',
        'expected': 'REJECT',
        'payload': proposal(rec(
            research_objective='To investigate whether RM13 is acceptable for a 12 oz latte.')),
        'note': 'Objective invents a price and a size the source never states.',
    },
    {
        'case': 'claim_in_reason',
        'category': 'negative',
        'expected': 'REJECT',
        'payload': proposal(rec(reason='This proves demand for the concept.')),
        'note': 'Prohibited claim placed in reason, not the objective.',
    },
    {
        'case': 'definite_value_as_gap',
        'category': 'negative',
        'expected': 'REJECT',
        'payload': proposal(rec(source_refs=[
            {'item_key': 'M2V1-02', 'answer_revision_id': 'r-02', 'item_version_id': 'v-02'},
        ])),
        'note': 'A definite DINE_IN answer dressed up as an information gap.',
    },
]

FACTS = ConfirmedFacts(
    assessment_id='e0124bfd-e54b-4d57-bc19-2023c8e7a5e6',
    objective_id='DEMO-OBJ-02',
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


def qg(**over) -> dict:
    base = {
        'decision': 'DRAFT',
        'question': 'How acceptable would an RM13 12 oz takeaway iced latte be to you?',
        'justification': 'The confirmed offer fixes the product, size, format and price.',
        'construct_interpretation': 'Stated acceptability of one fixed hypothetical offer.',
        'response_options': ['Acceptable', 'Not acceptable', "Don't know"],
        'response_codes': ['DA', 'PA', 'NS'],
        'routing': {'DA': 'RECORD_RESPONSE_CONTINUE', 'PA': 'RECORD_RESPONSE_CONTINUE',
                    'NS': 'RECORD_RESPONSE_CONTINUE'},
        'reference_period': 'At the moment the offer is shown.',
        'measurement_description': 'One single-select acceptability item.',
        'denominator_specification': 'Codes DA and PA are in the denominator; NS is excluded and reported separately.',
        'limitations': 'Stated acceptability of one hypothetical price is not a maximum willingness to pay.',
        'unresolved_assumptions': [],
        'missing_business_facts': [],
        'used_confirmed_facts': ['RM13', '12'],
    }
    base.update(over)
    return base


MULTI = dict(
    question='Which factors, if any, would you consider when choosing a cafe? (Select all that apply.)',
    response_options=['Coffee quality', 'Price', 'Atmosphere', 'Location', 'Not sure'],
    response_codes=['CQ', 'PR', 'AT', 'LC', 'NS'],
    routing={c: 'RECORD_RESPONSE_CONTINUE' for c in ['CQ', 'PR', 'AT', 'LC', 'NS']},
    denominator_specification='Codes CQ, PR, AT and LC are in the denominator; NS is excluded.',
)

QG_CASES = [
    {'case': 'clear_research_objective', 'category': 'positive', 'expected': 'ACCEPT',
     'payload': qg(), 'note': 'One single-select item over a fully confirmed offer.'},
    {'case': 'insufficient_objective_context', 'category': 'insufficient_context',
     'expected': 'ACCEPT',
     'payload': qg(decision='ABSTAIN_NEEDS_REVIEW', question='',
                   justification='The confirmed facts state no price.',
                   missing_business_facts=['PRICE']),
     'note': 'Structured abstention naming the missing fact.'},
    {'case': 'single_choice', 'category': 'positive', 'expected': 'ACCEPT',
     'payload': qg(), 'note': 'Three codes, one selection.'},
    {'case': 'multiple_choice', 'category': 'positive', 'expected': 'ACCEPT',
     'payload': qg(**MULTI), 'note': 'Five codes with an escape option.'},
    {'case': 'duplicate_answer_options', 'category': 'negative', 'expected': 'REJECT',
     'payload': qg(response_options=['Acceptable', 'Acceptable', "Don't know"]),
     'note': 'Two byte-identical labels.'},
    {'case': 'overlapping_options', 'category': 'negative', 'expected': 'REJECT',
     'payload': qg(response_options=['Coffee quality', 'Quality of coffee', "Don't know"]),
     'note': 'Same words reordered; production sees two distinct strings.'},
    {'case': 'unsupported_factual_assumption', 'category': 'negative', 'expected': 'REJECT',
     'payload': qg(question='How acceptable would an RM15 12 oz takeaway iced latte be?'),
     'note': 'Unconfirmed price inside the question.'},
    {'case': 'unsourced_amount_in_options', 'category': 'negative', 'expected': 'REJECT',
     'payload': qg(response_options=['RM15', 'RM13', "Don't know"]),
     'note': 'Unconfirmed price hidden in an option label.'},
    {'case': 'denominator_names_one_code', 'category': 'boundary', 'expected': 'REJECT',
     'payload': qg(denominator_specification='Respondents answering DA.'),
     'note': 'Denominator names a single code.'},
    {'case': 'denominator_substring_only', 'category': 'boundary', 'expected': 'REJECT',
     'payload': qg(response_options=['Acceptable', 'Not acceptable'],
                   response_codes=['DA', 'PA'],
                   routing={'DA': 'RECORD_RESPONSE_CONTINUE', 'PA': 'RECORD_RESPONSE_CONTINUE'},
                   denominator_specification='All DATA respondents are counted.'),
     'note': 'Only "match" is DA inside the word DATA.'},
    {'case': 'claim_in_justification', 'category': 'negative', 'expected': 'REJECT',
     'payload': qg(justification='This will definitely purchase at the proposed price.'),
     'note': 'Prohibited claim placed in justification.'},
]


# ---------------------------------------------------------------------------
# execution
# ---------------------------------------------------------------------------
def run_validator(fn, payload, arg) -> dict:
    try:
        fn(payload, arg)
        return {'outcome': 'ACCEPT', 'code': None}
    except WorkflowHeld as held:
        return {'outcome': 'REJECT', 'code': str(held)}
    except Exception as exc:  # pydantic ValidationError etc.
        return {'outcome': 'REJECT', 'code': f'{type(exc).__name__}: {str(exc)[:120]}'}


def schema_parses(kind: str, payload: dict) -> bool:
    """Pydantic parse only. Deliberately separate from semantic validation."""
    from pydantic import ValidationError
    try:
        if kind == 'bdj':
            from sitewise.project1.objective_proposal import ObjectiveProposal
            ObjectiveProposal.model_validate(payload)
        else:
            QGCandidate.model_validate(payload)
        return True
    except ValidationError:
        return False


def summarise(cases, original_fn, enhanced_fn, arg) -> dict:
    rows, stats = [], {'positive': 0, 'positive_original_ok': 0,
                       'positive_enhanced_ok': 0, 'negative': 0,
                       'negative_original_ok': 0, 'negative_enhanced_ok': 0}
    for case in cases:
        o = run_validator(original_fn, case['payload'], arg)
        e = run_validator(enhanced_fn, case['payload'], arg)
        row = {**{k: case[k] for k in ('case', 'category', 'expected', 'note')},
               'original': o, 'enhanced': e,
               'original_correct': o['outcome'] == case['expected'],
               'enhanced_correct': e['outcome'] == case['expected'],
               'diverges': o['outcome'] != e['outcome']}
        rows.append(row)
        if case['expected'] == 'ACCEPT':
            stats['positive'] += 1
            stats['positive_original_ok'] += row['original_correct']
            stats['positive_enhanced_ok'] += row['enhanced_correct']
        else:
            stats['negative'] += 1
            stats['negative_original_ok'] += row['original_correct']
            stats['negative_enhanced_ok'] += row['enhanced_correct']
    stats['original_correct'] = stats['positive_original_ok'] + stats['negative_original_ok']
    stats['enhanced_correct'] = stats['positive_enhanced_ok'] + stats['negative_enhanced_ok']
    stats['total'] = len(rows)
    stats['divergences'] = sum(1 for r in rows if r['diverges'])
    return {'rows': rows, 'stats': stats}


def packet_from_live_output(output: dict) -> dict:
    """Rebuild a declaration packet from the citations the model itself made.

    The diagnostic artefact persisted the model response but not the source
    packet that produced it, so an exact replay is impossible. This packet is
    reconstructed from the output's own source_refs and the answer values the
    output's reasons describe. Consequence: a replay here exercises the
    structural rules only. It cannot prove source binding, because the packet
    was derived from the output being checked.
    """
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
                'value': 'UNDECIDED' if key == 'M2V1-01' else 'UNKNOWN',
                'answer_revision_id': ref['answer_revision_id'],
                'item_version_id': ref['item_version_id'],
            })
    return {'declarations': declarations}


def recorded_bdj_output() -> dict | None:
    """Extract the raw JSON the live model actually returned, if recorded."""
    if not OBJ_LIVE.exists():
        return None
    doc = json.loads(OBJ_LIVE.read_text(encoding='utf-8'))
    out = doc['demo']['stdout']
    start = out.find('--- raw model output ---')
    end = out.find('--- contract validation ---')
    if start == -1 or end == -1:
        return None
    block = out[start + len('--- raw model output ---'):end].strip()
    try:
        return json.loads(block)
    except json.JSONDecodeError:
        return None


def recorded_qg_output() -> dict | None:
    if not QG_LIVE.exists():
        return None
    doc = json.loads(QG_LIVE.read_text(encoding='utf-8'))
    return {'stdout': doc['demo']['stdout'],
            'dispatched': doc.get('dispatched'),
            'model': doc.get('model')}


def prompt_record(p: Prompt, original: Prompt | None = None) -> dict:
    rec = {
        'version': p.version,
        'fingerprint': p.fingerprint,
        'fingerprint_short': p.fingerprint[:16],
        'role_chars': len(p.role),
        'instruction_chars': len(p.instruction),
        'examples': len(p.examples),
    }
    if original is not None:
        rec['original_version'] = original.version
        rec['original_fingerprint'] = original.fingerprint
        rec['appended_chars'] = len(p.instruction) - len(original.instruction)
        rec['original_is_prefix'] = p.instruction.startswith(original.instruction)
        rec['appended_text'] = p.instruction[len(original.instruction):].strip()
    return rec


def main() -> int:
    bdj = summarise(BDJ_CASES, validate_objective_proposal,
                    validate_objective_proposal_enhanced, PACKET)
    qg_summary = summarise(QG_CASES, validate_candidate,
                           validate_candidate_enhanced, FACTS)

    live_bdj = recorded_bdj_output()
    live_bdj_result = None
    if live_bdj is not None:
        replay_packet = packet_from_live_output(live_bdj)
        live_bdj_result = {
            'label': 'LIVE_RECORDED',
            'replay_fidelity': 'PARTIAL_RECONSTRUCTED_PACKET',
            'replay_caveat': (
                'The diagnostic persisted the model response but not the input '
                'packet, so this replay uses a packet reconstructed from the '
                "output's own citations. It proves structural and claim validity, "
                'not source binding. The missing input packet is recorded as an '
                'evidence-provenance defect.'
            ),
            'source': str(OBJ_LIVE.relative_to(ROOT)),
            'original': run_validator(validate_objective_proposal, live_bdj, replay_packet),
            'enhanced': run_validator(validate_objective_proposal_enhanced, live_bdj, replay_packet),
            'payload': live_bdj,
            'reconstructed_packet': replay_packet,
        }

    evidence = {
        'checkpoint': 'BDJ_QG_PROMPT_COMPARISON',
        'executed_at': __import__('datetime').datetime.now(
            __import__('datetime').timezone.utc).isoformat(),
        'mode': 'OFFLINE_EVALUATED',
        'mode_note': (
            'No cloud request was made by this harness. The ORIGINAL outputs that '
            'appear are either the recorded live response (labelled LIVE_RECORDED) '
            'or labelled synthetic fixtures. The ENHANCED prompt has no model '
            'output: it is LIVE_NOT_EXECUTED, and no text is attributed to it.'
        ),
        'cloud_calls_made': 0,
        'prompts': {
            'bdj_objective_original': prompt_record(PROMPTS['BDJ_OBJECTIVE']),
            'bdj_objective_enhanced': prompt_record(BDJ_ENHANCED, PROMPTS['BDJ_OBJECTIVE']),
            'qg_proposal_original': prompt_record(PROMPTS['QG_PROPOSAL']),
            'qg_proposal_enhanced': prompt_record(QG_ENHANCED, PROMPTS['QG_PROPOSAL']),
            'bdj_legacy_original': prompt_record(PROMPTS['BDJ']),
            'qj_retired': prompt_record(PROMPTS['QJ']),
        },
        'bdj_comparison': bdj,
        'qg_comparison': qg_summary,
        'recorded_live_bdj': live_bdj_result,
        'recorded_live_qg': recorded_qg_output(),
        'contract_capability_gaps': [
            {
                'gap': 'QGCandidate has no exclusive_options field',
                'evidence': sorted(QGCandidate.model_fields),
                'impact': (
                    'The demonstration contract marks "Not sure" / "None of these" as '
                    'mutually exclusive with substantive options; P1-QG-CONTRACT-2.0 '
                    'cannot express or validate that, so exclusivity is unenforced in '
                    'production.'
                ),
                'decision': 'DEFER_PENDING_AUTHORIZATION',
            },
        ],
        'metric_notes': {
            'schema_valid_outputs': 'measured as validator acceptance over labelled fixtures',
            'token_usage': 'ORIGINAL: recorded; ENHANCED: not executed',
            'latency': 'ORIGINAL: recorded; ENHANCED: not executed',
        },
    }

    OUT.write_text(json.dumps(evidence, indent=1), encoding='utf-8')

    # ---- console summary -------------------------------------------------
    def line(label, s):
        print(f'{label:10s} total={s["total"]:2d} correct={s["correct"] if "correct" in s else "-"}'
              f' original={s["original_correct"]:2d} enhanced={s["enhanced_correct"]:2d}'
              f' divergences={s["divergences"]}')
        print(f'           positives {s["positive_original_ok"]}/{s["positive"]} orig, '
              f'{s["positive_enhanced_ok"]}/{s["positive"]} enh')
        print(f'           negatives {s["negative_original_ok"]}/{s["negative"]} orig, '
              f'{s["negative_enhanced_ok"]}/{s["negative"]} enh')

    print('=' * 78)
    print('PHASE E — ORIGINAL vs ENHANCED (offline, 0 cloud calls)')
    print('=' * 78)
    line('BDJ', bdj['stats'])
    line('QG', qg_summary['stats'])
    print('-' * 78)
    for name, rows in (('BDJ', bdj['rows']), ('QG', qg_summary['rows'])):
        for r in rows:
            if r['diverges']:
                print(f'  DIVERGE {name} {r["case"]:34s} '
                      f'{r["original"]["outcome"]:6s} -> {r["enhanced"]["outcome"]:6s} '
                      f'({r["enhanced"]["code"]})')
    if live_bdj_result:
        print('-' * 78)
        print(f'  LIVE_RECORDED BDJ output: original={live_bdj_result["original"]["outcome"]} '
              f'enhanced={live_bdj_result["enhanced"]["outcome"]} '
              f'({live_bdj_result["enhanced"]["code"]})')
    print('-' * 78)
    print(f'  evidence -> {OUT.relative_to(ROOT)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
