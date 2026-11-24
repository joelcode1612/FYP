"""Candidate M2V2 BDJ rules module — NOT an adopted production rules module.

Every rule here restates a literal declared uncertainty already present in a
confirmed M2V2 answer. Nothing infers a business fact, a contradiction, a
demand level or a missing threshold, and nothing creates a research objective.

Deliberately **absent from ``RULE_MODULES``**: the M2V1 proposal artefact
declared ``ADOPTED = False`` while the registry listed it, and that
contradiction is what produced the ``ADOPTION_EVIDENCE_INCOMPLETE`` finding.
This module avoids repeating it — registration happens at adoption, not before.

Importable for isolated conformance tests. Never dispatches a provider.
"""
from sitewise.project1.projection import verify_projection
from sitewise.project1.contracts import WorkflowHeld

RULE_VERSION = 'BDJ-M2V2-IG-0.1-PROP'
STATUS = 'PROPOSED_NOT_ADOPTED'
ADOPTED = False
INSTRUMENT_VERSION = 'M2V2-20261122-1'
SUPPORTED_INSTRUMENT_VERSIONS = ('M2V2-20261122-1',)

# Every entry is an explicit information gap: the entrepreneur declared, in
# their own answer, that the thing is not decided, not known, or not sure.
# ``field`` is None for a flat answer (scalar or multi-select) and names the
# structured field for a COMPOSITE answer. ``quote`` is always the literal
# itself, which is an exact substring of the declared value — never question
# text, ``answer_display`` or a ``response_meanings`` label.
RULE_CATALOGUE = (
    {'rule_id': 'M2V2_EXPLICIT_PLANNING_UNDECIDED', 'kind': 'INFORMATION_GAP',
     'source_keys': ('M2V2-01', 'M2V2-02', 'M2V2-03', 'M2V2-04', 'M2V2-06', 'M2V2-07'),
     'literal': 'UNDECIDED', 'field': None},
    {'rule_id': 'M2V2_EVIDENCE_INVENTORY_UNKNOWN', 'kind': 'INFORMATION_GAP',
     'source_keys': ('M2V2-08',), 'literal': 'UNKNOWN', 'field': None},
    {'rule_id': 'M2V2_RESEARCH_DECISION_UNDECIDED', 'kind': 'INFORMATION_GAP',
     'source_keys': ('M2V2-11',), 'literal': 'UNDECIDED', 'field': None},
    {'rule_id': 'M2V2_RESEARCH_DECISION_UNSURE', 'kind': 'INFORMATION_GAP',
     'source_keys': ('M2V2-11',), 'literal': 'UNSURE', 'field': None},
    {'rule_id': 'M2V2_SERVICE_FORMATS_NOT_DECIDED', 'kind': 'INFORMATION_GAP',
     'source_keys': ('M2V2-15',), 'literal': 'NOT_DECIDED', 'field': None},
    {'rule_id': 'M2V2_PRICE_NOT_DECIDED', 'kind': 'INFORMATION_GAP',
     'source_keys': ('M2V2-14',), 'literal': 'PRICE_NOT_DECIDED', 'field': 'decision'},
    {'rule_id': 'M2V2_BUSINESS_STAGE_UNSURE', 'kind': 'INFORMATION_GAP',
     'source_keys': ('M2V2-19',), 'literal': 'UNSURE', 'field': 'stage'},
)

#: Items deliberately NOT covered, and why. Recorded so a reviewer can see the
#: exclusions are decisions rather than omissions.
EXCLUDED_ITEMS = {
    'M2V2-05': 'Conditional item derived from M2V2-04; carries no uncertainty literal of its own.',
    'M2V2-09': 'A NONE selection is a declined topic, not an information gap.',
    'M2V2-10': 'Conditional priority derived from M2V2-09; ordering only, never a gap.',
    'M2V2-12': 'review_status NOT_READY is a review workflow state, not business uncertainty.',
    'M2V2-13': 'Category domain comes from M2V2-03; product lists carry no uncertainty literal.',
    'M2V2-16': 'Feature multi-select has no UNDECIDED/UNSURE/UNKNOWN option.',
    'M2V2-17': 'Segment definitions are free-form; no uncertainty literal exists to match.',
    'M2V2-18': 'hypothesis_status values are definite answers (NO_SPECIFIC_PROBLEM, '
                'NOT_ESTABLISHED, HYPOTHESIS_IDENTIFIED). Treating them as gaps would '
                'invent a criterion; an exploratory research need is not an information gap.',
}


def _declared_values(answer):
    value = answer.get('value_json')
    return value if isinstance(value, list) else [value]


def _matches(rule, answer):
    """True only when the answer literally declares this rule's uncertainty."""
    field = rule.get('field')
    value = answer.get('value_json')
    if field is not None:
        return isinstance(value, dict) and value.get(field) == rule['literal']
    return rule['literal'] in _declared_values(answer)


def evaluate_candidate_issues(answers):
    """Existing BDJ rules-module interface, still PROPOSED and unregistered.

    Adoption also requires an owner-issued receipt; no caller can obtain that
    approval from this file.
    """
    candidates = []
    for key, answer in answers.items():
        if answer.get('answer_state') != 'ANSWERED':
            continue
        for rule in RULE_CATALOGUE:
            if key not in rule['source_keys'] or not _matches(rule, answer):
                continue
            field = rule.get('field')
            subject = f"{key}.{field}" if field else key
            candidates.append(dict(
                rule_id=rule['rule_id'], rule_version=RULE_VERSION,
                issue_type='INFORMATION_GAP', source_answer_ids=[str(answer['id'])],
                explanation=f"The confirmed response to {subject} is {rule['literal']}.",
                not_proven=('An undecided or unknown response is valid; no contradiction '
                            'or business defect is established.'),
                next_action=('Entrepreneur may clarify if relevant; do not rewrite answers '
                             'or create a research objective automatically.')))
    return candidates


def propose(packet):
    """Proposed BDJOutput. Caller still needs registered item/completeness checks.

    This helper does not authorize dispatch, register a rule, confirm a human
    choice, assess viability or turn an unresolved selection into a contradiction.
    """
    verify_projection(packet)
    if packet.get('instrument_version') != INSTRUMENT_VERSION:
        raise WorkflowHeld('BDJ_M2V2_INPUT_REQUIRED')
    if packet.get('confirmed') is not True:
        raise WorkflowHeld('BDJ_CONFIRMED_DECLARATIONS_REQUIRED')
    findings = []
    for source in packet['declarations']:
        if source['answer_state'] != 'ANSWERED':
            continue
        answer = {'value_json': source.get('value')}
        for rule in RULE_CATALOGUE:
            if source['item_key'] not in rule['source_keys'] or not _matches(rule, answer):
                continue
            field = rule.get('field')
            subject = f"{source['item_key']}.{field}" if field else source['item_key']
            findings.append(dict(
                rule_id=rule['rule_id'], kind='INFORMATION_GAP',
                source_refs=[dict(
                    item_key=source['item_key'],
                    answer_revision_id=source['answer_revision_id'],
                    item_version_id=source['item_version_id'],
                    quote=rule['literal'])],
                observed_condition=f"The confirmed response to {subject} is {rule['literal']}.",
                counterargument=('An explicitly undecided or unknown response is valid and is '
                                 'not a contradiction or business defect.'),
                justification=('This observation restates the exact source value only; no '
                               'additional business fact or research uncertainty is inferred.'),
                next_action=('Entrepreneur may clarify this response if relevant; do not alter '
                             'the answer or confirm a research objective automatically.')))
    return dict(issues=findings, overall_note=(
        'Only literal declared uncertainty observations are proposed. No contradiction, '
        'scientific acceptance, demand or viability conclusion is established.'))
