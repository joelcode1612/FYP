import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/core/routing/mobile_role.dart';
import 'package:fyp/presentation/mobile/provider/shell/provider_tab_host.dart';
import 'package:fyp/presentation/mobile/start/auth_blocking_views.dart';
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
      '/provider/enquiries',
      '/provider/performance',
      '/provider/profile',
      '/provider/schedule',
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

    test('the six stack pages map onto their own index', () {
      expect(ProviderTabHost.indexForRoute('/provider'), 0);
      expect(ProviderTabHost.indexForRoute('/provider/listings'), 1);
      expect(ProviderTabHost.indexForRoute('/provider/enquiries'), 2);
      expect(ProviderTabHost.indexForRoute('/provider/performance'), 3);
      expect(ProviderTabHost.indexForRoute('/provider/profile'), 4);
      expect(ProviderTabHost.indexForRoute('/provider/schedule'), 5);
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

    test('drill-ins highlight the tab they were opened from', () {
      // Add is a real dock destination now, so the form highlights Add.
      expect(parentShellRoute('/provider/add-property'), '/provider/add-property');
      // A property is opened from My listings.
      expect(parentShellRoute('/provider/property-detail'), '/provider/listings');
      // Performance is a Dashboard shortcut, not a tab: Home stays selected.
      expect(parentShellRoute('/provider/performance'), '/provider');
      // Schedule IS a real agent dock tab: it highlights itself.
      expect(parentShellRoute('/provider/schedule'), '/provider/schedule');
      // Verification and the authenticator step are Profile surfaces.
      expect(parentShellRoute('/provider/verification'), '/provider/profile');
      expect(parentShellRoute('/provider/mfa'), '/provider/profile');
    });

    test('the docks are role-scoped', () {
      // AGENT: Home | Listings | Enquiries | Schedule | Profile.
      expect(
        ProviderTabHost.destinationsFor(AppRole.agent).map((d) => d.route),
        [
          '/provider',
          '/provider/listings',
          '/provider/enquiries',
          '/provider/schedule',
          '/provider/profile',
        ],
      );
      expect(
        ProviderTabHost.destinationsFor(AppRole.agent).map((d) => d.label),
        ['Home', 'Listings', 'Enquiries', 'Schedule', 'Profile'],
      );
      // OWNER: Home | Properties | Add | Messages | Profile. The names differ
      // but the ROUTES are the same shared pages — one inbox, one listing
      // store, never per-role duplicate screens.
      expect(
        ProviderTabHost.destinationsFor(AppRole.owner).map((d) => d.route),
        [
          '/provider',
          '/provider/listings',
          '/provider/add-property',
          '/provider/enquiries',
          '/provider/profile',
        ],
      );
      expect(
        ProviderTabHost.destinationsFor(AppRole.owner).map((d) => d.label),
        ['Home', 'Properties', 'Add', 'Messages', 'Profile'],
      );
      // Performance must NOT be a dock tab for either role; it stays a stack
      // page reached from the Dashboard.
      for (final role in AppRole.values) {
        expect(
          ProviderTabHost.destinationsFor(role).any(
            (d) => d.route == '/provider/performance',
          ),
          isFalse,
        );
      }
      // While the report is open, Home keeps the highlight.
      expect(ProviderTabHost.highlightForStack[3], '/provider');
      // The Schedule stack page highlights the Schedule dock slot.
      expect(ProviderTabHost.highlightForStack[5], '/provider/schedule');
    });

    test('a trailing slash still highlights the right tab', () {
      expect(parentShellRoute('/provider/enquiries/'), '/provider/enquiries');
    });
  });

  group('workspace boundary', () {
    test('an entrepreneur may not enter any provider route', () {
      for (final path in const [
        '/provider',
        '/provider/listings',
        '/provider/enquiries',
        '/provider/performance',
        '/provider/profile',
        '/provider/schedule',
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
        '/provider/enquiries',
        '/provider/schedule',
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
      for (final path in const ['/owner/capture', '/tour-preview', '/onboarding']) {
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
                builder: (_) => const Scaffold(body: Text('entrepreneur shell')),
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
              () => _FixedAuthNotifier(_authenticatedAs(AppRole.agent)),
            ),
          ],
          child: MaterialApp(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => AuthGuard(
                access: RouteAccess.workspace,
                routeName: '/provider/enquiries',
                builder: (_) => const Scaffold(body: Text('provider shell')),
              ),
            ),
            initialRoute: '/provider/enquiries',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('provider shell'), findsOneWidget);
      expect(find.byType(WorkspaceMismatchView), findsNothing);
    });
  });
}

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
