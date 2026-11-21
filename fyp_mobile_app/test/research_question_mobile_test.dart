import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/presentation/mobile/entrepreneur/pages/research_question_mobile_page.dart';
import 'package:shared_logic/shared_logic.dart';

/// The mobile research-question surface.
///
/// Pinned here: the route contract, the argument parsing, and that a target
/// built from PERSISTED ids (assessment / confirmation / objective / revision /
/// context) drives the candidate flow, while a target-less route shows the
/// honest empty state and cannot prepare. The engine itself cannot be reached
/// end-to-end today — the backend runner is `None`, so a real prepare returns
/// 503. The payload-level behaviour (proposal marker, abstention wording,
/// conflict/budget/unavailable mapping) is covered by the shared contract test
/// in `shared_logic` and by the Jaspr widget test, which both drive the SAME
/// parsing and rules code this page uses.
const _assessmentId = '10000000-0000-4000-8000-000000000001';
const _confirmationId = '20000000-0000-4000-8000-000000000002';
const _objectiveId = '30000000-0000-4000-8000-000000000003';
const _contextId = '40000000-0000-4000-8000-000000000004';
const _objectiveText = 'Which rent level is acceptable?';

ResearchQuestionTarget _realTarget({String? contextId = _contextId}) =>
    ResearchQuestionTarget.fromPersistedIds(
      assessmentId: _assessmentId,
      confirmationId: _confirmationId,
      objectiveId: _objectiveId,
      expectedRevision: 3,
      contextId: contextId,
      objectiveText: _objectiveText,
    );

void main() {
  group('research question target', () {
    test('accepts the typed target', () {
      final target = _realTarget();
      expect(ResearchQuestionTarget.fromArguments(target), same(target));
    });

    test('accepts a map carrying every persisted id', () {
      final parsed = ResearchQuestionTarget.fromArguments({
        'assessment': _assessmentId,
        'confirmation': _confirmationId,
        'objective': _objectiveId,
        'revision': 4,
        'context': _contextId,
        'objectiveText': _objectiveText,
      });
      expect(parsed, isNotNull);
      expect(parsed!.assessmentId, _assessmentId);
      expect(parsed.confirmationId, _confirmationId);
      expect(parsed.objectiveId, _objectiveId);
      expect(parsed.expectedRevision, 4);
      expect(parsed.contextId, _contextId);
    });

    test('an incomplete argument is not turned into a target', () {
      expect(ResearchQuestionTarget.fromArguments(null), isNull);
      expect(
        ResearchQuestionTarget.fromArguments({
          'assessment': _assessmentId,
          'objective': _objectiveId,
          'revision': 3,
        }),
        isNull,
        reason: 'no confirmation id means an unconfirmed objective',
      );
      expect(
        ResearchQuestionTarget.fromArguments({
          'assessment': _assessmentId,
          'confirmation': _confirmationId,
          'objective': _objectiveId,
          'revision': '3',
        }),
        isNull,
      );
    });

    test('the persisted-id factory refuses an unconfirmed objective', () {
      expect(
        () => ResearchQuestionTarget.fromPersistedIds(
          assessmentId: _assessmentId,
          confirmationId: '',
          objectiveId: _objectiveId,
          expectedRevision: 3,
        ),
        throwsArgumentError,
      );
    });
  });

  group('route contract', () {
    test('the research-question route resolves and carries the target', () {
      final target = _realTarget();
      final route = AppRoutes.onGenerateRoute(
        RouteSettings(
          name: '/entrepreneur/research-questions',
          arguments: target,
        ),
      );
      expect(route, isNotNull);
      expect(route!.settings.name, '/entrepreneur/research-questions');
      expect(route.settings.arguments, same(target));
    });

    test('it highlights the Assess tab', () {
      expect(
        parentShellRoute('/entrepreneur/research-questions'),
        '/entrepreneur/assess',
      );
    });
  });

  group('screen states', () {
    Widget host(Widget child) =>
        ProviderScope(child: MaterialApp(home: child));

    testWidgets('without an objective it says so and offers no prepare action', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const ResearchQuestionMobilePage(target: null)),
      );
      await tester.pump();

      expect(find.text('No research objective selected'), findsOneWidget);
      expect(
        find.textContaining('Open it from an objective in your M2 assessment'),
        findsOneWidget,
      );
      expect(find.text('Prepare question'), findsNothing);
    });

    testWidgets('without a persisted context the prepare action is inert', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(ResearchQuestionMobilePage(target: _realTarget(contextId: null))),
      );
      await tester.pump();

      expect(find.text('Prepare question'), findsOneWidget);
      expect(
        find.textContaining('A persisted business context is required'),
        findsOneWidget,
      );
      // Tapping must not throw and must not attempt a request: with no
      // context id the handler is a no-op.
      await tester.tap(find.text('Prepare question'));
      await tester.pump();
      expect(find.text('Prepare question'), findsOneWidget);
    });

    testWidgets('navigating with a real target renders the candidate flow', (
      tester,
    ) async {
      await _pumpRoutedApp(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pushNamed(
        '/entrepreneur/research-questions',
        arguments: _realTarget(),
      );
      await tester.pumpAndSettle();

      expect(find.text('No research objective selected'), findsNothing);
      expect(
        find.textContaining('Assessment: $_assessmentId'),
        findsOneWidget,
        reason: 'the screen must identify its assessment',
      );
      expect(find.textContaining('Confirmation: $_confirmationId'), findsOneWidget);
      expect(find.textContaining('Objective text: $_objectiveText'), findsOneWidget);
      expect(find.text('Prepare question'), findsOneWidget);
      expect(
        find.textContaining('No candidate has been prepared'),
        findsOneWidget,
      );
      expect(
        find.textContaining('A persisted business context is required'),
        findsNothing,
      );
    });

    testWidgets('navigating without a target shows the honest empty state', (
      tester,
    ) async {
      await _pumpRoutedApp(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pushNamed('/entrepreneur/research-questions');
      await tester.pumpAndSettle();

      expect(find.text('No research objective selected'), findsOneWidget);
      expect(find.text('Prepare question'), findsNothing);
      expect(find.textContaining('Assessment:'), findsNothing);
    });
  });
}

/// The real route table behind a signed-in entrepreneur. `AuthGuard` is the
/// only indirection: the fake notifier keeps the test about the route argument
/// contract rather than Supabase.
Future<void> _pumpRoutedApp(WidgetTester tester) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      authNotifierProvider.overrideWith(
        () => _FixedAuthNotifier(
          AuthState(
            status: AuthStatus.authenticated,
            user: SitewiseUser(
              id: 'user-entrepreneur',
              name: 'Test Entrepreneur',
              email: 'test@sitewise.my',
              role: AppRole.entrepreneur,
              status: 'active',
              location: 'Kuala Lumpur',
              joinedAt: DateTime(2026, 1, 1),
            ),
          ),
        ),
      ),
    ],
    child: MaterialApp(
      onGenerateRoute: AppRoutes.onGenerateRoute,
      home: const Scaffold(body: Text('home')),
    ),
  ),
);

/// Publishes one fixed session and never touches the auth service.
class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this._state);

  final AuthState _state;

  @override
  AuthState build() => _state;

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}
}
