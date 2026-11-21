"""Application adapter for the existing CUST03 validators/A2 gate interpreter.

No independent branch interpreter or new scientific rules are introduced.
"""
from sitewise.domain.customer_questionnaire import classify_answer, digest, q01_screen

FACTS = {'Q01_SCREEN','Q01_COMPLETED','Q02_VISIBLE','Q04_ANSWER',
         'APPROVED_EXACT_OFFER_STIMULUS','OPTIONAL_CONTEXT_ENABLED','CONCEPT_READY',
         'MENU_READY','OCCASION_READY','FEATURE_BANK_READY'}


class CqRefused(ValueError):
    def __init__(self, code, status=409):
        self.code,self.status=code,status
        super().__init__(code)


def verify_release(manifest, policy, contract, reference):
    if manifest.get('contract_version')!='cq-manifest/1' or manifest.get('lane') not in {'BASELINE','ENTREPRENEUR_SPECIFIC'}:
        raise CqRefused('CQ_MANIFEST_INVALID')
    items=manifest.get('questions',[])
    if [x['id'] for x in items] != [x['id'] for x in contract['items']]:
        raise CqRefused('CQ_QUESTION_IDENTITIES_INVALID')
    if policy['gate'].get('unresolved_token_policy')!='NOT_SHOWN' or policy['gate'].get('undecided_input_policy')!='NOT_SHOWN':
        raise CqRefused('CQ_UNRESOLVED_POLICY_MUST_HOLD')
    positions={q['id']:i for i,q in enumerate(items)}
    authorized=manifest.get('authorized_question_ids',[])
    if (len(authorized)!=len(set(authorized)) or not set(authorized)<=set(positions)
            or 'Q01' not in authorized or manifest.get('locales') not in (['EN'], ['EN','BM'])):
        raise CqRefused('CQ_QUESTION_AUTHORITY_INVALID')
    for kind,stimulus in manifest.get('stimuli',{}).items():
        if kind not in {'concept','menu','offer','occasion','features'} or not stimulus.get('version') or any(
                not stimulus.get('text',{}).get(lang) for lang in manifest['locales']):
            raise CqRefused('CQ_STIMULUS_VERSION_INVALID')
    order=manifest.get('stimulus_order',[])
    if len(order)!=len(set(order)) or set(order)!=set(manifest['stimuli']):
        raise CqRefused('CQ_STIMULUS_ORDER_INVALID')
    for item,source in zip(items,contract['items']):
        if item['type']!=source['type'] or item['codes']!=source['codes'] or item['validation']!=source:
            raise CqRefused('CQ_CODEBOOK_MISMATCH')
        if not isinstance(item['required_for_presentation'],bool) or not isinstance(item['required_for_answer'],bool):
            raise CqRefused('CQ_REQUIREDNESS_UNVERIFIED')
        for language in manifest['locales']:
            if not item['wording'].get(language) or set(item['labels'].get(language,{})) != set(source['codes']):
                raise CqRefused('CQ_LANGUAGE_VERSION_INCOMPLETE')
        if any(d not in positions or positions[d]>=positions[item['id']] for d in item['dependencies']):
            raise CqRefused('CQ_ROUTING_DEPENDENCY_INVALID')
        expected=[] if item['id']=='Q01' else ['Q01']+(['Q04'] if item['id']=='Q08' else [])
        if item['dependencies']!=expected:
            raise CqRefused('CQ_ROUTING_DEPENDENCY_INVALID')
        token=policy['item_show_gate'].get(item['id'])
        if token not in policy['gate']['token_predicates']:
            raise CqRefused('CQ_GATE_UNREGISTERED')
        features=item['feature_ids']
        if (len(features)!=len(set(features)) or len(features)>4 or
                (features and item['id']!='Q10') or any(not isinstance(f,str) or not f or ':' in f for f in features)):
            raise CqRefused('CQ_FEATURE_BANK_INVALID')
        if item['id']=='Q10' and item['id'] in authorized and 'features' in manifest['stimuli'] and not features:
            raise CqRefused('CQ_FEATURE_BANK_INVALID')
    for predicate in policy['gate']['token_predicates'].values():
        for clause in predicate.get('clauses',[]):
            # The sealed A2 interpreter only implements a true const. Reject
            # unsupported false consts rather than editing its pinned bytes.
            if clause.get('op')=='const':
                if clause.get('value') is not True: raise CqRefused('CQ_UNSUPPORTED_REFERENCE_PREDICATE')
            elif clause.get('op') not in {'eq','is_true'} or clause.get('lhs') not in FACTS:
                raise CqRefused('CQ_ROUTING_DEPENDENCY_INVALID')
    if manifest['mode'] not in {'C0','C1'} or manifest['q02_policy'] not in {'SHOW_ALL','ELIGIBLE_ONLY','UNDECIDED'}:
        raise CqRefused('CQ_POLICY_VERSION_INVALID')
    if manifest['lane']=='ENTREPRENEUR_SPECIFIC':
        # No QJ/BCB/measurement/approved-bank adapter is fabricated here.
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_AUTHORITY_UNVERIFIED',503)


def route(manifest, policy, latest, exposures, reference):
    """Topological adapter around A2.gate; context-bound answers never resurrect."""
    effective={}; decisions=[]
    for item in manifest['questions']:
        q=item['id']; a1=effective.get('Q01',{})
        screen=q01_screen(manifest['questions'][0]['validation'],a1.get('state','SKIPPED'),a1.get('value'))
        a4=effective.get('Q04',{})
        ready=lambda kind: kind in manifest['stimuli'] and exposures.get(kind)==digest(manifest['stimuli'][kind])
        facts={'Q01_SCREEN':screen,'Q01_COMPLETED':bool(a1),
            'Q02_VISIBLE':manifest['q02_policy']=='SHOW_ALL' or (manifest['q02_policy']=='ELIGIBLE_ONLY' and screen=='ELIGIBLE'),
            'Q04_ANSWER':('ZERO' if a4.get('value')=='ZERO' else 'SUBSTANTIVE_NONZERO')
                if a4.get('state')=='ANSWERED_SUBSTANTIVE' else a4.get('state','NOT_ANSWERED'),
            'CONCEPT_READY':ready('concept'),'MENU_READY':ready('menu'),
            'OCCASION_READY':ready('occasion'),'FEATURE_BANK_READY':ready('features'),
            'APPROVED_EXACT_OFFER_STIMULUS':ready('offer'),
            'OPTIONAL_CONTEXT_ENABLED':manifest['optional_context']}
        token=policy['item_show_gate'][q]
        verdict,reason=reference.gate(token,facts,policy)
        if q not in manifest['authorized_question_ids']:
            verdict,reason='NOT_SHOWN','QUESTION_AUTHORITY_UNVERIFIED'
        dependencies={d:effective.get(d,{}).get('event_id') for d in item['dependencies']}
        kinds=item['stimulus_dependencies']
        context=digest({'manifest':manifest['version'],'policy':manifest['policy_version'],
            'dependencies':dependencies,'exposures':{k:exposures.get(k) for k in kinds}})
        slots=[q+':'+f for f in item['feature_ids']] if q=='Q10' and item['feature_ids'] else [q]
        for slot in slots:
            prior=latest.get(slot)
            valid=bool(prior and verdict=='SHOWN' and prior['context_digest']==context)
            state=prior['state'] if valid else 'NOT_SHOWN' if verdict!='SHOWN' else 'PENDING'
            decision={'slot_id':slot,'question_id':q,'verdict':verdict,'reason':reason,
                'gate':token,'facts':facts,'runtime_version':'cq-runtime/1','context_digest':context,'state':state,
                'event_id':str(prior['id']) if valid else None,
                'value':prior['value_json'] if valid else None}
            decisions.append(decision)
            if valid:
                effective[q]={'state':state,'value':prior['value_json'],'event_id':str(prior['id'])}
    return decisions,effective
