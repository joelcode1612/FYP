import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/components/m2_workflow_panel.dart';
import 'package:sitewise_jaspr_web/data/app_locator.dart';

const mid = '00000000-0000-4000-8000-000000000001';
const iid = '00000000-0000-4000-8000-000000000002';
const qid = '00000000-0000-4000-8000-000000000003';

/// Explicit synthetic transport fixture. The component and shared repository
/// are real; actual HTTP/PostgreSQL verification is recorded separately.
class SaveClient extends ApiClient {
  int revision = 1;
  String stored = 'A';
  final calls = <String>[];
  final receipt = Completer<void>();
  Object? refusal;
  Map<String, dynamic>? lastPutBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('GET $path');
    if (path == '/api/v1/m2/assessments') {
      return {
        'contract_version': 'm2-assessment-list/1',
        'items': [
          {'id': mid},
        ],
      };
    }
    if (path.endsWith('/$mid')) {
      return {
        'assessment': {
          'id': mid,
          'instrument_id': iid,
          'revision': revision,
          'confirmed_revision': null,
        },
        'instrument': {'id': iid, 'version_tag': 'TEST_ONLY'},
        'items': [
          {
            'id': qid,
            'instrument_id': iid,
            'item_key': 'TEST-01',
            'question_text': 'Synthetic text',
            'answer_kind': 'TEXT',
            'requiredness': 'REQUIRED',
            'effective_required': true,
            'applicable': true,
            'allowed_states': ['ANSWERED'],
            'option_values': {
              'options': [
                {'code': 'A', 'label': 'A'},
                {'code': 'B', 'label': 'B'},
              ],
            },
          },
        ],
        'answers': {
          'TEST-01': {
            'id': 'test-answer',
            'assessment_id': mid,
            'item_version_id': qid,
            'assessment_revision': revision,
            'answer_state': 'ANSWERED',
            'value_json': stored,
          },
        },
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add('PUT $path');
    lastPutBody = Map.of(body);
    await receipt.future;
    if (refusal != null) throw refusal!;
    expect(body['expected_revision'], revision);
    stored = body['value'] as String;
    revision++;
    return {'revision': revision};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected mutation');
}

void main() {
  late ApiM2Repository original;
  late SaveClient client;
  setUp(() {
    original = AppLocator.m2;
    client = SaveClient();
    AppLocator.m2 = ApiM2Repository(client);
  });
  tearDown(() {
    AppLocator.m2 = original;
    if (!client.receipt.isCompleted) client.receipt.complete();
  });
  Component panel() => const M2WorkflowPanel(
    assessmentId: mid,
    requireExplicitId: true,
    embedded: true,
  );

  testComponents(
    'bound assessment sends its marketplace ID with an answer',
    (tester) async {
      tester.pumpComponent(const M2WorkflowPanel(
        assessmentId: mid, requireExplicitId: true, embedded: true,
        marketplaceAssessmentId: iid,
      ));
      await tester.pump();
      (find.byType(textarea).evaluate().single.component as textarea).onInput!('B');
      await tester.pump();
      client.receipt.complete();
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      await tester.pump();
      expect(client.lastPutBody?['marketplace_assessment_id'], iid);
    },
  );
  testComponents(
    'edited answer loses its saved label until the API receipt and readback',
    (tester) async {
      tester.pumpComponent(panel());
      await tester.pump();
      expect(
        find.text('Requiredness REQUIRED · input TEXT · saved ✓'),
        findsOneComponent,
      );
      (find.byType(textarea).evaluate().single.component as textarea).onInput!(
        'B',
      );
      await tester.pump();
      expect(
        find.text('Requiredness REQUIRED · input TEXT · saved ✓'),
        findsNothing,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      await tester.pump();
      expect(client.calls.where((c) => c.startsWith('PUT ')), hasLength(1));
      expect(
        find.text('Requiredness REQUIRED · input TEXT · saved ✓'),
        findsNothing,
      );
      client.receipt.complete();
      await tester.pump();
      await tester.pump();
      expect(client.stored, 'B');
      expect(client.revision, 2);
      expect(
        find.text('Requiredness REQUIRED · input TEXT · saved ✓'),
        findsOneComponent,
      );
      await tester.click(
        find.ancestor(
          of: find.text('Pause for now'),
          matching: find.tag('button'),
        ),
      );
      expect(find.text('Return to assessments'), findsOneComponent);
      expect(
        client.calls.where(
          (c) => !c.startsWith('GET ') && !c.startsWith('PUT '),
        ),
        isEmpty,
      );
      tester.pumpComponent(const Component.fragment([]));
      await tester.pump();
      tester.pumpComponent(panel());
      await tester.pump();
      expect(
        find.text('Requiredness REQUIRED · input TEXT · saved ✓'),
        findsOneComponent,
      );
      expect(client.stored, 'B');
      expect(client.revision, 2);
    },
  );

  testComponents(
    'a refused autosave keeps the edit and displays the actionable API reason',
    (tester) async {
      client.refusal = const ServiceFailure.response(
        'Reload the current assessment revision.',
        statusCode: 409,
        backendCode: 'REVISION_CONFLICT',
      );
      tester.pumpComponent(panel());
      await tester.pump();
      (find.byType(textarea).evaluate().single.component as textarea).onInput!(
        'B',
      );
      await tester.pump();
      client.receipt.complete();
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      await tester.pump();
      expect(client.revision, 1);
      expect(client.stored, 'A');
      expect(find.textContaining('REVISION_CONFLICT'), findsOneComponent);
      expect(
        find.textContaining('Reload the current assessment revision.'),
        findsOneComponent,
      );
      expect(
        find.text('Requiredness REQUIRED · input TEXT · saved ✓'),
        findsNothing,
      );
      await tester.click(
        find.ancestor(
          of: find.text('Pause for now'),
          matching: find.tag('button'),
        ),
      );
      expect(find.text('Return to assessments'), findsNothing);
    },
  );
}
