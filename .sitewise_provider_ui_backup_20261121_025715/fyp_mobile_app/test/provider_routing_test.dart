import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/core/routing/mobile_role.dart';
import 'package:fyp/presentation/mobile/shell/mobile_navigation.dart';
import 'package:fyp/presentation/mobile/provider/shell/provider_tab_host.dart';
import 'package:fyp/presentation/mobile/start/auth_blocking_views.dart';
import 'package:fyp/presentation/shared/pages/not_found_mobile_page.dart';
import 'package:shared_logic/shared_logic.dart';

/// Regression guards for the shared Owner / Agent (Provider) workspace.
///
/// Two things are pinned here, because both are easy to break silently:
///
/// * the **route contract** — every Provider destination resolves, and each one
///   highlights the tab it belongs to;
/// * the **workspace boundary** — an Entrepreneur cannot open a Provider route
///   and a Provider cannot open an Entrepreneur one, decided by
///   [canEnterMobileRoute] and enforced by [AuthGuard] before the shell is
///   built.
///
/// The screens themselves are covered by `dart analyze` and by the backend
/// tests for the endpoints they call; what matters here is that no role can
/// reach the other workspace's shell.
void main() {
  group('provider role routing', () {
    test('owners and agents share the provider workspace', () {
      expect(mobileHomeRouteFor(AppRole.owner), '/provider');
      expect(mobileHomeRouteFor(AppRole.agent), '/provider');
    });

    test('entrepreneur keeps its own workspace', () {
      expect(mobileHomeRouteFor(AppRole.entrepreneur), '/entrepreneur');
    });

    test('admin has no mobile workspace', () {
      expect(mobileHomeRouteFor(AppRole.admin), isNull);
    });
  });

  group('provider route table', () {
    for (final path in const [
      '/provider',
      '/provider/listings',
      '/provider/performance',
      '/provider/profile',
      '/provider/add-property',
      '/provider/property-detail',
      '/provider/verification',
      '/provider/mfa',
    ]) {
      test('$path resolves', () {
        final route = AppRoutes.onGenerateRoute(RouteSettings(name: path));
        expect(route, isNotNull);
        expect(route!.settings.name, path);
      });
    }

    testWidgets('removed Enquiries and Schedule routes cannot render those '
        'screens', (tester) async {
      // The screens were removed from the workspace; the routes are
      // deliberately unregistered so an old deep link falls through to the
      // catch-all not-found page instead of resurrecting a removed screen.
      // The route's builder is resolved DIRECTLY so the assertion is about
      // the route contract itself, independent of MaterialApp's
      // initial-route plumbing.
      for (final removed in const [
        '/provider/enquiries',
        '/provider/schedule',
      ]) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authNotifierProvider.overrideWith(
                () => _FixedAuthNotifier(
                  _authenticatedAs(AppRole.agent, assurance: 'aal2'),
                ),
              ),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) {
                  final route =
                      AppRoutes.onGenerateRoute(RouteSettings(name: removed))!
                          as MaterialPageRoute<dynamic>;
                  return route.builder(context);
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NotFoundMobilePage), findsOneWidget);
        // And never a removed screen's content.
        expect(find.text('Enquiries'), findsNothing);
        expect(find.text('Schedule'), findsNothing);
      }
    });

    test('the persistent pages map onto their own index', () {
      expect(ProviderTabHost.indexForRoute('/provider'), 0);
      expect(ProviderTabHost.indexForRoute('/provider/listings'), 1);
      // Tasks is the agent's third destination, a page in the same stack.
      expect(ProviderTabHost.indexForRoute('/provider/tasks'), 2);
      expect(ProviderTabHost.indexForRoute('/provider/performance'), 3);
      expect(ProviderTabHost.indexForRoute('/provider/profile'), 4);
      // Add is a persistent page in the SAME IndexedStack, so switching to the
      // shared form never pushes a second full-screen route.
      expect(ProviderTabHost.indexForRoute('/provider/add-property'), 5);
      // An unknown provider path lands on the dashboard, not an arbitrary tab.
      expect(ProviderTabHost.indexForRoute('/provider/property-detail'), 0);
    });

    test('the tab route list is the reverse mapping', () {
      expect(ProviderTabHost.tabRoutes, hasLength(6));
      for (var index = 0; index < ProviderTabHost.tabRoutes.length; index++) {
        expect(
          ProviderTabHost.indexForRoute(ProviderTabHost.tabRoutes[index]),
          index,
        );
      }
    });

    test('dock result commands round-trip to a tab', () {
      for (final route in ProviderTabHost.tabRoutes) {
        expect(providerTabFromResult(providerTabResult(route)), route);
      }
      expect(providerTabFromResult(addPropertyDoneResult), isNull);
      expect(providerTabFromResult(null), isNull);
    });

    test('drill-ins highlight the tab they were opened from', () {
      // Add is a real dock destination now, so the form highlights Add.
      expect(
        parentShellRoute('/provider/add-property'),
        '/provider/add-property',
      );
      // A property is opened from My listings.
      expect(
        parentShellRoute('/provider/property-detail'),
        '/provider/listings',
      );
      // Performance is a Dashboard shortcut, not a tab: Home stays selected.
      expect(parentShellRoute('/provider/performance'), '/provider');
      // Verification and the authenticator step are Profile surfaces.
      expect(parentShellRoute('/provider/verification'), '/provider/profile');
      expect(parentShellRoute('/provider/mfa'), '/provider/profile');
    });

    test('the docks are role-scoped', () {
      // AGENT: Home | Listings | Tasks | Profile.
      expect(
        ProviderTabHost.destinationsFor(AppRole.agent).map((d) => d.route),
        [
          '/provider',
          '/provider/listings',
          '/provider/tasks',
          '/provider/profile',
        ],
      );
      expect(
        ProviderTabHost.destinationsFor(AppRole.agent).map((d) => d.label),
        ['Home', 'Listings', 'Tasks', 'Profile'],
      );
      // An agent is assigned properties rather than creating them, so the
      // create form is no longer an agent destination — while the route itself
      // stays registered for the flows that still resume a draft.
      expect(
        ProviderTabHost.destinationsFor(
          AppRole.agent,
        ).any((d) => d.route == '/provider/add-property'),
        isFalse,
      );
      // OWNER: Home | Properties | Add | Profile. The names differ but the
      // ROUTES are the same shared pages — one listing store, one form, never
      // per-role duplicate screens.
      expect(
        ProviderTabHost.destinationsFor(AppRole.owner).map((d) => d.route),
        [
          '/provider',
          '/provider/listings',
          '/provider/add-property',
          '/provider/profile',
        ],
      );
      expect(
        ProviderTabHost.destinationsFor(AppRole.owner).map((d) => d.label),
        ['Home', 'Properties', 'Add', 'Profile'],
      );
      // Performance must NOT be a dock tab for either role; it stays a stack
      // page reached from the Dashboard.
      for (final role in AppRole.values) {
        expect(
          ProviderTabHost.destinationsFor(
            role,
          ).any((d) => d.route == '/provider/performance'),
          isFalse,
        );
        // The removed Enquiries / Schedule slots must not come back.
        expect(
          ProviderTabHost.destinationsFor(role).any(
            (d) =>
                d.route == '/provider/enquiries' ||
                d.route == '/provider/schedule',
          ),
          isFalse,
        );
      }
      // Tasks is its own dock destination, so the stack highlights itself.
      expect(ProviderTabHost.highlightForStack[2], '/provider/tasks');
      // While the report is open, Home keeps the highlight.
      expect(ProviderTabHost.highlightForStack[3], '/provider');
    });
  });

  group('workspace boundary', () {
    test('an entrepreneur may not enter any provider route', () {
      for (final path in const [
        '/provider',
        '/provider/listings',
        '/provider/tasks',
        '/provider/performance',
        '/provider/profile',
        '/provider/add-property',
        '/provider/verification',
        '/provider/mfa',
      ]) {
        expect(
          canEnterMobileRoute(AppRole.entrepreneur, path),
          isFalse,
          reason: '$path must be closed to an entrepreneur',
        );
      }
    });

    test('a provider may not enter entrepreneur routes', () {
      for (final role in const [AppRole.owner, AppRole.agent]) {
        for (final path in const [
          '/entrepreneur',
          '/entrepreneur/assess',
          '/entrepreneur/spaces',
          '/entrepreneur/favourites',
          '/entrepreneur/recommendations',
          '/entrepreneur/saved',
          '/entrepreneur/profile',
          // The retired management shortcut stays closed to both sides.
          '/entrepreneur/add-property',
        ]) {
          expect(
            canEnterMobileRoute(role, path),
            isFalse,
            reason: '$path must be closed to ${role.name}',
          );
        }
      }
    });

    test('each workspace is open to its own roles', () {
      for (final path in const [
        '/provider',
        '/provider/listings',
        '/provider/tasks',
        '/provider/performance',
        '/provider/add-property',
      ]) {
        expect(canEnterMobileRoute(AppRole.owner, path), isTrue);
        expect(canEnterMobileRoute(AppRole.agent, path), isTrue);
      }
      for (final path in const [
        '/entrepreneur',
        '/entrepreneur/recommendations',
        '/entrepreneur/assessments',
      ]) {
        expect(canEnterMobileRoute(AppRole.entrepreneur, path), isTrue);
      }
    });

    test('shared capture and tour routes stay role-neutral', () {
      // Both workspaces capture 360° media and preview a tour, so these are
      // deliberately not owned by either shell.
      for (final path in const [
        '/owner/capture',
        '/tour-preview',
        '/onboarding',
      ]) {
        expect(mobileWorkspaceForRoute(path), isNull);
        expect(canEnterMobileRoute(AppRole.entrepreneur, path), isTrue);
        expect(canEnterMobileRoute(AppRole.owner, path), isTrue);
        expect(canEnterMobileRoute(AppRole.agent, path), isTrue);
      }
    });
  });

  group('AuthGuard refuses the other workspace', () {
    testWidgets('an entrepreneur opening /provider/listings sees the '
        'mismatch screen, not the shell', (tester) async {
      var built = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(
              () => _FixedAuthNotifier(_authenticatedAs(AppRole.entrepreneur)),
            ),
          ],
          child: MaterialApp(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => AuthGuard(
                access: RouteAccess.workspace,
                routeName: '/provider/listings',
                builder: (_) {
                  built = true;
                  return const Scaffold(body: Text('provider shell'));
                },
              ),
            ),
            initialRoute: '/provider/listings',
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(WorkspaceMismatchView), findsOneWidget);
      expect(find.text('provider shell'), findsNothing);
      expect(
        built,
        isFalse,
        reason: 'the protected page must never be constructed',
      );
    });

    testWidgets('a provider opening /entrepreneur sees the mismatch screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(
              () => _FixedAuthNotifier(_authenticatedAs(AppRole.owner)),
            ),
          ],
          child: MaterialApp(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => AuthGuard(
                access: RouteAccess.workspace,
                routeName: '/entrepreneur/recommendations',
                builder: (_) =>
                    const Scaffold(body: Text('entrepreneur shell')),
              ),
            ),
            initialRoute: '/entrepreneur/recommendations',
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(WorkspaceMismatchView), findsOneWidget);
      expect(find.text('entrepreneur shell'), findsNothing);
    });

    testWidgets('the same account still opens its own workspace', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(
              // An elevated (aal2) session: the guard's mandatory Provider MFA
              // is satisfied, not bypassed.
              () => _FixedAuthNotifier(
                _authenticatedAs(AppRole.agent, assurance: 'aal2'),
              ),
            ),
          ],
          child: MaterialApp(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => AuthGuard(
                access: RouteAccess.workspace,
                routeName: '/provider/listings',
                builder: (_) => const Scaffold(body: Text('provider shell')),
              ),
            ),
            initialRoute: '/provider/listings',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('provider shell'), findsOneWidget);
      expect(find.byType(WorkspaceMismatchView), findsNothing);
    });
  });
}

AuthState _authenticatedAs(AppRole role, {String? assurance}) => AuthState(
  status: AuthStatus.authenticated,
  user: SitewiseUser(
    id: 'user-${role.name}',
    name: 'Test ${role.label}',
    email: 'test@sitewise.my',
    role: role,
    status: 'active',
    location: 'Kuala Lumpur',
    joinedAt: DateTime(2026, 1, 1),
    // The guard requires a verified `aal2` session before painting ANY
    // Provider route (both Owner and Agent). Fixtures that enter the
    // workspace therefore present an elevated session; the guard must never
    // be bypassed in tests, only satisfied.
    assuranceLevel: assurance,
  ),
);

/// Publishes one fixed session and never touches the auth service.
///
/// The real notifier starts a restore in `AuthGuard.initState`; overriding the
/// two entry points keeps the test about the route boundary rather than about
/// Supabase.
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
