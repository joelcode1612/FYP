import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/core/routing/mobile_role.dart';
import 'package:fyp/features/authentication/data/api_staff_onboarding_repository.dart';

void main() {
  test('pending Owner navigation never targets the Provider workspace', () {
    final aal1 = _user(assurance: 'aal1');
    final mfa = postAuthNavigation(aal1);
    expect(mfa?.route, '/provider/mfa');
    expect(mfa?.arguments, isA<MfaEntryRequest>());
    expect(
      (mfa!.arguments as MfaEntryRequest).destination,
      providerOnboardingRoute,
    );

    final onboarding = postAuthNavigation(_user(assurance: 'aal2'));
    expect(onboarding?.route, providerOnboardingRoute);
    expect(authLandingRouteFor(aal1), isNot('/provider'));

    final active = postAuthNavigation(
      _user(status: 'Active', assurance: 'aal2'),
    );
    expect(active?.route, '/provider');
    AuthPendingDestination.clear();
  });

  test('Owner-only routes remain unavailable to Agents', () {
    expect(canEnterMobileRoute(AppRole.owner, '/provider/requests'), isTrue);
    expect(
      canEnterMobileRoute(AppRole.owner, '/provider/add-property'),
      isTrue,
    );
    expect(canEnterMobileRoute(AppRole.agent, '/provider/requests'), isFalse);
    expect(
      canEnterMobileRoute(AppRole.agent, '/provider/add-property'),
      isFalse,
    );
    expect(canEnterMobileRoute(AppRole.owner, '/provider/tasks'), isFalse);
  });

  test('onboarding completion sends only the trusted empty request', () async {
    final client = _RecordingApiClient();
    final repository = ApiStaffOnboardingRepository(client);

    await repository.complete();

    expect(client.postedPath, '/api/v1/staff/onboarding/complete');
    expect(client.postedBody, isEmpty);
  });

  testWidgets('aal2 pending session cannot paint a workspace deep link', (
    tester,
  ) async {
    await _pumpGuard(
      tester,
      user: _user(assurance: 'aal2'),
      requestedRoute: '/provider',
    );

    expect(find.text('PROTECTED WORKSPACE'), findsNothing);
    expect(find.text('ONBOARDING'), findsOneWidget);
  });

  testWidgets('aal1 pending session must pass through MFA before onboarding', (
    tester,
  ) async {
    await _pumpGuard(
      tester,
      user: _user(assurance: 'aal1'),
      requestedRoute: providerOnboardingRoute,
    );

    expect(find.text('PROTECTED WORKSPACE'), findsNothing);
    expect(find.text('MFA'), findsOneWidget);
  });
}

Future<void> _pumpGuard(
  WidgetTester tester, {
  required SitewiseUser user,
  required String requestedRoute,
}) async {
  final container = ProviderContainer(
    overrides: [
      authNotifierProvider.overrideWith(
        () => _RestrictedAuthNotifier(
          AuthState(status: AuthStatus.staffOnboarding, user: user),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        routes: {
          providerOnboardingRoute: (_) =>
              const Scaffold(body: Text('ONBOARDING')),
          '/provider/mfa': (_) => const Scaffold(body: Text('MFA')),
        },
        home: AuthGuard(
          access: RouteAccess.workspace,
          routeName: requestedRoute,
          builder: (_) => const Scaffold(body: Text('PROTECTED WORKSPACE')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

SitewiseUser _user({required String assurance, String status = 'Pending'}) =>
    SitewiseUser(
      id: 'owner-user',
      name: 'Invited Owner',
      email: 'owner@example.test',
      role: AppRole.owner,
      status: status,
      location: '',
      joinedAt: DateTime(2026, 1, 1),
      assuranceLevel: assurance,
    );

class _RestrictedAuthNotifier extends AuthNotifier {
  _RestrictedAuthNotifier(this.initial);

  final AuthState initial;

  @override
  AuthState build() => initial;

  @override
  Future<void> start() async {}
}

class _RecordingApiClient implements ApiClient {
  String? postedPath;
  Map<String, dynamic>? postedBody;

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    postedPath = path;
    postedBody = body;
    return const {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
