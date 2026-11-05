import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/application/services/service_locator.dart';
import 'package:fyp/data/datasources/local/onboarding_local_data_source.dart';
import 'package:fyp/data/repositories/auth_repository_impl.dart';
import 'package:fyp/data/repositories/onboarding_repository_impl.dart';
import 'package:fyp/main.dart';

/// Fake auth repository so tests can control the "authenticated" state without
/// touching disk or a backend.
class _FakeAuthRepository implements AuthRepository {
  SitewiseUser? user;

  static final SitewiseUser _demoUser = SitewiseUser(
    id: 'ent-1',
    name: 'Sarah Tan',
    email: 'sarah@artisanbrew.my',
    role: AppRole.entrepreneur,
    status: 'Active',
    location: 'Petaling Jaya, Selangor',
    joinedAt: DateTime(2024, 9, 5),
  );

  @override
  List<SitewiseUser> get demoAccounts => const [];

  @override
  Future<SitewiseUser?> currentUser() async => user;

  @override
  Future<bool> isAuthenticated() async => user != null;

  @override
  Future<SitewiseUser> signInWithEmail({
    required String email,
    required String password,
  }) async => user = _demoUser;

  @override
  Future<SitewiseUser> signUpWithEmail({
    required String email,
    required String password,
  }) async => user = _demoUser;

  @override
  Future<SitewiseUser> signInWithProvider(AuthProvider provider) async =>
      user = _demoUser;

  @override
  Future<void> signOut() async => user = null;
}

/// Phone-sized surface so the mobile onboarding pages lay out without
/// overflow (the default 800x600 test window is landscape).
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
  late _FakeAuthRepository auth;

  setUp(() {
    onboarding = InMemoryOnboardingLocalDataSource();
    auth = _FakeAuthRepository();
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(onboarding);
    ServiceLocator.auth = AuthService(auth);
  });

  tearDown(() {
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(
      FileOnboardingLocalDataSource(),
    );
    ServiceLocator.auth = AuthService(AuthRepositoryImpl());
  });

  // TEST 1 — fresh install: onboarding appears on mobile.
  testWidgets('fresh mobile launch shows the onboarding introduction', (
    tester,
  ) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Find the right F&B location'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
  });

  // TEST 2-5 — the five onboarding stages are reachable and the indicator
  // tracks them (5 stages, not 3).
  testWidgets('onboarding advances through all five stages', (tester) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(const SitewiseApp());
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
    expect(find.text('Get started'), findsOneWidget);
  });

  // TEST 6 — Get Started marks onboarding complete and opens Sign Up.
  testWidgets('Get Started completes onboarding and opens Sign Up', (
    tester,
  ) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    expect(await onboarding.hasCompletedOnboarding(), isTrue);
    expect(find.text('Create your account'), findsOneWidget);
  });

  // TEST 7 — Log In link completes onboarding and opens Log In.
  testWidgets('Log In link completes onboarding and opens Log In', (
    tester,
  ) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Already have an account?  Log in'));
    await tester.pumpAndSettle();

    expect(await onboarding.hasCompletedOnboarding(), isTrue);
    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 8 — Skip completes onboarding and goes to auth (never a protected page).
  testWidgets('Skip completes onboarding and routes to auth', (tester) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();

    expect(await onboarding.hasCompletedOnboarding(), isTrue);
    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 9 / 14 — completion survives a restart (persistent flag).
  testWidgets('completed onboarding is not shown again after restart', (
    tester,
  ) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(await onboarding.hasCompletedOnboarding(), isTrue);

    // Simulate a relaunch with the same persistent store. Tear the tree down
    // first so the Navigator is genuinely rebuilt from scratch.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Find the right F&B location'), findsNothing);
    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 10 — returning, unauthenticated user lands on auth.
  testWidgets('returning unauthenticated user lands on auth', (tester) async {
    _useMobileSurface(tester);
    onboarding = InMemoryOnboardingLocalDataSource(completed: true);
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(onboarding);

    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 11 — returning, authenticated user lands on their role home.
  testWidgets('returning authenticated user lands on the role home', (
    tester,
  ) async {
    _useMobileSurface(tester);
    onboarding = InMemoryOnboardingLocalDataSource(completed: true);
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(onboarding);
    auth.user = SitewiseUser(
      id: 'ent-1',
      name: 'Sarah Tan',
      email: 'sarah@artisanbrew.my',
      role: AppRole.entrepreneur,
      status: 'Active',
      location: 'Petaling Jaya, Selangor',
      joinedAt: DateTime(2024, 9, 5),
    );

    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    // Post-sign-in Home follows the Material 3 reference: greeting +
    // discovery feature card. The old "Find the right F&B location" banner
    // headline was removed by that redesign.
    expect(find.text('Welcome to Sitewise.'), findsOneWidget);
    expect(find.text('Explore listings'), findsOneWidget);
  });

  // TEST 12 — logging in from the auth screen enters the entrepreneur app.
  testWidgets('logging in from auth enters the entrepreneur app', (
    tester,
  ) async {
    _useMobileSurface(tester);
    onboarding = InMemoryOnboardingLocalDataSource(completed: true);
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(onboarding);

    await tester.pumpWidget(const SitewiseApp());
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

  // TEST 13 — post-sign-in Home uses the consolidated five-tab navigation and
  // the new Assess / Spaces tabs are reachable with real data.
  testWidgets('entrepreneur home shows the five Material 3 tabs', (tester) async {
    _useMobileSurface(tester);
    onboarding = InMemoryOnboardingLocalDataSource(completed: true);
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(onboarding);
    auth.user = _FakeAuthRepository._demoUser;

    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    // Reference nav: Home / Listing / Assess / Spaces / Profile.
    for (final label in const ['Home', 'Listing', 'Assess', 'Spaces', 'Profile']) {
      expect(find.text(label), findsOneWidget, reason: 'missing tab: $label');
    }
    // The retired tab labels must be gone.
    expect(find.text('Explore'), findsNothing);
    expect(find.text('Saved'), findsNothing);
    expect(find.text('Compare'), findsNothing);

    // Reference Home structure (top of the scroll view).
    expect(find.text('Welcome to Sitewise.'), findsOneWidget);
    expect(find.text('Your overview'), findsOneWidget);
    expect(find.text('Recommendations'), findsOneWidget);
    expect(find.text('Saved spaces'), findsOneWidget);

    // Sections further down the ListView are only built once scrolled into
    // view — scroll rather than asserting against an unbuilt subtree.
    await tester.scrollUntilVisible(
      find.text('Quick actions'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Quick actions'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Manage my spaces'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Demand assessments'), findsOneWidget);
    expect(find.text('Manage my spaces'), findsOneWidget);

    // Assess tab renders with real repository data (not invented records).
    await tester.tap(find.text('Assess'));
    await tester.pumpAndSettle();
    expect(find.text('My assessments'), findsOneWidget);
    expect(find.text('Available assessments'), findsOneWidget);

    // Spaces tab renders with an honest empty shortlist state.
    await tester.tap(find.text('Spaces'));
    await tester.pumpAndSettle();
    expect(find.text('My spaces'), findsOneWidget);
    expect(find.text('No spaces saved yet'), findsOneWidget);
  });

  // TEST 14 — the Flutter app is mobile-only now: even on a wide desktop
  // viewport it boots to the mobile onboarding, never the old web tree
  // (which lives in the Jaspr app, fyp_jaspr_web).
  testWidgets('wide viewport still boots the mobile flow, not a web tree', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Find the right F&B location'), findsOneWidget);
    expect(find.text('How It Works'), findsNothing);
  });
}
