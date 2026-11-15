import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/features/assessment/view/cq_invitations_page.dart';
import 'package:fyp/features/assessment/viewmodel/cq_view_model.dart';

class _InvitationApi extends ApiClient {
  final Map<String, dynamic> session;
  final bool held, resume;
  final posts = <Map<String, dynamic>>[];
  int reads = 0;
  _InvitationApi(this.session, {this.held = false, this.resume = false});

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v1/cq/invitations') {
      return {
        'contract_version': 'cq-invitations/1',
        'state': held ? 'held' : 'ready',
        'invitations': held
            ? []
            : [
                {
                  'execution_scope': 'ISOLATED_TEST',
                  'production_fielding_authorized': false,
                  'campaign_id': session['campaign_id'],
                  'release_id': session['release_id'],
                  'manifest_hash': session['manifest_hash'],
                  'title': 'Explicit test fixture',
                  'session_id': resume ? session['session_id'] : null,
                },
              ],
      };
    }
    expect(path, '/api/v1/cq/sessions/${session['session_id']}');
    reads++;
    return session;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    expect(path, '/api/v1/cq/sessions');
    posts.add(Map<String, dynamic>.from(body));
    return session;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Map<String, dynamic> fixture() =>
      jsonDecode(
            File(
              '../shared_logic/test/fixtures/cq_delivery_retry.json',
            ).readAsStringSync(),
          )['before']
          as Map<String, dynamic>;

  Future<void> open(WidgetTester tester, _InvitationApi api) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cqRepositoryProvider.overrideWithValue(
            ApiCustomerQuestionnaireRepository(api, allowIsolatedTesting: true),
          ),
        ],
        child: MaterialApp(
          home: const Scaffold(body: CqInvitationsPage()),
          onGenerateRoute: (settings) {
            expect(settings.name, AppRoutes.assessmentQuestionnaire);
            expect(settings.arguments, api.session['session_id']);
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) =>
                  const Scaffold(body: Text('Existing session route')),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('new invitation starts in English without a BM language picker', (
    tester,
  ) async {
    final englishOnly = fixture();
    final manifest = englishOnly['manifest'] as Map<String, dynamic>;
    manifest['locales'] = ['EN'];
    (manifest['consent_text'] as Map).remove('BM');
    for (final q in manifest['questions'] as List) {
      (q['wording'] as Map).remove('BM');
      (q['labels'] as Map).remove('BM');
    }
    for (final s in (manifest['stimuli'] as Map).values) {
      (s['text'] as Map).remove('BM');
    }
    englishOnly['manifest_hash'] = cqDigest(manifest);
    final api = _InvitationApi(englishOnly);
    await open(tester, api);
    expect(find.text('Bahasa Melayu'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(api.posts.single, {
      'campaign_id': api.session['campaign_id'],
      'manifest_hash': api.session['manifest_hash'],
      'locale': 'EN',
    });
    expect(find.text('Existing session route'), findsOneWidget);
  });

  testWidgets('held availability stays held without inventing an invitation', (
    tester,
  ) async {
    final api = _InvitationApi(fixture(), held: true);
    await open(tester, api);
    expect(
      find.textContaining('held pending scientific review'),
      findsOneWidget,
    );
    expect(find.text('Start'), findsNothing);
    expect(api.posts, isEmpty);
  });

  testWidgets(
    'resume keeps the existing versioned session without creating or relocalizing it',
    (tester) async {
      final old = fixture()..['locale'] = 'BM';
      final api = _InvitationApi(old, resume: true);
      await open(tester, api);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      expect(api.reads, 1);
      expect(api.session['locale'], 'BM');
      expect(find.text('Existing session route'), findsOneWidget);
    },
  );
}
