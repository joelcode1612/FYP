import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/config/cq_development_access.dart';
import 'package:fyp/core/config/dev_auth_bypass.dart';
import 'package:fyp/features/assessment/presentation/cq_invitations_page.dart';
import 'package:fyp/features/assessment/presentation/viewmodels/cq_view_model.dart';

class _NoSession extends ApiClient {
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async =>
      throw const UnauthorizedFailure('No authenticated session is available.');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  bool allowed({
    bool debug = true,
    bool bypass = true,
    bool requested = true,
    String base = 'http://127.0.0.1:62403',
    String lab = 'http://127.0.0.1:62403',
    String token = 'test-only',
  }) => CqDevelopmentAccess.permitted(
    debug: debug,
    bypass: bypass,
    requested: requested,
    apiBase: base,
    testBase: lab,
    token: token,
  );

  test(
    'production, missing opt-in and missing credentials deny test composition',
    () {
      expect(allowed(), isTrue);
      expect(allowed(debug: false), isFalse);
      expect(allowed(bypass: false), isFalse);
      expect(allowed(requested: false), isFalse);
      expect(allowed(token: ''), isFalse);
    },
  );
  test(
    'test credentials cannot target public, live-port or mismatched origins',
    () {
      for (final url in [
        'https://sitewise.example',
        'http://127.0.0.1:8090',
        'http://127.0.0.1:8000',
        'http://127.0.0.1:3080',
        'http://name:password@127.0.0.1:62403',
        'http://127.0.0.1:62403/private',
        'http://127.0.0.1:62403?token=anything',
      ]) {
        expect(
          allowed(base: url, lab: url),
          isFalse,
          reason: url,
        );
      }
      expect(allowed(lab: 'http://127.0.0.1:62404'), isFalse);
      expect(allowed(lab: 'not an origin'), isFalse);
    },
  );
  testWidgets(
    'Assess explains missing development session without inventing questionnaires',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cqRepositoryProvider.overrideWithValue(
              ApiCustomerQuestionnaireRepository(_NoSession()),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: CqInvitationsPage())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No authenticated session is available.'), findsNothing);
      expect(
        find.textContaining(
          devAuthBypassEnabled
              ? 'Development access is active'
              : 'Your session has expired',
        ),
        findsOneWidget,
      );
      expect(find.text('Start'), findsNothing);
      expect(find.text('Resume'), findsNothing);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cq-invitations-state')), findsOneWidget);
    },
  );
}
