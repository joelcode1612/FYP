// UI-only fixtures. Real HTTP/SQL verification is reported separately.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/features/assessment/view/cq_invitations_page.dart';
import 'package:fyp/features/assessment/view/cq_session_page.dart';
import 'package:fyp/features/assessment/view/assessment_live_hold.dart';
import 'package:fyp/features/assessment/view/components/question_option_tile.dart';
import 'package:fyp/features/assessment/viewmodel/cq_view_model.dart';
import 'package:fyp/presentation/mobile/shell/mobile_app_shell.dart';

Map<String, dynamic> fixture() =>
    jsonDecode(
          File(
            '../shared_logic/test/fixtures/cq_session_isolated.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

class FixtureApi extends ApiClient {
  Map<String, dynamic> data;
  final String availability;
  final bool unauthorized, failAnswer;
  int reads = 0;
  final posts = <String>[];
  FixtureApi(
    this.data, {
    this.availability = 'held',
    this.unauthorized = false,
    this.failAnswer = false,
  });

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    reads++;
    if (unauthorized) {
      throw const UnauthorizedFailure('Synthetic expired session.');
    }
    if (path.endsWith('/invitations')) {
      return {
        'contract_version': 'cq-invitations/1',
        'state': availability,
        'invitations': <dynamic>[],
      };
    }
    return data;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    posts.add(path);
    if (path.endsWith('/answers') && failAnswer) {
      throw const NetworkFailure(
        'Synthetic failed request; no answer committed.',
      );
    }
    if (path.endsWith('/withdraw')) {
      data = {
        ...data,
        'status': 'WITHDRAWN',
        'consented': false,
        'next_slot_id': null,
        'presentation': null,
        'can_submit': false,
      };
      return {
        'contract_version': 'cq-withdrawal/1',
        'session_id': data['session_id'],
        'status': 'WITHDRAWN',
      };
    } else if (!path.endsWith('/presentations')) {
      throw StateError('Unexpected mutation in UI test: $path');
    }
    return data;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> questionFixture() {
  final d = fixture();
  d['consented'] = true;
  d['next_slot_id'] = 'Q01';
  final q = d['manifest']['questions'][0] as Map;
  final row = (d['routing'] as List).first as Map;
  d['presentation'] = {
    'display_id': '00000000-0000-4000-8000-000000000001',
    'slot_id': 'Q01',
    'question_id': 'Q01',
    'question_version': q['version'],
    'context_digest': row['context_digest'],
  };
  return d;
}

void main() {
  test(
    'Q14 extension remains isolated-only and cannot decode as production',
    () {
      final d = questionFixture();
      final manifest = d['manifest'] as Map<String, dynamic>;
      final q = Map<String, dynamic>.from(manifest['questions'][3] as Map);
      q.addAll({
        'id': 'Q14',
        'version': '00000000-0000-4000-8000-000000000014',
        'required_for_answer': false,
        'required_for_presentation': true,
        'type': 'single_select',
        'stimulus_text': 'SYNTHETIC ISOLATED GATE FIXTURE',
        'feature_ids': <String>[],
      });
      q['option_version'] = cqDigest([
        for (final code in q['codes'] as List)
          [code, q['labels'][d['locale']][code]],
      ]);
      manifest['test_placement'] = 'isolated-last/1';
      (manifest['questions'] as List).add(q);
      (d['routing'] as List).add({
        ...Map<String, dynamic>.from(d['routing'][3] as Map),
        'slot_id': 'Q14',
        'question_id': 'Q14',
      });
      d['manifest_hash'] = cqDigest(manifest);
      expect(
        CqSession.fromJson(d, allowIsolatedTesting: true).manifest['questions'],
        hasLength(14),
      );
      expect(() => CqSession.fromJson(d), throwsFormatException);
      d['execution_scope'] = 'PRODUCTION';
      d['production_fielding_authorized'] = true;
      expect(
        () => CqSession.fromJson(d, allowIsolatedTesting: true),
        throwsFormatException,
      );
    },
  );

  Future<GlobalKey> open(
    WidgetTester tester,
    FixtureApi api,
    Widget page, {
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (Platform.environment['CQ_V072_EVIDENCE'] != null) {
      await tester.runAsync(() async {
        final fonts = {
          'Archivo': 'assets/fonts/Archivo-Regular.ttf',
          // Flutter's test fallback uses Ahem; use the bundled app font for capture.
          'Ahem': 'assets/fonts/Archivo-Regular.ttf',
          'MaterialIcons':
              r'C:\Users\HP\fvm\versions\3.44.6\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
        };
        for (final entry in fonts.entries) {
          final bytes = await File(entry.value).readAsBytes();
          await (FontLoader(
            entry.key,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      });
    }
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: ProviderScope(
          overrides: [
            cqRepositoryProvider.overrideWithValue(
              ApiCustomerQuestionnaireRepository(
                api,
                allowIsolatedTesting: true,
              ),
            ),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: sitewiseTheme(),
            home: MobileAppShell(
              title: 'Questionnaire',
              currentRoute: '/entrepreneur/assess',
              body: page,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    return boundary;
  }

  Future<void> capture(
    WidgetTester tester,
    GlobalKey boundary,
    String name,
  ) async {
    final out = Platform.environment['CQ_V072_EVIDENCE'];
    if (out == null) return;
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final width in [360.0, 1024.0]) {
    testWidgets('held invitations preserve shell and refresh at width $width', (
      tester,
    ) async {
      final api = FixtureApi(fixture());
      final boundary = await open(
        tester,
        api,
        const CqInvitationsPage(),
        width: width,
      );
      expect(find.text('Questionnaire invitations'), findsOneWidget);
      expect(find.byKey(const Key('cq-invitations-state')), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      expect(find.byType(QuestionOptionTile), findsNothing);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(api.reads, 2);
      expect(api.posts, isEmpty);
      await capture(tester, boundary, 'v072-held-${width.toInt()}');
    });
  }

  testWidgets('empty invitations do not invent an invitation', (tester) async {
    final api = FixtureApi(fixture(), availability: 'empty');
    await open(tester, api, const CqInvitationsPage());
    expect(
      find.text('No authorized questionnaire invitations are available.'),
      findsOneWidget,
    );
    expect(find.text('Start'), findsNothing);
    expect(find.text('Resume'), findsNothing);
    expect(api.posts, isEmpty);
  });

  testWidgets('exact consent text and withdrawal without agreeing', (
    tester,
  ) async {
    final d = fixture();
    final api = FixtureApi(d);
    final boundary = await open(
      tester,
      api,
      CqSessionPage(sessionId: d['session_id']),
    );
    expect(
      find.text(d['manifest']['consent_text'][d['locale']] as String),
      findsOneWidget,
    );
    expect(find.byType(QuestionOptionTile), findsNothing);
    await capture(tester, boundary, 'v072-consent');
    await tester.ensureVisible(find.byKey(const Key('cq-withdraw')));
    await tester.tap(find.byKey(const Key('cq-withdraw')));
    await tester.pumpAndSettle();
    expect(api.posts.single, endsWith('/withdraw'));
    expect(find.byKey(const Key('cq-consent')), findsNothing);
    expect(find.textContaining('Loading your saved'), findsNothing);
    expect(find.byType(QuestionOptionTile), findsNothing);
  });

  testWidgets(
    'exact question/options, selection and failed save do not advance',
    (tester) async {
      final d = questionFixture();
      final api = FixtureApi(d, failAnswer: true);
      final boundary = await open(
        tester,
        api,
        CqSessionPage(sessionId: d['session_id']),
      );
      final q = d['manifest']['questions'][0] as Map;
      expect(find.text(q['wording'][d['locale']] as String), findsOneWidget);
      final tile = find.byKey(const ValueKey('cq-option-LIVE'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pump();
      expect(tester.widget<QuestionOptionTile>(tile).selected, isTrue);
      expect(find.byKey(const Key('cq-slot')), findsOneWidget);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pump();
      await capture(tester, boundary, 'v072-question');
      await tester.ensureVisible(find.byKey(const Key('cq-answer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cq-answer')));
      await tester.pumpAndSettle();
      expect(api.posts.where((p) => p.endsWith('/answers')), hasLength(1));
      expect(find.byKey(const Key('cq-error')), findsOneWidget);
      expect(find.text('Q01'), findsOneWidget);
      expect(api.data['revision'], d['revision']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('withdrawn session never renders new questions or consent', (
    tester,
  ) async {
    final d = fixture()..['status'] = 'WITHDRAWN';
    final api = FixtureApi(d);
    await open(tester, api, CqSessionPage(sessionId: d['session_id']));
    expect(find.text('Participation withdrawn.'), findsOneWidget);
    expect(find.byType(QuestionOptionTile), findsNothing);
    expect(find.byKey(const Key('cq-consent')), findsNothing);
    expect(api.posts, isEmpty);
  });

  testWidgets(
    'expired authentication shows error without a fabricated question',
    (tester) async {
      final d = fixture();
      final api = FixtureApi(d, unauthorized: true);
      await open(tester, api, CqSessionPage(sessionId: d['session_id']));
      expect(find.byKey(const Key('cq-error')), findsOneWidget);
      expect(find.textContaining('Loading your saved'), findsNothing);
      expect(find.byType(QuestionOptionTile), findsNothing);
      expect(api.posts, isEmpty);
    },
  );

  testWidgets('legacy hold screen retains collection restriction', (
    tester,
  ) async {
    final api = FixtureApi(fixture());
    await open(tester, api, const AssessmentLiveHold());
    expect(
      find.text('QUESTIONNAIRE COLLECTION ON HOLD · NO DEMO DATA'),
      findsOneWidget,
    );
    expect(find.byType(QuestionOptionTile), findsNothing);
    expect(api.posts, isEmpty);
    expect(api.reads, 0);
  });
}
