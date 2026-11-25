/// Recorded shapes for the Stage 5 composed-questionnaire tests.
///
/// The document builder below mirrors `sitewise-questionnaire-composition/1`
/// exactly — same keys, same nesting, same vocabularies — because a fixture that
/// drifts from the contract stops being evidence. It is deliberately *not* a
/// subset: every field the component reads is present, so a test that passes
/// here is a statement about the real payload shape.
library;

const String stage5MarketplaceAssessmentId =
    '9af8000e-7eef-4597-a0c8-d7f88ad1381f';
const String stage5M2AssessmentId = '0f958d15-c629-4df4-90b1-ba444e042612';
const String stage5ConfirmationId = '4a2a8906-f110-5e54-931a-a14fc60260b7';
const int stage5Revision = 24;

Map<String, dynamic> stage5LinkPayload() => {
  'm2_assessment_id': stage5M2AssessmentId,
  'marketplace_assessment_id': stage5MarketplaceAssessmentId,
};

/// A minimal saved M2 draft.
///
/// `M2Draft.fromJson` refuses an empty item list and requires the instrument
/// bindings to agree, so this carries one item rather than an empty array — a
/// fixture that omitted it would fail validation for the wrong reason.
Map<String, dynamic> stage5M2DraftPayload({int revision = stage5Revision}) => {
  'assessment': {
    'id': stage5M2AssessmentId,
    'revision': revision,
    'instrument_id': 'm2v2',
  },
  'instrument': {'id': 'm2v2'},
  'items': [
    {
      'id': '9a8b7c6d-aaaa-4bbb-8ccc-ddddeeeeffff',
      'item_key': 'M2V2-01',
      'instrument_id': 'm2v2',
    },
  ],
  'answers': <String, dynamic>{},
};

Map<String, dynamic> stage5ConfirmationPayload({
  int revision = stage5Revision,
  String id = stage5ConfirmationId,
}) => {
  'id': id,
  'assessment_id': stage5M2AssessmentId,
  'assessment_revision': revision,
  'is_current': true,
};

/// One governed core item. Q01 and Q07 carry a required unresolved slot, which
/// is what the live document reported for this assessment.
Map<String, dynamic> _fixedItem(int n, {bool unresolved = false}) {
  final id = 'Q${n.toString().padLeft(2, '0')}';
  return {
    'item_id': id,
    'section': 'A_FIXED_CORE',
    'display_order': n,
    'source': 'GOVERNED_CORE',
    'stem': unresolved
        ? 'How often do you visit a [named area] in the next 6 months?'
        : 'Governed core question $id wording.',
    'stem_template': unresolved
        ? 'How often do you visit a [named area] in the next 6 months?'
        : 'Governed core question $id wording.',
    'response_format': n.isEven ? 'SINGLE_CHOICE' : 'MULTI_CHOICE',
    'options': [
      {'code': 'R1', 'label': ''},
      {'code': 'R2', 'label': ''},
    ],
    'construct': 'visitor_frequency',
    'question_class': 'BEHAVIOUR',
    'measurement_status': 'NOT_APPROVED',
    'approval_state': 'NOT_APPROVED',
    'authority_to_activate': 'NOT_GRANTED',
    'population_status': unresolved ? 'PARTIAL_UNRESOLVED' : 'COMPLETE',
    'unresolved_slots': unresolved
        ? [
            {
              'token': '[named area]',
              'slot': 'named_area',
              'source': 'M2V2-01',
              'required': true,
              'reason': 'The owner has not declared the study area.',
            },
          ]
        : <Map<String, dynamic>>[],
    'fielding_authorized': false,
    'publication_authorized': false,
    'scientifically_accepted': false,
    'review_controls': 'NONE',
  };
}

Map<String, dynamic> stage5AdditionalItem() => {
  'item_id': 'c1d2e3f4-1111-4222-8333-944455556666',
  'section': 'B_ADDITIONAL',
  'display_order': 14,
  'source': 'QG_CANDIDATE',
  'stem':
      'How far would you travel for a climbing session on a weekday evening?',
  'response_format': 'SINGLE_CHOICE',
  'options': [
    {
      'code': 'A',
      'label': 'Under 10 minutes',
      'order': 1,
      'order_source': 'GENERATOR',
    },
    {
      'code': 'B',
      'label': '10 to 20 minutes',
      'order': 2,
      'order_source': 'GENERATOR',
    },
    {
      'code': 'C',
      'label': 'More than 20 minutes',
      'order': 3,
      'order_source': 'GENERATOR',
    },
  ],
  'objective_id': 'aa11bb22-cc33-4dd4-8ee5-ff6677889900',
  'objective_admission_id': 'bb22cc33-dd44-4ee5-8ff6-001122334455',
  'measurement_id': 'travel_tolerance',
  'measurement_version': '1',
  'review_decision': 'APPROVE_FOR_REVIEW',
  'review_recorded_at': '2026-11-24T10:41:02Z',
  'owner_intended_option': 'B',
  'owner_intended_option_scope': 'ENTREPRENEUR_ONLY_METADATA',
  'candidate_state': 'VALIDATED',
  'structural_status': 'STRUCTURALLY_VALID',
  'semantic_status': 'UNDER_REVIEW',
  'provenance_status': 'SOURCE_BOUND',
  'semantic_basis': 'OWNER_REVIEW',
  'execution_mode': 'LIVE',
  'dispatched': true,
  'unresolved_slots': <Map<String, dynamic>>[],
  'approval_state': 'NOT_APPROVED',
  'fielding_authorized': false,
  'publication_authorized': false,
  'scientifically_accepted': false,
  'review_controls': 'PER_ITEM',
};

/// The composed document.
///
/// `additional: false` reproduces the empty-Section-B document the live route
/// returned for this assessment; `additional: true` reproduces a document with
/// one approved additional question, which is the state the panel must render
/// once an approval exists.
Map<String, dynamic> stage5ComposedDocument({
  bool additional = true,
  bool unresolved = true,
  bool validationPassed = true,
}) {
  final fixed = [
    for (var n = 1; n <= 13; n++)
      _fixedItem(n, unresolved: unresolved && (n == 1 || n == 7)),
  ];
  final extra = additional
      ? [stage5AdditionalItem()]
      : <Map<String, dynamic>>[];
  final items = [...fixed, ...extra];

  final requirements = <Map<String, dynamic>>[
    if (unresolved) ...[
      {
        'code': 'FIXED_CORE_SLOT_UNRESOLVED',
        'scope': 'A_FIXED_CORE',
        'item_id': 'Q01',
        'slot': 'named_area',
        'source': 'M2V2-01',
        'required': true,
        'blocking': true,
        'detail': 'Q01 cannot be fielded until M2V2-01 is declared.',
      },
      {
        'code': 'FIXED_CORE_SLOT_UNRESOLVED',
        'scope': 'A_FIXED_CORE',
        'item_id': 'Q07',
        'slot': 'named_area',
        'source': 'M2V2-01',
        'required': true,
        'blocking': true,
        'detail': 'Q07 cannot be fielded until M2V2-01 is declared.',
      },
    ],
    if (!additional)
      {
        'code': 'NO_ELIGIBLE_ADDITIONAL_QUESTION',
        'scope': 'B_ADDITIONAL',
        'required': false,
        'blocking': true,
        'detail':
            'No additional question is eligible. Section B is empty, so the '
            'composed questionnaire is the fixed core only.',
      },
    if (!validationPassed)
      {
        'code': 'QUESTIONNAIRE_VALIDATION_FAILED',
        'scope': 'DOCUMENT',
        'required': false,
        'blocking': true,
        'detail': 'The composed document failed its own validation: QV-07.',
      },
  ];

  final excluded = additional
      ? <Map<String, dynamic>>[]
      : [
          {
            'candidate_id': 'deadbeef-0000-4000-8000-000000000001',
            'objective_id': 'aa11bb22-cc33-4dd4-8ee5-ff6677889900',
            'reason': 'CANDIDATE_NOT_APPROVED',
            'assessment_revision': stage5Revision,
          },
        ];

  return {
    'contract_version': 'sitewise-questionnaire-composition/1',
    'assessment_id': stage5M2AssessmentId,
    'confirmation_id': stage5ConfirmationId,
    'assessment_revision': stage5Revision,
    'sections': [
      {
        'key': 'A_FIXED_CORE',
        'title': 'Fixed core questionnaire',
        'review_controls': 'NONE',
        'item_count': fixed.length,
        'items': fixed,
      },
      {
        'key': 'B_ADDITIONAL',
        'title': 'Additional question candidates',
        'review_controls': 'PER_ITEM',
        'item_count': extra.length,
        'items': extra,
      },
    ],
    'items': items,
    'counts': {
      'fixed_core': fixed.length,
      'additional': extra.length,
      'total': items.length,
      'approved_fixed_core': 0,
      'approved_additional': additional ? 1 : 0,
      'excluded_candidates': excluded.length,
    },
    'composition_status': validationPassed ? 'VALID' : 'INVALID',
    'population_status': unresolved ? 'PARTIAL_UNRESOLVED' : 'COMPLETE',
    'additional_status': additional ? 'AVAILABLE' : 'NONE_ELIGIBLE',
    'admitted_objective_count': additional ? 1 : 0,
    'unresolved_requirements': requirements,
    'excluded_candidates': excluded,
    'validation': {
      'contract_version': 'sitewise-questionnaire-validation/1',
      'status': validationPassed ? 'PASS' : 'FAIL',
      'failure_count': validationPassed ? 0 : 1,
      'check_count': 10,
      'checks': <Map<String, dynamic>>[],
      'failed_checks': validationPassed ? <String>[] : ['QV-07'],
    },
    'declarations': {
      'slot_values': {'named_area': null},
      'context_available': true,
      'context_id': stage5ConfirmationId,
      'context_packet_hash': List<String>.filled(64, 'a').join(),
    },
    'publication_readiness': {
      'ready': false,
      'blockers': [
        for (final requirement in requirements)
          if (requirement['blocking'] == true) requirement['code'] as String,
      ],
      'detail':
          'Composition and publication are different decisions. Nothing in this '
          'document is scientifically accepted or authorised for fielding, so it '
          'cannot be published.',
    },
    'fielding_authorized': false,
    'publication_authorized': false,
    'scientifically_accepted': false,
    'customer_fielding_enabled': false,
    'report_release_authorized': false,
    'scientific_acceptance': false,
    'owner_authorization': false,
  };
}

/// Business-context status for the confirmed revision.
///
/// Mirrors `GET /m2/assessments/{id}/confirmations/{cid}/business-context-status`.
Map<String, dynamic> stage5ContextStatusPayload({
  String status = 'PERSISTED',
  bool sourceIsCurrent = true,
  String? contextId = stage5ConfirmationId,
}) => {
  'assessment_id': stage5M2AssessmentId,
  'confirmation_id': stage5ConfirmationId,
  'assessment_revision': stage5Revision,
  'status': status,
  'source_is_current': sourceIsCurrent,
  'context_id': contextId,
  'attempt_count': 1,
};
