import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/chart_spec_view.dart';

import 'fixtures/chart_spec_fixtures.dart';

void main() {
  group('ChartSpecModel parsing', () {
    test('parses the held production payload without a percentage', () {
      final spec = ChartSpecModel.fromJson(heldChartPayload());
      expect(spec.schemaVersion, chartSchemaVersion);
      expect(spec.renderState, ChartRenderState.withheldNotAuthorized);
      expect(spec.isReportAdmissible, isFalse);
      expect(spec.hasPercentages, isFalse);
      expect(spec.admission.isHeld, isTrue);
      expect(spec.admission.gates, contains('REPORT_ADMISSION_REQUIRED'));
      expect(spec.options.map((option) => option.percentageText), everyElement(isNull));
    });

    test('keeps contract display order rather than sorting by code', () {
      final spec = ChartSpecModel.fromJson(heldChartPayload());
      expect(
        spec.options.map((option) => option.code).toList(),
        ['DEF_NO', 'PROB_NO', 'UNSURE', 'PROB_YES', 'DEF_YES'],
      );
    });

    test('reads ordinal meaning separately from display position', () {
      final spec = ChartSpecModel.fromJson(heldChartPayload());
      expect(spec.responseKind, ChartResponseKind.ordinal);
      expect(
        {for (final option in spec.options) option.code: option.ordinalValue},
        {'DEF_NO': 1, 'PROB_NO': 2, 'UNSURE': 3, 'PROB_YES': 4, 'DEF_YES': 5},
      );
    });

    test('keeps the derived aggregate out of the option list', () {
      final spec = ChartSpecModel.fromJson(heldChartPayload());
      expect(spec.options.map((option) => option.code), isNot(contains('TOP_TWO_STATED_INTEREST')));
      expect(spec.derivedLines, hasLength(1));
      expect(spec.derivedLines.single.count, 22);
      expect(spec.derivedLines.single.numeratorCodes, ['DEF_YES', 'PROB_YES']);
    });

    test('reports the tied highest options as a tie', () {
      final payload = heldChartPayload();
      payload['options'] = [
        for (final entry in {
          'DEF_NO': 10,
          'PROB_NO': 10,
          'UNSURE': 0,
          'PROB_YES': 0,
          'DEF_YES': 0,
        }.entries)
          {
            'code': entry.key,
            'label': null,
            'label_source': 'CODE_FALLBACK',
            'ordinal_value': null,
            'count': entry.value,
            'percentage': null,
            'percentage_status': 'WITHHELD_NOT_AUTHORIZED',
          },
      ];
      payload['derived_lines'] = <Map<String, dynamic>>[];
      payload['highest_options'] = ['DEF_NO', 'PROB_NO'];
      payload['measurement'] = {
        'I': 'UNKNOWN_NOT_ENUMERABLE',
        'Q': 22,
        'S': 20,
        'A': 20,
        'V': 20,
      };
      final spec = ChartSpecModel.fromJson(payload);
      expect(spec.highestOptions, ['DEF_NO', 'PROB_NO']);
    });

    test('carries the evidence context hash that binds it to an explanation', () {
      final spec = ChartSpecModel.fromJson(heldChartPayload());
      expect(spec.evidenceContextHash, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(spec.evidenceContextHash), isTrue);
    });

    test('rejects a missing or malformed evidence context hash', () {
      final payload = heldChartPayload()..['evidence_context_hash'] = 'not-a-hash';
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_EVIDENCE_CONTEXT_HASH_INVALID',
        )),
      );
    });

    test('percentage is a decimal string and is not re-derived', () {
      final spec = ChartSpecModel.fromJson(conformanceChartPayload());
      expect(spec.renderState, ChartRenderState.renderable);
      expect(spec.isReportAdmissible, isTrue);
      expect(spec.options.first.percentageText, '24.0000');
      expect(spec.options.first.percentageValue, closeTo(24.0, 1e-9));
    });

    test('rejects a percentage carried on a held spec', () {
      final payload = heldChartPayload();
      (payload['options'] as List<dynamic>).first['percentage'] = '24.0000';
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY',
        )),
      );
    });

    test('rejects a JSON number where a decimal string is required', () {
      final payload = conformanceChartPayload();
      (payload['options'] as List<dynamic>).first['percentage'] = 24.0;
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_PERCENTAGE_NOT_A_DECIMAL_STRING',
        )),
      );
    });

    test('rejects a renderable spec whose option lacks a percentage', () {
      final payload = conformanceChartPayload();
      (payload['options'] as List<dynamic>).first['percentage'] = null;
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_PERCENTAGE_STATUS_MISSING_VALUE',
        )),
      );
    });

    test('rejects an unknown schema version', () {
      final payload = heldChartPayload()..['schema_version'] = 'chart-spec/2';
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_SCHEMA_VERSION_UNSUPPORTED',
        )),
      );
    });

    test('rejects a non-canonical report section', () {
      final payload = heldChartPayload()..['report_sections'] = ['R08_LIMITED_CONTEXT'];
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_NONCANONICAL_REPORT_SECTION',
        )),
      );
    });

    test('rejects a single-select distribution that does not sum to V', () {
      final payload = heldChartPayload();
      (payload['options'] as List<dynamic>).first['count'] = 11;
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_SINGLE_SELECT_SUM_MISMATCH',
        )),
      );
    });

    test('rejects a derived count that disagrees with its options', () {
      final payload = heldChartPayload();
      (payload['derived_lines'] as List<dynamic>).first['count'] = 21;
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_DERIVED_COUNT_MISMATCH',
        )),
      );
    });

    test('rejects a highest-options list that disagrees with the counts', () {
      final payload = heldChartPayload()..['highest_options'] = ['DEF_NO'];
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_HIGHEST_OPTIONS_MISMATCH',
        )),
      );
    });

    test('rejects a non-monotonic funnel', () {
      final payload = heldChartPayload();
      (payload['measurement'] as Map<String, dynamic>)['S'] = 99;
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_FUNNEL_NON_MONOTONIC',
        )),
      );
    });

    test('rejects a held admission with no open gate', () {
      final payload = heldChartPayload();
      (payload['admission'] as Map<String, dynamic>)['gates'] = <String>[];
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_HELD_WITHOUT_GATE',
        )),
      );
    });

    test('rejects a missing limitations list', () {
      final payload = heldChartPayload()..['limitations'] = <String>[];
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(isA<ChartSpecException>().having(
          (error) => error.code,
          'code',
          'E_LIMITATION_MISSING',
        )),
      );
    });
  });

  group('ChartSpecView rendering', () {
    testComponents('renders bars, counts and percentages for a renderable spec', (tester) {
      tester.pumpComponent(
        ChartSpecView(spec: ChartSpecModel.fromJson(conformanceChartPayload())),
      );

      expect(find.text('Stated first-three-month interest'), findsOneComponent);
      expect(find.text('R03'), findsOneComponent);
      // Pill label plus the ordinal column header.
      expect(find.text('Ordinal'), findsNComponents(2));
      // Each figure appears twice by design: once on the bar and once in the
      // accessible table, which is the semantic representation.
      expect(find.text('PROB_YES'), findsNComponents(2));
      expect(find.text('14'), findsNComponents(2));
      // 14 / 50 = 28.0000, printed from the backend decimal string.
      expect(find.text('28%'), findsNComponents(2));
      expect(find.text('24%'), findsNComponents(2));
      expect(find.text('Limitations'), findsOneComponent);
      expect(find.text('Not report-admissible'), findsNothing);
    });

    testComponents('held spec shows the notice and no bars and no counts', (tester) {
      tester.pumpComponent(
        ChartSpecView(spec: ChartSpecModel.fromJson(heldChartPayload())),
      );

      expect(find.text('Findings withheld'), findsOneComponent);
      expect(find.text('Not report-admissible'), findsOneComponent);
      // The option labels still appear in the accessible table, but the counts
      // are withheld rather than partially published.
      expect(find.text('14'), findsNothing);
      expect(find.text('28%'), findsNothing);
      // Five options contribute a count cell and a share cell; the derived
      // aggregate contributes one more.
      expect(find.text('withheld'), findsNComponents(11));
      expect(find.text('Limitations'), findsOneComponent);
    });

    testComponents('V = 0 renders "not estimable", never 0%', (tester) {
      tester.pumpComponent(
        ChartSpecView(spec: ChartSpecModel.fromJson(notEstimableChartPayload())),
      );

      expect(find.text('Not estimable'), findsOneComponent);
      expect(find.textContaining('never rendered as 0%'), findsOneComponent);
      expect(find.text('0%'), findsNothing);
      expect(find.text('0'), findsNothing);
    });

    testComponents('NOT_SHOWN renders the routing notice', (tester) {
      tester.pumpComponent(
        ChartSpecView(spec: ChartSpecModel.fromJson(notShownChartPayload())),
      );

      expect(find.text('Not shown'), findsOneComponent);
      expect(find.textContaining('not a result of zero'), findsOneComponent);
    });

    testComponents('always renders the denominator, limitations and provenance', (tester) {
      tester.pumpComponent(
        ChartSpecView(spec: ChartSpecModel.fromJson(heldChartPayload())),
      );

      expect(find.textContaining('Denominator —'), findsOneComponent);
      // The number only: `denominatorScope` states what V counts, so appending
      // a second characterisation here could contradict it.
      expect(find.textContaining('V = 50'), findsOneComponent);
      expect(find.text('Q05 · q05-v1'), findsOneComponent);
      expect(find.text('D01_CONCEPT_INTENT'), findsOneComponent);
      expect(find.text('2026-11-22 09:00 UTC'), findsOneComponent);
      expect(find.textContaining('REPORT_ADMISSION_REQUIRED'), findsOneComponent);
    });

    testComponents('renders the accessible table with a caption and row headers', (tester) {
      tester.pumpComponent(
        ChartSpecView(spec: ChartSpecModel.fromJson(conformanceChartPayload())),
      );

      expect(find.text('Option'), findsOneComponent);
      expect(find.text('Count'), findsOneComponent);
      expect(
        find.textContaining('Counts and percentages for Q05'),
        findsOneComponent,
      );
      expect(find.text('Share of V'), findsOneComponent);
      expect(find.text('Ordinal'), findsNComponents(2)); // pill + column header
    });

    test('parses draft labels without treating them as approved wording', () {
      final spec = ChartSpecModel.fromJson(draftLabelChartPayload());
      expect(spec.options.first.label, 'Definitely would not');
      expect(spec.options.first.labelSource, 'CONTRACT_OPTION_BANK_DRAFT');
      expect(spec.options.every((option) => option.label != null), isTrue);
    });

    testComponents('shows a draft label instead of the raw code', (tester) {
      tester.pumpComponent(
        ChartSpecView(spec: ChartSpecModel.fromJson(draftLabelChartPayload())),
      );

      // The draft label is displayed, so the code is no longer the visible text.
      expect(find.text('Probably would'), findsOneComponent);
      expect(find.text('PROB_YES'), findsNothing);
    });

    testComponents('still shows the code when no label bank is bound', (tester) {
      tester.pumpComponent(
        ChartSpecView(spec: ChartSpecModel.fromJson(heldChartPayload())),
      );

      expect(find.text('PROB_YES'), findsOneComponent);
    });
  });
}
