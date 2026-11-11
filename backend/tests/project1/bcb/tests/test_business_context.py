from copy import deepcopy
from dataclasses import replace
import json
from pathlib import Path
import unittest
from uuid import UUID

from sandbox_support import (load_fixture, request_for, rebind, SyntheticAuthorization,
                             SyntheticSnapshots, FixedClock)
from sitewise.services.business_context_v1 import BusinessContextBuilderV1, ContextRefused, source_hash


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.f = load_fixture()
        self.auth = SyntheticAuthorization(self.f)
        self.snap = SyntheticSnapshots(self.f)
        self.service = BusinessContextBuilderV1(self.auth, self.snap, FixedClock())
        self.fixture_path = Path(__file__).resolve().parents[1]/'fixtures/valid_confirmed.json'
        self.original_file = self.fixture_path.read_bytes()

    def tearDown(self):
        self.assertEqual(self.fixture_path.read_bytes(), self.original_file)
        self.assertTrue(set(self.snap.calls) <= {'assessment','confirmation','instrument','items','answers','findings'})

    def call(self, request=None):
        original = deepcopy(self.f)
        try:
            return self.service.get_context(request or request_for(self.f))
        finally:
            self.assertEqual(self.f, original, 'Canonical synthetic records/history were mutated')

    def refuse(self, code=None, request=None):
        with self.assertRaises(ContextRefused) as caught:
            self.call(request)
        if code:
            self.assertEqual(caught.exception.code, code)
        return caught.exception

    def test_valid_confirmed_context(self):
        p = self.call()
        self.assertEqual(p['confirmation']['revision'], 2)
        self.assertEqual(len(p['m2_answers']), 3)
        self.assertTrue(all(x['response_version'] and x['codebook_version'] and x['question_version'] for x in p['m2_answers']))

    def test_missing_optional_m2_04(self):
        del self.f['answers']['M2-04']; self.f['findings'] = []; rebind(self.f)
        p = self.call()
        self.assertIsNone(p['business_description'])
        self.assertIn('M2_04_MISSING', [x['code'] for x in p['unknowns']])

    def test_description_exact_bytes_including_spacing(self):
        self.assertEqual(self.call()['business_description']['value'], self.f['answers']['M2-04']['value_json'])

    def test_missing_mandatory_answer(self):
        del self.f['answers']['M2-01']; rebind(self.f)
        self.refuse('MANDATORY_CONTEXT_MISSING')

    def test_mandatory_nonprovided(self):
        self.f['answers']['M2-01'].update(answer_state='NOT_PROVIDED', value_json=None); rebind(self.f)
        self.refuse('MANDATORY_CONTEXT_MISSING')

    def test_instrument_defined_unknown_remains_unknown(self):
        self.f['items'][0]['allowed_states'].append('DONT_KNOW')
        self.f['answers']['M2-01'].update(answer_state='DONT_KNOW', value_json=None); rebind(self.f)
        p = self.call()
        self.assertIn('M2_NONANSWER', [x['code'] for x in p['unknowns']])

    def test_unconfirmed_m2(self):
        self.f['assessment']['confirmed_revision'] = None
        self.refuse('M2_CONFIRMATION_STALE')

    def test_changed_m2_revision(self):
        self.f['assessment']['revision'] = 3
        self.refuse('M2_CONFIRMATION_STALE')

    def test_changed_answer_under_same_revision(self):
        self.f['answers']['M2-01']['value_json'] = 'SYNTHETIC_B'
        self.refuse('M2_ANSWERS_CHANGED')

    def test_missing_confirmation_record(self):
        self.f['confirmation'] = None
        self.refuse('M2_CONFIRMATION_MISSING')

    def test_confirmation_digest_tamper(self):
        self.f['confirmation']['snapshot_json']['instrument_version'] = 'tampered'
        self.refuse('CONFIRMATION_DIGEST_INVALID')

    def test_confirmation_bound_to_other_assessment(self):
        self.f['confirmation']['assessment_id'] = 'other'
        self.refuse('M2_CONFIRMATION_STALE')

    def test_expired_concept(self):
        self.f['bindings']['concept']['valid_until'] = '2026-11-07T00:00:00Z'
        self.refuse('CONCEPT_STALE')

    def test_stale_concept_version(self):
        self.f['bindings']['current_concept_version'] = 'v2'
        self.refuse('CONCEPT_STALE')

    def test_unconfirmed_concept(self):
        self.f['bindings']['concept']['status'] = 'DRAFT'
        self.refuse('CONCEPT_STALE')

    def test_concept_hash_tamper(self):
        self.f['bindings']['concept']['content']['description'] = 'tampered'
        self.refuse('CONCEPT_SOURCE_INVALID')

    def test_concept_missing(self):
        self.f['bindings']['concept'] = None
        self.refuse('CONCEPT_MISSING')

    def test_unauthorized_denied_before_content(self):
        self.f['decision']['allowed'] = False
        self.refuse('ACCESS_DENIED')
        self.assertEqual(self.snap.opens, 0)
        self.assertEqual(self.snap.calls, [])

    def test_cross_tenant_denied_before_content(self):
        self.refuse('ACCESS_DENIED', replace(request_for(self.f), tenant_id='TENANT-B'))
        self.assertEqual(self.snap.opens, 0)

    def test_other_viewer_denied_before_content(self):
        self.refuse('ACCESS_DENIED', replace(request_for(self.f), viewer_id=UUID(int=999)))
        self.assertEqual(self.snap.opens, 0)

    def test_forged_role_denied_before_content(self):
        self.refuse('ACCESS_DENIED', replace(request_for(self.f), role='admin'))
        self.assertEqual(self.snap.opens, 0)

    def test_expired_authorization_denied_before_content(self):
        self.f['decision']['valid_until'] = '2000-01-01T00:00:00Z'
        self.refuse('ACCESS_DENIED'); self.assertEqual(self.snap.opens, 0)

    def test_unapproved_purpose_denied_before_content(self):
        self.refuse('INVALID_REQUEST', replace(request_for(self.f), purpose='REPORT_RELEASE'))
        self.assertEqual(self.snap.opens, 0)

    def test_snapshot_cross_tenant(self):
        self.f['bindings']['scope']['tenant_id'] = 'TENANT-B'
        self.refuse('SNAPSHOT_SCOPE_INVALID'); self.assertEqual(self.snap.calls, [])

    def test_snapshot_not_consistent(self):
        self.f['bindings']['consistency'] = 'READ_COMMITTED'
        self.refuse('SNAPSHOT_SCOPE_INVALID')

    def test_wrong_owner_even_if_port_errs(self):
        self.f['assessment']['owner_user_id'] = 'other'
        self.refuse('ACCESS_DENIED')

    def test_unsupported_geographic_identifier(self):
        self.f['bindings']['geography'].update(source_code='2_1', area_id='MY-ADM2-2_1', jurisdiction='Kedah')
        self.refuse('GEO_SCOPE_INVALID')

    def test_nonexistent_in_scope_district(self):
        self.f['bindings']['geography'].update(source_code='14_2', area_id='MY-ADM2-14_2')
        self.refuse('GEO_SCOPE_INVALID')

    def test_geo_unapproved(self):
        self.f['bindings']['geography']['approval_state'] = 'PROPOSED'
        self.refuse('GEO_UNAPPROVED')

    def test_kl_is_federal_territory(self):
        self.assertEqual(self.call()['geography']['area_kind'], 'FEDERAL_TERRITORY_STATISTICAL_REPRESENTATION')

    def test_kl_ordinary_district_rejected(self):
        self.f['bindings']['geography']['area_kind'] = 'ADMINISTRATIVE_DISTRICT'
        self.refuse('GEO_SCOPE_INVALID')

    def test_all_four_jurisdictions(self):
        for code,name in [('1','Johor'),('7','Pulau Pinang'),('10','Selangor'),('14','W.P. Kuala Lumpur')]:
            with self.subTest(jurisdiction=name):
                g = self.f['bindings']['geography']
                g.update(source_code=code+'_1', area_id='MY-ADM2-'+code+'_1', jurisdiction=name,
                         area_kind='FEDERAL_TERRITORY_STATISTICAL_REPRESENTATION' if code=='14' else 'ADMINISTRATIVE_DISTRICT')
                g['identity_hash'] = source_hash({k:g[k] for k in ('area_id','source_code','jurisdiction','area_kind','catalogue_version','catalogue_hash')})
                self.assertEqual(self.call()['geography']['jurisdiction'], name)

    def test_candidate_finding_not_promoted(self):
        f = self.call()['findings'][0]
        self.assertEqual(f['review_state'], 'CANDIDATE')
        self.assertIsNone(f['authority_reference'])
        self.assertFalse(f['business_facts_verified']); self.assertFalse(f['report_admitted'])

    def test_stale_finding_rule_version(self):
        self.f['findings'][0]['rule_version'] = 'old'
        self.refuse('FINDING_VERSION_INVALID')

    def test_stale_finding_answer_reference(self):
        self.f['findings'][0]['source_answer_ids'] = ['historical-answer']
        self.refuse('FINDING_VERSION_INVALID')

    def test_stale_finding_revision(self):
        self.f['findings'][0]['assessment_revision'] = 1
        self.refuse('FINDING_VERSION_INVALID')

    def test_finding_lost_after_confirmation(self):
        self.f['findings'] = []
        self.refuse('FINDING_CONFIRMATION_MISMATCH')

    def test_verified_finding_requires_event(self):
        self.f['findings'][0]['review_state'] = 'VERIFIED'
        self.refuse('FINDING_AUTHORITY_INVALID')

    def test_verified_finding_preserves_narrow_authority(self):
        f = self.f['findings'][0]; f['review_state'] = 'VERIFIED'
        self.f['bindings']['finding_authorities'][f['id']] = {
            **self.f['bindings']['scope'], 'finding_hash':source_hash(f),
            'confirmation_id':self.f['confirmation']['id'], 'review_event_id':'SYNTHETIC-INDEPENDENT-REVIEW'}
        out = self.call()['findings'][0]
        self.assertEqual(out['review_state'], 'VERIFIED')
        self.assertFalse(out['business_facts_verified'])

    def test_contradictions_remain_unresolved(self):
        self.assertEqual(self.call()['contradictions'][0]['status'], 'UNRESOLVED')

    def test_missing_external_evidence_is_limitation(self):
        self.f['bindings']['sources'] = []
        self.assertIn('EXTERNAL_EVIDENCE_MISSING', [x['code'] for x in self.call()['unknowns']])

    def test_external_instructions_stay_untrusted(self):
        p = self.call()
        self.assertIn('publish a report', p['supporting_sources'][0]['facts'][0]['text'])
        self.assertTrue(p['supporting_sources'][0]['untrusted_text'])
        self.assertFalse(any(p['permissions'].values()))

    def test_entrepreneur_declaration_not_customer_evidence(self):
        self.assertTrue(all(x['evidence_class']=='ENTREPRENEUR_DECLARED' and x['facts_independently_verified'] is False for x in self.call()['m2_answers']))

    def test_external_source_not_authorized(self):
        self.f['bindings']['sources'][0]['authorized'] = False
        self.refuse('SOURCE_ACCESS_DENIED')

    def test_external_source_wrong_viewer(self):
        self.f['bindings']['sources'][0]['allowed_viewers'] = []
        self.refuse('SOURCE_ACCESS_DENIED')

    def test_external_source_cross_tenant(self):
        self.f['bindings']['sources'][0]['tenant_id'] = 'TENANT-B'
        self.refuse('SOURCE_SCOPE_INVALID')

    def test_source_evidence_promotion_rejected(self):
        self.f['bindings']['sources'][0]['evidence_class'] = 'VERIFIED_CUSTOMER_DEMAND'
        self.refuse('SOURCE_QUALIFICATION_INVALID')

    def test_expired_external_source(self):
        self.f['bindings']['sources'][0]['valid_until'] = '2000-01-01T00:00:00Z'
        self.refuse('SOURCE_STALE')

    def test_no_uncertainty_inferred(self):
        p = self.call()
        self.assertIsNone(p['confirmed_uncertainty'])
        self.assertIn('UNCERTAINTY_NOT_CONFIRMED', [x['code'] for x in p['unknowns']])

    def test_optional_confirmed_uncertainty(self):
        self.f['bindings']['uncertainty'] = {'id':'SYNTHETIC-U1', 'confirmation_id':self.f['confirmation']['id'],
            'actor_user_id':self.f['assessment']['owner_user_id'], 'exact_text':'My exact synthetic uncertainty.'}
        self.assertEqual(self.call()['confirmed_uncertainty']['exact_text'], 'My exact synthetic uncertainty.')

    def test_uncertainty_wrong_confirmation(self):
        self.f['bindings']['uncertainty'] = {'id':'SYNTHETIC-U1', 'confirmation_id':'old',
            'actor_user_id':self.f['assessment']['owner_user_id'], 'exact_text':'exact'}
        self.refuse('UNCERTAINTY_UNCONFIRMED')

    def test_stable_packet_hash(self):
        self.assertEqual(self.call(), self.call())

    def test_independently_recompute_packet_hash(self):
        p = self.call(); digest = p.pop('packet_hash')
        self.assertEqual(digest, source_hash(p))

    def test_authorized_source_version_changes_hash(self):
        a = self.call()['packet_hash']
        self.f['bindings']['sources'][0]['version'] = 'v2'
        self.assertNotEqual(a, self.call()['packet_hash'])

    def test_changed_concept_version_changes_hash(self):
        a = self.call()['packet_hash']
        self.f['request']['concept_version'] = 'SYNTHETIC-CONCEPT-2'
        self.f['decision']['scope']['concept_version'] = 'SYNTHETIC-CONCEPT-2'
        self.f['bindings']['current_concept_version'] = 'SYNTHETIC-CONCEPT-2'
        self.f['bindings']['concept']['version'] = 'SYNTHETIC-CONCEPT-2'
        self.assertNotEqual(a, self.call()['packet_hash'])

    def test_mapping_insertion_order_not_hash_significant(self):
        a = self.call()['packet_hash']
        self.f['answers'] = dict(reversed(list(self.f['answers'].items())))
        self.assertEqual(a, self.call()['packet_hash'])

    def test_returned_packet_is_detached(self):
        p = self.call(); p['m2_answers'][0]['value'] = 'output changed'
        self.assertNotEqual(p['m2_answers'][0]['value'], self.call()['m2_answers'][0]['value'])

    def test_history_preserved(self):
        before = deepcopy(self.f['history']); self.call()
        self.assertEqual(before, self.f['history'])

    def test_purpose_specific_contexts_available_without_execution(self):
        for purpose in ['EXPLANATION','QJ_CONTEXT','EE01_CONTEXT']:
            with self.subTest(purpose=purpose):
                self.f['request']['purpose'] = purpose
                self.f['decision']['scope']['purpose'] = purpose
                self.assertEqual(self.call()['access']['scope']['purpose'], purpose)
                self.assertFalse(any(self.call()['permissions'].values()))

    def test_missing_binding_fails_closed(self):
        del self.f['bindings']['geography']
        self.refuse('MALFORMED_SOURCE')

    def test_no_financial_amounts_inferred(self):
        p = self.call()
        self.assertNotIn('revenue', p); self.assertNotIn('profit', p)
        self.assertNotIn('price', p); self.assertNotIn('customer_preferences', p)

    def test_unauthorized_instrument(self):
        self.f['instrument']['approval_state'] = 'RESEARCH_ONLY'
        self.refuse('INSTRUMENT_UNAUTHORIZED')

    def test_invalid_answer_option(self):
        self.f['answers']['M2-01']['value_json'] = 'invented'; rebind(self.f)
        self.refuse('MALFORMED_SOURCE')

    def test_future_answer_version(self):
        self.f['answers']['M2-01']['assessment_revision'] = 3
        self.refuse('ANSWER_VERSION_INVALID')

    def test_adapter_extras_cannot_escape_into_packet(self):
        self.f['bindings']['concept']['report_admitted'] = True
        self.f['bindings']['geography']['raw_customer_answers'] = ['PRIVATE-SENTINEL']
        self.f['bindings']['uncertainty'] = {'id':'SYNTHETIC-U1', 'confirmation_id':self.f['confirmation']['id'],
            'actor_user_id':self.f['assessment']['owner_user_id'], 'exact_text':'Exact uncertainty',
            'raw_customer_answers':['PRIVATE-SENTINEL']}
        p = self.call()
        self.assertNotIn('PRIVATE-SENTINEL', json.dumps(p))
        self.assertNotIn('report_admitted', p['concept'])

    def test_nested_raw_customer_data_rejected(self):
        source = self.f['bindings']['sources'][0]
        source['facts'][0]['raw_customer_answers'] = ['PRIVATE-SENTINEL']
        source['source_hash'] = source_hash(source['facts'])
        self.refuse('SOURCE_QUALIFICATION_INVALID')

    def test_nested_concept_extras_rejected(self):
        concept = self.f['bindings']['concept']
        concept['content']['raw_customer_answers'] = ['PRIVATE-SENTINEL']
        concept['source_hash'] = source_hash(concept['content'])
        self.refuse('CONCEPT_SOURCE_INVALID')

    def test_malformed_authorization_denied_before_content(self):
        self.f['decision'] = None
        self.refuse('ACCESS_DENIED')
        self.assertEqual(self.snap.opens, 0)

    def test_missing_authorization_expiry_denied_before_content(self):
        del self.f['decision']['valid_until']
        self.refuse('ACCESS_DENIED')
        self.assertEqual(self.snap.opens, 0)

    def test_nested_source_limitation_rejected(self):
        self.f['bindings']['sources'][0]['limitations'] = [{'raw_customer_answers':['PRIVATE']}]
        self.refuse('SOURCE_QUALIFICATION_INVALID')

    def test_nontext_source_citation_rejected(self):
        self.f['bindings']['sources'][0]['citation'] = {'raw_customer_answers':['PRIVATE']}
        self.refuse('SOURCE_QUALIFICATION_INVALID')

    def test_nontext_finding_explanation_rejected(self):
        self.f['findings'][0]['explanation'] = {'raw_customer_answers':['PRIVATE']}
        self.refuse('FINDING_VERSION_INVALID')

    def test_nested_snapshot_id_rejected(self):
        self.f['bindings']['snapshot_id'] = {'raw_customer_answers':['PRIVATE']}
        self.refuse('SNAPSHOT_SCOPE_INVALID')

    def test_boolean_revision_rejected_before_content(self):
        self.refuse('INVALID_REQUEST', replace(request_for(self.f), confirmed_revision=True))
        self.assertEqual(self.snap.opens, 0)


if __name__ == '__main__': unittest.main()
