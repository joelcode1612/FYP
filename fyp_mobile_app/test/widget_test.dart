import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/application/services/service_locator.dart';
import 'package:fyp/data/datasources/local/onboarding_local_data_source.dart';
import 'package:fyp/data/repositories/auth_repository_impl.dart';
import 'package:fyp/data/repositories/onboarding_repository_impl.dart';
import 'package:fyp/main.dart';
import 'package:fyp/presentation/mobile/widgets/mobile_property_card.dart';

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
    ServiceLocator.assessmentSession.discard();
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

    // Assess tab renders the Option A hub (session draft + honest labels).
    await tester.tap(find.text('Assess'));
    await tester.pumpAndSettle();
    expect(find.text('Your assessments'), findsOneWidget);
    expect(find.text('Recent activity'), findsOneWidget);

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

  // TEST 15 — the public landing page: its Log In action opens the Sign In
  // screen (the account carries the role; there is no role-picker dialog).
  // Log In lives in the navigation drawer, so the test opens it first.
  testWidgets('landing Log In opens the Sign In screen', (tester) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed('/landing');
    await tester.pumpAndSettle();

    // The eyebrow renders uppercased by MobileEyebrow.
    expect(
      find.textContaining('EVIDENCE-BASED F&B LOCATION'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log In'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
  });

  // TEST 16 — mobile ships the Entrepreneur workspace only: the Property
  // Owner landing card cannot route to the deleted /owner screens; it lands
  // on Sign In, which explains where that workspace lives.
  testWidgets('landing Owner card falls back to Sign In', (tester) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed('/landing');
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

  // TEST 17 — the floating dock contract: every slot is a >=48x48 target,
  // exactly one label is visible at a time (the active tab), and switching
  // tabs moves that visibility with the selection.
  testWidgets('floating dock keeps 48dp targets and active-only labels', (
    tester,
  ) async {
    _useMobileSurface(tester);
    onboarding = InMemoryOnboardingLocalDataSource(completed: true);
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(onboarding);
    auth.user = _FakeAuthRepository._demoUser;

    await tester.pumpWidget(const SitewiseApp());
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

  // TEST 18 — the Option A journey: Listing → Property Details →
  // Assess This Property → setup → evidence → summary → save, with the
  // property staying linked the whole way and the hub showing the
  // session-only record afterwards.
  testWidgets('assessment journey keeps the property link end to end', (
    tester,
  ) async {
    _useMobileSurface(tester);
    onboarding = InMemoryOnboardingLocalDataSource(completed: true);
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(onboarding);
    auth.user = _FakeAuthRepository._demoUser;

    Future<void> scrollTo(Finder finder) async {
      await tester.dragUntilVisible(
        finder,
        find.byType(ListView).first,
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(const SitewiseApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Listing'));
    await tester.pumpAndSettle();
    expect(find.text('Find a location'), findsOneWidget);

    // Open the first real repository listing.
    await tester.tap(find.byType(MobilePropertyCard).first);
    await tester.pumpAndSettle();
    final assessButton = find.text('Assess this property');
    await scrollTo(assessButton);
    await tester.tap(assessButton);
    await tester.pumpAndSettle();

    // Setup: the property arrived via route arguments — the screen shows the
    // link without asking for the property again.
    expect(find.text('Tell us about your business'), findsOneWidget);
    expect(find.text('NEW ASSESSMENT / STEP 1 OF 3'), findsOneWidget);
    await tester.tap(find.text('Specialty café'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '8500');
    await tester.pumpAndSettle();
    await scrollTo(find.text('Residents'));
    await tester.tap(find.text('Residents'));
    await tester.pumpAndSettle();
    await scrollTo(find.text('Continue to evidence matching'));
    await tester.tap(find.text('Continue to evidence matching'));
    await tester.pumpAndSettle();

    // Evidence: honest states only — no fabricated campaign matching.
    expect(find.text('Evidence matching'), findsOneWidget);
    expect(find.text('Property linked'), findsOneWidget);
    expect(find.text('Survey evidence requires backend check'), findsOneWidget);
    await scrollTo(find.text('View assessment summary'));
    await tester.tap(find.text('View assessment summary'));
    await tester.pumpAndSettle();

    // Summary: repository analysis (or its explicit absence), never invented.
    expect(find.text('Assessment summary'), findsOneWidget);
    expect(find.text('Demand analysis'), findsOneWidget);
    final saveButton = find.text('Save this assessment');
    await scrollTo(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    // Back on the hub: one session record, explicitly session-scoped.
    expect(find.text('Saved in this session'), findsOneWidget);
    expect(find.textContaining('Specialty café'), findsOneWidget);
  });
}
