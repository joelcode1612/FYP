"""Exhaustive classification over the four persisted outcome dimensions.

Pure Python: no database, no network, no provider. The database side of the same
contract (generated column, single-value CHECK, refusals) is proven against the
isolated clone by scripts/cp04a_clone_security_verify.py.

The engine verdicts used here are built by `BDJEngine._result()` itself rather
than hand-written dicts, so the test cannot pass against a shape the engine does
not actually produce.
"""
from pathlib import Path
from uuid import uuid4

import pytest

from sitewise.project1.bdj import BDJEngine
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.result_contracts import (
    EXECUTION_OUTCOMES, FINDING_AUTHORITIES, REVIEW_OUTCOMES, VALIDATION_STATUSES,
    classify, derived_admission)

UNCLASSIFIED = 'RESULT_OUTCOME_UNCLASSIFIED'
DIGEST = 'a' * 64
MIGRATION = (Path(__file__).resolve().parents[2]
             / 'migrations' / 'project1_ai' / '20261117_03_bdj_result_persistence.sql')

PACKET = {'assessment_id': str(uuid4()), 'assessment_revision': 3,
          'source_fingerprint': 'f' * 64}
FINDING = {'rule_id': 'BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE', 'kind': 'UNSUPPORTED_ASSERTION',
           'source_refs': [{'item_key': 'M2-04', 'answer_revision_id': 'r1',
                            'item_version_id': 'v1', 'quote': 'We are takeaway-only.'}],
           'observed_condition': 'Synthetic.', 'counterargument': 'Synthetic.',
           'justification': 'Synthetic.', 'next_action': 'Synthetic.'}


def engine_result(outcome: str, findings=()) -> dict:
    """A real BDJEngine.review() return value, built by the engine's own factory."""
    return BDJEngine._result(PACKET, [], list(findings), outcome)


def assert_unclassified(callable_, *args, **kwargs) -> None:
    with pytest.raises(WorkflowHeld) as raised:
        callable_(*args, **kwargs)
    assert str(raised.value) == UNCLASSIFIED


# ---------------------------------------------------------------------------
# The full cartesian product: D1 (3) x D3 (3 + NULL) = 12 pairs.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize('execution_outcome', EXECUTION_OUTCOMES)
@pytest.mark.parametrize('review_outcome', REVIEW_OUTCOMES + (None,))
def test_every_dimension_pair_is_classified_or_refused(execution_outcome, review_outcome):
    review_result = None if review_outcome is None else engine_result(review_outcome)

    # Only a returned response can be reviewed; a review cannot exist without one.
    if review_outcome is None:
        if execution_outcome == 'returned':
            assert_unclassified(classify, None, execution_outcome)
            return
        assert classify(None, execution_outcome) == {
            'execution_outcome': execution_outcome,
            'review_outcome': None,
            'output_digest': None,
            'result_payload': None,
            'finding_authority': 'candidate_only',
            'finding_count': 0,
        }
        return

    if execution_outcome != 'returned':
        assert_unclassified(classify, review_result, execution_outcome,
                            output_digest=DIGEST)
        return

    # C2: only a validated result stores a payload, and 'rejected' is not valid.
    expected_payload = None if review_outcome == 'rejected' else {'findings': []}
    assert classify(review_result, 'returned', output_digest=DIGEST) == {
        'execution_outcome': 'returned',
        'review_outcome': review_outcome,
        'output_digest': DIGEST,
        'result_payload': expected_payload,
        'finding_authority': 'candidate_only',
        'finding_count': 0,
    }


def test_all_twelve_pairs_accounted_for():
    """The product is complete: 3 x 4, and each cell is one of two outcomes."""
    assert len(EXECUTION_OUTCOMES) * (len(REVIEW_OUTCOMES) + 1) == 12
    reachable = {(o, r) for o in EXECUTION_OUTCOMES for r in REVIEW_OUTCOMES + (None,)}
    assert len(reachable) == 12


# ---------------------------------------------------------------------------
# The engine's four verdicts, as the spec's table says.
# ---------------------------------------------------------------------------
def test_reviewed_carries_payload_and_findings():
    row = classify(engine_result('reviewed', [FINDING, FINDING]), 'returned',
                   output_digest=DIGEST)
    assert row['review_outcome'] == 'reviewed'
    assert row['result_payload'] == {'findings': [FINDING, FINDING]}
    assert row['finding_count'] == 2


def test_reviewed_with_no_findings_stores_the_empty_object():
    """Not NULL: 'reviewed with nothing to report' is a result, not a failure."""
    row = classify(engine_result('reviewed', []), 'returned', output_digest=DIGEST)
    assert row['review_outcome'] == 'reviewed'
    assert row['result_payload'] == {'findings': []}
    assert row['finding_count'] == 0


def test_rejected_drops_the_payload():
    row = classify(engine_result('rejected', []), 'returned', output_digest=DIGEST)
    assert row['review_outcome'] == 'rejected'
    assert row['result_payload'] is None
    assert row['finding_count'] == 0


def test_stale_stores_whatever_the_engine_returned():
    row = classify(engine_result('stale', []), 'returned', output_digest=DIGEST)
    assert row['review_outcome'] == 'stale'
    assert row['result_payload'] == {'findings': []}


def test_held_is_unrepresentable_because_it_has_no_attempt():
    """bdj.py:70-73 returns 'held' before ledger.reserve(); there is no FK target."""
    assert engine_result('held')['outcome'] == 'held'
    assert_unclassified(classify, engine_result('held'), 'returned', output_digest=DIGEST)
    assert 'held' not in REVIEW_OUTCOMES


def test_every_engine_verdict_is_covered_by_the_matrix():
    assert set(REVIEW_OUTCOMES) | {'held'} == {'reviewed', 'rejected', 'stale', 'held'}


# ---------------------------------------------------------------------------
# Fail-closed edges: nothing defaults to success, nothing is translated.
# ---------------------------------------------------------------------------
def test_returned_without_a_digest_is_refused():
    assert_unclassified(classify, engine_result('reviewed', []), 'returned')


def test_failure_outcome_carrying_a_digest_is_refused():
    """C1: a digest exists only for a returned response."""
    assert_unclassified(classify, None, 'unknown_outcome', output_digest=DIGEST)


def test_unknown_transport_outcome_is_refused():
    assert_unclassified(classify, None, 'TIMED_OUT')
    assert_unclassified(classify, None, 'RETURNED')
    assert_unclassified(classify, None, '')


def test_unknown_review_outcome_is_refused():
    assert_unclassified(classify, engine_result('ADMITTED'), 'returned',
                        output_digest=DIGEST)


def test_result_claiming_verified_authority_is_refused():
    """D4: a cloud result may never claim authority, in any spelling."""
    claimed = engine_result('reviewed', [FINDING]) | {'finding_authority': 'VERIFIED'}
    assert_unclassified(classify, claimed, 'returned', output_digest=DIGEST)
    lower = engine_result('reviewed', [FINDING]) | {'finding_authority': 'candidate_only'}
    assert_unclassified(classify, lower, 'returned', output_digest=DIGEST)


def test_review_result_missing_contract_keys_is_refused():
    assert_unclassified(classify, {'outcome': 'reviewed'}, 'returned',
                        output_digest=DIGEST)
    assert_unclassified(classify, {'findings': []}, 'returned', output_digest=DIGEST)


def test_rejected_verdict_carrying_findings_is_refused():
    """The engine drops findings when validation fails; a non-empty list is not it."""
    assert_unclassified(classify, engine_result('rejected', [FINDING]), 'returned',
                        output_digest=DIGEST)


def test_no_uppercase_or_withdrawn_value_survives_in_the_tuples():
    for value in EXECUTION_OUTCOMES + REVIEW_OUTCOMES + VALIDATION_STATUSES + FINDING_AUTHORITIES:
        assert value == value.lower()
    assert 'TIMED_OUT' not in EXECUTION_OUTCOMES
    assert 'unknown_outcome' in EXECUTION_OUTCOMES
    assert FINDING_AUTHORITIES == ('candidate_only',)


# ---------------------------------------------------------------------------
# derived_admission: presentation only, never stored.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize('count,expected', [
    (0, 'no_admissible_finding'), (1, 'admitted'), (2, 'admitted'), (20, 'admitted')])
def test_derived_admission_splits_reviewed_on_finding_count(count, expected):
    row = {'review_outcome': 'reviewed', 'finding_count': count}
    assert derived_admission(row) == expected


def test_no_admissible_finding_requires_reviewed_and_zero():
    assert derived_admission({'review_outcome': 'reviewed', 'finding_count': 0}) == \
        'no_admissible_finding'
    # Zero findings is not a licence to claim 'no_admissible_finding' for a
    # result that never reached a review.
    assert derived_admission({'review_outcome': None, 'finding_count': 0}) == 'not_reviewed'
    assert derived_admission({'review_outcome': 'rejected', 'finding_count': 0}) == 'rejected'
    assert derived_admission({'review_outcome': 'stale', 'finding_count': 0}) == 'stale'


def test_derived_admission_reads_held_only_from_an_unpersisted_engine_result():
    assert derived_admission(engine_result('held')) == 'held'
    assert 'review_outcome' not in engine_result('held')


def test_derived_admission_refuses_unknown_or_incomplete_rows():
    assert_unclassified(derived_admission, {'review_outcome': 'held', 'finding_count': 0})
    assert_unclassified(derived_admission, {'review_outcome': 'reviewed'})
    assert_unclassified(derived_admission, {'review_outcome': 'reviewed', 'finding_count': -1})
    assert_unclassified(derived_admission, {'review_outcome': 'ADMITTED', 'finding_count': 1})
    assert_unclassified(derived_admission, {})


def test_derived_admission_returns_only_the_closed_label_set():
    """Six labels, and 'held' is reachable only from an unpersisted engine result.

    'rejected' and 'stale' are spelled the same as review_outcome values on
    purpose: the label names the same fact. The label itself is never stored.
    """
    labels = {'admitted', 'no_admissible_finding', 'rejected', 'held', 'stale',
              'not_reviewed'}
    produced = {derived_admission({'review_outcome': 'reviewed', 'finding_count': 0}),
                derived_admission({'review_outcome': 'reviewed', 'finding_count': 1}),
                derived_admission({'review_outcome': 'rejected', 'finding_count': 0}),
                derived_admission({'review_outcome': 'stale', 'finding_count': 0}),
                derived_admission({'review_outcome': None, 'finding_count': 0}),
                derived_admission(engine_result('held'))}
    assert produced == labels


# ---------------------------------------------------------------------------
# Drift guard: the Python tuples and the SQL CHECK lists must name the same set.
# ---------------------------------------------------------------------------
def test_tuples_match_the_migration():
    sql = MIGRATION.read_text(encoding='utf-8')
    for value in EXECUTION_OUTCOMES + REVIEW_OUTCOMES + VALIDATION_STATUSES + FINDING_AUTHORITIES:
        assert f"'{value}'" in sql, value
