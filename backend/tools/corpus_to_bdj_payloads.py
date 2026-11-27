"""Compile the 30-scenario corpus into M2V2 source packets the real prompt consumes.

The problem this solves
-----------------------
``deliverables/experimental_eval_20261126/EVALUATION_DATASET.jsonl`` holds thirty
scenarios written as **prose** — ``"Area: Johor Bahru city centre"``,
``"price 12.00 declared as hypothesis, not verified"``. The BDJ objective prompt does
not consume prose. It consumes a **source packet**: the 19-item M2 V2 projection, each
declaration carrying its registered question text, its item and answer revision
identities, the exact stored value, the registered meaning of every code, and a
fingerprint that ``verify_m2v2_projection`` can recompute from the packet alone.

So the corpus cannot be fed to the prompt as it stands, and a pilot run on it would
measure the adapter rather than the prompt. This script is the adapter, and it is
deliberately the *only* one: it reuses the production projector's own helpers
(``response_meanings``, ``_display``, ``digest``, ``NOT_ANSWERED``,
``SCHEMA_VERSION``, ``M2V2_ITEMS``) so the packet it emits is structurally identical
to what the server emits, and it validates every packet with the production
``verify_m2v2_projection`` — a verifier that refuses an invented answer on an
unanswered item.

The rule that governs every mapping
-----------------------------------
**Never invent a value.** A prose declaration is mapped to a registered option code
only when a keyword in the declared table below matches it. When nothing matches, the
item is left without an answer row and the projection records ``NOT_ANSWERED``. That
is not a gap in the adapter; it is the difference between a corpus that says "the
entrepreneur declared this" and one that says "we assumed it".

Instrument scope — a finding, not a filter
------------------------------------------
The M2 V2 instrument is written for a **café**. Its product categories are
``COFFEE`` / ``BAKED_GOODS`` / ``LIGHT_MEALS``; its occasions are ``QUICK_PURCHASE`` /
``STUDY_WORK`` / ``MEAL_SNACK``. Eleven of the thirty scenarios describe businesses
that instrument cannot represent — a laundry, a climbing gym, a co-working space.
Compiling those would require inventing option codes, which is exactly what the rule
above forbids. Two more are refused for reasons that are not about the instrument at
all: S13 withholds the concept, and S12 describes a defect in its own declarations
rather than a business. Those are counted separately, because folding them into
"out of scope" would overstate how café-specific the instrument is.

The thirteen are therefore **not compiled**. Each one is emitted as a refusal record
naming the items that cannot be represented, and the conversion report counts them. A
pilot that silently compiled a laundry into a café projection would be measuring the
compiler's imagination.

Usage:
    backend/.venv/Scripts/python.exe tools/corpus_to_bdj_payloads.py
    backend/.venv/Scripts/python.exe tools/corpus_to_bdj_payloads.py --check
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
DATASET = (REPO / 'deliverables/experimental_eval_20261126'
           / 'EVALUATION_DATASET.jsonl')
OUT_DIR = REPO / 'deliverables/pilot_20261126/payloads'
INDEX = OUT_DIR / 'INDEX.json'
INSTRUMENT = BACKEND / 'src/sitewise/instruments/m2v2_20261122/definition.json'

sys.path.insert(0, str(BACKEND / 'src'))

from sitewise.project1.contracts import digest  # noqa: E402
from sitewise.project1.m2v2_projection import (  # noqa: E402
    M2V2_ITEMS, M2V2_VERSION, NOT_ANSWERED, SCHEMA_VERSION, _display,
    response_meanings, verify_m2v2_projection)

NAMESPACE = uuid.UUID('7c1e4b90-0000-4000-8000-000000000000')
TRUST_CLASS = 'SYNTHETIC_NONHUMAN'

#: The six mandatory objectives, and the M2V2-09 research topic each one is about.
#: This is the only mapping in this file that is exact rather than heuristic: the
#: objectives were derived from these codes in the first place.
OBJECTIVE_TOPICS = {
    'O1': 'CONCEPT_INTEREST',
    'O2': 'PRODUCT_PREFERENCE',
    'O3': 'PRICE_ACCEPTABILITY',
    'O4': 'SERVICE_PREFERENCE',
    'O5': 'EXPERIENCE_PREFERENCE',
    'O6': 'SEGMENT_INTEREST',
}

#: Words that put a scenario inside the instrument's scope. The instrument asks about
#: "your proposed café", its product categories and its customer occasions; a business
#: with no food or beverage service has no registered answer to those questions.
#:
#: Deliberately narrow. ``food`` and ``kitchen`` are absent because they appear in
#: declarations that describe something else — a convenience store's "range: packaged
#: food and household" is not a café, and matching it would have compiled a 24-hour
#: shop into a café projection.
FOOD_SERVICE_NOUNS = (
    'cafe', 'café', 'coffee', 'bakery', 'bakehouse', 'bubble tea', 'tea house',
    'restaurant', 'eatery', 'bistro', 'patisserie',
)

#: Phrases that contain a food-service noun but name a different business. "Repair
#: café" is a repair shop; the word is a fashion, not a service format. Checked before
#: the noun list, so these override a match rather than competing with it.
NOT_FOOD_SERVICE_PHRASES = (
    'repair cafe', 'repair café', 'bike cafe', 'bike café',
    'cat cafe', 'internet cafe', 'internet café',
)

#: M2V2-01 GEO. Matched on the declared area text.
AREA_CODES = (
    ('kuala lumpur', 'KUALA_LUMPUR'), (' kl ', 'KUALA_LUMPUR'),
    ('johor', 'JOHOR'), ('penang', 'PENANG'), ('selangor', 'SELANGOR'),
)

#: M2V2-02 / M2V2-15 service format. Order matters: the most specific wins.
FORMAT_CODES = (
    ('counter and pre-order', 'HYBRID'),
    ('dine-in and takeaway', 'HYBRID'),
    ('dine in and takeaway', 'HYBRID'),
    ('dine-in', 'DINE_IN'), ('dine in', 'DINE_IN'),
    ('takeaway', 'TAKEAWAY'), ('take-away', 'TAKEAWAY'),
    ('delivery', 'DELIVERY'),
    ('counter', 'HYBRID'),
)

#: M2V2-03 product categories.
CATEGORY_CODES = (
    ('coffee', 'COFFEE'), ('espresso', 'COFFEE'), ('filter', 'COFFEE'),
    ('bubble tea', 'NON_COFFEE'), ('tea', 'NON_COFFEE'),
    ('bakery', 'BAKED_GOODS'), ('bread', 'BAKED_GOODS'), ('loaf', 'BAKED_GOODS'),
    ('pastr', 'BAKED_GOODS'), ('cake', 'BAKED_GOODS'),
    ('menu', 'LIGHT_MEALS'), ('meal', 'LIGHT_MEALS'), ('sandwich', 'LIGHT_MEALS'),
    ('dessert', 'DESSERTS'),
)

#: M2V2-04 customer groups.
GROUP_CODES = (
    ('office worker', 'OFFICE_WORKERS'), ('office tower', 'OFFICE_WORKERS'),
    ('student', 'STUDENTS'), ('school', 'STUDENTS'), ('university', 'STUDENTS'),
    ('remote worker', 'REMOTE_WORKERS'), ('co-working', 'REMOTE_WORKERS'),
    ('resident', 'RESIDENTS'), ('neighbourhood', 'RESIDENTS'),
    ('suburb', 'RESIDENTS'), ('commuter', 'RESIDENTS'),
    ('visitor', 'VISITORS'), ('tourist', 'VISITORS'), ('mall', 'VISITORS'),
)

#: M2V2-06 concept emphasis.
EMPHASIS_CODES = (
    ('affordab', 'AFFORDABILITY'), ('cheap', 'AFFORDABILITY'),
    ('value', 'AFFORDABILITY'),
    ('quality', 'QUALITY'), ('speciality', 'QUALITY'), ('specialty', 'QUALITY'),
    ('convenien', 'CONVENIENCE'), ('quick', 'CONVENIENCE'), ('speed', 'CONVENIENCE'),
    ('ambience', 'AMBIENCE'), ('cosy', 'AMBIENCE'), ('cozy', 'AMBIENCE'),
    ('distinctive', 'DISTINCTIVE_CONCEPT'), ('unique', 'DISTINCTIVE_CONCEPT'),
    ('concept', 'DISTINCTIVE_CONCEPT'),
)

#: M2V2-07 customer occasion.
OCCASION_CODES = (
    ('quick', 'QUICK_PURCHASE'), ('grab', 'QUICK_PURCHASE'),
    ('study', 'STUDY_WORK'), ('work', 'STUDY_WORK'), ('laptop', 'STUDY_WORK'),
    ('social', 'SOCIAL'), ('meet', 'SOCIAL'), ('catch up', 'SOCIAL'),
    ('snack', 'MEAL_SNACK'), ('meal', 'MEAL_SNACK'), ('lunch', 'MEAL_SNACK'),
    ('leisure', 'LEISURE'), ('browse', 'LEISURE'), ('relax', 'LEISURE'),
)

#: The single instrument item whose absence makes the whole projection unusable for
#: BDJ: without a declared concept there is nothing to review.
CONCEPT_ITEM = 'M2V2-12'


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'), allow_nan=False)


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def _load_dataset() -> list[dict]:
    rows = [json.loads(line) for line in
            DATASET.read_text(encoding='utf-8').splitlines() if line.strip()]
    if len(rows) != 30:
        raise SystemExit(f'expected 30 scenarios, found {len(rows)}')
    return rows


def _instrument() -> tuple[dict, dict[str, dict]]:
    definition = json.loads(INSTRUMENT.read_text(encoding='utf-8-sig'))
    items = {item['item_key']: item for item in definition['items']}
    if set(items) != M2V2_ITEMS:
        raise SystemExit('the instrument does not hold the 19 registered items')
    return definition, items


# ---------------------------------------------------------------------------
# scope classification
# ---------------------------------------------------------------------------

#: Concept text that describes the corpus's own data defect rather than a business.
#: S12's concept is "Contradictory price declarations": it names two prices and no
#: trade, so refusing it as *out of instrument scope* would blame the instrument for
#: a gap in the scenario. The distinction is not cosmetic — it decides whether the
#: finding reads "the instrument is café-specific" or "this scenario withheld the
#: business type".
META_CONCEPT_MARKERS = (
    'declaration', 'contradictory', 'conflict', 'incomplete', 'missing',
)


def _haystack(scenario: dict) -> str:
    parts = [scenario.get('concept') or '']
    parts += scenario.get('business_declarations') or []
    return ' ' + ' '.join(parts).lower() + ' '


def classify(scenario: dict) -> tuple[str, str]:
    """IN_SCOPE / NO_CONCEPT / NO_BUSINESS_TYPE / OUT_OF_SCOPE, with the reason.

    Total: every scenario gets exactly one verdict. The three refusals are kept
    apart because they are different facts about different things — one says the
    instrument does not fit, one says the corpus withheld the concept on purpose
    (S13 tests exactly that), and one says the corpus described a data defect
    instead of a business (S12 names two prices and no trade).
    """
    concept = (scenario.get('concept') or '').strip().lower()
    if not concept or 'not stated' in concept or 'no concept' in concept:
        return 'NO_CONCEPT', 'the scenario deliberately states no concept'
    hay = _haystack(scenario)
    for phrase in NOT_FOOD_SERVICE_PHRASES:
        if phrase in hay:
            return ('OUT_OF_SCOPE',
                    f'"{phrase}" names a non-food business despite the word it '
                    'contains; the M2 V2 instrument does not describe it')
    if any(noun in hay for noun in FOOD_SERVICE_NOUNS):
        return 'IN_SCOPE', 'a food or beverage service the M2 V2 instrument addresses'
    if any(marker in concept for marker in META_CONCEPT_MARKERS):
        return ('NO_BUSINESS_TYPE',
                'the concept describes a defect in the declarations rather than a '
                'business, so there is no trade for the instrument to describe')
    return ('OUT_OF_SCOPE',
            'the scenario does not name a food or beverage service, so the '
            "instrument's product categories, occasions and service formats have no "
            'referent to select from')


#: Trades that sell food or drink as a sideline. "Bookshop with coffee corner" is in
#: scope for its beverage trade and for nothing else, so it is compiled *and* marked.
#: Kept explicit rather than inferred from the absence of a food noun: S26 names
#: "coffee" in its concept, so a rule keyed on that absence would never fire — which
#: is exactly how the first version of this function failed to flag the one scenario
#: it was written for.
NON_FOOD_TRADE_NOUNS = (
    'bookshop', 'bookstore', 'books', 'florist', 'flowers', 'barber', 'salon',
    'gallery', 'pharmacy', 'laundrette', 'hardware', 'stationery', 'boutique',
    'plant shop', 'gift shop', 'convenience store',
)


def hybrid_note(scenario: dict) -> str | None:
    """Flag a scenario whose food-service trade is only part of a larger business.

    ``S26 — Bookshop with coffee corner`` sells coffee but is not a café. The
    instrument fits its beverage trade and not the rest, so it is compiled **and**
    marked, rather than quietly treated as a full café.
    """
    concept = (scenario.get('concept') or '').lower()
    food = [noun for noun in FOOD_SERVICE_NOUNS if noun in concept]
    trade = [noun for noun in NON_FOOD_TRADE_NOUNS if noun in concept]
    if not food or not trade:
        return None
    return (f'the concept names both a food-service trade ({food[0]}) and a non-food '
            f'business ({trade[0]}); this is a hybrid business and the instrument '
            'fits only its food-service trade')


# ---------------------------------------------------------------------------
# prose -> registered codes
# ---------------------------------------------------------------------------

def _first_match(hay: str, table) -> str | None:
    for token, code in table:
        if token in hay:
            return code
    return None


def _all_matches(hay: str, table) -> list[str]:
    found: list[str] = []
    for token, code in table:
        if token in hay and code not in found:
            found.append(code)
    return found


def _answers_for(scenario: dict) -> dict[str, object]:
    """The answers the prose actually establishes. Nothing else is added.

    Every value here is traceable to a substring of ``concept`` or
    ``business_declarations``; the conversion report records the token that matched so
    a reviewer can disagree with a specific line rather than with the adapter.
    """
    hay = _haystack(scenario)
    answers: dict[str, object] = {}

    area = _first_match(hay, AREA_CODES)
    if area:
        answers['M2V2-01'] = area

    fmt = _first_match(hay, FORMAT_CODES)
    if fmt:
        answers['M2V2-02'] = fmt

    categories = _all_matches(hay, CATEGORY_CODES)
    if categories:
        answers['M2V2-03'] = categories

    groups = _all_matches(hay, GROUP_CODES)
    if groups:
        answers['M2V2-04'] = groups
        # M2V2-05 has no option set of its own: it names one of the groups chosen
        # at M2V2-04, so it is only answerable once that answer exists.
        answers['M2V2-05'] = groups[0]

    emphasis = _first_match(hay, EMPHASIS_CODES)
    if emphasis:
        answers['M2V2-06'] = emphasis

    occasion = _first_match(hay, OCCASION_CODES)
    if occasion:
        answers['M2V2-07'] = occasion

    # M2V2-09 is the one exact mapping: the scenario names the mandatory objectives
    # it bears on, and those objectives were derived from these very codes.
    topics = [OBJECTIVE_TOPICS[o] for o in
              (scenario.get('relevant_mandatory_objectives') or [])
              if o in OBJECTIVE_TOPICS]
    topics = list(dict.fromkeys(topics))
    if topics:
        answers['M2V2-09'] = topics
        answers['M2V2-10'] = topics[0]

    return answers


# ---------------------------------------------------------------------------
# packet construction — the same shape build_packet() emits
# ---------------------------------------------------------------------------

def compile_packet(scenario: dict, definition: dict,
                   items: dict[str, dict]) -> dict:
    scenario_id = scenario['scenario_id']
    assessment_id = uuid.uuid5(NAMESPACE, f'{scenario_id}:assessment')
    answers = _answers_for(scenario)

    declarations = []
    for item in sorted(items.values(), key=lambda i: (i['sort_order'],
                                                      i['item_key'])):
        key = item['item_key']
        if item['lifecycle'] != 'ACTIVE' or item['answer_kind'] == 'ACTION':
            continue
        meanings = response_meanings(item, items)
        if key in answers:
            state = 'ANSWERED'
            value = answers[key]
            revision_id = str(uuid.uuid5(NAMESPACE, f'{scenario_id}:{key}:answer'))
            revision = 1
        else:
            # No answer row. NOT_ANSWERED is the projection's own word for that; it
            # is deliberately not one of the instrument's allowed_states, so a reader
            # cannot confuse "not answered yet" with "recorded as not provided".
            state, value, revision_id, revision = NOT_ANSWERED, None, None, None
        declarations.append({
            'item_key': key,
            'question': item['question_text'],
            'item_version_id': str(uuid.uuid5(NAMESPACE, f'instrument:{key}')),
            'definition_digest': digest(item),
            'answer_revision_id': revision_id,
            'answer_revision': revision,
            'answer_state': state,
            'value': value,
            'answer_display': _display(item, state, value, meanings),
            'answer_kind': item['answer_kind'],
            'requiredness': item['requiredness'],
            'response_meanings': meanings,
            'trust_class': TRUST_CLASS,
        })

    answered = sum(1 for d in declarations if d['answer_state'] != NOT_ANSWERED)
    packet = {
        'schema_version': SCHEMA_VERSION,
        'assessment_id': str(assessment_id),
        'assessment_revision': 1,
        'instrument_id': str(uuid.uuid5(NAMESPACE, 'instrument')),
        'instrument_version': definition['version_tag'],
        'instrument_digest': definition['source_sha256'],
        'instrument_authorization': {
            'state': definition['adoption']['approval_state'],
            'usable': True,
            'basis': 'SYNTHETIC_SCOPE',
        },
        'declarations': declarations,
        'declaration_count': len(declarations),
        'answered_count': answered,
        'unanswered_count': len(declarations) - answered,
        'governance_items': [],
        'excluded_items': {},
        'confirmed': True,
        'facts_independently_verified': False,
        'evidence_boundary': (
            'Entrepreneur declarations only. No demand, willingness to pay, '
            'profitability, market size or viability is established by this source.'),
        'synthetic_provenance': {
            'class': TRUST_CLASS,
            'corpus': 'deliverables/experimental_eval_20261126/EVALUATION_DATASET.jsonl',
            'scenario_id': scenario_id,
            'compiled_by': 'backend/tools/corpus_to_bdj_payloads.py',
            'note': ('Compiled from prose for evaluation only. Not an entrepreneur '
                     'submission, not a confirmed revision, and not admissible as '
                     'evidence of any business fact.'),
        },
    }
    return {**packet, 'source_fingerprint': digest(packet)}


def _unrepresentable(scenario: dict, items: dict[str, dict]) -> list[dict]:
    """The items a scenario's business has no registered answer for."""
    hay = _haystack(scenario)
    rows = []
    for key in ('M2V2-03', 'M2V2-06', 'M2V2-07'):
        item = items[key]
        options = (item.get('option_values') or {}).get('options') or []
        codes = [o['code'] for o in options if o.get('code')]
        matched = [c for c in codes if c.lower() in hay]
        if not matched:
            rows.append({'item': key, 'question': item['question_text'],
                         'registered_codes': codes,
                         'why': 'no registered code describes this business'})
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true',
                        help='exit 1 if any written payload differs from a rebuild')
    args = parser.parse_args()

    scenarios = _load_dataset()
    definition, items = _instrument()

    compiled: list[dict] = []
    refused: list[dict] = []
    files: dict[str, str] = {}

    for scenario in scenarios:
        scenario_id = scenario['scenario_id']
        verdict, reason = classify(scenario)
        if verdict != 'IN_SCOPE':
            refused.append({'scenario_id': scenario_id,
                            'class': scenario.get('class'),
                            'verdict': verdict, 'reason': reason,
                            'concept': scenario.get('concept'),
                            'unrepresentable': (
                                [] if verdict == 'NO_CONCEPT'
                                else _unrepresentable(scenario, items))})
            continue

        packet = compile_packet(scenario, definition, items)
        # The production verifier: recomputes the fingerprint from the packet alone
        # and refuses an invented answer on an unanswered item.
        verify_m2v2_projection(packet)
        answers = _answers_for(scenario)
        compiled.append({
            'scenario_id': scenario_id,
            'class': scenario.get('class'),
            'answered_items': sorted(answers),
            'answered_count': packet['answered_count'],
            'unanswered_count': packet['unanswered_count'],
            'source_fingerprint': packet['source_fingerprint'],
            'expected_suitability': scenario.get('expected_suitability'),
            'hybrid_note': hybrid_note(scenario),
        })
        files[f'{scenario_id}.json'] = _canonical(packet) + '\n'

    report = {
        'contract_version': 'corpus-payload-conversion/1',
        'corpus': str(DATASET.relative_to(REPO)).replace('\\', '/'),
        'instrument': definition['version_tag'],
        'instrument_approval_state': definition['adoption']['approval_state'],
        'projection_schema': SCHEMA_VERSION,
        'scenarios_total': len(scenarios),
        'compiled': compiled,
        'refused': refused,
        'counts': {
            'compiled': len(compiled),
            'refused': len(refused),
            'refused_no_concept': sum(1 for r in refused
                                      if r['verdict'] == 'NO_CONCEPT'),
            'refused_no_business_type': sum(1 for r in refused
                                            if r['verdict'] == 'NO_BUSINESS_TYPE'),
            'refused_out_of_scope': sum(1 for r in refused
                                        if r['verdict'] == 'OUT_OF_SCOPE'),
        },
        'finding': (
            'The M2 V2 instrument is written for a café. Of the thirteen scenarios '
            'not compiled, eleven describe a business with no food or beverage '
            'service and have no registered answer for M2V2-03 (product '
            'categories), M2V2-06 (concept emphasis) or M2V2-07 (customer '
            'occasion); one withholds the concept (S13) and one describes a defect '
            'in its declarations instead of a business (S12). All thirteen are '
            'refused rather than compiled, because compiling them would require '
            'inventing option codes.'),
    }
    report_text = json.dumps(report, indent=2, ensure_ascii=False) + '\n'

    # A payload written by an earlier version of this compiler is not part of the
    # current conversion. Left on disk it would be indistinguishable from a compiled
    # scenario — a reader would find S09.json and reasonably conclude S09 compiled.
    orphans = sorted(p.name for p in OUT_DIR.glob('S*.json')
                     if p.name not in files) if OUT_DIR.exists() else []

    if args.check:
        stale = []
        if not INDEX.exists() or INDEX.read_text(encoding='utf-8') != report_text:
            stale.append(str(INDEX))
        for name, body in files.items():
            path = OUT_DIR / name
            if not path.exists() or path.read_text(encoding='utf-8') != body:
                stale.append(str(path))
        if orphans:
            stale.extend(f'{OUT_DIR / name}  (orphan: not in the index)' for name
                         in orphans)
        if stale:
            print('STALE:')
            for path in stale:
                print('  ', path)
            return 1
        print(f'OK  {len(files)} payloads + index, {len(compiled)} compiled, '
              f'{len(refused)} refused')
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, body in files.items():
        (OUT_DIR / name).write_text(body, encoding='utf-8')
    INDEX.write_text(report_text, encoding='utf-8')
    for name in orphans:
        (OUT_DIR / name).unlink()

    print(f'wrote {len(files)} payloads to '
          f'{OUT_DIR.relative_to(REPO)}')
    print(f'  compiled        : {len(compiled)}')
    print(f'  refused         : {len(refused)} '
          f'({report["counts"]["refused_no_concept"]} no concept, '
          f'{report["counts"]["refused_no_business_type"]} no business type, '
          f'{report["counts"]["refused_out_of_scope"]} out of instrument scope)')
    print(f'  answered items  : '
          f'{sorted({n for c in compiled for n in c["answered_items"]})}')
    print(f'  refused ids     : {[r["scenario_id"] for r in refused]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
