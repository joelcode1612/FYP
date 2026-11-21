"""V2.0 active path: BCB -> QG, with QJ retired and no shared-bank gate.

The directive removes QJ from the active path and forbids a replacement module.
Two consequences are tested here rather than assumed:

1. The direct path never invokes QJ, never consults the bank, and never lets a
   packet's QJ permission decide whether it may run.
2. The frozen measurement has **no production producer** once QJ is gone. That
   gap is named (``DIRECT_QG_MEASUREMENT_SOURCES``) and refused, not filled in.
   ``test_no_production_measurement_source_exists_today`` is the executable form
   of that unresolved contract decision: the only source this engine accepts is
   the versioned synthetic fixture, and the production entry is refused by code.

Every refusal test also asserts how far execution got, so a passing test proves
the guard ran rather than that it was never reached.
"""
from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest

from sitewise.project1.contracts import Measurement, WorkflowHeld, digest
from sitewise.project1.measurement_policy import (
    LAB_PRICE_RM13_POLICY, lab_authority,
)
from sitewise.project1.research import (
    DIRECT_QG_MEASUREMENT_SOURCES, ResearchWorkflow,
)

UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
EXACT_TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
              'iced latte?')
SYNTHETIC_SOURCE = 'CANONICAL_SYNTHETIC_FIXTURE'
SYNTHETIC_REF = 'tests/m2_bcb/lab_measurement_v0_1.py::canonical_spec'


def _baseline():
    """Load the P1 lab baseline by path, independent of test package layout."""
    path = (Path(__file__).resolve().parents[1] / 'm2_bcb'
            / 'lab_measurement_v0_1.py')
    spec = importlib.util.spec_from_file_location('lab_measurement_v0_1_direct', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def packet(*, status='CURRENT_CONFIRMED', uncertainty=True, permissions=None,
           exact_text=EXACT_TEXT, geography=None):
    value = {
        'schema_version': 'business-context-package/1.1',
        'confirmation': {'status': status, 'id': CONFIRMATION_ID, 'revision': 1},
        'confirmed_uncertainty': ({
            'id': UNCERTAINTY_ID,
            'confirmation_id': CONFIRMATION_ID,
            'actor_user_id': 'c3d4e5f6-0000-4000-8000-000000000000',
            'exact_text': exact_text,
        } if uncertainty else None),
        'geography': geography,
        'permissions': ({'qj_execution': False} if permissions is None else permissions),
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def frozen_measurement():
    """The one complete Measurement that exists in this tree, test-only."""
    return _baseline().canonical_spec().to_contract([UNCERTAINTY_ID], UNCERTAINTY_ID)


def candidate_question(measurement: Measurement) -> str:
    """A question that quotes every frozen field verbatim.

    ``validate_draft`` requires the stimulus, population and timeframe to appear
    exactly, so the question is deliberately repetitive: the point of the case is
    the contract, not the prose.
    """
    return (f'{measurement.stimulus} Asked of {measurement.population} '
            f'Timing: {measurement.timeframe} Would you describe this offer as acceptable?')


class _ForbiddenBank:
    """Fails the test if the direct path touches a shared bank at all."""

    def lookup(self, *a, **k):
        raise AssertionError('direct QG path must not consult the question bank')

    def verify_receipt(self, *a, **k):
        raise AssertionError('direct QG path must not verify a bank receipt')


def workflow(*, runner=None, authority=None, packet_value=None, bank=None):
    measurement = frozen_measurement()
    calls = []

    def default_runner(stage, payload, output_type):
        calls.append(stage)
        return {'decision': 'DRAFT',
                'question': candidate_question(measurement),
                'measurement': measurement.model_dump(),
                'justification': 'Synthetic direct-path candidate only.'}

    def recording(stage, payload, output_type):
        calls.append(stage)
        return runner(stage, payload, output_type)

    value = packet() if packet_value is None else packet_value
    w = ResearchWorkflow(SimpleNamespace(get_context=lambda _: copy.deepcopy(value)),
                         authority or lab_authority(LAB_PRICE_RM13_POLICY),
                         bank or _ForbiddenBank(),
                         recording if runner else default_runner)
    return w, calls, measurement


# ---------------------------------------------------------------------------
# The happy path, and what it refuses to claim
# ---------------------------------------------------------------------------
def test_direct_path_drafts_one_candidate_without_qj():
    w, calls, measurement = workflow()
    result = w.execute_direct_qg(None, frozen_measurement=measurement,
                                 measurement_source=SYNTHETIC_SOURCE,
                                 measurement_source_ref=SYNTHETIC_REF)
    assert calls == ['QG'], 'QJ must not be invoked on the active path'
    assert result['qj'] is None
    assert result['qg']['decision'] == 'DRAFT'
    assert result['qg']['question'].startswith(measurement.stimulus)


def test_direct_path_records_the_bank_as_not_consulted_not_as_unchecked():
    """`not_checked` would read as a skipped step; this is a contract change."""
    w, _, measurement = workflow()
    result = w.execute_direct_qg(None, frozen_measurement=measurement,
                                 measurement_source=SYNTHETIC_SOURCE,
                                 measurement_source_ref=SYNTHETIC_REF)
    assert result['bank'] == 'NOT_CONSULTED_DIRECT_QG'
    assert result['bank'] != 'not_checked'


def test_direct_path_grants_no_authority_of_any_kind():
    w, _, measurement = workflow()
    result = w.execute_direct_qg(None, frozen_measurement=measurement,
                                 measurement_source=SYNTHETIC_SOURCE,
                                 measurement_source_ref=SYNTHETIC_REF)
    assert result['candidate_authority'] == 'ENTREPRENEUR_REVIEW_ONLY'
    for flag in ('scientific_acceptance', 'owner_authorization',
                 'publication_authorized', 'fielding_authorized',
                 'report_release_authorized'):
        assert result[flag] is False
    assert result['measurement_validation']['production_eligible'] is False
    assert result['measurement_validation']['status'] == 'TEST_SCOPED_VALID'


def test_direct_path_carries_the_resolved_version_and_its_basis():
    w, _, measurement = workflow()
    result = w.execute_direct_qg(None, frozen_measurement=measurement,
                                 measurement_source=SYNTHETIC_SOURCE,
                                 measurement_source_ref=SYNTHETIC_REF)
    assert result['admission']['uncertainty_version'] == UNCERTAINTY_ID
    assert result['admission']['uncertainty_version_basis'] == 'confirmed_uncertainty.id'
    assert result['source_fingerprint']


# ---------------------------------------------------------------------------
# CP-02: an entrepreneur-originated objective needs no BDJ finding
# ---------------------------------------------------------------------------
def test_zero_bdj_finding_entrepreneur_objective_reaches_qg():
    """No BDJ finding is required: the objective itself is the input.

    The BDJ engine is not composed into this path at all, so there is nothing
    that could require a finding. The objective is passed through to QG and its
    id is recorded on the result so a review can link candidate to objective.
    """
    seen = {}

    def runner(stage, payload, output_type):
        seen['payload'] = payload
        measurement = frozen_measurement()
        return {'decision': 'DRAFT', 'question': candidate_question(measurement),
                'measurement': measurement.model_dump(),
                'justification': 'Synthetic objective-driven candidate only.'}

    w, calls, measurement = workflow(runner=runner)
    objective = {'objective_id': 'SYN-OBJ-1', 'origin': 'ENTREPRENEUR',
                 'text': 'Is RM13 acceptable for the 12 oz takeaway iced latte?'}
    result = w.execute_direct_qg(None, frozen_measurement=measurement,
                                 measurement_source=SYNTHETIC_SOURCE,
                                 measurement_source_ref=SYNTHETIC_REF,
                                 objective=objective)
    assert calls == ['QG']
    assert seen['payload']['research_objective'] == objective
    assert result['objective_id'] == 'SYN-OBJ-1'
    assert result['qg']['decision'] == 'DRAFT'


def test_no_objective_still_drafts_and_records_the_absence():
    w, _, measurement = workflow()
    result = w.execute_direct_qg(None, frozen_measurement=measurement,
                                 measurement_source=SYNTHETIC_SOURCE,
                                 measurement_source_ref=SYNTHETIC_REF)
    assert result['objective_id'] is None


# ---------------------------------------------------------------------------
# Context gates run before any model call
# ---------------------------------------------------------------------------
@pytest.mark.parametrize('value,code', [
    (dict(status='SUPERSEDED'), 'BCB_CONFIRMATION_REQUIRED'),
    (dict(uncertainty=False), 'UNCERTAINTY_NOT_CONFIRMED'),
])
def test_unconfirmed_context_stops_before_the_model(value, code):
    w, calls, measurement = workflow(packet_value=packet(**value))
    with pytest.raises(WorkflowHeld, match=code):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == [], 'no model call may precede a context refusal'


def test_restricted_m2_membership_stops_the_direct_path():
    value = packet()
    value['m2_answers'].append({'answer_revision_id': 'SYN-A2', 'item_key': 'M2-11'})
    value['packet_hash'] = digest({k: v for k, v in value.items() if k != 'packet_hash'})
    w, calls, measurement = workflow(packet_value=value)
    with pytest.raises(WorkflowHeld, match='BCB_RESTRICTED_ITEM_MEMBERSHIP'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == []


def test_a_tampered_packet_fails_its_fingerprint():
    value = packet()
    value['confirmed_uncertainty']['exact_text'] = 'Something the owner never confirmed.'
    w, calls, measurement = workflow(packet_value=value)
    with pytest.raises(WorkflowHeld, match='BCB_PACKET_FINGERPRINT_INVALID'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == []


# ---------------------------------------------------------------------------
# CP-01: the direct path does not inherit QJ's permission
# ---------------------------------------------------------------------------
def test_a_packet_that_asserts_qj_authority_is_refused_by_the_legacy_path_only():
    """QJ permission is not a precondition of a path that does not run QJ.

    Both halves matter. The legacy admission still refuses a packet granting
    itself QJ authority, and the direct path runs on that same packet — which is
    what "QJ is off the active path" has to mean in code.
    """
    value = packet(permissions={'qj_execution': True})
    with pytest.raises(WorkflowHeld, match='F01_PACKET_ASSERTS_QJ_AUTHORITY'):
        lab_authority(LAB_PRICE_RM13_POLICY).admit_qj(value)
    w, calls, measurement = workflow(packet_value=value)
    result = w.execute_direct_qg(None, frozen_measurement=measurement,
                                 measurement_source=SYNTHETIC_SOURCE,
                                 measurement_source_ref=SYNTHETIC_REF)
    assert calls == ['QG'] and result['qg']['decision'] == 'DRAFT'


def test_geography_is_still_refused_on_the_direct_path():
    w, calls, measurement = workflow(packet_value=packet(geography={'locality': 'x'}))
    with pytest.raises(WorkflowHeld, match='F02_GEO_NOT_EXCLUDED'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == []


# ---------------------------------------------------------------------------
# The unresolved dependency: no production measurement source exists
# ---------------------------------------------------------------------------
def test_the_only_accepted_measurement_source_is_the_synthetic_fixture():
    assert DIRECT_QG_MEASUREMENT_SOURCES[SYNTHETIC_SOURCE]['test_only'] is True
    assert DIRECT_QG_MEASUREMENT_SOURCES[SYNTHETIC_SOURCE]['requires_ref'] is True
    assert [name for name, spec in DIRECT_QG_MEASUREMENT_SOURCES.items()
            if spec['test_only']] == [SYNTHETIC_SOURCE]


def test_no_production_measurement_source_exists_today():
    """The named gap, refused by code rather than filled in.

    Removing QJ removed the only component that produced a Measurement. The
    BCB packet carries the uncertainty as free text and the concept as a single
    ``description`` string, so construct, population, timeframe, response
    coding, routing, denominator and limitations have no persisted, confirmed
    source. Accepting a production claim here would be accepting an unevidenced
    assertion, so the entry is refused until an authorised spec exists.
    """
    assert DIRECT_QG_MEASUREMENT_SOURCES['AUTHORISED_PRODUCTION_SPEC']['test_only'] is False
    w, calls, measurement = workflow()
    with pytest.raises(WorkflowHeld, match='QG_MEASUREMENT_SOURCE_NOT_AVAILABLE'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source='AUTHORISED_PRODUCTION_SPEC',
                            measurement_source_ref='OWNER-SPEC-1')
    assert calls == []


def test_an_undeclared_measurement_source_is_refused():
    w, calls, measurement = workflow()
    with pytest.raises(WorkflowHeld, match='QG_MEASUREMENT_SOURCE_UNRECOGNIZED'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source='MODEL_OUTPUT')
    assert calls == []


def test_a_measurement_source_without_a_reference_is_refused():
    w, calls, measurement = workflow()
    with pytest.raises(WorkflowHeld, match='QG_MEASUREMENT_SOURCE_REF_REQUIRED'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE)
    assert calls == []


@pytest.mark.parametrize('value', [None, {}, 'a measurement', 0])
def test_a_non_contract_measurement_is_refused(value):
    w, calls, _ = workflow()
    with pytest.raises(WorkflowHeld, match='QG_FROZEN_MEASUREMENT_REQUIRED'):
        w.execute_direct_qg(None, frozen_measurement=value,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == []


def test_a_measurement_bound_to_another_uncertainty_is_refused():
    other = frozen_measurement().model_copy(update={'uncertainty_version': 'other-id'})
    w, calls, _ = workflow()
    with pytest.raises(WorkflowHeld, match='MEASUREMENT_SOURCE_MISMATCH'):
        w.execute_direct_qg(None, frozen_measurement=other,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == []


# ---------------------------------------------------------------------------
# The QG output contract survives the path change
# ---------------------------------------------------------------------------
def test_price_drift_is_refused_on_the_direct_path():
    """D-01 retained: RM13 must not become RM12 just because QJ is gone.

    The frozen stimulus is quoted verbatim and a *second*, different price is
    appended. Replacing the price inside the stimulus would trip the wording
    check first, and the amount guard would never be exercised.
    """
    measurement = frozen_measurement()

    def runner(stage, payload, output_type):
        return {'decision': 'DRAFT',
                'question': candidate_question(measurement) + ' Would you pay RM12 instead?',
                'measurement': measurement.model_dump(),
                'justification': 'Synthetic price drift only.'}

    w, calls, _ = workflow(runner=runner)
    with pytest.raises(WorkflowHeld, match='QG_UNSOURCED_AMOUNT'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == ['QG']


def test_the_model_cannot_rewrite_the_frozen_measurement():
    measurement = frozen_measurement()
    changed = measurement.model_copy(update={'stimulus': 'a 16 oz takeaway iced latte at RM9'})

    def runner(stage, payload, output_type):
        return {'decision': 'DRAFT', 'question': candidate_question(measurement),
                'measurement': changed.model_dump(),
                'justification': 'Synthetic measurement drift only.'}

    w, calls, _ = workflow(runner=runner)
    with pytest.raises(WorkflowHeld, match='QG_FROZEN_MEASUREMENT_CHANGED'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == ['QG']


def test_abstention_yields_no_candidate():
    measurement = frozen_measurement()

    def runner(stage, payload, output_type):
        return {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': '',
                'measurement': measurement.model_dump(),
                'justification': 'No neutral single-construct wording preserves the contract.'}

    w, calls, _ = workflow(runner=runner)
    result = w.execute_direct_qg(None, frozen_measurement=measurement,
                                 measurement_source=SYNTHETIC_SOURCE,
                                 measurement_source_ref=SYNTHETIC_REF)
    assert result['qg']['decision'] == 'ABSTAIN_NEEDS_REVIEW'
    assert result['qg']['question'] == ''
    assert result['candidate_authority'] == 'ENTREPRENEUR_REVIEW_ONLY'
    assert result['fielding_authorized'] is False


def test_an_abstention_that_smuggles_a_question_is_refused():
    measurement = frozen_measurement()

    def runner(stage, payload, output_type):
        return {'decision': 'ABSTAIN_NEEDS_REVIEW',
                'question': candidate_question(measurement),
                'measurement': measurement.model_dump(),
                'justification': 'Synthetic abstention with a question.'}

    w, calls, _ = workflow(runner=runner)
    with pytest.raises(WorkflowHeld, match='QG_ABSTENTION_CONTAINS_QUESTION'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == ['QG']


def test_a_question_that_drops_the_frozen_population_is_refused():
    measurement = frozen_measurement()

    def runner(stage, payload, output_type):
        return {'decision': 'DRAFT',
                'question': measurement.stimulus + ' Would you accept it?',
                'measurement': measurement.model_dump(),
                'justification': 'Synthetic wording contract breach.'}

    w, calls, _ = workflow(runner=runner)
    with pytest.raises(WorkflowHeld, match='QG_WORDING_CONTRACT_MISMATCH'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == ['QG']


# ---------------------------------------------------------------------------
# F-02 still applies: the receipt is verified, not trusted
# ---------------------------------------------------------------------------
def test_a_no_op_authority_cannot_reach_the_direct_path():
    class NoOp:
        measurement_policy_version = 'MEASUREMENT-LAB-POLICY-0.1'

        def resolve_version(self, packet):
            return {'uncertainty_version': UNCERTAINTY_ID,
                    'policy_version': 'MEASUREMENT-LAB-POLICY-0.1'}

        def require_current(self, *a):
            pass

        def validate_measurement(self, *a):
            return None

    w, calls, measurement = workflow(authority=NoOp())
    with pytest.raises(WorkflowHeld, match='MEASUREMENT_RECEIPT_MISSING'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == [], 'a candidate must not be drafted on an unverified receipt'


def test_an_authority_without_version_resolution_is_refused():
    class LegacyOnly:
        measurement_policy_version = 'MEASUREMENT-LAB-POLICY-0.1'

        def admit_qj(self, packet):
            return {'uncertainty_version': UNCERTAINTY_ID}

    w, calls, measurement = workflow(authority=LegacyOnly())
    with pytest.raises(WorkflowHeld, match='QG_MEASUREMENT_AUTHORITY_UNVERIFIED'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == []


def test_a_withdrawn_context_after_drafting_stops_the_result():
    """The candidate is withdrawn rather than returned against a dead context."""
    w, calls, measurement = workflow()
    w.authority.require_current = lambda *a: (_ for _ in ()).throw(
        WorkflowHeld('F01_CONTEXT_CHANGED_SINCE_ADMISSION'))
    with pytest.raises(WorkflowHeld, match='F01_CONTEXT_CHANGED_SINCE_ADMISSION'):
        w.execute_direct_qg(None, frozen_measurement=measurement,
                            measurement_source=SYNTHETIC_SOURCE,
                            measurement_source_ref=SYNTHETIC_REF)
    assert calls == ['QG']


# ---------------------------------------------------------------------------
# CP-01: historical QJ records stay readable through the retained path
# ---------------------------------------------------------------------------
def test_the_legacy_path_is_retained_and_still_returns_qj_records():
    """Retiring QJ from the active path is not deleting its history."""
    class Bank:
        def lookup(self, *a):
            raise AssertionError('a HOLD route must not consult the bank')

        def verify_receipt(self, *a):
            raise AssertionError('a HOLD route must not verify a bank receipt')

    def runner(stage, payload, output_type):
        assert stage == 'QJ'
        # `measurement` is nullable but not optional in the contract, so a HOLD
        # record must state the absence explicitly rather than omit the key.
        return {'route': 'HOLD', 'justification': 'Synthetic historical record.',
                'measurement': None}

    w = ResearchWorkflow(SimpleNamespace(get_context=lambda _: copy.deepcopy(packet())),
                         lab_authority(LAB_PRICE_RM13_POLICY), Bank(), runner)
    result = w.execute(None)
    assert result['qj']['route'] == 'HOLD'
    assert result['qg'] is None
