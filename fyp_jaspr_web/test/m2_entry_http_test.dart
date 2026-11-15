// Real Jaspr controls -> existing WebApiClient -> private signed JWT -> FastAPI
// -> disposable PostgreSQL. This is not browser or real-Supabase acceptance.
import 'dart:convert';
import 'dart:io';
import 'package:jaspr/dom.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/components/m2_entry_panel.dart';
import 'package:sitewise_jaspr_web/components/m2_activity_panel.dart';
import 'package:sitewise_jaspr_web/pages/entrepreneur/confirmed_business_review_page.dart';
import 'package:sitewise_jaspr_web/data/auth_service.dart';
import 'package:sitewise_jaspr_web/data/app_locator.dart';
import 'package:sitewise_jaspr_web/data/web_api_client.dart';
import 'package:shared_logic/shared_logic.dart';

class RecordingM2Client extends ApiClient {
  final delegate = const WebApiClient();
  final calls = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    final result = await delegate.get(path, query: query);
    calls.add({'method': 'GET', 'path': path, 'query': query, 'success': true});
    return result;
  }

  @override
  Future<Map<String, dynamic>> put(
    String path,
    Map<String, dynamic> body,
  ) async {
    final result = await delegate.put(path, body);
    calls.add({'method': 'PUT', 'path': path, 'body': body, 'success': true});
    return result;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final result = await delegate.post(path, body);
    calls.add({'method': 'POST', 'path': path, 'body': body, 'success': true});
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected operation');
}

void main() {
  final id = Platform.environment['PART_TWO_M2_ID'];
  setUp(() {
    if (id == null) return;
    WebAuth.installServerSession({
      'sitewise_token': Platform.environment['PART_TWO_M2_TOKEN']!,
      'sitewise_session': base64Url.encode(
        utf8.encode(
          jsonEncode({
            'user_id': Platform.environment['PART_TWO_ACTOR'],
            'role': 'entrepreneur',
            'name': 'Private development identity',
          }),
        ),
      ),
    });
  });
  testComponents(
    'typed business context controls reuse an actual persisted packet without research activation',
    (tester) async {
      final mid = Platform.environment['V13_CONTEXT_ASSESSMENT']!,
          cid = Platform.environment['V13_CONTEXT_CONFIRMATION']!;
      tester.pumpComponent(
        BusinessContextActions(
          assessmentId: mid,
          confirmationId: cid,
          revision: 3,
        ),
      );
      Future<void> click(String text) async {
        await tester.click(
          find.ancestor(of: find.text(text), matching: find.tag('button')),
        );
        for (var i = 0; i < 35; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      }

      await click('Check business context status');
      expect(
        find.text(
          'BCB PERSISTED · revision 3 · attempts 1 · reason Not recorded · source revision current. Latest snapshot only, not attempt history.',
        ),
        findsOneComponent,
      );
      await click('Build business context');
      expect(
        find.text(
          'Business context persisted. Research authorization remains separate.',
        ),
        findsOneComponent,
      );
      final packet = await AppLocator.m2.readContext(
        mid,
        cid,
        3,
        Platform.environment['V13_CONTEXT_ID']!,
      );
      expect(packet.data['qj_execution_authorized'], false);
      expect(packet.data['qg_execution_authorized'], false);
    },
    skip: Platform.environment['V13_CONTEXT_ID'] == null,
  );

  testComponents(
    'explicit uncertainty is saved once and missing BCB authority remains a durable hold',
    (tester) async {
      var draft = await AppLocator.m2.create(
        (await AppLocator.m2.instruments()).first['id'] as String,
      );
      draft = await AppLocator.m2.save(
        draft,
        'M2-01',
        'ANSWERED',
        'SYNTHETIC_A',
      );
      draft = await AppLocator.m2.save(draft, 'M2-05', 'NOT_DECIDED', null);
      await AppLocator.m2.evaluate(draft);
      await AppLocator.m2.review(draft);
      final confirmation = await AppLocator.m2.confirm(draft, []),
          cid = confirmation['id'] as String;
      tester.pumpComponent(
        BusinessContextActions(
          assessmentId: draft.id,
          confirmationId: cid,
          revision: draft.revision,
        ),
      );
      await tester.pump();
      (find.byType(textarea).evaluate().single.component as textarea).onInput!(
        'Synthetic uncertainty separately confirmed by the test actor.',
      );
      await tester.pump();
      Future<void> click(String text) async {
        await tester.click(
          find.ancestor(of: find.text(text), matching: find.tag('button')),
        );
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      }

      await click('Confirm separate uncertainty');
      final history = await AppLocator.m2.activity(draft.id);
      final uncertainty = (history['events'] as List)
          .where((e) => e['kind'] == 'UNCERTAINTY_CONFIRMED')
          .single;
      expect(
        find.text('Separate uncertainty saved: ${uncertainty['event_id']}'),
        findsOneComponent,
      );
      await click('Confirm separate uncertainty');
      expect(
        ((await AppLocator.m2.activity(draft.id))['events'] as List).where(
          (e) => e['kind'] == 'UNCERTAINTY_CONFIRMED',
        ),
        hasLength(1),
      );
      await click('Build business context');
      expect(
        find.text(
          'Business context persisted. Research authorization remains separate.',
        ),
        findsNothing,
      );
      final status = await AppLocator.m2.contextStatus(
        draft.id,
        cid,
        draft.revision,
      );
      expect(status['status'], 'HELD');
      await click('Check business context status');
      expect(
        find.text(
          'BCB HELD · revision ${draft.revision} · attempts 1 · reason ${status['last_code']} · source revision current. Latest snapshot only, not attempt history.',
        ),
        findsOneComponent,
      );
      final out = Platform.environment['M2_BCB_EVIDENCE'];
      if (out != null)
        File('$out/v13_uncertainty_http.json').writeAsStringSync(
          jsonEncode({
            'assessment_id': draft.id,
            'confirmation_id': cid,
            'uncertainty_id': uncertainty['event_id'],
            'revision': draft.revision,
            'bcb_status': status['status'],
            'scope': 'PRIVATE_SYNTHETIC_ONLY',
          }),
        );
    },
    skip: id == null,
  );
  testComponents(
    'open and save the initial M2 without entrepreneur confirmation',
    (tester) async {
      tester.pumpComponent(M2EntryPanel(assessmentId: id!));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
        if (find.text('M2-04').evaluate().isNotEmpty) break;
      }
      expect(find.text('Café planning questionnaire'), findsOneComponent);
      expect(find.text('M2 binding required'), findsNothing);
      await tester.click(
        find.ancestor(of: find.text('M2-04'), matching: find.tag('button')),
      );
      await tester.pump();
      final editor =
          find.byType(textarea).evaluate().single.component as textarea;
      editor.onInput!('Saved from actual Jaspr M2 controls.');
      await tester.pump();
      await tester.click(
        find.ancestor(
          of: find.text('Save answer'),
          matching: find.tag('button'),
        ),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
        if (find.text('Answer saved at revision 1.').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.text('Answer saved at revision 1.'), findsOneComponent);
      final saved = await AppLocator.m2.read(id);
      expect(
        saved.answers['M2-04']['value_json'],
        'Saved from actual Jaspr M2 controls.',
      );
      expect(saved.data['assessment']['confirmed_revision'], isNull);
    },
    skip: id == null,
  );
  testComponents(
    'activity loads actual saved answer event before confirmation',
    (tester) async {
      tester.pumpComponent(M2ActivityPanel(assessmentId: id!));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
        if (find.text('ANSWER_SAVED').evaluate().isNotEmpty) break;
      }
      expect(find.text('ANSWER_SAVED').evaluate(), isNotEmpty);
      expect(find.text('Activity Timeline (2)'), findsOneComponent);
      expect(find.text('Workflow history coverage'), findsOneComponent);
      expect(find.text('Engine / Module'), findsOneComponent);
      expect(find.text('Activity Details'), findsOneComponent);
      expect(find.text('Activity history unavailable'), findsNothing);
      final history = await AppLocator.m2.activity(id);
      expect(history['history_extension'], 'workflow-history-metadata/1');
      expect(history['authorization_decisions_included'], false);
      expect((history['events'] as List).map((e) => e['kind']).toSet(), {
        'ASSESSMENT_CREATED',
        'ANSWER_SAVED',
      });
      expect(jsonEncode(history).contains('value_json'), false);
    },
    skip: id == null,
  );
  testComponents(
    'real HTTP missing source keeps history unavailable and hides prior rows',
    (tester) async {
      tester.pumpComponent(
        const M2ActivityPanel(
          assessmentId: '00000000-0000-4000-8000-000000000099',
        ),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
        if (find
                .text('Activity Timeline — unavailable')
                .evaluate()
                .isNotEmpty &&
            find
                .text(
                  'Saved activity could not be loaded from the current service. No substitute activity records are shown.',
                )
                .evaluate()
                .isNotEmpty)
          break;
      }
      expect(find.text('Activity Timeline — unavailable'), findsOneComponent);
      expect(
        find
            .text(
              'Saved activity could not be loaded from the current service. No substitute activity records are shown.',
            )
            .evaluate(),
        isNotEmpty,
      );
      expect(find.text('Activity Timeline (0)'), findsNothing);
      expect(find.text('ANSWER_SAVED'), findsNothing);
    },
    skip: id == null,
  );
  testComponents(
    'submit pending M2 input through real HTTP, review findings without reevaluation, then confirm',
    (tester) async {
      final original = AppLocator.m2, recording = RecordingM2Client();
      AppLocator.m2 = ApiM2Repository(recording);
      try {
        final instruments = await AppLocator.m2.instruments();
        var draft = await AppLocator.m2.create(
          instruments.first['id'] as String,
        );
        draft = await AppLocator.m2.save(
          draft,
          'M2-01',
          'ANSWERED',
          'SYNTHETIC_A',
        );
        draft = await AppLocator.m2.save(draft, 'M2-05', 'NOT_DECIDED', null);
        expect(
          (await AppLocator.m2.worksheet(draft))['evaluation_state'],
          'NOT_EVALUATED',
        );
        tester.pumpComponent(M2EntryPanel(assessmentId: draft.id));
        Future<void> settle() async {
          for (var i = 0; i < 45; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
        }

        Future<void> click(String label) async {
          await tester.click(
            find.ancestor(of: find.text(label), matching: find.tag('button')),
          );
          await settle();
        }

        await settle();
        await click('M2-04');
        (find.byType(textarea).evaluate().single.component as textarea)
            .onInput!('We guarantee profit.');
        await tester.pump();
        expect(
          recording.calls.where((c) => c['path'].endsWith('/bdj/evaluate')),
          isEmpty,
        );
        await click('Submit answers for BDJ review');
        expect(find.text('Business description review'), findsOneComponent);
        final submitted = await AppLocator.m2.read(draft.id);
        expect(submitted.revision, 3);
        expect(
          submitted.answers['M2-04']['value_json'],
          'We guarantee profit.',
        );
        await click('Keep my original answer');
        expect(
          recording.calls
              .where((c) => c['path'].endsWith('/bdj/evaluate'))
              .length,
          1,
        );
        await click('Record that I reviewed this revision');
        await click('Confirm this business information');
        expect(
          find.text('Your confirmation snapshot was saved.'),
          findsOneComponent,
        );
        final confirmed = await AppLocator.m2.read(draft.id);
        expect(confirmed.data['assessment']['confirmed_revision'], 3);
        final output = Platform.environment['M2_BCB_EVIDENCE'];
        if (output != null) {
          File('$output/jaspr_submission_http.json').writeAsStringSync(
            jsonEncode({
              'assessment_id': draft.id,
              'revision': 3,
              'scope': 'JASPR_COMPONENT_REAL_HTTP_PRIVATE_POSTGRES',
              'production_acceptance': false,
              'calls': recording.calls,
            }),
          );
        }
      } finally {
        AppLocator.m2 = original;
      }
    },
    skip: id == null,
  );
}
