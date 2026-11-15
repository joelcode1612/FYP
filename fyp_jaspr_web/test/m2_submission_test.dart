// Synthetic transport fixtures test UI submission behavior, not production adoption.
import 'dart:convert';
import 'package:jaspr/dom.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/components/m2_entry_panel.dart';
import 'package:sitewise_jaspr_web/data/app_locator.dart';

const aid = '00000000-0000-4000-8000-000000000001';
const iid = '00000000-0000-4000-8000-000000000002';

class SubmissionClient extends ApiClient {
  int revision = 0;
  bool failSave = false;
  final answers = <String, dynamic>{};
  final calls = <String>[];
  final items = [
    for (final key in ['M2-01', 'M2-04'])
      {
        'id': '$iid-$key',
        'instrument_id': iid,
        'item_key': key,
        'lifecycle': 'ACTIVE',
        'answer_kind': 'TEXT',
        'question_text': 'Fixture $key',
        'requiredness': 'REQUIRED',
        'option_values': <String>[],
        'allowed_states': ['ANSWERED'],
      },
  ];
  Map<String, dynamic> worksheet() => {
    'assessment_id': aid,
    'revision': revision,
    'evaluation_state': 'EVALUATED_CANDIDATE',
    'claims_boundary': 'Fixture declarations only.',
    'findings': [
      {
        'id': '00000000-0000-4000-8000-000000000003',
        'rule_id': 'FIXTURE',
        'explanation': 'Fixture issue',
        'source_answer_ids': ['fixture-answer'],
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('GET $path');
    if (path.endsWith('/instruments')) {
      return {'contract_version': 'm2-instrument-list/1', 'items': <dynamic>[]};
    }
    if (path.endsWith('/assessments')) {
      return {'contract_version': 'm2-assessment-list/1', 'items': <dynamic>[]};
    }
    if (path.endsWith('/business-understanding')) return worksheet();
    return jsonDecode(
          jsonEncode({
            'assessment': {
              'id': aid,
              'instrument_id': iid,
              'revision': revision,
            },
            'instrument': {'id': iid, 'version_tag': 'SYNTHETIC-TEST-ONLY'},
            'items': items,
            'answers': answers,
          }),
        )
        as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> put(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add('PUT $path');
    if (failSave) throw const NetworkFailure('Fixture save failed.');
    expect(body['expected_revision'], revision);
    final key = path.split('/').last;
    revision++;
    answers[key] = {
      'id': 'answer-$revision',
      'assessment_id': aid,
      'item_version_id': '$iid-$key',
      'assessment_revision': revision,
      'answer_state': body['answer_state'],
      'value_json': body['value'],
    };
    return {'revision': revision};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add('POST $path @${body['expected_revision']}');
    expect(body['expected_revision'], revision);
    if (path.endsWith('/bdj/evaluate')) return worksheet();
    if (path.endsWith('/decisions'))
      return {
        'answer_changed': false,
        'finding_resolved': false,
        'event': {
          'assessment_id': aid,
          'assessment_revision': revision,
          'finding_id': '00000000-0000-4000-8000-000000000003',
          'decision': body['decision'],
          'request_id': body['request_id'],
        },
      };
    throw StateError('Unexpected mutation: $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected call');
}

void main() {
  late ApiM2Repository original;
  late SubmissionClient client;
  setUp(() {
    original = AppLocator.m2;
    client = SubmissionClient();
    AppLocator.m2 = ApiM2Repository(client);
  });
  tearDown(() => AppLocator.m2 = original);
  Future<void> open(ComponentTester tester) async {
    tester.pumpComponent(const M2EntryPanel(assessmentId: aid));
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  Future<void> click(ComponentTester tester, String label) async {
    await tester.click(
      find.ancestor(of: find.text(label), matching: find.tag('button')),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  Future<void> type(ComponentTester tester, String value) async {
    (find.byType(textarea).evaluate().single.component as textarea).onInput!(
      value,
    );
    await tester.pump();
  }

  testComponents(
    'typing and save never evaluate; incomplete submit saves pending text and lists missing items',
    (tester) async {
      await open(tester);
      await type(tester, 'Exact entrepreneur wording');
      expect(
        client.calls.where((c) => c.startsWith('PUT') || c.startsWith('POST')),
        isEmpty,
      );
      await click(tester, 'Submit answers for BDJ review');
      expect(
        client.answers['M2-01']['value_json'],
        'Exact entrepreneur wording',
      );
      expect(
        find.text(
          'Complete the required answers before submitting for BDJ review: M2-04',
        ),
        findsOneComponent,
      );
      expect(client.calls.where((c) => c.contains('/bdj/evaluate')), isEmpty);
      await click(tester, 'Save answer');
      expect(client.calls.where((c) => c.contains('/bdj/evaluate')), isEmpty);
    },
  );
  testComponents(
    'navigation saves without evaluating; explicit submit includes the last unsaved answer and exact revision',
    (tester) async {
      await open(tester);
      await type(tester, 'First declaration');
      await click(tester, 'Next question');
      expect(client.revision, 1);
      expect(client.calls.where((c) => c.startsWith('POST')), isEmpty);
      await type(tester, 'Last pending declaration');
      await click(tester, 'Submit answers for BDJ review');
      expect(client.answers['M2-04']['value_json'], 'Last pending declaration');
      expect(
        client.calls.where((c) => c.contains('/bdj/evaluate')).single,
        endsWith('@2'),
      );
      expect(find.text('Business description review'), findsOneComponent);
      final writes = client.calls
          .where((c) => c.startsWith('PUT') || c.startsWith('POST'))
          .toList();
      expect(writes.length, 3);
      expect(writes[1], contains('/answers/M2-04'));
      expect(writes[2], contains('/bdj/evaluate'));
      await click(tester, 'Keep my original answer');
      expect(client.calls.where((c) => c.contains('/bdj/evaluate')).length, 1);
      expect(
        client.calls.last,
        'GET /api/v1/m2/assessments/$aid/business-understanding',
      );
      await type(tester, 'Changed after review');
      expect(find.text('Confirm this business information'), findsNothing);
      expect(find.text('Business description review'), findsNothing);
    },
  );
  testComponents(
    'failed save prevents evaluation and preserves input for retry',
    (tester) async {
      await open(tester);
      await type(tester, 'Retain this input');
      client.failSave = true;
      await click(tester, 'Submit answers for BDJ review');
      expect(find.text('Fixture save failed.'), findsOneComponent);
      expect(client.calls.where((c) => c.startsWith('POST')), isEmpty);
      expect(client.revision, 0);
      client.failSave = false;
      await click(tester, 'Next question');
      expect(client.answers['M2-01']['value_json'], 'Retain this input');
      expect(client.calls.where((c) => c.startsWith('POST')), isEmpty);
    },
  );
}
