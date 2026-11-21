"""Cutoff-bound immutable measurement diagnostics over committed CQ evidence.

No adopted A/revision policy or scientific claim adapter has been verified.
Both named diagnostic interpretations are supported; official percentages and
report findings are withheld. A diagnostic job is never run on a mobile tap.
"""
import json
from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4

from sqlalchemy import text
from sitewise.domain.customer_questionnaire import digest
from sitewise.domain.cq_runtime import CqRefused


def plain(value):
    return json.loads(json.dumps(value, default=str))


class Ee01Service:
    RULES = {'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC', 'ACCEPTED_EFFECTIVE_DIAGNOSTIC'}

    def __init__(self, engine):
        self.engine = engine

    @contextmanager
    def connection(self, actor):
        with self.engine.begin() as c:
            c.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
            role = c.execute(text('SELECT current_user,rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user')).one()
            if role != ('p1_ee01_runtime', False, False):
                raise CqRefused('EE01_RESTRICTED_ROLE_REQUIRED', 503)
            c.execute(text("SELECT set_config('project1.actor_id',:actor,true)"), {'actor': str(actor)})
            yield c

    def build_diagnostic(self, actor, assessment_id, campaign_id, slot, cutoff, rule):
        if rule not in self.RULES or cutoff.tzinfo is None or cutoff > datetime.now(timezone.utc):
            raise CqRefused('EE01_CUTOFF_OR_RULE_INVALID', 422)
        cutoff = cutoff.astimezone(timezone.utc)
        with self.connection(actor) as c:
            campaign = c.execute(text('SELECT * FROM cq_campaigns WHERE id=:cid AND assessment_id=:aid'),
                                 {'cid': campaign_id, 'aid': assessment_id}).mappings().first()
            if not campaign:
                raise CqRefused('EE01_CAMPAIGN_NOT_FOUND', 404)
            release = c.execute(text('SELECT * FROM cq_manifest_releases WHERE id=:id'), {'id': campaign['release_id']}).mappings().one()
            m = release['manifest_json']
            if digest(m) != release['manifest_hash'] or digest(release['policy_json']) != release['policy_hash']:
                raise CqRefused('EE01_SOURCE_INTEGRITY_INVALID', 503)
            if release['source_class'] != 'SYNTHETIC_FIXTURE':
                # The adopted qualification/revision/scientific adapter is
                # intentionally not fabricated from a candidate manifest.
                raise CqRefused('EE01_MEASUREMENT_AUTHORITY_UNVERIFIED', 503)
            q = next((q for q in m['questions'] if q['id'] == slot.split(':')[0]), None)
            assignment = c.execute(text('SELECT * FROM cq_question_assignments WHERE release_id=:rid AND slot_id=:slot'),
                                   {'rid': release['id'], 'slot': slot}).mappings().first()
            bank = c.execute(text('SELECT * FROM cq_bank_versions WHERE version=:v'), {'v': m['bank_version']}).mappings().one()
            if not q or not assignment or assignment['content_hash'] != digest(q) or bank['content_hash'] != digest(m['questions']):
                raise CqRefused('EE01_ITEM_BINDING_INVALID', 503)
            units = []
            params = {'cid': campaign_id, 'cutoff': cutoff, 'slot': slot}
            sessions = c.execute(text('SELECT * FROM cq_sessions WHERE campaign_id=:cid AND created_at<=:cutoff ORDER BY id'), params).mappings()
            for s in sessions:
                p = {**params, 'sid': s['id']}
                control = c.execute(text('SELECT * FROM cq_session_controls WHERE session_id=:sid AND created_at<=:cutoff'), p).mappings().first()
                consent = c.execute(text('SELECT * FROM cq_consent_events WHERE session_id=:sid AND created_at<=:cutoff ORDER BY revision DESC LIMIT 1'), p).mappings().first()
                render = c.execute(text('SELECT r.*,p.context_digest FROM cq_render_events r JOIN cq_presentations p ON p.id=r.display_id '
                                        'WHERE r.session_id=:sid AND r.slot_id=:slot AND r.created_at<=:cutoff ORDER BY r.created_at DESC,r.id LIMIT 1'), p).mappings().first()
                accepted = c.execute(text('SELECT * FROM cq_answer_revisions WHERE session_id=:sid AND slot_id=:slot AND created_at<=:cutoff ORDER BY revision DESC LIMIT 1'), p).mappings().first()
                rejected = c.execute(text('SELECT * FROM cq_rejected_answer_events WHERE session_id=:sid AND slot_id=:slot AND created_at<=:cutoff ORDER BY created_at DESC,id LIMIT 1'), p).mappings().first()
                exposures = list(c.execute(text('SELECT kind,stimulus_hash FROM cq_stimulus_deliveries WHERE session_id=:sid AND created_at<=:cutoff ORDER BY kind'), p).mappings())
                from sitewise.domain.cq_runtime import route
                from sitewise.services.customer_questionnaire_candidate import load_sources
                history = c.execute(text('SELECT * FROM cq_answer_revisions WHERE session_id=:sid AND created_at<=:cutoff ORDER BY revision'), p).mappings()
                latest = {a['slot_id']: dict(a) for a in history}
                routing, _ = route(m, release['policy_json'], latest, {e['kind']: e['stimulus_hash'] for e in exposures}, load_sources()[2])
                effective = next((r for r in routing if r['slot_id'] == slot), None)
                source_ok = bool(control and digest(control['source_json']) == control['source_hash'])
                if source_ok:
                    expected = {'assessment_id': str(assessment_id), 'campaign_id': str(campaign_id),
                                'session_id': str(s['id']), 'owner_user_id': str(actor),
                                'respondent_user_id': str(s['respondent_user_id']), 'manifest_hash': release['manifest_hash'],
                                'bank_version': m['bank_version'], 'consent_version': m['consent_version']}
                    source_ok = all(control['source_json'].get(k) == v for k, v in expected.items())
                if control and (not source_ok or control['source_json'].get('source_class') != release['source_class']):
                    raise CqRefused('EE01_QUALIFICATION_INTEGRITY_INVALID', 503)
                qualified = bool(source_ok and control['eligibility'] == 'ELIGIBLE'
                                 and control['research_mode'] == 'CUSTOMER_DEMAND_SURVEY'
                                 and consent and consent['consented'] and consent['version'] == m['consent_version'])
                state = 'NOT_SHOWN' if not render else 'SHOWN_NO_ANSWER'
                selected = accepted
                # Accepted revisions advance the locked root; rejected attempts
                # retain its current revision. Transaction-start timestamps can
                # precede lock acquisition, so use revision causality here.
                is_rejected = bool(rejected and (not accepted or rejected['revision'] >= accepted['revision']))
                if rule == 'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC' and is_rejected:
                    selected = rejected
                else:
                    is_rejected = False
                # Prepared delivery alone is never evidence of an actual display.
                if render and selected:
                    selected_render = c.execute(text('SELECT id FROM cq_render_events WHERE display_id=:pid AND session_id=:sid AND created_at<=:cutoff'),
                                                {**p, 'pid': selected['display_id']}).scalar_one_or_none()
                    if selected_render:
                        render_id = selected_render
                        state = 'INVALID' if is_rejected else selected['state']
                        if not effective or effective['verdict'] != 'SHOWN' or (
                            not is_rejected and effective['event_id'] != str(selected['id'])):
                            state = 'SHOWN_NO_ANSWER'
                            selected = None
                    else:
                        selected = None
                        render_id = render['id']
                else:
                    render_id = render['id'] if render else None
                    selected = None
                # Missing/mismatched required stimuli invalidate quantitative use.
                expected_stimuli = {k: digest(m['stimuli'][k]) for k in q['stimulus_dependencies'] if k in m['stimuli']}
                stimulus_ok = len(expected_stimuli) == len(q['stimulus_dependencies']) and all(
                    any(e['kind'] == k and e['stimulus_hash'] == h for e in exposures) for k, h in expected_stimuli.items())
                unit = {'session_id': str(s['id']), 'qualified': qualified, 'shown': bool(render),
                        'state': state, 'value': None if selected is None else selected.get('raw_value', selected.get('value_json')),
                        'render_id': str(render_id) if render_id else None,
                        'answer_id': str(selected['id']) if selected and not is_rejected else None,
                        'rejected_id': str(selected['id']) if selected and is_rejected else None,
                        'selected_revision': selected['revision'] if selected else None,
                        'control': plain(dict(control)) if control else None,
                        'consent_id': str(consent['id']) if consent else None, 'stimulus_ok': stimulus_ok,
                        'exposures': [dict(e) for e in exposures]}
                if not stimulus_ok and unit['state'] == 'ANSWERED_SUBSTANTIVE':
                    unit['state'] = 'INVALID'
                units.append(unit)
            counted = [u for u in units if u['qualified']]
            counts = {k: sum(u['shown'] and u['state'] == k for u in counted) for k in
                      ('ANSWERED_SUBSTANTIVE', 'ANSWERED_NON_SUBSTANTIVE', 'REFUSED', 'INVALID', 'SKIPPED', 'SHOWN_NO_ANSWER')}
            counts.update(not_shown=sum(not u['shown'] for u in counted), excluded=len(units)-len(counted))
            Q = len(counted); S = sum(u['shown'] for u in counted)
            V = counts['ANSWERED_SUBSTANTIVE']
            A = sum(counts[k] for k in ('ANSWERED_SUBSTANTIVE', 'ANSWERED_NON_SUBSTANTIVE', 'REFUSED', 'INVALID'))
            status = 'NOT_SHOWN' if not S else 'NOT_ESTIMABLE' if not V else 'WITHHELD_NOT_AUTHORIZED'
            metadata = {'manifest_hash': release['manifest_hash'], 'instrument_version': m['version'],
                        'bank_version': m['bank_version'], 'routing_version': m['policy_version'],
                        'consent_version': m['consent_version'], 'stimulus_hash': digest(expected_stimuli),
                        'qualification_versions': sorted({u['control']['qualification_version'] for u in units if u['control']}),
                        'research_mode': 'CUSTOMER_DEMAND_SURVEY', 'rule': rule,
                        'authority': 'AUTHORITY_UNVERIFIED', 'privacy_policy': 'WITHHOLD_ALL_FINDINGS',
                        'selection': 'LATEST_ATTEMPT' if rule.startswith('CUST03') else 'LATEST_ACCEPTED',
                        'cutoff_basis': 'COMMITTED_BUILD_SNAPSHOT_WITH_EVENT_TIME_CUTOFF',
                        'scientific_gaps': ['A_DEFINITION_UNRESOLVED', 'REVISION_POLICY_UNVERIFIED', 'MEASUREMENT_CLAIM_UNAUTHORIZED']}
            rules_hash = digest(metadata)
            scope = 'ISOLATED_TEST' if release['source_class'] == 'SYNTHETIC_FIXTURE' else 'PRODUCTION'
            source_hash = digest(units)
            fp = digest([str(actor), str(assessment_id), str(campaign_id), slot, q['version'], cutoff.isoformat(), rules_hash, source_hash])
            prior = c.execute(text('SELECT id FROM ee01_measurement_snapshots WHERE fingerprint=:fp'), {'fp': fp}).scalar_one_or_none()
            if prior:
                return self._read(c, prior, assessment_id, campaign_id)
            sid = uuid4()
            c.execute(text('INSERT INTO ee01_measurement_snapshots(id,owner_user_id,assessment_id,campaign_id,release_id,slot_id,question_version,cutoff,fingerprint,rules_hash,source_hash,scope,status,q,s,a,v,metadata_json,counts_json) '
                           'VALUES(:id,:owner,:aid,:cid,:rid,:slot,:qv,:cutoff,:fp,:rh,:sh,:scope,:status,:q,:s,:a,:v,CAST(:meta AS jsonb),CAST(:counts AS jsonb))'),
                      {'id': sid, 'owner': actor, 'aid': assessment_id, 'cid': campaign_id, 'rid': release['id'], 'slot': slot,
                       'qv': q['version'], 'cutoff': cutoff, 'fp': fp, 'rh': rules_hash, 'sh': source_hash, 'scope': scope,
                       'status': status, 'q': Q, 's': S, 'a': A, 'v': V, 'meta': json.dumps(metadata), 'counts': json.dumps(counts)})
            for u in units:
                c.execute(text('INSERT INTO ee01_source_units(snapshot_id,session_id,render_id,answer_id,rejected_id,source_json,source_hash) '
                               'VALUES(:id,:session_id,:render_id,:answer_id,:rejected_id,CAST(:source AS jsonb),:hash)'),
                          {'id': sid, **u, 'source': json.dumps(u), 'hash': digest(u)})
            categories = {code: [code] for code in q['validation']['substantive_codes']}
            if q['id'] == 'Q05' and {'PROB_YES', 'DEF_YES'} <= set(categories):
                categories['TOP_TWO_STATED_INTEREST'] = ['PROB_YES', 'DEF_YES']
            for code, codes in categories.items():
                x = sum(u['qualified'] and u['shown'] and u['state'] == 'ANSWERED_SUBSTANTIVE'
                        and bool(set(u['value'] if isinstance(u['value'], list) else [u['value']]) & set(codes)) for u in units)
                # Diagnostic percentages are never returned through a final report.
                diagnostic = Decimal(100)*Decimal(x)/Decimal(V) if V and scope == 'ISOLATED_TEST' else None
                c.execute(text('INSERT INTO ee01_category_cells(snapshot_id,code,x,v,percentage,diagnostic_percentage,status) VALUES(:id,:code,:x,:v,NULL,:pct,:status)'),
                          {'id': sid, 'code': code, 'x': x, 'v': V, 'pct': diagnostic, 'status': status})
            result = self._read(c, sid, assessment_id, campaign_id)
            self._store_held_context(c, result)
            return result

    @staticmethod
    def _read(c, snapshot_id, assessment_id, campaign_id):
        row = c.execute(text('SELECT * FROM ee01_measurement_snapshots WHERE id=:id AND assessment_id=:aid AND campaign_id=:cid'),
                        {'id': snapshot_id, 'aid': assessment_id, 'cid': campaign_id}).mappings().first()
        if not row:
            raise CqRefused('EE01_SNAPSHOT_NOT_FOUND', 404)
        sources = list(c.execute(text('SELECT source_json,source_hash FROM ee01_source_units WHERE snapshot_id=:id ORDER BY session_id'), {'id': snapshot_id}).mappings())
        if (digest(row['metadata_json']) != row['rules_hash'] or
                any(digest(u['source_json']) != u['source_hash'] for u in sources) or
                digest([u['source_json'] for u in sources]) != row['source_hash']):
            raise CqRefused('EE01_SNAPSHOT_INTEGRITY_INVALID', 503)
        cells = list(c.execute(text('SELECT code,x,v,percentage,diagnostic_percentage,status FROM ee01_category_cells WHERE snapshot_id=:id ORDER BY code'), {'id': snapshot_id}).mappings())
        return plain({'contract_version': 'ee01-diagnostic/1', **dict(row), 'cells': [dict(x) for x in cells]})

    def read(self, actor, assessment_id, campaign_id, snapshot_id):
        with self.connection(actor) as c:
            return self._read(c, snapshot_id, assessment_id, campaign_id)

    @staticmethod
    def _store_held_context(c, row):
        context = {'snapshot_id': row['id'], 'fingerprint': row['fingerprint'],
                   'assessment_id': row['assessment_id'], 'campaign_id': row['campaign_id'],
                   'source_hash': row['source_hash'], 'rules_hash': row['rules_hash'],
                   'authority': 'AUTHORITY_UNVERIFIED', 'findings': [],
                   'gates': ['EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED', 'A10_ADAPTER_UNVERIFIED', 'REPORT_ADMISSION_REQUIRED']}
        ch = digest(context)
        c.execute(text('INSERT INTO ee01_report_readbacks(id,snapshot_id,context_hash,context_json,status) VALUES(:id,:sid,:hash,CAST(:ctx AS jsonb),:status) ON CONFLICT DO NOTHING'),
                  {'id': uuid4(), 'sid': row['id'], 'hash': ch, 'ctx': json.dumps(context),
                   'status': 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'})

    def report_readback(self, actor, assessment_id, campaign_id, snapshot_id):
        with self.connection(actor) as c:
            self._read(c, snapshot_id, assessment_id, campaign_id)
            row = c.execute(text('SELECT context_hash,context_json,status FROM ee01_report_readbacks WHERE snapshot_id=:id'),
                            {'id': snapshot_id}).mappings().one_or_none()
            if not row or digest(row['context_json']) != row['context_hash']:
                raise CqRefused('EE01_CONTEXT_UNAVAILABLE', 503)
            return {'contract_version': 'ee01-report-readback/1', 'status': row['status'],
                    'context_hash': row['context_hash'], 'context': row['context_json'], 'findings': []}
