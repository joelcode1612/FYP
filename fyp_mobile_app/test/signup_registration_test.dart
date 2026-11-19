import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fyp/core/auth/account_purpose.dart';
import 'package:fyp/core/auth/signup_password_policy.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/core/routing/mobile_role.dart';
import 'package:fyp/presentation/mobile/auth/pages/signup_mobile_page.dart';
import 'package:fyp/presentation/mobile/auth/widgets/signup_role_card.dart';
import 'package:fyp/presentation/mobile/auth/widgets/signup_step_indicator.dart';
import 'package:shared_logic/shared_logic.dart';

void main() {
  group('registration password policy', () {
    test('matches the three requirements shown on Step 2', () {
      final rules = SignupPasswordPolicy.evaluate('Passw0rd');
      expect(rules, hasLength(3));
      expect(rules.every((rule) => rule.met), isTrue);
      expect(SignupPasswordPolicy.isValid('Passw0rd'), isTrue);
    });

    test('indicators change dynamically with the typed value', () {
      expect(
        SignupPasswordPolicy.evaluate('short'),
        <({String label, bool met})>[
          (label: 'At least 8 characters', met: false),
          (label: 'Includes a letter (A–Z)', met: true),
          (label: 'Includes a number (0–9)', met: false),
        ],
      );
      expect(SignupPasswordPolicy.isValid('abcdefgh'), isFalse);
      expect(SignupPasswordPolicy.isValid('12345678'), isFalse);
      expect(SignupPasswordPolicy.isValid(''), isFalse);
    });
  });

  group('account purpose', () {
    test('is a preference, never a backend role', () {
      expect(AccountPurpose.values, hasLength(2));
      expect(AccountPurpose.entrepreneur.wireValue, 'entrepreneur');
      expect(AccountPurpose.ownerAgent.wireValue, 'listing_provider');
      expect(AccountPurpose.metadataKey, 'account_purpose');
      // No self-registration path may carry an admin value.
      expect(
        AccountPurpose.values.map((p) => p.wireValue),
        isNot(contains('admin')),
      );
    });
  });

  group('routing', () {
    test('both signup entry points resolve to a public route', () {
      for (final name in <String>['/signup', '/auth']) {
        final route = AppRoutes.onGenerateRoute(
          RouteSettings(
            name: name,
            arguments: name == '/auth' ? 'signUp' : null,
          ),
        );
        expect(route, isA<MaterialPageRoute<dynamic>>());
      }
    });
  });

  group('signup widgets', () {
    testWidgets('the three-stage reference indicator still renders', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SignupStepIndicator(currentStep: 1),
          ),
        ),
      );
      expect(find.text('Account Type'), findsOneWidget);
      expect(find.text('Account Details'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('entrepreneur registration has exactly two steps and no Verify step', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SignupStepIndicator(
              currentStep: 1,
              labels: SignupStepIndicator.entrepreneurLabels,
            ),
          ),
        ),
      );
      expect(find.text('Account Type'), findsOneWidget);
      expect(find.text('Account Details'), findsOneWidget);
      expect(find.text('Verify'), findsNothing);
      expect(find.text('Authenticator'), findsNothing);
      expect(find.text('3'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('the owner/agent third step is MFA, never email verification', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SignupStepIndicator(
              currentStep: 1,
              labels: SignupStepIndicator.providerLabels,
            ),
          ),
        ),
      );
      expect(find.text('Authenticator'), findsOneWidget);
      expect(find.text('Verify'), findsNothing);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('only one role card can be selected at a time', (tester) async {
      AccountPurpose? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: <Widget>[
                  for (final purpose in AccountPurpose.values)
                    SignupRoleCard(
                      icon: Icons.storefront_rounded,
                      title: purpose.label,
                      description: purpose.description,
                      selected: selected == purpose,
                      onTap: () => setState(() => selected = purpose),
                    ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Entrepreneur'), findsOneWidget);
      expect(find.text('Property Owner / Agent'), findsOneWidget);
      await tester.tap(find.text('Property Owner / Agent'));
      await tester.pump();
      expect(selected, AccountPurpose.ownerAgent);
      List<SignupRoleCard> cards() => tester
          .widgetList<SignupRoleCard>(find.byType(SignupRoleCard))
          .toList();
      expect(cards().where((card) => card.selected).length, 1);
      await tester.tap(find.text('Entrepreneur'));
      await tester.pump();
      expect(selected, AccountPurpose.entrepreneur);
      expect(cards().where((card) => card.selected).length, 1);
    });
  });

  test('the public enum has no email-verification stage', () {
    expect(SignupStage.values, <SignupStage>[
      SignupStage.accountType,
      SignupStage.accountDetails,
    ]);
    expect(SignupStage.values.map((s) => s.name), isNot(contains('verify')));
  });

  // -------------------------------------------------------------------------
  // Final role-based authentication flows
  // -------------------------------------------------------------------------
  group('post-authentication landing', () {
    setUp(() => AuthPendingDestination.clear());

    SitewiseUser user(AppRole role, {String? aal}) => SitewiseUser(
      id: 'user-${role.name}',
      name: 'Test ${role.label}',
      email: 'test@sitewise.my',
      role: role,
      status: 'active',
      location: '',
      joinedAt: DateTime(2026, 1, 1),
      assuranceLevel: aal,
    );

    test('an entrepreneur goes straight to its dashboard with no MFA', () {
      final entrepreneur = user(AppRole.entrepreneur, aal: 'aal1');
      expect(requiresStaffMfa(entrepreneur), isFalse);
      expect(authLandingRouteFor(entrepreneur), '/entrepreneur');
      final nav = postAuthNavigation(entrepreneur);
      expect(nav?.route, '/entrepreneur');
      expect(nav?.arguments, isNull);
    });

    test('a property owner must finish MFA before Provider workspace', () {
      final owner = user(AppRole.owner, aal: 'aal1');
      expect(requiresStaffMfa(owner), isTrue);
      expect(authLandingRouteFor(owner), '/provider/mfa');
      final nav = postAuthNavigation(owner);
      expect(nav?.route, '/provider/mfa');
      expect(nav?.arguments, isA<MfaEntryRequest>());
      expect((nav!.arguments! as MfaEntryRequest).destination, '/provider');
    });

    test('an owner with verified aal2 enters Provider without MFA loop', () {
      final owner = user(AppRole.owner, aal: 'aal2');
      expect(requiresStaffMfa(owner), isFalse);
      expect(authLandingRouteFor(owner), '/provider');
      expect(postAuthNavigation(owner)?.route, '/provider');
      expect(postAuthNavigation(owner)?.arguments, isNull);
    });

    test('unknown owner assurance requires MFA', () {
      expect(requiresStaffMfa(user(AppRole.owner)), isTrue);
    });

    test('an agent with aal1 must complete MFA before the dashboard', () {
      final agent = user(AppRole.agent, aal: 'aal1');
      expect(requiresStaffMfa(agent), isTrue);
      expect(authLandingRouteFor(agent), '/provider/mfa');
      final nav = postAuthNavigation(agent);
      expect(nav?.route, '/provider/mfa');
      expect(nav?.arguments, isA<MfaEntryRequest>());
      expect(
        (nav!.arguments! as MfaEntryRequest).destination,
        '/provider',
      );
    });

    test('an agent with an unknown assurance level fails closed to MFA', () {
      expect(requiresStaffMfa(user(AppRole.agent)), isTrue);
    });

    test('an agent at aal2 is not re-prompted for enrollment or verification', () {
      final agent = user(AppRole.agent, aal: 'aal2');
      expect(requiresStaffMfa(agent), isFalse);
      expect(authLandingRouteFor(agent), '/provider');
      expect(postAuthNavigation(agent)?.arguments, isNull);
    });

    test('an administrator keeps the web-only flow', () {
      final admin = user(AppRole.admin, aal: 'aal2');
      expect(authLandingRouteFor(admin), isNull);
      expect(postAuthNavigation(admin), isNull);
    });

    test('an allowed deep link survives sign-in; a foreign one does not', () {
      AuthPendingDestination.save('/provider/listings', null);
      final nav = postAuthNavigation(user(AppRole.agent, aal: 'aal1'));
      expect(
        (nav!.arguments! as MfaEntryRequest).destination,
        '/provider/listings',
      );
      // Consumed exactly once.
      expect(
        postAuthNavigation(user(AppRole.agent, aal: 'aal2'))?.route,
        '/provider',
      );

      AuthPendingDestination.save('/entrepreneur/favourites', null);
      expect(
        postAuthNavigation(user(AppRole.entrepreneur))?.route,
        '/entrepreneur/favourites',
      );
    });

    test('no login decision opens provider verification', () {
      for (final role in AppRole.values) {
        final nav = postAuthNavigation(user(role, aal: 'aal2'));
        expect(nav?.route, isNot('/provider/verification'));
      }
    });
  });
}
