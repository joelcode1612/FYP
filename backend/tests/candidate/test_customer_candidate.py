"""Offline synthetic tests. Run with unittest to avoid the live-DB conftest."""
from copy import deepcopy
import itertools
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, select
from sqlalchemy.exc import DatabaseError
from sqlalchemy.pool import StaticPool

from sitewise.api.v1.customer_candidate import create_synthetic_app
from sitewise.db.models.customer_candidate_schema import events, sessions
from sitewise.domain.customer_questionnaire import classify_answer, digest, q01_screen
from sitewise.services import customer_questionnaire_candidate as module
from sitewise.services.customer_questionnaire_candidate import CustomerCandidateService


def fixture_asset(kind, *, locales=('EN', 'BM')):
    content = {locale: 'SYNTHETIC STIMULUS — NOT APPROVED TRANSLATION' for locale in locales}
    if kind in {'features', 'menu', 'occasion'}:
        content['concept_version'] = 'SYN-v1'
        content['concept_sha256'] = digest({locale: 'SYNTHETIC STIMULUS — NOT APPROVED TRANSLATION'
                                            for locale in locales})
    if kind in {'menu', 'occasion'}:
        contract = module.load_sources()[0]
        q = 'Q06' if kind == 'menu' else 'Q09'
        content['option_codes'] = next(x['codes'] for x in contract['items'] if x['id'] == q)
    if kind == 'features':
        content['feature_ids'] = ['SYN-FEATURE-1', 'SYN-FEATURE-2']
    return {'kind': kind, 'version': 'SYN-v1', 'content': content,
            'review_record': {'record_id': 'SYN-REVIEW-' + kind, 'reviewer': 'SYNTHETIC TEST FIXTURE',
                              'date': '2026-11-07', 'status': 'SYNTHETIC_REVIEW_FIXTURE',
                              'scope': kind, 'artifact_version': 'SYN-v1',
                              'artifact_sha256': digest(content)}}


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine('sqlite:///:memory:', poolclass=StaticPool,
                                    connect_args={'check_same_thread': False})
        self.assets = {k: fixture_asset(k) for k in ('concept', 'menu', 'offer', 'occasion', 'features')}
        self.service = CustomerCandidateService(self.engine, assets=self.assets)

    def tearDown(self):
        self.engine.dispose()

    def new(self, **kwargs):
        sid = 'SYN-' + str(uuid4())
        self.service.create(sid, qualification='ACCEPTED_SYNTHETIC', **kwargs)
        return sid

    def answer(self, sid, q, value, feature=''):
        rev = self.service.route(sid)['revision']
        display = self.service.show(sid, q, expected_revision=rev, feature=feature)
        return self.service.answer(sid, q, value, expected_revision=rev, request_id=str(uuid4()),
                                   display_id=display['id'], feature=feature)

    def ready(self, **kwargs):
        sid = self.new(asset_ids={k:k for k in self.assets}, **kwargs)
        self.answer(sid, 'Q01', ['LIVE'])
        rev = self.service.route(sid)['revision']
        self.service.expose(sid, 'concept', expected_revision=rev)
        return sid

    def test_source_and_reference_are_byte_pinned(self):
        contract, policy, reference = module.load_sources()
        self.assertEqual(contract['spec_version'], self.service.contract['spec_version'])
        self.assertEqual(policy['source_sha256'], module.SOURCE_SHA)
        self.assertTrue(callable(reference.gate))

    def test_source_negative_control_detects_byte_flip(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'contracts'
            shutil.copytree(module.CONTRACTS, dest, ignore=shutil.ignore_patterns('__pycache__'))
            target = dest / 'reference/CUST_RECOVERY_20261027/CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json'
            target.write_bytes(target.read_bytes() + b' ')
            with patch.object(module, 'CONTRACTS', dest), self.assertRaises(ValueError):
                module.load_sources()

    def test_all_512_q01_sets_have_strict_proposed_outcomes(self):
        item = self.service.items['Q01']
        histogram = {}
        for n in range(10):
            for subset in itertools.combinations(item['codes'], n):
                state, _ = classify_answer(item, list(subset), self.service.policy['q01_option_state_map'])
                histogram[state] = histogram.get(state, 0) + 1
                screen = q01_screen(item, state, list(subset))
                if set(subset).intersection(item['exclusive_codes']) and len(subset) > 1:
                    self.assertEqual((state, screen), ('INVALID', 'SCREEN_INVALID'))
        self.assertEqual(histogram, {'SKIPPED':1, 'ANSWERED_SUBSTANTIVE':63,
                                    'ANSWERED_NON_SUBSTANTIVE':3, 'INVALID':445})

    def test_bad_duplicate_and_wrong_shape_q01_inputs(self):
        for value in [['BAD'], ['LIVE', 'LIVE'], 'LIVE', [True], {'LIVE': True}]:
            with self.subTest(value=value):
                self.assertEqual(self.answer(self.new(), 'Q01', value)['answer_state'], 'INVALID')

    def test_q01_terminal_never_becomes_eligible(self):
        for code, expected in [('RARELY','AREA_OUTSIDE'), ('NEVER','AREA_OUTSIDE'), ('NOT_SURE','AREA_UNKNOWN')]:
            sid = self.new()
            self.answer(sid, 'Q01', [code])
            self.assertEqual(self.service.route(sid)['q01_screen'], expected)
            self.assertEqual(self.service.counts(sid, 'Q01')['Q_post'], 0)
            self.assertEqual(self.service.route(sid)['items']['Q04']['verdict'], 'NOT_SHOWN')

    def test_q02_distinct_days_preserves_exact_source_codes(self):
        item = self.service.items['Q02']
        labels = self.service.policy['q02_distinct_day_labels']
        self.assertEqual(set(labels), set(item['codes']))
        self.assertEqual(labels['DAYS_GT_20'], '21–28 days')
        for code in item['codes']:
            state, _ = classify_answer(item, code, {})
            self.assertEqual(state, 'REFUSED' if code == 'PREFER_NOT_TO_ANSWER' else 'ANSWERED_SUBSTANTIVE')

    def test_q02_all_versus_eligible_and_undecided(self):
        for policy in ['SHOW_ALL','ELIGIBLE_ONLY','UNDECIDED']:
            for answer in [['LIVE'], ['NEVER'], ['NOT_SURE'], ['LIVE','NEVER'], []]:
                sid = self.new(q02_policy=policy)
                self.assertEqual(self.service.route(sid)['items']['Q02']['verdict'], 'NOT_SHOWN')
                self.answer(sid, 'Q01', answer)
                should_show = policy == 'SHOW_ALL' or policy == 'ELIGIBLE_ONLY' and answer == ['LIVE']
                self.assertEqual(self.service.route(sid)['items']['Q02']['verdict'], 'SHOWN' if should_show else 'NOT_SHOWN')

    def test_q02_is_not_an_extra_eligibility_threshold(self):
        sid = self.new(q02_policy='ELIGIBLE_ONLY')
        self.answer(sid, 'Q01', ['LIVE'])
        self.answer(sid, 'Q02', 'NONE')
        self.assertEqual(self.service.route(sid)['q01_screen'], 'ELIGIBLE')

    def test_q05_requires_reviewed_and_actually_seen_stimulus(self):
        sid = self.new(asset_ids={'concept':'concept'})
        self.answer(sid, 'Q01', ['LIVE'])
        self.assertEqual(self.service.route(sid)['items']['Q05']['verdict'], 'NOT_SHOWN')
        self.service.expose(sid, 'concept', expected_revision=1)
        self.assertEqual(self.service.route(sid)['items']['Q05']['verdict'], 'SHOWN')

    def test_forged_boolean_or_mismatched_asset_record_fails_closed(self):
        for key, value in [('status','APPROVED'), ('artifact_sha256','wrong'),
                           ('artifact_version','wrong'), ('scope','wrong'), ('reviewer','')]:
            assets = deepcopy(self.assets)
            assets['concept']['review_record'][key] = value
            engine = create_engine('sqlite:///:memory:')
            try:
                service = CustomerCandidateService(engine, assets=assets)
                service.create('SYN-asset', qualification='ACCEPTED_SYNTHETIC', asset_ids={'concept':'concept'})
                with self.assertRaises(ValueError):
                    service.expose('SYN-asset', 'concept', expected_revision=0)
            finally:
                engine.dispose()

    def test_q09_is_independent_of_every_q04_code_and_q05_positivity(self):
        for code in self.service.items['Q04']['codes']:
            for intent in ['DEF_NO','UNSURE','DEF_YES','PREFER_NOT_TO_ANSWER']:
                sid = self.ready()
                self.answer(sid, 'Q04', code)
                self.answer(sid, 'Q05', intent)
                self.assertEqual(self.service.route(sid)['items']['Q09']['verdict'], 'SHOWN')
                self.assertEqual(self.service.route(sid)['items']['Q08']['verdict'],
                                 'SHOWN' if code in ['ONE','TWO_THREE','FOUR_SEVEN','EIGHT_PLUS'] else 'NOT_SHOWN')

    def test_q09_requires_occasion_bank_and_concept(self):
        for ids in [{}, {'concept':'concept'}, {'occasion':'occasion'}]:
            sid = self.new(asset_ids=ids)
            self.answer(sid, 'Q01', ['LIVE'])
            if 'concept' in ids:
                self.service.expose(sid, 'concept', expected_revision=1)
            self.assertEqual(self.service.route(sid)['items']['Q09']['verdict'], 'NOT_SHOWN')

    def test_q10_no_bank_no_feature_response(self):
        sid = self.new(asset_ids={'concept':'concept'})
        self.answer(sid, 'Q01', ['LIVE'])
        self.service.expose(sid, 'concept', expected_revision=1)
        self.assertEqual(self.service.route(sid)['items']['Q10']['verdict'], 'NOT_SHOWN')
        with self.assertRaises(ValueError):
            self.service.show(sid, 'Q10', expected_revision=2, feature='INVENTED')

    def test_banks_for_different_concepts_are_withheld(self):
        for kind, q in [('features','Q10'), ('occasion','Q09'), ('menu','Q06')]:
            bank = self.service.assets[kind]
            bank['content']['concept_version'] = 'DIFFERENT-CONCEPT'
            bank['review_record']['artifact_sha256'] = digest(bank['content'])
            sid = self.ready()
            self.assertEqual(self.service.route(sid)['items'][q]['verdict'], 'NOT_SHOWN')

    def test_q10_per_feature_funnels_and_no_composite(self):
        sid = self.ready()
        self.answer(sid, 'Q10', 'VERY_IMPORTANT', 'SYN-FEATURE-1')
        self.answer(sid, 'Q10', 'PREFER_NOT_TO_ANSWER', 'SYN-FEATURE-2')
        self.assertEqual(self.service.counts(sid, 'Q10', feature='SYN-FEATURE-1')['V'], 1)
        c = self.service.counts(sid, 'Q10', feature='SYN-FEATURE-2')
        self.assertEqual((c['S'],c['A'],c['V'],c['refused']), (1,1,0,1))
        record = self.service.record_pretest(sid, 'Q10', 'FEATURE_ROW_COMPREHENSION', 'CORRECT',
                    expected_revision=self.service.route(sid)['revision'], feature='SYN-FEATURE-1')
        self.assertEqual(record['feature_id'], 'SYN-FEATURE-1')
        with self.assertRaises(ValueError):
            self.service.counts(sid, 'Q10')

    def test_exact_source_maps_all_non_q01_options(self):
        for q, item in self.service.items.items():
            if q == 'Q01':
                continue
            for code in item['codes']:
                value = [code] if item['type'] == 'multi_select' else code
                state, _ = classify_answer(item, value, {})
                self.assertEqual(state, item['option_to_state_map'][code], (q,code))

    def test_multiselect_cap_exclusivity_and_refusal(self):
        item = self.service.items['Q06']
        for value in [['NONE','COFFEE_ESPRESSO'], ['PREFER_NOT_TO_ANSWER','COFFEE_ESPRESSO'],
                      ['COFFEE_ESPRESSO','NON_COFFEE','BAKED_PASTRY','LIGHT_MEALS']]:
            self.assertEqual(classify_answer(item,value,{})[0], 'INVALID')

    def test_histories_revisions_retries_and_stale_writes(self):
        sid = self.new()
        display = self.service.show(sid,'Q01',expected_revision=0)
        args = dict(expected_revision=0, request_id='request-1',display_id=display['id'])
        first = self.service.answer(sid,'Q01',['LIVE'],**args)
        self.assertEqual(self.service.answer(sid,'Q01',['LIVE'],**args),first)
        with self.assertRaises(ValueError):
            self.service.answer(sid,'Q01',['WORK'],**args)
        with self.assertRaises(ValueError):
            self.service.answer(sid,'Q01',['LIVE'],**dict(args,request_id='request-2'))
        self.answer(sid,'Q01',['WORK'])
        self.assertEqual(len(self.service.history(sid)),2)
        self.assertEqual(self.service.history(sid)[0]['raw_response'],['LIVE'])
        self.assertEqual(self.service.counts(sid,'Q01')['V'],1)

    def test_route_edits_invalidate_history_without_resurrection(self):
        sid = self.ready()
        self.answer(sid,'Q04','ONE')
        self.answer(sid,'Q08',['SOCIAL'])
        self.answer(sid,'Q09',['SOCIAL'])
        self.answer(sid,'Q04','ZERO')
        self.assertEqual(self.service.counts(sid,'Q08')['V'],0)
        self.assertEqual(self.service.counts(sid,'Q09')['V'],1)
        self.answer(sid,'Q04','ONE')
        self.assertEqual(self.service.counts(sid,'Q08')['V'],0)
        self.assertEqual(self.service.counts(sid,'Q08')['S'],0)
        self.assertTrue(any(e['reason']=='ROUTE_CHANGE_SUPERSEDED' for e in self.service.history(sid)))
        self.answer(sid,'Q01',['NEVER'])
        self.assertEqual(self.service.counts(sid,'Q09')['V'],0)
        self.answer(sid,'Q01',['LIVE'])
        self.assertEqual(self.service.counts(sid,'Q09')['V'],0)
        self.assertEqual(self.service.counts(sid,'Q09')['S'],0)

    def test_display_only_does_not_resurrect_when_route_reopens(self):
        sid = self.ready()
        self.answer(sid, 'Q04', 'ONE')
        self.service.show(sid, 'Q08', expected_revision=self.service.route(sid)['revision'])
        self.assertEqual(self.service.counts(sid,'Q08')['S'],1)
        self.answer(sid, 'Q04', 'ZERO')
        self.answer(sid, 'Q04', 'ONE')
        self.assertEqual(self.service.counts(sid,'Q08')['S'],0)

    def test_history_is_database_enforced_append_only(self):
        sid = self.new()
        self.answer(sid, 'Q01', ['LIVE'])
        for mutation in [events.update().values(raw_response=['NEVER']), events.delete()]:
            with self.assertRaises(DatabaseError), self.engine.begin() as conn:
                conn.execute(mutation)

    def test_preview_is_not_exposure_and_refusal_is_not_skip(self):
        sid = self.new(q02_policy='SHOW_ALL')
        self.answer(sid,'Q01',['LIVE'])
        self.service.route(sid)
        self.assertEqual(self.service.counts(sid,'Q02')['S'],0)
        self.service.show(sid,'Q02',expected_revision=1)
        self.assertEqual(self.service.counts(sid,'Q02')['skipped'],1)
        self.answer(sid,'Q02','PREFER_NOT_TO_ANSWER')
        c = self.service.counts(sid,'Q02')
        self.assertEqual((c['S'],c['A'],c['V'],c['refused'],c['skipped']), (1,1,0,1,0))
        self.assertEqual(c['I'],'UNKNOWN_NOT_ENUMERABLE')
        self.assertEqual(c['estimate_status'],'NOT_ESTIMABLE')

    def test_q02_cohorts_are_policy_specific(self):
        sid = self.new(q02_policy='SHOW_ALL')
        self.answer(sid,'Q01',['NEVER'])
        self.answer(sid,'Q02','NONE')
        c = self.service.counts(sid,'Q02')
        self.assertEqual((c['Q_pre'],c['Q_post'],c['Q'],c['V']), (1,0,1,1))
        self.assertEqual(c['cohort'],'Q_pre_CANDIDATE')

    def test_every_prequalification_exclusion_stays_distinct(self):
        for reason in module.PRETEST_QUALIFICATIONS - {'ACCEPTED_SYNTHETIC'}:
            sid = 'SYN-' + str(uuid4())
            self.service.create(sid,qualification=reason)
            c = self.service.counts(sid,'Q01')
            self.assertEqual((c['Q'],c['S'],c['A'],c['V']), (0,0,0,0))
            self.assertEqual(c['qualification'],reason)

    def test_all_13_have_closed_en_bm_pretest_metadata(self):
        metadata = self.service.policy['structured_pretest']
        self.assertEqual(set(metadata),set(self.service.items))
        for q, m in metadata.items():
            self.assertEqual(m['locales'],['EN','BM'])
            self.assertEqual(m['option_codes'], self.service.items[q]['codes'])
            self.assertEqual(m['human_results'],'NOT_EXECUTED')
            self.assertEqual(m['bm_translation_status'],'MISSING_NOT_APPROVED')

    def test_closed_pretest_storage_for_both_locales(self):
        for locale in ['EN','BM']:
            sid = self.new(locale=locale)
            self.service.show(sid,'Q01',expected_revision=0)
            record = self.service.record_pretest(sid,'Q01','MEANING_MATCH','CORRECT',expected_revision=0)
            self.assertEqual(record['locale'],locale)
            with self.assertRaises(ValueError):
                self.service.record_pretest(sid,'Q01','MEANING_MATCH','free text',expected_revision=0)

    def test_bm_missing_stimulus_does_not_fall_back_to_en(self):
        self.service.assets['concept'] = fixture_asset('concept',locales=('EN',))
        sid = self.new(locale='BM',asset_ids={'concept':'concept'})
        with self.assertRaises(ValueError):
            self.service.expose(sid,'concept',expected_revision=0)

    def test_session_asset_snapshot_is_immutable(self):
        sid = self.new(asset_ids={'concept':'concept'})
        self.service.assets['concept']['content']['EN'] = 'CHANGED LATER'
        delivered = self.service.expose(sid,'concept',expected_revision=0)
        self.assertNotEqual(delivered['content'],'CHANGED LATER')

    def test_policy_snapshot_integrity_is_checked(self):
        sid = self.new()
        with self.engine.begin() as conn:
            row = conn.execute(select(sessions).where(sessions.c.id==sid)).mappings().one()
            bad = deepcopy(row['policy_snapshot'])
            bad['version'] = 'TAMPERED'
            conn.execute(sessions.update().where(sessions.c.id==sid).values(policy_snapshot=bad))
        with self.assertRaises(ValueError):
            self.service.route(sid)

    def test_nonmemory_databases_are_rejected_before_connect(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'never-created.db'
            engine = create_engine('sqlite:///' + str(path))
            with self.assertRaises(ValueError):
                CustomerCandidateService(engine)
            self.assertFalse(path.exists())
            engine.dispose()

    def test_separate_schema_cannot_seed_or_authorize_instruments(self):
        tables = inspect(self.engine).get_table_names()
        self.assertEqual(len(tables),5)
        self.assertTrue(all(t.startswith('cq_candidate_') for t in tables))
        with self.assertRaises(ValueError):
            self.service.create('real-person',qualification='ACCEPTED_SYNTHETIC')

    def test_postgres_draft_matches_metadata_and_stays_outside_discovery(self):
        root = Path(__file__).resolve().parents[2]
        path = root / 'candidates/cust03_vnext/compile_schema.py'
        spec = importlib.util.spec_from_file_location('compile_candidate', path)
        compiler = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(compiler)
        draft = path.with_name('001_customer_candidate_REVIEW_ONLY.sql')
        self.assertEqual(draft.read_text(encoding='utf-8'), compiler.render())
        self.assertFalse((root/'supabase/migrations'/draft.name).exists())
        self.assertFalse((root/'alembic/versions'/draft.name).exists())

    def test_sandbox_api_end_to_end_and_strict_requests(self):
        with TestClient(create_synthetic_app(self.service)) as client:
            response = client.post('/candidate/sessions',json={'session_id':'SYN-api','qualification':'ACCEPTED_SYNTHETIC'})
            self.assertEqual(response.status_code,201)
            shown = client.post('/candidate/sessions/SYN-api/items/Q01/display',json={'expected_revision':0}).json()
            response = client.post('/candidate/sessions/SYN-api/items/Q01/answers',json={
                'expected_revision':0,'request_id':'api1','display_id':shown['display']['id'],'value':['LIVE']})
            self.assertEqual(response.status_code,200)
            self.assertEqual(response.json()['answer_state'],'ANSWERED_SUBSTANTIVE')
            self.assertEqual(client.get('/candidate/sessions/SYN-api/items/Q01/counts').json()['V'],1)
            self.assertEqual(client.post('/candidate/sessions',json={
                'session_id':'SYN-forged','scientifically_approved':True}).status_code,422)
            self.assertEqual(client.post('/candidate/sessions',json={
                'session_id':'SYN-api'}).status_code,409)

    def test_application_router_has_no_candidate_registration(self):
        root = Path(__file__).resolve().parents[2]
        for relative in ['src/sitewise/api/v1/router.py','src/sitewise/main.py','src/sitewise/db/models/__init__.py']:
            self.assertNotIn('customer_candidate', (root/relative).read_text(encoding='utf-8'))

    def test_unresolved_predicate_withholds_and_rules_are_data_driven(self):
        self.service.policy['gate']['token_predicates'].pop('FUTURE_OCCASION')
        sid = self.ready()
        route = self.service.route(sid)['items']['Q09']
        self.assertEqual(route['verdict'], 'NOT_SHOWN')
        self.assertIn('TOKEN_NOT_IN_SPEC', route['reason'])

    def test_event_provenance_retains_source_and_successor_versions(self):
        sid = self.new()
        event = self.answer(sid, 'Q01', ['LIVE'])
        p = event['provenance']
        self.assertNotEqual(p['question_version'], p['source_question_version'])
        for name in self.service.contract['event_fields']:
            self.assertIn(name, p, name)
        self.assertEqual(p['option_ids'], ['LIVE'])
        self.assertEqual(p['source_original'], 'CS-01')

    def test_invalid_answers_are_preserved_but_excluded_from_v(self):
        sid = self.new()
        event = self.answer(sid, 'Q01', ['LIVE','NEVER'])
        self.assertEqual(event['raw_response'], ['LIVE','NEVER'])
        counts = self.service.counts(sid,'Q01')
        self.assertEqual((counts['S'],counts['A'],counts['V'],counts['invalid']), (1,1,0,1))


if __name__ == '__main__':
    unittest.main(verbosity=2)
