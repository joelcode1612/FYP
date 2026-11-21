"""Policy mechanism and immutable-pin checks; test values are not adoption."""
from datetime import datetime,timedelta,timezone
from copy import deepcopy
import pytest
import bootstrap
from harness import fixture
from sitewise.repositories.m2_context_bindings import confirmation_horizon
from sitewise.services.business_context_v1 import ContextRefused
from sitewise.domain.m2_provenance import confirmation_pins,pins_match

def test_proposed_one_day_test_basis_is_exact_and_not_a_silent_default():
    created=datetime(2026,11,19,4,0,tzinfo=timezone(timedelta(hours=8)))
    result=confirmation_horizon({'created_at':created},timedelta(days=1))
    assert datetime.fromisoformat(result)==created+timedelta(days=1)
    with pytest.raises(ContextRefused,match='VALIDITY_BASIS_UNAUTHORIZED'):
        confirmation_horizon({'created_at':created},None)

def test_invalid_or_naive_validity_sources_are_refused():
    for duration in (timedelta(0),timedelta(days=-1)):
        with pytest.raises(ContextRefused,match='VALIDITY_BASIS_UNAUTHORIZED'):
            confirmation_horizon({'created_at':datetime.now(timezone.utc)},duration)
    with pytest.raises(Exception,match='BCB_CONFIRMATION_TIMESTAMP_UNVERIFIED'):
        confirmation_horizon({'created_at':datetime(2026,11,19)},timedelta(days=1))

def test_post_confirmation_cloud_candidates_cannot_be_inserted_into_old_pinned_findings():
    f=fixture();evaluation={'id':'TEST-EVALUATION'};review={'id':'TEST-REVIEW'}
    pins=confirmation_pins('TEST-RULES',evaluation,review,f['findings'],f['items'])
    assert pins_match(pins,evaluation,review,f['findings'],f['items'])
    extra=deepcopy(f['findings'][0]) if f['findings'] else dict(
        id='TEST-POST-CONFIRMATION-CANDIDATE',assessment_id=f['assessment']['id'],
        assessment_revision=2,rule_id='TEST-CANDIDATE',rule_version='TEST-ONLY',
        source_answer_ids=[f['answers']['M2-04']['id']],issue_type='INFORMATION_GAP',
        explanation='Candidate observation.',not_proven='No business fact verified.',
        next_action='Review only.',review_state='CANDIDATE')
    assert not pins_match(pins,evaluation,review,[*f['findings'],extra],f['items'])
