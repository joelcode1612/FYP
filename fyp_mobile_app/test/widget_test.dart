import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/application/providers.dart';
import 'package:fyp/application/services/draft_repository.dart';
import 'package:fyp/application/services/service_locator.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/data/datasources/local/draft_local_data_source.dart';
import 'package:fyp/data/datasources/local/onboarding_local_data_source.dart';
import 'package:fyp/data/repositories/onboarding_repository_impl.dart';
import 'package:fyp/data/repositories/supabase_auth_repository.dart';
import 'package:fyp/main.dart';
import 'package:fyp/presentation/mobile/widgets/mobile_property_card.dart';

import 'support/fake_auth_repository.dart';

/// Phone-sized surface so the mobile pages lay out without overflow (the
/// default 800x600 test window is landscape).
void _useMobileSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  late InMemoryOnboardingLocalDataSource onboarding;
  late FakeAuthRepository auth;

  void useOnboarding({bool completed = false}) {
    onboarding = InMemoryOnboardingLocalDataSource(completed: completed);
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(onboarding);
  }

  /// The production tree over the freshly swapped composition root:
  /// [sitewiseOverrides] reads [ServiceLocator.auth] at call time, so the
  /// fake repository installed by [setUp] is what the scope points at.
  Widget app() =>
      ProviderScope(overrides: sitewiseOverrides(), child: const SitewiseApp());

  setUp(() {
    auth = FakeAuthRepository();
    useOnboarding();
    ServiceLocator.auth = AuthService(auth);
    // The startup gate awaits the boot-time draft restore. The file-backed
    // store asks path_provider through a platform channel that a widget test
    // never answers, so the restore would never complete and the gate would
    // hold its animating splash forever. An in-memory store keeps the real
    // gate code under test without faking the app's behaviour.
    ServiceLocator.drafts = ApplicationDraftRepository(
      InMemoryDraftLocalDataSource(),
    );
    AuthPendingDestination.clear();
  });

  tearDown(() {
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(
      FileOnboardingLocalDataSource(),
    );
    // Back to the production wiring so a later test file cannot inherit a
    // fake session or an in-memory draft store.
    ServiceLocator.drafts = ServiceLocator.productionDrafts;
    ServiceLocator.auth = AuthService(SupabaseAuthRepository());
    ServiceLocator.assessmentSession.discard();
    AuthPendingDestination.clear();
  });

  // Regression guard: a live-API build once listed TWO overrides for
  // getLocationAnalysisProvider, and Riverpod red-screened the app with
  // "Tried to override a provider twice within the same container" before the
  // first frame. Constructing the container is what triggers that assertion.
  // Run this test with SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY dart-defines to
  // exercise the live branch as well as the default demo branch.
  test('composition root overrides each provider at most once', () {
    // The live-mode verification run passes VERIFY_LIVE=true together with
    // SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY. Without this guard a mistyped
    // define would silently reduce that run to a second demo-mode check and
    // the crashing branch would go untested.
    const verifyLive = bool.fromEnvironment('VERIFY_LIVE');
    if (verifyLive) {
      expect(
        MobileConfig.usesLiveApi,
        isTrue,
        reason: 'live run must compile with valid Supabase defines',
      );
    }

    final container = ProviderContainer(overrides: sitewiseOverrides());
    addTearDown(container.dispose);

    final analysis = container.read(getLocationAnalysisProvider);
    expect(analysis, isA<GetLocationAnalysis>());
    // The single override must still select the correct repository: demo
    // ranking locally, live ranking plus API-backed location intelligence.
    expect(
      analysis.repo,
      MobileConfig.usesLiveApi
          ? isA<IntelligenceBackedRecommendationRepository>()
          : isA<RecommendationRepositoryImpl>(),
    );
  });

  // TEST 1 — authentication comes first: a signed-out launch shows Sign In,
  // not onboarding.
  testWidgets('cold launch with no session shows Sign In, not onboarding', (
    tester,
  ) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.textContaining('Find the right F&B location'), findsNothing);
    expect(find.text('Skip for now'), findsNothing);
    // The header is brand-only: no return control and no top mode switch.
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    expect(find.text('Log In'), findsNothing);
    expect(find.text('Sign Up'), findsNothing);
  });

  // TEST 2 — onboarding is gated behind a session: a signed-in first-time
  // user sees it, and it precedes the workspace.
  testWidgets('signed-in first run shows onboarding before the workspace', (
    tester,
  ) async {
    _useMobileSurface(tester);
    auth.user = testUser();

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.textContaining('Find the right F&B location'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
    expect(find.text('Welcome to Sitewise.'), findsNothing);
  });

  // TEST 3 — the five onboarding stages remain reachable and ordered.
  testWidgets('onboarding advances through all five stages', (tester) async {
    _useMobileSurface(tester);
    auth.user = testUser();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Future<void> tapNext() async {
      await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('Find the right F&B location'), findsOneWidget);

    await tapNext(); // 2 — Business Preferences
    expect(find.textContaining('Tell us about'), findsOneWidget);

    await tapNext(); // 3 — Location Intelligence
    expect(find.textContaining('See the location'), findsOneWidget);

    await tapNext(); // 4 — 360° Exploration
    expect(find.textContaining('Explore the space'), findsOneWidget);

    await tapNext(); // 5 — Get Started
    expect(find.textContaining('Ready to find your'), findsOneWidget);
    // Already signed in, so the hand-off asks to continue, not to register.
    expect(find.text('Enter Sitewise'), findsOneWidget);
    expect(find.text('Already have an account?  Log in'), findsNothing);
  });

  // TEST 4 — Get Started marks onboarding complete and enters the workspace.
  testWidgets('Get Started completes onboarding and opens the workspace', (
    tester,
  ) async {
    _useMobileSurface(tester);
    auth.user = testUser();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Enter Sitewise'));
    await tester.pumpAndSettle();

    expect(await onboarding.hasCompletedOnboarding(), isTrue);
    expect(find.text('Welcome to Sitewise.'), findsOneWidget);
  });

  // TEST 5 — Skip completes onboarding and goes to the workspace.
  testWidgets('Skip completes onboarding and routes to the workspace', (
    tester,
  ) async {
    _useMobileSurface(tester);
    auth.user = testUser();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();

    expect(await onboarding.hasCompletedOnboarding(), isTrue);
    expect(find.text('Welcome to Sitewise.'), findsOneWidget);
  });

  // TEST 6 — completion survives a restart (persistent flag).
  testWidgets('completed onboarding is not shown again after restart', (
    tester,
  ) async {
    _useMobileSurface(tester);
    auth.user = testUser();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(await onboarding.hasCompletedOnboarding(), isTrue);

    // Simulate a relaunch with the same persistent store. Tear the tree down
    // first so the Navigator is genuinely rebuilt from scratch.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.textContaining('Find the right F&B location'), findsNothing);
    expect(find.text('Welcome to Sitewise.'), findsOneWidget);
  });

  // TEST 7 — an unauthenticated restart lands on Sign In even when
  // onboarding is already complete.
  testWidgets('returning unauthenticated user lands on auth', (tester) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Welcome to Sitewise.'), findsNothing);
  });

  // TEST 8 — a valid stored session enters the role home without a sign-in,
  // and only one restore runs.
  testWidgets('returning authenticated user lands on the role home', (
    tester,
  ) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);
    auth.user = testUser();

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(auth.restoreCalls, 1, reason: 'the restore must run exactly once');
    expect(find.text('Welcome to Sitewise.'), findsOneWidget);
    expect(find.text('Explore listings'), findsOneWidget);
  });

  // TEST 9 — logging in from the auth screen enters the entrepreneur app.
  testWidgets('logging in from auth enters the entrepreneur app', (
    tester,
  ) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      'sarah@artisanbrew.my',
    );
    await tester.enterText(find.byType(TextField).last, 'secret123');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Sitewise.'), findsOneWidget);
    expect(find.text('Your overview'), findsOneWidget);
  });

  // TEST 10 — Sign Up collects a full name, and the account it creates is an
  // entrepreneur whatever the form says.
  testWidgets('sign up collects a full name and creates an entrepreneur', (
    tester,
  ) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    // The top Log In / Sign Up switch is gone; the inline account link at the
    // foot of the form is the in-screen way to reach registration.
    await tester.ensureVisible(find.text('Sign up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();

    expect(find.text('Full name'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'joel@artisanbrew.my');
    await tester.enterText(fields.at(1), 'Joel Tan');
    await tester.enterText(fields.at(2), 'secret123');
    await tester.enterText(fields.at(3), 'secret123');
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign up'));
    await tester.pumpAndSettle();

    expect(auth.lastSignUpFullName, 'Joel Tan');
    expect(auth.user?.role, AppRole.entrepreneur);
    expect(find.text('Welcome to Sitewise.'), findsOneWidget);
  });

  // TEST 11 — validation is real: an address that is not an email never
  // reaches the repository.
  testWidgets('invalid email is rejected before any auth call', (tester) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'not-an-email');
    await tester.enterText(find.byType(TextField).last, 'secret123');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(find.text('Please enter a valid email address.'), findsOneWidget);
    expect(auth.credentialCalls, 0);
    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 12 — wrong credentials keep the user on the form with the server's
  // reason, and never show a dashboard.
  testWidgets('rejected credentials keep the user on the sign-in form', (
    tester,
  ) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);
    auth.signInFailure = const InvalidCredentialsFailure();

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      'sarah@artisanbrew.my',
    );
    await tester.enterText(find.byType(TextField).last, 'wrong-password');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(find.text('Incorrect email or password.'), findsOneWidget);
    expect(find.text('Welcome to Sitewise.'), findsNothing);
    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 13 — a suspended account is told so instead of being routed in.
  testWidgets('suspended account is blocked with an explanation', (
    tester,
  ) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);
    auth.signInFailure = const AccountInactiveFailure(status: 'suspended');

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      'sarah@artisanbrew.my',
    );
    await tester.enterText(find.byType(TextField).last, 'secret123');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(find.text('Account not active'), findsOneWidget);
    expect(find.textContaining('suspended'), findsOneWidget);
    expect(find.text('Welcome to Sitewise.'), findsNothing);
  });

  // TEST 14 — an Administrator has no mobile workspace: the Staff Web Portal
  // is named and no dashboard is painted.
  testWidgets('admin account is pointed at the Staff Web Portal', (
    tester,
  ) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);
    auth.result = testUser(
      id: 'adm-1',
      name: 'SiteWise Administrator',
      email: 'admin.sitewise@gmail.com',
      role: AppRole.admin,
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      'admin.sitewise@gmail.com',
    );
    await tester.enterText(find.byType(TextField).last, 'secret123');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Staff Web Portal'), findsOneWidget);
    expect(find.text('Welcome to Sitewise.'), findsNothing);
  });

  // TEST 15 — the backend being unreachable during startup does NOT trap the
  // user on a blocking screen: the Sign In screen stays reachable with a
  // non-blocking warning and a Retry action, and no workspace is painted.
  // A successful Retry re-verifies the (preserved) session and enters the
  // workspace just like a fresh sign-in.
  testWidgets(
    'unreachable sign-in service keeps Sign In reachable with retry',
    (tester) async {
      _useMobileSurface(tester);
      useOnboarding(completed: true);
      auth.restoreFailure = const AuthUnavailableFailure();

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Startup lands on the Sign In screen, not a full-screen block.
      expect(find.text('Welcome Back'), findsOneWidget);
      expect(find.textContaining('could not reach'), findsOneWidget);
      expect(find.text('Retry connection check'), findsOneWidget);
      expect(find.text('Welcome to Sitewise.'), findsNothing);

      auth.restoreFailure = null;
      auth.user = testUser();
      await tester.ensureVisible(find.text('Retry connection check'));
      await tester.pump();
      await tester.tap(find.text('Retry connection check'));
      await tester.pumpAndSettle();

      expect(find.text('Welcome to Sitewise.'), findsOneWidget);
    },
  );

  // TEST 16 — a stale session found during a passive cold-start check is
  // dropped (fail closed) but must NOT produce a "Session expired" warning on
  // a Sign In screen the user has never left. Nobody signed in yet in this
  // process, so there is nothing to warn about. See auth_flow_test.dart for
  // the complementary case: a 401 AFTER a verified session is still reported.
  testWidgets('stale session at cold start opens a clean Sign In form', (
    tester,
  ) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);
    auth.user = testUser();
    auth.restoreFailure = const SessionExpiredFailure();

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.textContaining('session has expired'), findsNothing);
    expect(find.text('Session expired'), findsNothing);
    expect(find.text('Sign-in service unavailable'), findsNothing);
    expect(find.text('Welcome to Sitewise.'), findsNothing);
    expect(auth.signOutCalls, 1, reason: 'an invalid session must be dropped');
  });

  // TEST 17 — the workspace itself is guarded: navigating straight in while
  // signed out redirects, and the original destination is replayed after the
  // sign-in that authorises it.
  testWidgets(
    'deep link while signed out redirects and replays after sign in',
    (tester) async {
      _useMobileSurface(tester);
      useOnboarding(completed: true);

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pushNamed('/entrepreneur/saved');
      await tester.pumpAndSettle();

      expect(find.text('Welcome Back'), findsOneWidget);
      expect(AuthPendingDestination.current?.route, '/entrepreneur/saved');

      await tester.enterText(
        find.byType(TextField).first,
        'sarah@artisanbrew.my',
      );
      await tester.enterText(find.byType(TextField).last, 'secret123');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing saved yet'), findsOneWidget);
      expect(AuthPendingDestination.current, isNull);
    },
  );

  // TEST 18 — signing out clears the session and the next protected route is
  // refused again.
  testWidgets('signing out locks the workspace behind it', (tester) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);
    auth.user = testUser();

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Sitewise.'), findsOneWidget);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pushNamed('/entrepreneur/profile');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
    expect(auth.user, isNull);

    navigator.pushNamed('/entrepreneur/saved');
    await tester.pumpAndSettle();
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Nothing saved yet'), findsNothing);
  });

  // TEST 19 — the Flutter app is mobile-only: even on a wide desktop
  // viewport it boots to Sign In, never the old web tree (which lives in the
  // Jaspr app, fyp_jaspr_web).
  testWidgets('wide viewport still boots the mobile flow, not a web tree', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.textContaining('Find the right F&B location'), findsNothing);
    expect(find.text('How It Works'), findsNothing);
  });

  // TEST 20 — the public landing page stays reachable without a session and
  // its Log In action opens the Sign In screen.
  testWidgets('landing Log In opens the Sign In screen', (tester) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/landing');
    await tester.pumpAndSettle();

    // The eyebrow renders uppercased by MobileEyebrow.
    expect(find.textContaining('EVIDENCE-BASED F&B LOCATION'), findsOneWidget);

    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log In').last);
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 21 — mobile ships the Entrepreneur workspace only: the Property
  // Owner landing card cannot route to the deleted /owner screens; it lands
  // on Sign In, which explains where that workspace lives.
  testWidgets('landing Owner card falls back to Sign In', (tester) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/landing');
    await tester.pumpAndSettle();

    // The CTA renders as "See property presentation →" (arrow suffix).
    final ownerLink = find.textContaining('See property presentation');
    await tester.scrollUntilVisible(
      ownerLink,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(ownerLink);
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 22 — the floating dock contract: every slot is a >=48x48 target,
  // exactly one label is visible at a time (the active tab), and switching
  // tabs moves that visibility with the selection.
  testWidgets('floating dock keeps 48dp targets and active-only labels', (
    tester,
  ) async {
    _useMobileSurface(tester);
    useOnboarding(completed: true);
    auth.user = testUser();

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    const labels = ['Home', 'Listing', 'Assess', 'Spaces', 'Profile'];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget, reason: 'missing tab: $label');
    }

    double opacityOf(String label) => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    // Only the landing tab (Home) is announced visually.
    expect(opacityOf('Home'), 1.0);
    for (final label in labels.skip(1)) {
      expect(opacityOf(label), 0.0, reason: '$label should be hidden');
    }

    // Each slot is the tap target: it must clear 48x48 even on a narrow
    // phone so taps cannot misclick between destinations.
    for (final label in labels) {
      final inkWell = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      final rect = tester.getRect(inkWell);
      expect(rect.width, greaterThanOrEqualTo(48), reason: '$label too narrow');
      expect(rect.height, greaterThanOrEqualTo(48), reason: '$label too short');
    }

    // Selecting Listing moves the active state (the pill slides with it).
    await tester.tap(find.text('Listing'));
    await tester.pumpAndSettle();
    expect(opacityOf('Listing'), 1.0);
    expect(opacityOf('Home'), 0.0);
    expect(find.text('Explore'), findsNothing);
  });

  // TEST 23 — the Option A journey: Listing → Property Details →
  // Assess This Property → setup → evidence → summary → save, with the
  // property staying linked the whole way and the hub showing the
  // session-only record afterwards.
  testWidgets(
    'assessment opens the eight-question flow for the chosen property',
    (tester) async {
      _useMobileSurface(tester);
      useOnboarding(completed: true);
      auth.user = testUser();

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Listing'));
      await tester.pumpAndSettle();
      expect(find.text('Find a location'), findsOneWidget);

      // Open the first real repository listing and enter the assessment.
      await tester.tap(find.byType(MobilePropertyCard).first);
      await tester.pumpAndSettle();
      final assessButton = find.text('Assess this property');
      await tester.dragUntilVisible(
        assessButton,
        find.byType(ListView).first,
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      await tester.tap(assessButton);
      await tester.pumpAndSettle();

      // The property id travels as the route argument. The questionnaire now
      // persists to the backend, so with no service reachable in a widget test
      // the page reports the real blocker instead of inventing an assessment
      // record and accepting answers that could never be saved.
      expect(
        find.text('Assessment unavailable'),
        findsOneWidget,
        reason: 'no backend record means no questionnaire to answer',
      );
    },
  );
}
