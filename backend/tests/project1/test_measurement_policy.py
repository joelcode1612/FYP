"""F-01 and F-02: the uncertainty-version rule and the real measurement validator.

F-01 root cause: ``Measurement.uncertainty_version`` was a required field whose
value nothing supplied. The QJ prompt never named it, so a compliant model could
not produce it and the survey branch was reachable only by guessing.

F-02 root cause: every ``authority.validate_measurement`` was ``lambda *_: None``,
so "validated" meant nothing and a QG draft could follow an unchecked measurement.

Each test below pins one half of the repair. Where a test asserts that a refusal
does *not* happen, it also asserts that the refusal was reachable — otherwise a
passing test would only prove the guard was never exercised.
"""
from __future__ import annotations

import copy

import pytest

from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.measurement_policy import (
    verify_validation_receipt,
    LAB_PRICE_RM13_POLICY, QJ_INVARIANTS_POLICY, MeasurementAuthority,
    composite_uncertainty_version, lab_authority, resolve_uncertainty_version,
)

UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
EXACT_TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
              'iced latte?')


def packet(*, uncertainty_id=UNCERTAINTY_ID, confirmation_id=CONFIRMATION_ID,
           revision=1, exact_text=EXACT_TEXT, status='CURRENT_CONFIRMED',
           geography=None, permissions=None, confirmation_id_on_uncertainty=None):
    value = {
        'schema_version': 'business-context-package/1.1',
        'confirmation': {'status': status, 'id': confirmation_id, 'revision': revision},
        'confirmed_uncertainty': {
            'id': uncertainty_id,
            'confirmation_id': (confirmation_id if confirmation_id_on_uncertainty is None
                                else confirmation_id_on_uncertainty),
            'actor_user_id': 'c3d4e5f6-0000-4000-8000-000000000000',
            'exact_text': exact_text},
        'geography': geography,
        'permissions': ({'qj_execution': False} if permissions is None else permissions),
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def rehash(value: dict) -> dict:
    value = copy.deepcopy(value)
    value.pop('packet_hash', None)
    value['packet_hash'] = digest(value)
    return value


def measurement(**overrides):
    """A measurement the invariant document admits."""
    value = dict(uncertainty_version=UNCERTAINTY_ID, construct='stated price acceptability',
                 population='eligible screened respondents',
                 timeframe='at presentation of the hypothetical offer',
                 stimulus='12 oz takeaway iced latte at RM13',
                 response_options=['Acceptable', 'Not acceptable', 'Unsure'],
                 response_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE', 'UNSURE'],
                 routing={'ACCEPTABLE': 'RECORD', 'NOT_ACCEPTABLE': 'RECORD',
                          'UNSURE': 'RECORD'},
                 denominator='ACCEPTABLE and NOT_ACCEPTABLE respondents; UNSURE apart',
                 source_refs=[UNCERTAINTY_ID],
                 limitations='Stated acceptability of one hypothetical price; not a '
                             'maximum willingness-to-pay and not a purchase forecast.')
    value.update(overrides)
    return value


def pinned_measurement(**overrides):
    """A measurement the pinned lab instrument admits, exactly."""
    value = dict(
        uncertainty_version=UNCERTAINTY_ID,
        construct=('Hypothetical stated acceptability of RM13 for an exactly described '
                   '12 oz takeaway iced latte'),
        population=('Synthetic eligible respondents flagged synthetic_eligibility=true in '
                    'a disposable test cluster; no real sampling frame is authorized'),
        timeframe=('Judgment at the moment the respondent views the hypothetical offer; '
                   'no future purchase window is inferred'),
        stimulus='Hypothetical offer: a 12 oz takeaway iced latte priced at RM13.',
        response_options=['Acceptable', 'Not acceptable', "Don't know",
                          'Prefer not to answer'],
        response_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED'],
        routing={code: 'END' for code in
                 ('ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED')},
        denominator=('Count of eligible in-scope respondents answering ACCEPTABLE or '
                     'NOT_ACCEPTABLE; DONT_KNOW, REFUSED, SKIPPED, NOT_APPLICABLE, MISSING '
                     'and INVALID excluded and reported separately'),
        source_refs=[UNCERTAINTY_ID],
        limitations=('Sample-descriptive only: X of Y eligible respondents described the '
                     'fixed RM13 offer as acceptable. Not a demand, willingness-to-pay, '
                     'sales, profitability or GEO estimate.'))
    value.update(overrides)
    return value


def held(code: str, function) -> None:
    with pytest.raises(WorkflowHeld) as caught:
        function()
    assert str(caught.value) == code


# ---------------------------------------------------------------------------
# F-01 — the version label is server-authored, unique and immutable
# ---------------------------------------------------------------------------
def test_f01_resolves_the_confirmed_uncertainty_id_as_the_version():
    resolved = resolve_uncertainty_version(packet())
    assert resolved.value == UNCERTAINTY_ID
    assert resolved.basis == 'confirmed_uncertainty.id'
    assert resolved.confirmation_id == CONFIRMATION_ID
    assert resolved.assessment_revision == 1
    assert resolved.packet_hash == packet()['packet_hash']


def test_f01_refuses_a_confirmation_that_is_not_current():
    held('F01_CONFIRMATION_NOT_CURRENT',
         lambda: resolve_uncertainty_version(packet(status='REVOKED')))


def test_f01_refuses_a_packet_without_a_confirmation_id():
    value = packet()
    del value['confirmation']['id']
    held('F01_UNCERTAINTY_IDENTITY_INCOMPLETE',
         lambda: resolve_uncertainty_version(rehash(value)))


def test_f01_refuses_a_packet_without_a_revision():
    value = packet()
    del value['confirmation']['revision']
    held('F01_UNCERTAINTY_IDENTITY_INCOMPLETE',
         lambda: resolve_uncertainty_version(rehash(value)))


def test_f01_refuses_an_uncertainty_bound_to_another_confirmation():
    held('F01_UNCERTAINTY_CONFIRMATION_MISMATCH',
         lambda: resolve_uncertainty_version(
             packet(confirmation_id_on_uncertainty='other-confirmation')))


def test_f01_refuses_blank_uncertainty_text():
    held('F01_UNCERTAINTY_TEXT_MISSING',
         lambda: resolve_uncertainty_version(packet(exact_text='   ')))


def test_f01_refuses_a_non_integer_revision():
    held('F01_UNCERTAINTY_IDENTITY_INCOMPLETE',
         lambda: resolve_uncertainty_version(packet(revision='one')))


def test_f01_refuses_a_negative_revision():
    held('F01_UNCERTAINTY_IDENTITY_INCOMPLETE',
         lambda: resolve_uncertainty_version(packet(revision=-1)))


def test_f01_a_new_revision_with_a_new_id_is_a_new_version():
    first = resolve_uncertainty_version(packet())
    second = resolve_uncertainty_version(
        packet(uncertainty_id='d4e5f6a7-0000-4000-8000-000000000000',
               confirmation_id='e5f6a7b8-0000-4000-8000-000000000000', revision=2))
    assert first.value != second.value


def test_f01_the_same_text_under_a_new_id_is_still_a_new_version():
    """CLARIFY mints a child id even when the wording is unchanged.

    This is the direction that matters: a version labels a confirmation *event*.
    If the label were derived from the text, a re-confirmation would collide with
    its parent and the ancestry walk could not tell them apart.
    """
    parent = resolve_uncertainty_version(packet())
    child = resolve_uncertainty_version(
        packet(uncertainty_id='f6a7b8c9-0000-4000-8000-000000000000',
               confirmation_id='a7b8c9d0-0000-4000-8000-000000000000', revision=2,
               exact_text=EXACT_TEXT))
    assert parent.exact_text_digest == child.exact_text_digest
    assert parent.value != child.value


def test_f01_the_composite_rule_binds_text_and_revision():
    resolved = composite_uncertainty_version(packet())
    assert resolved.value.startswith(UNCERTAINTY_ID + '@1:')
    assert resolved.exact_text_digest[:12] in resolved.value
    # The two rules must never produce the same label, or a deployment could switch
    # rule and silently accept an old value.
    assert resolved.value != resolve_uncertainty_version(packet()).value


def test_f01_admission_states_the_version_and_its_provenance():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    assert task['uncertainty_version'] == UNCERTAINTY_ID
    assert task['uncertainty_version_source']['uncertainty_id'] == UNCERTAINTY_ID
    assert task['uncertainty_version_source']['packet_hash'] == packet()['packet_hash']
    assert task['production_eligible'] is False


def test_f01_a_packet_may_not_assert_qj_authority():
    held('F01_PACKET_ASSERTS_QJ_AUTHORITY',
         lambda: lab_authority().admit_qj(packet(permissions={'qj_execution': True})))


def test_f01_a_context_change_after_admission_invalidates_the_task():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    moved = packet(uncertainty_id='0f0f0f0f-0000-4000-8000-000000000000',
                   confirmation_id='1f1f1f1f-0000-4000-8000-000000000000', revision=2)
    held('F01_CONTEXT_CHANGED_SINCE_ADMISSION',
         lambda: authority.require_current(moved, task))


def test_f01_a_packet_hash_change_alone_invalidates_the_task():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    moved = copy.deepcopy(packet())
    moved['m2_answers'][0]['item_key'] = 'M2-05'
    held('F01_CONTEXT_CHANGED_SINCE_ADMISSION',
         lambda: authority.require_current(rehash(moved), task))


def test_f01_a_stale_admission_cannot_validate_a_measurement():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    moved = packet(uncertainty_id='2f2f2f2f-0000-4000-8000-000000000000',
                   confirmation_id='3f3f3f3f-0000-4000-8000-000000000000', revision=2)
    held('F01_ADMISSION_STALE',
         lambda: authority.validate_measurement(moved, task, measurement()))


def test_f01_the_model_cannot_substitute_another_uncertainty_version():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    substituted = measurement(uncertainty_version='some-other-version')
    held('F02_UNCERTAINTY_VERSION_MISMATCH',
         lambda: authority.validate_measurement(packet(), task, substituted))


# ---------------------------------------------------------------------------
# F-02 — the real versioned validator, replacing the no-op
# ---------------------------------------------------------------------------
def test_f02_a_conforming_measurement_is_test_scoped_valid_and_not_accepted():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    receipt = authority.validate_measurement(packet(), task, measurement())
    assert receipt['status'] == 'TEST_SCOPED_VALID'
    assert receipt['scientific_accepted'] is False
    assert receipt['production_eligible'] is False
    assert receipt['fielding_authorized'] is False
    assert receipt['authorization_status'] == 'TEST_SCOPED_NOT_AUTHORIZED'
    assert receipt['policy_version'] == QJ_INVARIANTS_POLICY.policy_version


def test_f02_geography_is_refused():
    held('F02_GEO_NOT_EXCLUDED',
         lambda: lab_authority().admit_qj(packet(geography={'locality': 'somewhere'})))


@pytest.mark.parametrize('field', ['construct', 'population', 'timeframe', 'stimulus',
                                   'denominator', 'limitations'])
def test_f02_a_blank_required_field_is_refused(field):
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_MEASUREMENT_INCOMPLETE',
         lambda: authority.validate_measurement(packet(), task, measurement(**{field: '  '})))


def test_f02_unequal_code_and_label_counts_are_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_RESPONSE_CODING_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task, measurement(response_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE'])))


def test_f02_duplicate_codes_are_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_RESPONSE_CODING_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task,
             measurement(response_codes=['ACCEPTABLE', 'ACCEPTABLE', 'UNSURE'])))


def test_f02_a_malformed_code_is_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_RESPONSE_CODING_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task,
             measurement(response_codes=['ACCEPTABLE', 'not acceptable', 'UNSURE'])))


def test_f02_an_unrouted_code_is_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_ROUTING_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task,
             measurement(routing={'ACCEPTABLE': 'RECORD', 'NOT_ACCEPTABLE': 'RECORD'})))


def test_f02_a_routing_key_that_is_not_a_declared_code_is_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_ROUTING_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task,
             measurement(routing={'ACCEPTABLE': 'RECORD', 'NOT_ACCEPTABLE': 'RECORD',
                                  'UNSURE': 'RECORD', 'SKIPPED': 'RECORD'})))


def test_f02_a_denominator_over_undeclared_codes_is_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_DENOMINATOR_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task, measurement(denominator='all respondents who replied')))


def test_f02_an_unentailed_source_reference_is_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_SOURCE_NOT_BOUND_TO_PACKET',
         lambda: authority.validate_measurement(
             packet(), task, measurement(source_refs=[UNCERTAINTY_ID, 'INVENTED@1'])))


def test_f02_a_duplicate_source_reference_is_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_SOURCE_REFS_INVALID',
         lambda: authority.validate_measurement(
             packet(), task, measurement(source_refs=[UNCERTAINTY_ID, UNCERTAINTY_ID])))


def test_f02_a_trivial_limitation_is_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_LIMITATIONS_INCOMPLETE',
         lambda: authority.validate_measurement(
             packet(), task, measurement(limitations='Synthetic.')))


def test_f02_a_prohibited_claim_in_the_estimand_is_refused():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('PROHIBITED_VIABILITY_CLAIM',
         lambda: authority.validate_measurement(
             packet(), task,
             measurement(construct='stated price acceptability and cafe profitability')))


def test_f02_a_policy_document_without_authority_cannot_serve_production():
    held('F02_POLICY_NOT_AUTHORIZED',
         lambda: lab_authority(production_requested=True))


def test_f02_a_missing_lab_scope_record_is_refused():
    held('F02_TEST_SCOPE_NOT_AUTHORIZED',
         lambda: MeasurementAuthority(QJ_INVARIANTS_POLICY, lab_scope_record=''))


# ---------------------------------------------------------------------------
# Pinned instrument — the RM13-not-RM12 fidelity requirement
# ---------------------------------------------------------------------------
def test_f02_pinned_instrument_accepts_the_authorised_offer():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    receipt = authority.validate_measurement(packet(), task, pinned_measurement())
    assert receipt['status'] == 'TEST_SCOPED_VALID'
    assert receipt['policy_scope'] == 'PINNED_INSTRUMENT'


def test_f02_pinned_instrument_refuses_a_substituted_price():
    """RM12 must fail even though the stimulus already contains the digits "12".

    This is the D-01 hole in executable form: a digit-subset test passes here
    because "12 oz" supplies the token "12", so only a whole-token currency
    comparison can refuse the substitution. The invariant layer gets there first
    (the uncertainty never confirmed RM12), which is the correct root cause; the
    pinned layer is isolated separately below.
    """
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    swapped = pinned_measurement(
        stimulus='Hypothetical offer: a 12 oz takeaway iced latte priced at RM12.')
    held('F02_STIMULUS_NOT_SUPPORTED_BY_UNCERTAINTY',
         lambda: authority.validate_measurement(packet(), task, swapped))


def test_f02_pinned_instrument_refuses_a_price_drift_within_a_multi_price_uncertainty():
    """Isolates the pinned rule: the uncertainty permits both prices, the offer must not.

    Without this case the price check could be deleted entirely and every test
    would still pass, because the invariant would have caught the substitution.
    """
    multi = packet(exact_text='Would eligible customers find RM13, or RM12 for a '
                              'smaller cup, acceptable for a 12 oz takeaway iced latte?')
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(multi)
    held('F02_STIMULUS_PRICE_DRIFT',
         lambda: authority.validate_measurement(
             multi, task,
             pinned_measurement(stimulus='Hypothetical offer: a 12 oz takeaway iced '
                                         'latte priced at RM12.')))


def test_f02_pinned_instrument_refuses_a_dropped_price():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    held('F02_STIMULUS_PRICE_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task,
             pinned_measurement(stimulus='Hypothetical offer: a 12 oz takeaway iced latte.')))


def test_f02_pinned_instrument_refuses_a_second_price():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    held('F02_STIMULUS_NOT_SUPPORTED_BY_UNCERTAINTY',
         lambda: authority.validate_measurement(
             packet(), task,
             pinned_measurement(stimulus='Hypothetical offer: a 12 oz takeaway iced '
                                         'latte priced at RM13, or RM10 for two.')))


def test_f02_pinned_instrument_refuses_a_different_population():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    held('F02_POPULATION_UNAUTHORIZED',
         lambda: authority.validate_measurement(
             packet(), task, pinned_measurement(population='All consumers in the area')))


def test_f02_pinned_instrument_refuses_a_different_construct():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    held('F02_CONSTRUCT_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task, pinned_measurement(construct='purchase intent')))


def test_f02_pinned_instrument_refuses_relabelled_options():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    held('F02_RESPONSE_LABEL_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task,
             pinned_measurement(response_options=['Yes', 'No', 'Maybe', 'Skip'])))


def test_f02_pinned_instrument_refuses_a_redirected_route():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    redirected = {code: 'RECORD_RESPONSE_CONTINUE' for code in
                  ('ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED')}
    redirected['REFUSED'] = 'END_QUESTIONNAIRE'
    held('F02_ROUTING_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task, pinned_measurement(routing=redirected)))


def test_f02_pinned_instrument_requires_only_the_confirmed_uncertainty_as_source():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    held('F02_SOURCE_REFS_NOT_ENTAILED',
         lambda: authority.validate_measurement(
             packet(), task,
             pinned_measurement(source_refs=[UNCERTAINTY_ID, 'SYN-A1'])))


# ---------------------------------------------------------------------------
# Point 3 — reconciliation with the P1 provisional baseline
# ---------------------------------------------------------------------------
def _provisional_baseline():
    """Load the P1 lab baseline without depending on its test path layout."""
    import importlib.util
    from pathlib import Path

    path = (Path(__file__).resolve().parents[1] / 'm2_bcb'
            / 'lab_measurement_v0_1.py')
    spec = importlib.util.spec_from_file_location('lab_measurement_v0_1', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_lab_policy_matches_the_provisional_baseline():
    """The policy must describe the baseline's instrument, not a rival one.

    Two documents both claiming to pin the same measurement is the failure mode
    this test exists to prevent: whichever one a reviewer read last would win.
    """
    baseline = _provisional_baseline()
    canonical = baseline.canonical_spec()
    contract = canonical.to_contract([UNCERTAINTY_ID], UNCERTAINTY_ID)
    policy = LAB_PRICE_RM13_POLICY
    assert policy.pinned_construct == contract.construct_name
    assert policy.pinned_population == contract.population
    assert policy.pinned_timeframe == contract.timeframe
    assert tuple(policy.pinned_response_codes) == tuple(contract.response_codes)
    assert tuple(policy.pinned_response_labels) == tuple(contract.response_options)
    assert policy.pinned_routing == contract.routing
    assert policy.pinned_denominator_tokens == ('ACCEPTABLE', 'NOT_ACCEPTABLE')
    # The price and the offer components are the same claim stated two ways.
    assert policy.pinned_currency_tokens == {'RM13'}
    assert all(token.lower() in contract.stimulus.lower()
               for token in policy.pinned_stimulus_tokens)


def test_provisional_baseline_contract_is_admitted_by_the_policy():
    """End to end: baseline -> live Measurement contract -> pinned policy receipt."""
    baseline = _provisional_baseline()
    contract = baseline.canonical_spec().to_contract([UNCERTAINTY_ID], UNCERTAINTY_ID)
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    receipt = authority.validate_measurement(packet(), task, contract.model_dump())
    assert receipt['status'] == 'TEST_SCOPED_VALID'
    assert receipt['production_eligible'] is False


def test_provisional_baseline_flags_stay_false_under_the_policy():
    """A validated measurement still carries no approval, by either document."""
    baseline = _provisional_baseline()
    assert all(value is False for value in baseline.APPROVAL_FLAGS.values())
    receipt = QJ_INVARIANTS_POLICY.validate(measurement(), packet(),
                                            resolve_uncertainty_version(packet()))
    assert receipt['scientific_accepted'] is False
    assert receipt['fielding_authorized'] is False


def test_f02_a_price_the_uncertainty_never_confirmed_is_refused():
    """A correct version label is not proof that the instrument measures that offer.

    The candidate echoes the right uncertainty_version and then asks about RM12.
    Nothing in the version check notices, so the stimulus has to be bound to the
    confirmed text independently.
    """
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_STIMULUS_NOT_SUPPORTED_BY_UNCERTAINTY',
         lambda: authority.validate_measurement(
             packet(), task,
             measurement(stimulus='12 oz takeaway iced latte at RM12')))


def test_f02_a_stimulus_without_a_price_is_not_refused_by_that_rule():
    """The guard must be narrow: a stimulus that states no amount is not a mismatch."""
    authority = lab_authority()
    task = authority.admit_qj(packet())
    receipt = authority.validate_measurement(
        packet(), task,
        measurement(stimulus='A 12 oz takeaway iced latte, price shown on the card.'))
    assert receipt['status'] == 'TEST_SCOPED_VALID'


# ---------------------------------------------------------------------------
# 3.4 — a receipt must be verified, not taken at its word
# ---------------------------------------------------------------------------
def _genuine_receipt():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    return authority.validate_measurement(packet(), task, measurement())


def _reseal(receipt: dict) -> dict:
    """Recompute receipt_id after an edit, to reach checks that sit behind it."""
    body = {k: v for k, v in receipt.items() if k != 'receipt_id'}
    return {**body, 'receipt_id': digest(body)}


def test_receipt_a_genuine_receipt_verifies():
    receipt = _genuine_receipt()
    assert verify_validation_receipt(receipt, measurement(), packet()) is receipt


def test_receipt_a_missing_receipt_is_refused():
    held('MEASUREMENT_RECEIPT_MISSING',
         lambda: verify_validation_receipt(None, measurement(), packet()))


def test_receipt_an_unregistered_policy_is_refused():
    receipt = _reseal(dict(_genuine_receipt(), policy_version='NOT-A-REGISTERED-POLICY'))
    held('MEASUREMENT_RECEIPT_UNKNOWN_POLICY',
         lambda: verify_validation_receipt(receipt, measurement(), packet()))


def test_receipt_a_borrowed_policy_version_is_refused():
    """Copying the version without the document's digest is the fabrication route."""
    receipt = _reseal(dict(_genuine_receipt(), policy_digest='fabricated'))
    held('MEASUREMENT_RECEIPT_POLICY_DIGEST_MISMATCH',
         lambda: verify_validation_receipt(receipt, measurement(), packet()))


def test_receipt_a_receipt_for_another_measurement_is_refused():
    held('MEASUREMENT_RECEIPT_MEASUREMENT_MISMATCH',
         lambda: verify_validation_receipt(
             _genuine_receipt(), measurement(construct='a different construct'), packet()))


def test_receipt_a_replayed_receipt_from_another_packet_is_refused():
    other = packet(uncertainty_id='9a9a9a9a-0000-4000-8000-000000000000',
                   confirmation_id='8b8b8b8b-0000-4000-8000-000000000000', revision=2)
    held('MEASUREMENT_RECEIPT_CONTEXT_MISMATCH',
         lambda: verify_validation_receipt(_genuine_receipt(), measurement(), other))


def test_receipt_a_receipt_naming_another_version_is_refused():
    receipt = _reseal(dict(_genuine_receipt(), uncertainty_version='another-version'))
    held('MEASUREMENT_RECEIPT_VERSION_MISMATCH',
         lambda: verify_validation_receipt(receipt, measurement(), packet()))


def test_receipt_an_edited_body_is_detected():
    """A field that no earlier check inspects, added without resealing.

    Editing `measurement_digest` would be caught by the measurement comparison
    first; this case proves the self-hash catches edits the semantic checks do not.
    """
    receipt = dict(_genuine_receipt())
    receipt['policy_scope'] = 'PINNED_INSTRUMENT'
    held('MEASUREMENT_RECEIPT_TAMPERED',
         lambda: verify_validation_receipt(receipt, measurement(), packet()))


def test_receipt_a_non_valid_status_is_refused():
    receipt = _reseal(dict(_genuine_receipt(), status='SCIENTIFICALLY_ACCEPTED'))
    held('MEASUREMENT_RECEIPT_STATUS_INVALID',
         lambda: verify_validation_receipt(receipt, measurement(), packet()))


def test_receipt_an_upgraded_authority_claim_is_refused():
    """Even a correctly sealed receipt cannot claim acceptance it never had."""
    receipt = _reseal(dict(_genuine_receipt(), scientific_accepted=True))
    held('MEASUREMENT_RECEIPT_AUTHORITY_ESCALATION',
         lambda: verify_validation_receipt(receipt, measurement(), packet()))


def test_receipt_the_receipt_never_claims_scientific_acceptance():
    receipt = _genuine_receipt()
    assert receipt['scientific_accepted'] is False
    assert receipt['production_eligible'] is False
    assert receipt['status'] == 'TEST_SCOPED_VALID'
