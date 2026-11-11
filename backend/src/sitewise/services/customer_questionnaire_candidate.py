"""Synthetic-only CUST03 successor backend. No application startup registration.

The shipped A2 gate evaluator is reused verbatim, with separately versioned
successor predicate data. This service only accepts private in-memory SQLite;
it cannot connect to the user's configured database or authorize fielding.
"""
from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
from uuid import uuid4

from sqlalchemy import insert, select, update

from sitewise.db.models.customer_candidate_schema import (
    customer_candidate_metadata, displays, events, exposures, pretests, sessions,
)
from sitewise.domain.customer_questionnaire import (
    classify_answer, digest, q01_screen, validate_structured_pretest,
)

CONTRACTS = Path(__file__).resolve().parents[1] / 'customer_contracts'
SOURCE_SHA = 'ec2b5494ecf82447076e0d7a2bfb57599a24f049bbcc925a9ecbea6e833bce59'
PRETEST_QUALIFICATIONS = {'ACCEPTED_SYNTHETIC', 'NO_CONSENT', 'DUPLICATE', 'QUALITY_FAILED',
                        'UNDER_AGE', 'VERSION_MISMATCH', 'AFTER_CUTOFF', 'REJECTED_RESPONSE',
                        'NOT_ASSESSED'}


def load_sources():
    manifest = json.loads((CONTRACTS / 'source_manifest.json').read_text(encoding='utf-8'))
    for name, expected in manifest['files'].items():
        if hashlib.sha256((CONTRACTS / name).read_bytes()).hexdigest() != expected:
            raise ValueError('Frozen source or reference router changed: ' + name)
    path = CONTRACTS / 'reference/a2_router_lib.py'
    spec = importlib.util.spec_from_file_location('cust03_reference', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    contract, sha, _ = module.load_contract()
    if sha != SOURCE_SHA:
        raise ValueError('Authoritative CUST03 source mismatch.')
    policy = json.loads((CONTRACTS / 'candidate_c0c1_v1.json').read_text(encoding='utf-8'))
    if policy['source_sha256'] != sha or policy['fielding_authorized'] is not False:
        raise ValueError('Invalid candidate source/authority declaration.')
    return contract, policy, module


class CustomerCandidateService:
    """One isolated synthetic store. Assets are trusted fixture inputs, never API claims."""

    def __init__(self, engine, *, assets: dict | None = None):
        url = engine.url
        if url.drivername != 'sqlite' or url.database != ':memory:' or url.query:
            raise ValueError('Candidate execution requires private sqlite:///:memory: only.')
        self.engine = engine
        self.contract, self.policy, self.reference = load_sources()
        self.items = {item['id']: item for item in self.contract['items']}
        self.assets = deepcopy(assets or {})
        customer_candidate_metadata.create_all(engine)

    def _session(self, conn, sid):
        row = conn.execute(select(sessions).where(sessions.c.id == sid)).mappings().first()
        if row is None:
            raise ValueError('Synthetic session not found.')
        if row['policy_digest'] != digest(row['policy_snapshot']):
            raise ValueError('Policy snapshot integrity failure.')
        if row['contract_digest'] != SOURCE_SHA:
            raise ValueError('Contract integrity failure.')
        return dict(row)

    def create(self, sid, *, locale='EN', q02_policy='UNDECIDED',
               qualification='NOT_ASSESSED', asset_ids=None, optional=False):
        if not isinstance(sid, str) or not sid.startswith('SYN-') or len(sid) > 80:
            raise ValueError('Synthetic identifiers must start SYN- (maximum 80 characters).')
        if locale not in {'EN', 'BM'} or q02_policy not in self.policy['q02_policy_choices']:
            raise ValueError('Unregistered locale or Q02 policy.')
        if qualification not in PRETEST_QUALIFICATIONS or type(optional) is not bool:
            raise ValueError('Explicit synthetic qualification and optional policy required.')
        ids = asset_ids or {}
        if not isinstance(ids, dict) or any(k not in {'concept', 'menu', 'offer', 'occasion', 'features'}
                                           or v not in self.assets for k, v in ids.items()):
            raise ValueError('Asset IDs must refer to the trusted synthetic fixture registry.')
        context = {'locale': locale, 'q02_policy': q02_policy, 'qualification': qualification,
                   'asset_ids': ids, 'optional': optional, 'stimuli_shown': {},
                   'assets': {k: deepcopy(self.assets[v]) for k, v in ids.items()}}
        row = dict(id=sid, purpose='SYNTHETIC_ONLY', revision=0, contract_digest=SOURCE_SHA,
                   policy_digest=digest(self.policy), policy_snapshot=deepcopy(self.policy),
                   context=context)
        with self.engine.begin() as conn:
            conn.execute(insert(sessions).values(**row))
        return row

    def _asset(self, context, kind):
        asset = context['assets'].get(kind, {})
        record = asset.get('review_record', {})
        content = asset.get('content')
        if not content or not asset.get('version') or asset.get('kind') != kind:
            return None
        if record.get('status') != 'SYNTHETIC_REVIEW_FIXTURE':
            return None
        if not all(record.get(k) for k in ('record_id', 'reviewer', 'date')):
            return None
        if (record.get('artifact_sha256') != digest(content)
                or record.get('artifact_version') != asset['version']
                or record.get('scope') != kind):
            return None
        # Every stimulus and bank has locale-bound content. BM is not fabricated.
        if not content.get(context['locale']):
            return None
        if kind in {'menu', 'occasion', 'features'}:
            concept = context['assets'].get('concept', {})
            if (content.get('concept_version') != concept.get('version')
                    or content.get('concept_sha256') != digest(concept.get('content'))):
                return None
        bank_question = {'menu': 'Q06', 'occasion': 'Q09'}.get(kind)
        if bank_question and content.get('option_codes') != self.items[bank_question]['codes']:
            return None
        if kind == 'features':
            rows = content.get('feature_ids', [])
            if not rows or len(rows) > self.items['Q10']['feature_count_max']:
                return None
            if any(not isinstance(x, str) or not x or len(x) > 80 for x in rows):
                return None
            if len(rows) != len(set(rows)):
                return None
        return asset

    def _latest(self, conn, sid):
        rows = conn.execute(select(events).where(events.c.session_id == sid)
                            .order_by(events.c.revision)).mappings()
        return {(r['question_id'], r['feature_id']): dict(r) for r in rows}

    def _routes(self, row, latest):
        ctx, policy = row['context'], row['policy_snapshot']
        a1 = latest.get(('Q01', ''), {})
        state = a1.get('answer_state', 'NOT_SHOWN')
        screen = q01_screen(self.items['Q01'], state, a1.get('raw_response'))
        accepted = ctx['qualification'] == 'ACCEPTED_SYNTHETIC'
        eligible = screen == 'ELIGIBLE' and accepted
        a4 = latest.get(('Q04', ''), {})
        past = (a4.get('answer_state') == 'ANSWERED_SUBSTANTIVE'
                and a4.get('raw_response') != 'ZERO')
        assets = {k: self._asset(ctx, k) for k in ('concept', 'menu', 'offer', 'occasion', 'features')}
        concept_seen = bool(assets['concept']) and ctx['stimuli_shown'].get('concept') == digest(assets['concept']['content'])
        offer_seen = bool(assets['offer']) and ctx['stimuli_shown'].get('offer') == digest(assets['offer']['content'])
        inputs = {'Q01_SCREEN': screen,
                  'Q01_COMPLETED': bool(a1),
                  'Q02_VISIBLE': ctx['q02_policy'] == 'SHOW_ALL' or
                                 (ctx['q02_policy'] == 'ELIGIBLE_ONLY' and eligible),
                  'Q04_ANSWER': 'SUBSTANTIVE_NONZERO' if past else 'ZERO',
                  'APPROVED_EXACT_OFFER_STIMULUS': offer_seen,
                  'OPTIONAL_CONTEXT_ENABLED': ctx['optional'],
                  'CONCEPT_READY': concept_seen, 'MENU_READY': bool(assets['menu']),
                  'OCCASION_READY': bool(assets['occasion']), 'FEATURE_BANK_READY': bool(assets['features'])}
        # Qualification never becomes geographic rejection; retain screen separately.
        inputs['Q01_SCREEN'] = screen
        routes = {}
        for q, token in policy['item_show_gate'].items():
            verdict, reason = self.reference.gate(token, inputs, policy)
            if not accepted:
                verdict, reason = 'NOT_SHOWN', 'UNIT_' + ctx['qualification']
            dependencies = {'policy': row['policy_digest'], 'locale': ctx['locale'],
                            'qualification': ctx['qualification']}
            if q != 'Q01':
                dependencies['q01_answer_event'] = a1.get('id')
            if q == 'Q08':
                dependencies['past_purchase_answer_event'] = a4.get('id')
            kinds = {'Q03': ['concept'], 'Q05': ['concept'], 'Q06': ['concept', 'menu'],
                     'Q07': ['offer'], 'Q09': ['concept', 'occasion'],
                     'Q10': ['concept', 'features']}.get(q, [])
            dependencies['assets'] = {k: digest(assets[k]) if assets[k] else None for k in kinds}
            if q == 'Q02':
                dependencies['q02_policy'] = ctx['q02_policy']
            routes[q] = {'question_id': q, 'phase': 'C0' if q in {'Q01', 'Q02'} else 'C1',
                         'verdict': verdict, 'reason': reason, 'gate': token,
                         'context_digest': digest(dependencies),
                         'policy_status': policy['status'], 'publishable': False}
        return routes, screen

    def route(self, sid):
        with self.engine.connect() as conn:
            row = self._session(conn, sid)
            routes, screen = self._routes(row, self._latest(conn, sid))
            return {'revision': row['revision'], 'q01_screen': screen, 'items': routes,
                    'status': self.policy['status'], 'fielding_authorized': False}

    def _feature(self, row, q, feature):
        if q not in self.items:
            raise ValueError('Unknown source question code.')
        if q != 'Q10' and feature:
            raise ValueError('Only Q10 accepts a feature cell.')
        if q == 'Q10':
            bank = self._asset(row['context'], 'features')
            if not bank or feature not in bank['content']['feature_ids']:
                raise ValueError('Feature is not in the reviewed synthetic feature bank.')

    def _provenance(self, row, q):
        ctx = row['context']
        return {'campaign_id': 'SYNTHETIC_ONLY', 'respondent_unit_pseudonym': row['id'],
                'question_id': q, 'question_version': row['policy_snapshot']['version'] + ':' + q,
                'source_question_version': self.contract['spec_version'],
                'source_original': self.items[q].get('source_original'),
                'option_bank_version': row['policy_snapshot']['version'] + ':' + q + ':OPTIONS',
                'option_bank_digest': digest(self.items[q]['codes']),
                'cohort_rule_version': row['policy_snapshot']['version'],
                'policy_digest': row['policy_digest'], 'contract_digest': SOURCE_SHA,
                'locale': ctx['locale'], 'timestamp': datetime.now(timezone.utc).isoformat(),
                'shown_at': None, 'answered_at': None,
                'concept_version': ctx['assets'].get('concept', {}).get('version'),
                'stimulus_hash': digest(ctx['assets']) if ctx['assets'] else None,
                'stimuli': {k: {'version': v.get('version'),
                                'hash': digest(v.get('content')),
                                'review_record': v.get('review_record')}
                            for k, v in ctx['assets'].items()},
                'scientific_acceptance': 'PENDING', 'owner_adoption': 'PENDING',
                'cutoff': 'CURRENT_SYNTHETIC_REVISION_ONLY'}

    def expose(self, sid, kind, *, expected_revision):
        """Record actual delivery of the pinned stimulus before dependent questions."""
        with self.engine.begin() as conn:
            row = self._session(conn, sid)
            if row['revision'] != expected_revision:
                raise ValueError('Stale stimulus exposure revision.')
            asset = self._asset(row['context'], kind)
            if kind not in {'concept', 'offer'} or not asset:
                raise ValueError('Reviewed, locale-compatible stimulus fixture required.')
            context = deepcopy(row['context'])
            context['stimuli_shown'][kind] = digest(asset['content'])
            changed = conn.execute(update(sessions).where(sessions.c.id == sid,
                sessions.c.revision == expected_revision).values(context=context, revision=expected_revision + 1))
            if changed.rowcount != 1:
                raise ValueError('Concurrent stimulus exposure; reload session.')
            exposure = dict(id=str(uuid4()), session_id=sid, revision=expected_revision + 1,
                            asset_kind=kind, asset_digest=digest(asset['content']),
                            provenance={'version': asset['version'], 'review_record': asset['review_record'],
                                        'locale': context['locale'], 'policy_digest': row['policy_digest']})
            conn.execute(insert(exposures).values(**exposure))
            return {'exposure': exposure, 'content': asset['content'][context['locale']],
                    'revision': expected_revision + 1, 'status': 'SYNTHETIC_FIXTURE_ONLY'}

    def show(self, sid, q, *, expected_revision, feature=''):
        with self.engine.begin() as conn:
            row = self._session(conn, sid)
            if row['revision'] != expected_revision:
                raise ValueError('Stale session revision.')
            self._feature(row, q, feature)
            route = self._routes(row, self._latest(conn, sid))[0][q]
            if route['verdict'] != 'SHOWN':
                raise ValueError('Item withheld: ' + str(route['reason']))
            existing = conn.execute(select(displays).where(
                displays.c.session_id == sid, displays.c.question_id == q,
                displays.c.feature_id == feature, displays.c.revision == expected_revision,
                displays.c.context_digest == route['context_digest'])).mappings().first()
            if existing:
                return dict(existing)
            shown = dict(id=str(uuid4()), session_id=sid, question_id=q, feature_id=feature,
                         revision=expected_revision, context_digest=route['context_digest'],
                         provenance=self._provenance(row, q))
            shown['provenance']['shown_at'] = shown['provenance']['timestamp']
            conn.execute(insert(displays).values(**shown))
            return shown

    def answer(self, sid, q, value, *, expected_revision, request_id, display_id, feature=''):
        if not isinstance(request_id, str) or not request_id or len(request_id) > 80:
            raise ValueError('A bounded idempotency request ID is required.')
        body_hash = digest([q, value, expected_revision, display_id, feature])
        with self.engine.begin() as conn:
            row = self._session(conn, sid)
            retry = conn.execute(select(events).where(events.c.session_id == sid,
                                                      events.c.request_id == request_id)).mappings().first()
            if retry:
                if retry['request_digest'] != body_hash:
                    raise ValueError('Idempotency request reused with different input.')
                return dict(retry)
            if expected_revision != row['revision']:
                raise ValueError('Stale session revision.')
            self._feature(row, q, feature)
            latest = self._latest(conn, sid)
            before, _ = self._routes(row, latest)
            shown = conn.execute(select(displays).where(displays.c.id == display_id,
                                    displays.c.session_id == sid, displays.c.question_id == q,
                                    displays.c.feature_id == feature)).mappings().first()
            if (not shown or before[q]['verdict'] != 'SHOWN'
                    or shown['revision'] != expected_revision
                    or shown['context_digest'] != before[q]['context_digest']):
                raise ValueError('Current authorized synthetic display is required.')
            state, reason = classify_answer(self.items[q], value, row['policy_snapshot']['q01_option_state_map'])
            changed = conn.execute(update(sessions).where(sessions.c.id == sid,
                        sessions.c.revision == expected_revision).values(revision=expected_revision + 1))
            if changed.rowcount != 1:
                raise ValueError('Concurrent update; reload session.')
            event = dict(id=str(uuid4()), session_id=sid, question_id=q, feature_id=feature,
                         revision=expected_revision + 1, request_id=request_id,
                         request_digest=body_hash, display_id=display_id, answer_state=state,
                         raw_response=value, reason=reason, context_digest=before[q]['context_digest'],
                         provenance=self._provenance(row, q))
            event['provenance'].update(shown_at=shown['provenance']['shown_at'],
                answered_at=event['provenance']['timestamp'], answer_state=state,
                non_substantive_reason=reason,
                option_ids=value if isinstance(value, list) else [value] if isinstance(value, str) else [])
            conn.execute(insert(events).values(**event))
            latest[(q, feature)] = event
            after, _ = self._routes(row, latest)
            # A route-changing edit appends invalidations; it never deletes history
            # or resurrects an answer when a route later reopens.
            for (dep, cell), old in latest.items():
                if dep == q or old['answer_state'] == 'NOT_SHOWN':
                    continue
                if (after[dep]['verdict'] != 'SHOWN'
                        or before[dep]['context_digest'] != after[dep]['context_digest']):
                    invalidated = dict(event, id=str(uuid4()), question_id=dep, feature_id=cell,
                        request_id='SYS-' + str(uuid4()), request_digest=digest(old['id']),
                        display_id=None, answer_state='NOT_SHOWN', raw_response=None,
                        reason='ROUTE_CHANGE_SUPERSEDED', context_digest=after[dep]['context_digest'],
                        provenance=self._provenance(row, dep))
                    conn.execute(insert(events).values(**invalidated))
            return event

    def history(self, sid):
        with self.engine.connect() as conn:
            self._session(conn, sid)
            return [dict(r) for r in conn.execute(select(events).where(events.c.session_id == sid)
                                                  .order_by(events.c.revision, events.c.question_id)).mappings()]

    def counts(self, sid, q, *, feature=''):
        with self.engine.connect() as conn:
            row = self._session(conn, sid)
            self._feature(row, q, feature)
            latest = self._latest(conn, sid)
            routes, screen = self._routes(row, latest)
            pre = int(row['context']['qualification'] == 'ACCEPTED_SYNTHETIC')
            post = int(pre == 1 and screen == 'ELIGIBLE')
            pre_item = q == 'Q01' or (q == 'Q02' and row['context']['q02_policy'] == 'SHOW_ALL')
            cohort = pre if pre_item else post
            shown = conn.execute(select(displays).where(displays.c.session_id == sid,
                                    displays.c.question_id == q, displays.c.feature_id == feature,
                                    displays.c.context_digest == routes[q]['context_digest'])).first()
            active = routes[q]['verdict'] == 'SHOWN' and cohort == 1
            event = latest.get((q, feature), {})
            current = event.get('context_digest') == routes[q]['context_digest']
            state = event.get('answer_state', 'SKIPPED') if active and current else 'NOT_SHOWN'
            s = int(active and bool(shown))
            a = int(s == 1 and state in {'REFUSED', 'INVALID', 'ANSWERED_SUBSTANTIVE', 'ANSWERED_NON_SUBSTANTIVE'})
            v = int(s == 1 and state == 'ANSWERED_SUBSTANTIVE')
            result = {'I': 'UNKNOWN_NOT_ENUMERABLE', 'Q_pre': pre, 'Q_post': post, 'Q': cohort,
                      'cohort': 'Q_pre_CANDIDATE' if pre_item else 'Q_post_CANDIDATE',
                      'S': s, 'A': a, 'V': v,
                      'invalid': int(a == 1 and state == 'INVALID'),
                      'refused': int(a == 1 and state == 'REFUSED'),
                      'non_substantive': int(a == 1 and state == 'ANSWERED_NON_SUBSTANTIVE'),
                      'skipped': int(s == 1 and a == 0), 'not_shown': int(s == 0),
                      'qualification': row['context']['qualification'], 'q01_screen': screen,
                      'estimate_status': 'NOT_ESTIMABLE' if v == 0 else 'SYNTHETIC_ONLY',
                      'publishable': False}
            if not 0 <= v <= a <= s <= cohort:
                raise ValueError('Funnel integrity failure.')
            return result

    def record_pretest(self, sid, q, check, result, *, expected_revision, feature=''):
        with self.engine.begin() as conn:
            row = self._session(conn, sid)
            if row['revision'] != expected_revision:
                raise ValueError('Stale pretest route revision.')
            locale = row['context']['locale']
            self._feature(row, q, feature)
            validate_structured_pretest(q, locale, check, result, row['policy_snapshot'])
            route = self._routes(row, self._latest(conn, sid))[0][q]
            shown = conn.execute(select(displays).where(displays.c.session_id == sid,
                displays.c.question_id == q, displays.c.feature_id == feature,
                displays.c.context_digest == route['context_digest'])).first()
            if not shown or route['verdict'] != 'SHOWN':
                raise ValueError('Pretest requires an actually displayed item on the current route.')
            record = dict(id=str(uuid4()), session_id=sid, question_id=q, feature_id=feature, locale=locale,
                          check_code=check, result_code=result,
                          question_version=row['policy_snapshot']['version'] + ':' + q,
                          route_revision=expected_revision, policy_digest=row['policy_digest'],
                          option_bank_digest=digest(self.items[q]['codes']))
            conn.execute(insert(pretests).values(**record))
            return record
