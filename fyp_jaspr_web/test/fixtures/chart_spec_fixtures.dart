/// Synthetic `chart-spec/1` payloads for component tests.
///
/// Two kinds of payload appear here, and the distinction matters:
///
/// * [heldChartPayload] is what the backend can actually produce in V1: a
///   synthetic EE-01 snapshot whose readback is held, so every percentage is
///   absent. It is the production shape.
/// * [conformanceChartPayload] is a **contract-conformance** fixture with
///   `ADMITTED` admission, used only to exercise the percentage-rendering path.
///   Its `source_provenance` says so and it never enters a report.
library;

const _q05Codes = ['DEF_NO', 'PROB_NO', 'UNSURE', 'PROB_YES', 'DEF_YES'];
const _q05Counts = {'DEF_NO': 12, 'PROB_NO': 9, 'UNSURE': 7, 'PROB_YES': 14, 'DEF_YES': 8};
const _q05Ordinal = {'DEF_NO': 1, 'PROB_NO': 2, 'UNSURE': 3, 'PROB_YES': 4, 'DEF_YES': 5};

const _questionText =
    'If the café described in [concept_card_version] opened in [named area], '
    'how likely would you be to visit it at least once during its first three months?';

const _limitations = <String>[
  'The stem compounds a time horizon with an at-least-once event; which clause '
      'drives the answer is untested. UNSURE is substantive per the applicable A10 '
      'worked example and is counted in V; CANNOT_JUDGE is not.',
  'Calibrated probability; predicted visits; customers; revenue; demand score; '
      'any conversion to a rate',
];

Map<String, dynamic> _base({
  required String renderState,
  required bool estimable,
  required String admissionStatus,
  required String provenance,
  required int V,
  required int S,
}) {
  const gates = <String>[
    'EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED',
    'A10_ADAPTER_UNVERIFIED',
    'REPORT_ADMISSION_REQUIRED',
  ];
  final options = [
    for (final code in _q05Codes)
      {
        'code': code,
        'label': null,
        'label_source': 'CODE_FALLBACK',
        'ordinal_value': _q05Ordinal[code],
        'count': _q05Counts[code],
        'percentage': estimable
            ? ((_q05Counts[code]! * 100) / V).toStringAsFixed(4)
            : null,
        'percentage_status': estimable ? 'ESTIMABLE' : 'WITHHELD_NOT_AUTHORIZED',
      },
  ];
  final top = _q05Counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  final highest = _q05Counts.entries
      .where((entry) => entry.value == top.value)
      .map((entry) => entry.key)
      .toList()
    ..sort();
  return {
    'schema_version': 'chart-spec/1',
    'chart_id': 'chart:snap-0001:R03',
    'chart_type': 'HORIZONTAL_BAR',
    'source_provenance': provenance,
    // Stands in for the EE-01 readback context_hash; 64 hex characters.
    'evidence_context_hash': 'a' * 64,
    'campaign_id': 'campaign-0001',
    'question_id': 'Q05',
    'construct_id': 'D01_CONCEPT_INTENT',
    'report_sections': ['R03'],
    'question_version': 'q05-v1',
    'option_bank_version': 'bank-v1',
    'stimulus_hash': 'stimulus-0001',
    'concept_version': 'concept-v1',
    'cohort_scope': 'DEVELOPER_PREVIEW / qualification qual-v1',
    'cutoff': '2026-11-22T09:00:00Z',
    'measurement': {
      'I': 'UNKNOWN_NOT_ENUMERABLE',
      'Q': S + 2,
      'S': S,
      'A': V,
      'V': V,
    },
    'denominator_scope': 'V = substantive answers to Q05 at this version and stimulus',
    'limitation': _limitations.first,
    'title': 'Stated first-three-month interest',
    'question_text': _questionText,
    'response_kind': 'ORDINAL',
    'options': options,
    'derived_lines': [
      {
        'code': 'TOP_TWO_STATED_INTEREST',
        'label': null,
        'numerator_codes': ['DEF_YES', 'PROB_YES'],
        'count': 22,
        'percentage': estimable ? ((22 * 100) / V).toStringAsFixed(4) : null,
        'percentage_status': estimable ? 'ESTIMABLE' : 'WITHHELD_NOT_AUTHORIZED',
        'formula': '100 * (x[DEF_YES] + x[PROB_YES]) / V',
        'output_label': 'stated first-three-month interest',
        'combination': 'DISJOINT_SINGLE_SELECT',
      },
    ],
    'highest_options': highest,
    'limitations': _limitations,
    'render_state': renderState,
    'admission': {
      'status': admissionStatus,
      'authority': estimable ? 'TEST_FIXTURE_CONTRACT_CONFORMANCE' : 'AUTHORITY_UNVERIFIED',
      'gates': estimable ? <String>[] : gates,
      'real_reportable': false,
    },
  };
}

/// The production shape: synthetic measurement, held readback, no percentages.
Map<String, dynamic> heldChartPayload() => _base(
  renderState: 'WITHHELD_NOT_AUTHORIZED',
  estimable: false,
  admissionStatus: 'HELD',
  provenance: 'SYNTHETIC_TEST',
  V: 50,
  S: 53,
);

/// Draft option labels, as the backend now supplies them from the contract
/// matrix. They are candidates, not approved wording, and the payload says so.
const _q05DraftLabels = {
  'DEF_NO': 'Definitely would not',
  'PROB_NO': 'Probably would not',
  'UNSURE': 'Not sure',
  'PROB_YES': 'Probably would',
  'DEF_YES': 'Definitely would',
};

/// The production shape **with** the draft label bank bound.
Map<String, dynamic> draftLabelChartPayload() {
  final payload = heldChartPayload();
  for (final option in payload['options'] as List<dynamic>) {
    final map = option as Map<String, dynamic>;
    final label = _q05DraftLabels[map['code']];
    map['label'] = label;
    map['label_source'] = label == null ? 'CODE_FALLBACK' : 'CONTRACT_OPTION_BANK_DRAFT';
  }
  return payload;
}

/// Contract-conformance only: exercises the authorized-percentage path.
Map<String, dynamic> conformanceChartPayload() => _base(
  renderState: 'RENDERABLE',
  estimable: true,
  admissionStatus: 'ADMITTED',
  provenance: 'TEST_FIXTURE_CONTRACT_CONFORMANCE',
  V: 50,
  S: 53,
);

/// V = 0: no substantive answers, so no percentage may exist at all.
Map<String, dynamic> notEstimableChartPayload() {
  final payload = _base(
    renderState: 'NOT_ESTIMABLE',
    estimable: false,
    admissionStatus: 'HELD',
    provenance: 'SYNTHETIC_TEST',
    V: 50,
    S: 53,
  );
  payload['measurement'] = {
    'I': 'UNKNOWN_NOT_ENUMERABLE',
    'Q': 5,
    'S': 5,
    'A': 0,
    'V': 0,
  };
  for (final option in payload['options'] as List<dynamic>) {
    (option as Map<String, dynamic>)['count'] = 0;
    option['percentage_status'] = 'NOT_ESTIMABLE';
  }
  final derived = (payload['derived_lines'] as List<dynamic>).first as Map<String, dynamic>;
  derived['count'] = 0;
  derived['percentage_status'] = 'NOT_ESTIMABLE';
  payload['highest_options'] = <String>[];
  return payload;
}

/// S = 0: routing never displayed the item to an eligible unit.
Map<String, dynamic> notShownChartPayload() {
  final payload = _base(
    renderState: 'NOT_SHOWN',
    estimable: false,
    admissionStatus: 'HELD',
    provenance: 'SYNTHETIC_TEST',
    V: 50,
    S: 53,
  );
  payload['measurement'] = {
    'I': 'UNKNOWN_NOT_ENUMERABLE',
    'Q': 4,
    'S': 0,
    'A': 0,
    'V': 0,
  };
  for (final option in payload['options'] as List<dynamic>) {
    (option as Map<String, dynamic>)['count'] = 0;
    option['percentage_status'] = 'NOT_SHOWN';
  }
  final derived = (payload['derived_lines'] as List<dynamic>).first as Map<String, dynamic>;
  derived['count'] = 0;
  derived['percentage_status'] = 'NOT_SHOWN';
  payload['highest_options'] = <String>[];
  return payload;
}
