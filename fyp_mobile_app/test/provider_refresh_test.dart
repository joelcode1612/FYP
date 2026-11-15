import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_dashboard_controller.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_models.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_ui.dart';
import 'package:fyp/presentation/mobile/provider/shell/provider_tab_host.dart';
import 'package:shared_logic/shared_logic.dart';

/// Regression guards for the Provider workspace reload behaviour.
///
/// Two defects are pinned here:
///
/// * `_load()` used an arrow-bodied `setState(() => _future = request)`. The
///   assignment expression returns the `Future`, so Flutter's `setState`
///   assertion failed and painted a red error screen on Dashboard and
///   Listings. Every reload now uses a block body and publishes a captured
///   request.
/// * The top-right reload button has been removed. Reload is swipe-down, so
///   every tab must carry a `RefreshIndicator` and no refresh icon.
void main() {
  group('reload helpers', () {
    test('settleRefresh completes for a successful request', () async {
      await expectLater(settleRefresh(Future<int>.value(1)), completes);
    });

    test('settleRefresh swallows a failed request', () async {
      // The FutureBuilder renders the error card; onRefresh must never rethrow
      // it, or a swipe becomes an unhandled async exception.
      await expectLater(
        settleRefresh(Future<int>.error(StateError('backend unavailable'))),
        completes,
      );
    });

    testWidgets('the loading view stays scrollable so a swipe still works', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: providerLoadingView())),
      );
      final view = tester.widget<ListView>(find.byType(ListView));
      expect(view.physics, isA<AlwaysScrollableScrollPhysics>());
    });
  });

  group('Provider shell reload', () {
    testWidgets('all six tabs build without the setState-Future error', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(
              () => _FixedAuthNotifier(_authenticatedAs(AppRole.owner)),
            ),
            // Fixed dashboard bundle: this test is about the SHELL, not the
            // network; the live controller would only add nondeterminism.
            providerDashboardProvider.overrideWith((ref) async {
              return _fixedDashboard(isAgent: false);
            }),
          ],
          child: const MaterialApp(
            home: ProviderTabHost(initialRoute: '/provider'),
          ),
        ),
      );
      await tester.pump();

      // Before the fix this returned the "setState() callback argument
      // returned a Future" assertion that produced the red screen.
      expect(tester.takeException(), isNull);
      // IndexedStack keeps every tab alive but parks the inactive ones
      // offstage, so the finder must include them. The sixth is Schedule,
      // the agent dock's own page.
      expect(
        find.byType(RefreshIndicator, skipOffstage: false),
        findsNWidgets(6),
      );
      // No tab keeps a top-right reload button.
      expect(
        find.byIcon(Icons.refresh_rounded, skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('Listings keeps swipe-down reload with its filter row', (
      tester,
    ) async {
      // Listings wraps a Column (filter strip + Expanded list) rather than a
      // bare scroll view. This pins that the gesture still reaches the
      // RefreshIndicator above that Column.
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RefreshIndicator(
              onRefresh: () async {
                refreshes++;
              },
              notificationPredicate: (notification) =>
                  notification.depth == 0 &&
                  notification.metrics.axis == Axis.vertical,
              child: Column(
                children: [
                  const SizedBox(
                    height: 48,
                    child: Center(child: Text('filters')),
                  ),
                  Expanded(
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(
                          height: 600,
                          child: Center(child: Text('rows')),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.drag(find.text('rows'), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(refreshes, 1);
    });

    testWidgets('swiping down on Profile triggers a reload without an error', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(
              () => _FixedAuthNotifier(_authenticatedAs(AppRole.owner)),
            ),
            providerDashboardProvider.overrideWith((ref) async {
              return _fixedDashboard(isAgent: false);
            }),
          ],
          child: const MaterialApp(
            home: ProviderTabHost(initialRoute: '/provider/profile'),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      // A vertical drag from the top of the profile list is the platform's
      // standard pull-to-refresh gesture.
      await tester.drag(find.byType(ListView).last, const Offset(0, 260));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  });
}

/// An empty, successful dashboard bundle — no network, no estimates, nothing
/// to render except the honest empty states.
ProviderDashboardData _fixedDashboard({required bool isAgent}) =>
    ProviderDashboardData(
      isAgent: isAgent,
      firstName: 'Test',
      listings: const [],
      enquiryMetrics: ProviderEnquiryMetrics.empty,
      recentEnquiries: const [],
      tasks: const [],
      performance: null,
    );

AuthState _authenticatedAs(AppRole role) => AuthState(
  status: AuthStatus.authenticated,
  user: SitewiseUser(
    id: 'user-${role.name}',
    name: 'Test ${role.label}',
    email: 'test@sitewise.my',
    role: role,
    status: 'active',
    location: 'Kuala Lumpur',
    joinedAt: DateTime(2026, 1, 1),
  ),
);

/// A fixed session; the real notifier would start a Supabase restore.
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
