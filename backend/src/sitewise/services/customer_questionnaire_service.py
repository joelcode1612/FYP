"""CQ orchestration over existing CUST03 validation and A2 routing, no LLM.

The existing synthetic factory stays isolated. Production approval is supplied
by a separate trusted port, not promoted from candidate booleans or filenames.
"""
from uuid import UUID,uuid4

from sitewise.domain.cq_runtime import CqRefused,route,verify_release
from sitewise.domain.customer_questionnaire import classify_answer,digest
from sitewise.project1 import consent_notice
from sitewise.services.customer_questionnaire_candidate import load_sources,SOURCE_SHA


class CustomerQuestionnaireService:
    def __init__(self,store,authority):
        self.store,self.authority=store,authority
        self.contract,_,self.reference=load_sources()

    def _release(self,unit,rid,actor,operation):
        release=unit.release(rid)
        if release is None: raise CqRefused('CQ_MANIFEST_NOT_FOUND',404)
        manifest,policy=release['manifest_json'],release['policy_json']
        if (digest(manifest)!=release['manifest_hash'] or digest(policy)!=release['policy_hash']
                or manifest['source_hash']!=SOURCE_SHA or manifest['policy_hash']!=release['policy_hash']):
            raise CqRefused('CQ_MANIFEST_INTEGRITY_INVALID',503)
        verify_release(manifest,policy,self.contract,self.reference)
        bank=unit.bank(manifest['bank_version'])
        if bank is None or bank['questions_json']!=manifest['questions'] or bank['content_hash']!=digest(manifest['questions']):
            raise CqRefused('CQ_BANK_VERSION_INVALID',503)
        assignments=unit.assignments(rid)
        expected={}
        for q in manifest['questions']:
            slots=[q['id']+':'+f for f in q['feature_ids']] if q['id']=='Q10' and q['feature_ids'] else [q['id']]
            for slot in slots: expected[slot]=(q['version'],digest(q),q['id'])
        actual={a['slot_id']:(a['question_version'],a['content_hash'],a['question_id']) for a in assignments}
        if actual!=expected or any(a['bank_version']!=manifest['bank_version'] for a in assignments):
            raise CqRefused('CQ_ASSIGNMENT_VERSION_INVALID',503)
        grant=self.authority.authorize(unit,release,actor,operation)
        if grant.scope not in {'PRODUCTION','ISOLATED_TEST'} or not grant.receipt:
            raise CqRefused('PRODUCTION_FIELDING_HOLD',503)
        if grant.scope=='PRODUCTION' and (release['source_class']!='ADOPTED' or not grant.production_fielding_authorized):
            raise CqRefused('PRODUCTION_FIELDING_HOLD',503)
        # Defence in depth, not a replacement for the two locks above. A human-facing
        # scope may not proceed on a notice whose disclosures are still unapproved
        # (OD-08). This is refused at the single release choke point so no caller --
        # manifest, invitations, start, consent -- can route around it.
        consent_notice.require_approved(consent_notice.build_notice(self.contract,scope=grant.scope))
        return release,manifest,policy,grant

    def manifest(self,rid,actor):
        with self.store.open() as unit:
            release,manifest,_,grant=self._release(unit,rid,actor,'manifest')
            return {'contract_version':'cq-release/1','release_id':rid,'manifest_hash':release['manifest_hash'],
                'execution_scope':grant.scope,'production_fielding_authorized':grant.production_fielding_authorized,
                'manifest':manifest}

    def create_campaign(self,aid,rid,actor):
        with self.store.open() as unit:
            assessment=unit.m2.get_assessment_for_update(aid,actor)
            if assessment is None: raise CqRefused('CQ_ASSESSMENT_NOT_FOUND',404)
            self._release(unit,rid,actor,'campaign')
            row=unit.create_campaign(aid,actor,rid)
            if row['release_id']!=rid or row['owner_user_id']!=actor:
                raise CqRefused('CQ_ASSESSMENT_ALREADY_HAS_CAMPAIGN')
            unit.commit();return row

    def invite(self,cid,respondent,actor):
        with self.store.open() as unit:
            campaign=unit.campaign(cid)
            if campaign is None or campaign['owner_user_id']!=actor: raise CqRefused('CQ_CAMPAIGN_NOT_FOUND',404)
            self._release(unit,campaign['release_id'],actor,'invite')
            unit.add_participant(cid,respondent);unit.commit()
            return {'campaign_id':cid,'respondent_id':respondent}

    def invitations(self,actor):
        with self.store.open() as unit:
            result=[];held=False
            for row in unit.invitations(actor):
                try: release,m,_,grant=self._release(unit,row['release_id'],actor,'participate')
                except CqRefused: held=True;continue
                result.append({'campaign_id':row['id'],'release_id':row['release_id'],
                    'manifest_hash':release['manifest_hash'],'title':m['title'],
                    'session_id':row['session_id'],'execution_scope':grant.scope,
                    'production_fielding_authorized':grant.production_fielding_authorized})
            return {'contract_version':'cq-invitations/1','state':'ready' if result else 'held' if held else 'empty',
                'code':'PRODUCTION_FIELDING_HOLD' if held and not result else None,
                # Additive: says the runtime IS enabled but the authority refused
                # this respondent, which is the opposite cause from the
                # route-level CQ_RUNTIME_DISABLED.
                'reason':'AUTHORIZATION_DENIED' if held and not result else None,
                'invitations':result}

    def start(self,cid,manifest_hash,locale,actor):
        with self.store.open() as unit:
            campaign=unit.campaign(cid)
            if campaign is None or not unit.participant(cid,actor): raise CqRefused('CQ_CAMPAIGN_NOT_FOUND',404)
            release,m,p,g=self._release(unit,campaign['release_id'],actor,'participate')
            if manifest_hash!=release['manifest_hash']: raise CqRefused('CQ_STALE_MANIFEST')
            if locale not in m['locales']: raise CqRefused('CQ_LOCALE_NOT_AUTHORIZED',422)
            session=unit.create_session(campaign,actor,locale)
            if session['locale']!=locale: raise CqRefused('CQ_SESSION_ALREADY_PINNED_TO_LOCALE')
            if g.measurement_context is not None:
                context=dict(g.measurement_context)
                if (g.scope!='ISOLATED_TEST' or context.get('source_class')!='SYNTHETIC_FIXTURE'
                    or context.get('research_mode') not in {'COGNITIVE_PRETEST','CUSTOMER_DEMAND_SURVEY','DEVELOPER_PREVIEW'}
                    or context.get('eligibility') not in {'ELIGIBLE','INELIGIBLE','UNRESOLVED'}
                    or not context.get('qualification_version') or not context.get('receipt')):
                    raise CqRefused('CQ_QUALIFICATION_SOURCE_UNVERIFIED',503)
                context.update(session_id=str(session['id']),assessment_id=str(campaign['assessment_id']),
                    campaign_id=str(cid),owner_user_id=str(campaign['owner_user_id']),respondent_user_id=str(actor),
                    manifest_hash=manifest_hash,instrument_version=m['version'],bank_version=m['bank_version'],
                    routing_version=m['policy_version'],consent_version=m['consent_version'],
                    consent_hash=digest(m['consent_text'][locale]))
                existing=unit.control(session['id'])
                if existing and existing['source_hash']!=digest(context):
                    raise CqRefused('CQ_QUALIFICATION_SOURCE_CHANGED')
                if not existing:
                    unit.insert_control(session_id=session['id'],research_mode=context['research_mode'],
                        eligibility=context['eligibility'],qualification_version=context['qualification_version'],
                        source_json=context,source_hash=digest(context))
            session['_paused']=unit.paused(session['id'])
            result=self._view(unit,session,release,m,p,g);unit.commit();return result

    def _load(self,unit,sid,actor,lock=False):
        session=unit.owned_session(sid,actor,lock)
        if session is None: raise CqRefused('CQ_SESSION_NOT_FOUND',404)
        release,m,p,g=self._release(unit,session['release_id'],actor,'participate')
        campaign=unit.campaign(session['campaign_id'])
        if campaign is None or campaign['release_id']!=session['release_id'] or not unit.participant(campaign['id'],actor):
            raise CqRefused('CQ_SESSION_BINDING_INVALID',403)
        session['_paused']=unit.paused(sid)
        return session,release,m,p,g

    @staticmethod
    def _active(session,revision,manifest_hash,release,consent=True):
        if manifest_hash!=release['manifest_hash']: raise CqRefused('CQ_STALE_MANIFEST')
        if session['revision']!=revision: raise CqRefused('CQ_STALE_REVISION')
        if session['state']!='ACTIVE': raise CqRefused('CQ_SESSION_CLOSED')
        if session.get('_paused'): raise CqRefused('CQ_SESSION_PAUSED')
        if consent and not session['consented']: raise CqRefused('CQ_CONSENT_REQUIRED',403)

    def _view(self,unit,s,release,m,p,g):
        rows,effective=route(m,p,unit.latest(s['id']),unit.exposure_map(s['id']),self.reference)
        if s['state']=='WITHDRAWN':
            rows=[{**r,'verdict':'NOT_SHOWN','reason':'CONSENT_WITHDRAWN','state':'NOT_SHOWN','event_id':None,'value':None} for r in rows]
            effective={}
        can_act=s['consented'] and s['state']=='ACTIVE' and not s.get('_paused')
        next_slot=next((r['slot_id'] for r in rows if r['verdict']=='SHOWN' and r['state']=='PENDING'),None) if can_act else None
        screen=next((r for r in rows if r['question_id']=='Q01'),{})
        from sitewise.domain.customer_questionnaire import q01_screen
        a1=effective.get('Q01',{})
        disposition=q01_screen(m['questions'][0]['validation'],a1.get('state','SKIPPED'),a1.get('value'))
        used={k for q in m['questions'] if q['id'] in m['authorized_question_ids'] for k in q['stimulus_dependencies']}
        exposure=unit.exposure_map(s['id'])
        stimulus=next((k for k in m['stimulus_order'] if k in used and k not in exposure),None) if can_act and disposition=='ELIGIBLE' else None
        receipt=unit.receipt(s['id'])
        if receipt:
            body=dict(receipt['payload_json']);claimed=body.pop('receipt_hash',None)
            if (claimed!=receipt['receipt_hash'] or digest(body)!=claimed or body['session_id']!=str(s['id'])
                    or body['manifest_hash']!=release['manifest_hash']):
                raise CqRefused('CQ_RECEIPT_INTEGRITY_INVALID',503)
            if s['state']=='SUBMITTED' and (body['effective_answers']!=rows or body['decision_hash']!=digest(rows)):
                raise CqRefused('CQ_RECEIPT_ROUTING_MISMATCH',503)
        return {'contract_version':'cq-session/1','session_id':s['id'],'campaign_id':s['campaign_id'],
            'release_id':s['release_id'],'manifest_hash':release['manifest_hash'],
            'manifest':m,'execution_scope':g.scope,'production_fielding_authorized':g.production_fielding_authorized,
            'revision':s['revision'],'status':'PAUSED' if s['state']=='ACTIVE' and s.get('_paused') else s['state'],'consented':s['consented'],
            'lifecycle_version':'cq-lifecycle/1','render_ack_version':'cq-render/1',
            'locale':s['locale'],'routing':rows,'next_slot_id':next_slot if stimulus is None else None,
            'next_stimulus_kind':stimulus,'can_submit':can_act and next_slot is None and stimulus is None,
            'screen_disposition':disposition,'receipt':receipt['payload_json'] if receipt else None,
            # Additive sibling of the manifest, never part of it: inserting a key into
            # `m` would break digest(manifest)==release['manifest_hash'].
            'consent_notice':(consent_notice.synthetic_notice(m,locale=s['locale']) if g.scope=='ISOLATED_TEST'
                else consent_notice.build_notice(self.contract,scope=g.scope))}

    def read(self,sid,actor):
        with self.store.open() as unit:
            return self._view(unit,*self._load(unit,sid,actor))

    def consent(self,sid,actor,*,revision,manifest_hash,request_id,consented,version):
        with self.store.open() as unit:
            s,release,m,p,g=self._load(unit,sid,actor,True)
            if not consented: raise CqRefused('CQ_USE_WITHDRAWAL_ENDPOINT',422)
            body=digest([revision,manifest_hash,consented,version]);retry=unit.consent_retry(sid,request_id)
            if retry:
                if retry['request_hash']!=body: raise CqRefused('CQ_IDEMPOTENCY_CONFLICT')
                return self._view(unit,s,release,m,p,g)
            self._active(s,revision,manifest_hash,release,False)
            if version!=m['consent_version']: raise CqRefused('CQ_CONSENT_VERSION_INVALID')
            unit.insert_consent(id=uuid4(),session_id=sid,revision=revision+1,request_id=request_id,
                request_hash=body,consented=consented,version=version)
            unit.update_session(sid,revision,consented=consented,consent_version=version,
                state='ACTIVE' if consented else 'WITHDRAWN')
            s.update(revision=revision+1,consented=consented,state='ACTIVE' if consented else 'WITHDRAWN')
            result=self._view(unit,s,release,m,p,g);unit.commit();return result

    def expose(self,sid,actor,*,revision,manifest_hash,kind):
        with self.store.open() as unit:
            s,release,m,p,g=self._load(unit,sid,actor,True)
            self._active(s,revision,manifest_hash,release)
            before=self._view(unit,s,release,m,p,g)
            if before['next_stimulus_kind']!=kind: raise CqRefused('CQ_STIMULUS_NOT_APPLICABLE')
            unit.insert_exposure(id=uuid4(),session_id=sid,revision=revision+1,kind=kind,stimulus_hash=digest(m['stimuli'][kind]))
            unit.update_session(sid,revision);s['revision']+=1
            result=self._view(unit,s,release,m,p,g)
            result['delivered_stimulus']={'kind':kind,'text':m['stimuli'][kind]['text'][s['locale']],
                'version':m['stimuli'][kind]['version'],'hash':digest(m['stimuli'][kind])}
            self._record(unit,s,result['routing']);unit.commit();return result

    def _record(self,unit,s,rows):
        decision=unit.decision(s['id'],s['revision'],rows)
        unit.canonical(s['id'],s['revision'],rows)
        return decision

    def present(self,sid,actor,*,revision,manifest_hash,edit_slot_id=None):
        with self.store.open() as unit:
            s,release,m,p,g=self._load(unit,sid,actor,True)
            self._active(s,revision,manifest_hash,release)
            view=self._view(unit,s,release,m,p,g)
            slot=edit_slot_id or view['next_slot_id']
            row=next((r for r in view['routing'] if r['slot_id']==slot),None)
            if view['next_stimulus_kind'] or row is None or row['verdict']!='SHOWN' or (edit_slot_id and row['event_id'] is None):
                raise CqRefused('CQ_QUESTION_NOT_APPLICABLE')
            decision=self._record(unit,s,view['routing'])
            display=unit.presentation(sid,revision,slot,row['context_digest'],decision['id'])
            question=next(q for q in m['questions'] if q['id']==row['question_id'])
            view['presentation']={'display_id':display['id'],'slot_id':slot,'question_id':question['id'],
                'question_version':question['version'],'context_digest':row['context_digest'],
                'delivered_at':display['created_at']}
            unit.commit();return view

    def answer(self,sid,actor,*,revision,manifest_hash,request_id,display_id,slot_id,value):
        with self.store.open() as unit:
            s,release,m,p,g=self._load(unit,sid,actor,True)
            if not s['consented'] or s['state']!='ACTIVE': raise CqRefused('CQ_SESSION_CLOSED')
            body=digest([revision,manifest_hash,str(display_id),slot_id,value]);retry=unit.answer_retry(sid,request_id)
            if retry:
                if retry['request_hash']!=body: raise CqRefused('CQ_IDEMPOTENCY_CONFLICT')
                return self._view(unit,s,release,m,p,g)
            rejected=unit.rejected_retry(sid,request_id)
            if rejected:
                if rejected['request_hash']!=body: raise CqRefused('CQ_IDEMPOTENCY_CONFLICT')
                raise CqRefused(rejected['reason'],422)
            self._active(s,revision,manifest_hash,release)
            view=self._view(unit,s,release,m,p,g)
            current=next((r for r in view['routing'] if r['slot_id']==slot_id),None)
            display=unit.display(display_id)
            if (not display or display['session_id']!=sid or display['slot_id']!=slot_id
                    or display['revision']!=revision or current is None or current['verdict']!='SHOWN'
                    or current['context_digest']!=display['context_digest']):
                raise CqRefused('CQ_CURRENT_PRESENTATION_REQUIRED')
            question=next(q for q in m['questions'] if q['id']==current['question_id'])
            state,reason=classify_answer(question['validation'],value,p['q01_option_state_map'])
            if state=='INVALID' or state=='SKIPPED' and question['required_for_answer']:
                unit.reject_answer(id=uuid4(),session_id=sid,display_id=display_id,revision=revision,
                    request_id=request_id,request_hash=body,slot_id=slot_id,raw_value=value,
                    reason=reason or 'CQ_ANSWER_REQUIRED')
                unit.commit()
                raise CqRefused(reason or 'CQ_ANSWER_REQUIRED',422)
            unit.insert_answer(id=uuid4(),session_id=sid,slot_id=slot_id,revision=revision+1,
                request_id=request_id,request_hash=body,display_id=display_id,state=state,
                value_json=value,context_digest=current['context_digest'])
            unit.update_session(sid,revision);s['revision']+=1
            result=self._view(unit,s,release,m,p,g);self._record(unit,s,result['routing'])
            unit.commit();return result

    def submit(self,sid,actor,*,revision,manifest_hash,request_id):
        with self.store.open() as unit:
            s,release,m,p,g=self._load(unit,sid,actor,True)
            prior=unit.receipt(sid)
            if prior:
                if manifest_hash!=release['manifest_hash']: raise CqRefused('CQ_STALE_MANIFEST')
                if s['state']!='SUBMITTED' or not s['consented']: raise CqRefused('CQ_SESSION_CLOSED')
                if str(prior['request_id'])==str(request_id) and prior['request_hash']!=digest([revision,manifest_hash]):
                    raise CqRefused('CQ_IDEMPOTENCY_CONFLICT')
                if revision not in {prior['revision']-1,prior['revision']}:
                    raise CqRefused('CQ_STALE_REVISION')
                return self._view(unit,s,release,m,p,g)
            self._active(s,revision,manifest_hash,release)
            result=self._view(unit,s,release,m,p,g)
            if not result['can_submit']: raise CqRefused('CQ_SESSION_INCOMPLETE')
            decision=self._record(unit,s,result['routing'])
            payload={'contract_version':'cq-submission-receipt/1','receipt_id':str(uuid4()),
                'session_id':str(sid),'campaign_id':str(s['campaign_id']),'manifest_hash':manifest_hash,
                'answer_revision':revision,'submitted_revision':revision+1,'decision_hash':decision['decision_hash'],
                'disposition':result['screen_disposition'],'effective_answers':result['routing'],
                'execution_scope':g.scope,'production_fielding_authorized':g.production_fielding_authorized}
            payload['receipt_hash']=digest(payload)
            unit.insert_receipt(id=UUID(payload['receipt_id']),session_id=sid,request_id=request_id,
                request_hash=digest([revision,manifest_hash]),revision=revision+1,
                receipt_hash=payload['receipt_hash'],payload_json=payload)
            unit.update_session(sid,revision,state='SUBMITTED');s.update(revision=revision+1,state='SUBMITTED')
            result=self._view(unit,s,release,m,p,g);unit.commit();return result

    def history(self,sid,actor):
        with self.store.open() as unit:
            self._load(unit,sid,actor)
            return {'contract_version':'cq-history/1','session_id':sid,'answers':unit.history(sid)}

    def lifecycle(self,sid,actor,*,action,revision,manifest_hash,request_id):
        if action not in {'PAUSE','RESUME'}: raise CqRefused('CQ_LIFECYCLE_ACTION_INVALID',422)
        with self.store.open() as unit:
            s,release,m,p,g=self._load(unit,sid,actor,True)
            body=digest([revision,manifest_hash,action]);retry=unit.lifecycle_retry(sid,request_id)
            if retry:
                if retry['request_hash']!=body: raise CqRefused('CQ_IDEMPOTENCY_CONFLICT')
                return self._view(unit,s,release,m,p,g)
            if manifest_hash!=release['manifest_hash']: raise CqRefused('CQ_STALE_MANIFEST')
            if s['revision']!=revision: raise CqRefused('CQ_STALE_REVISION')
            if s['state']!='ACTIVE' or not s['consented']: raise CqRefused('CQ_SESSION_CLOSED')
            if bool(s.get('_paused'))==(action=='PAUSE'): raise CqRefused('CQ_LIFECYCLE_ALREADY_APPLIED')
            unit.insert_lifecycle(id=uuid4(),session_id=sid,revision=revision+1,
                request_id=request_id,request_hash=body,action=action)
            unit.update_session(sid,revision);s.update(revision=revision+1,_paused=action=='PAUSE')
            result=self._view(unit,s,release,m,p,g);unit.commit();return result

    def rendered(self,sid,actor,*,revision,manifest_hash,display_id):
        with self.store.open() as unit:
            s,release,m,p,g=self._load(unit,sid,actor,True)
            self._active(s,revision,manifest_hash,release)
            d=unit.display(display_id)
            if not d or d['session_id']!=sid or d['revision']!=revision:
                raise CqRefused('CQ_CURRENT_PRESENTATION_REQUIRED')
            view=self._view(unit,s,release,m,p,g)
            row=next((r for r in view['routing'] if r['slot_id']==d['slot_id']),None)
            if row is None or row['verdict']!='SHOWN' or row['context_digest']!=d['context_digest']:
                raise CqRefused('CQ_CURRENT_PRESENTATION_REQUIRED')
            unit.render(id=uuid4(),session_id=sid,display_id=display_id,slot_id=d['slot_id'],revision=revision)
            view['presentation']={'display_id':d['id'],'slot_id':d['slot_id'],'question_id':row['question_id'],
                'question_version':next(q['version'] for q in m['questions'] if q['id']==row['question_id']),
                'context_digest':d['context_digest'],'delivered_at':d['created_at'],'rendered':True}
            unit.commit();return view

    def withdraw(self,sid,actor,*,revision,manifest_hash,request_id):
        # Withdrawal stays available to the owning respondent after authority
        # revocation. It never returns or activates an unapproved instrument.
        with self.store.open() as unit:
            s=unit.owned_session(sid,actor,True)
            if s is None: raise CqRefused('CQ_SESSION_NOT_FOUND',404)
            release=unit.release(s['release_id'])
            if not release or release['manifest_hash']!=manifest_hash: raise CqRefused('CQ_STALE_MANIFEST')
            body=digest([revision,manifest_hash,False]);retry=unit.consent_retry(sid,request_id)
            if retry and retry['request_hash']!=body: raise CqRefused('CQ_IDEMPOTENCY_CONFLICT')
            if not retry:
                if s['revision']!=revision: raise CqRefused('CQ_STALE_REVISION')
                if s['state']!='WITHDRAWN':
                    unit.insert_consent(id=uuid4(),session_id=sid,revision=revision+1,request_id=request_id,
                        request_hash=body,consented=False,version=s['consent_version'] or 'NOT_GIVEN')
                    unit.update_session(sid,revision,consented=False,state='WITHDRAWN')
                    unit.withdraw_effective(sid,revision+1);s.update(revision=revision+1,state='WITHDRAWN')
                    unit.commit()
            return {'contract_version':'cq-withdrawal/1','session_id':sid,'status':'WITHDRAWN','revision':s['revision']}
