"""CP13 V2 review artefact, NOT an active/adopted production rules module.

Direct literal uncertainty observations only. D02 contradiction retirements stand.
Importable for isolated conformance tests, deliberately absent from RULE_MODULES.
"""
from sitewise.project1.projection import verify_projection
from sitewise.project1.contracts import WorkflowHeld

RULE_VERSION = 'BDJ-M2V1-IG-0.1-PROP'
STATUS = 'PROPOSED_NOT_ADOPTED'
ADOPTED = False
INSTRUMENT_VERSION = 'M2V1-20261114-1'
RULE_CATALOGUE = (
    {'rule_id':'M2V1_EXPLICIT_PLANNING_UNDECIDED','kind':'INFORMATION_GAP',
     'source_keys':('M2V1-01','M2V1-02','M2V1-03','M2V1-04','M2V1-06'), 'literal':'UNDECIDED'},
    {'rule_id':'M2V1_EVIDENCE_INVENTORY_UNKNOWN','kind':'INFORMATION_GAP',
     'source_keys':('M2V1-08',), 'literal':'UNKNOWN'},
    {'rule_id':'M2V1_RESEARCH_PURPOSE_UNSURE','kind':'INFORMATION_GAP',
     'source_keys':('M2V1-11',), 'literal':'UNSURE'},
)

def evaluate_candidate_issues(answers):
    """Existing BDJ rules-module interface, still PROPOSED and unregistered.

    Adoption also requires correcting the engine's classification adapter to
    preserve INFORMATION_GAP. No caller can obtain that approval from this file.
    """
    candidates=[]
    for key,answer in answers.items():
        if answer.get('answer_state')!='ANSWERED':continue
        value=answer.get('value_json');values=value if isinstance(value,list) else [value]
        for rule in RULE_CATALOGUE:
            if key in rule['source_keys'] and rule['literal'] in values:
                candidates.append(dict(rule_id=rule['rule_id'],rule_version=RULE_VERSION,
                    issue_type='INFORMATION_GAP',source_answer_ids=[str(answer['id'])],
                    explanation=f"The confirmed response to {key} is {rule['literal']}.",
                    not_proven='An undecided or unknown response is valid; no contradiction or business defect is established.',
                    next_action='Entrepreneur may clarify if relevant; do not rewrite answers or create a research objective automatically.'))
    return candidates

def propose(packet):
    """Proposed BDJOutput. Caller still needs registered item/completeness checks.

    This helper does not authorize dispatch, register a rule, confirm a human
    choice, assess viability or turn an unresolved selection into a contradiction.
    """
    verify_projection(packet)
    if packet.get('instrument_version') != INSTRUMENT_VERSION:
        raise WorkflowHeld('BDJ_M2V1_INPUT_REQUIRED')
    if packet.get('confirmed') is not True:
        raise WorkflowHeld('BDJ_CONFIRMED_DECLARATIONS_REQUIRED')
    findings=[]
    for source in packet['declarations']:
        if source['answer_state']!='ANSWERED':continue
        values=source['value'] if isinstance(source['value'],list) else [source['value']]
        for rule in RULE_CATALOGUE:
            if source['item_key'] not in rule['source_keys'] or rule['literal'] not in values:continue
            findings.append(dict(rule_id=rule['rule_id'],kind='INFORMATION_GAP',source_refs=[dict(
                item_key=source['item_key'],answer_revision_id=source['answer_revision_id'],
                item_version_id=source['item_version_id'],quote=rule['literal'])],
                observed_condition=f"The confirmed response to {source['item_key']} is {rule['literal']}.",
                counterargument='An explicitly undecided or unknown response is valid and is not a contradiction or business defect.',
                justification='This observation restates the exact source code only; no additional business fact or research uncertainty is inferred.',
                next_action='Entrepreneur may clarify this response if relevant; do not alter the answer or confirm a research objective automatically.'))
    return dict(issues=findings,overall_note='Only literal declared uncertainty observations are proposed. No contradiction, scientific acceptance, demand or viability conclusion is established.')
