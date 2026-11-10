import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/application/providers.dart';
import 'package:fyp/application/services/draft_repository.dart';
import 'package:fyp/application/services/service_locator.dart';
import 'package:fyp/data/datasources/local/draft_local_data_source.dart';
import 'package:fyp/data/datasources/local/onboarding_local_data_source.dart';
import 'package:fyp/data/repositories/onboarding_repository_impl.dart';
import 'package:fyp/data/repositories/supabase_auth_repository.dart';
import 'package:fyp/main.dart';

import 'support/fake_auth_repository.dart';

/// Regression guard for the Add Property screen's header chrome:
///  * no back arrow beside the SiteWise lockup (the flow is entered from the
///    Spaces tab, so the tab dock is the way back), and
///  * no `Home › My Properties › Add Property` breadcrumb trail.
void main() {
  late FakeAuthRepository auth;

  void useMobileSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget app() =>
      ProviderScope(overrides: sitewiseOverrides(), child: const SitewiseApp());

  setUp(() {
    auth = FakeAuthRepository();
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(
      InMemoryOnboardingLocalDataSource(completed: true),
    );
    ServiceLocator.auth = AuthService(auth);
    ServiceLocator.drafts = ApplicationDraftRepository(
      InMemoryDraftLocalDataSource(),
    );
  });

  tearDown(() {
    ServiceLocator.onboardingRepo = OnboardingRepositoryImpl(
      FileOnboardingLocalDataSource(),
    );
    ServiceLocator.drafts = ServiceLocator.productionDrafts;
    ServiceLocator.auth = AuthService(SupabaseAuthRepository());
  });

  testWidgets('Add Property shows no back arrow and no breadcrumb trail', (
    tester,
  ) async {
    useMobileSurface(tester);

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

    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pushNamed('/entrepreneur/add-property');
    await tester.pumpAndSettle();

    // The screen itself is on the stack.
    expect(find.text('Add commercial property'), findsOneWidget);

    // No breadcrumb trail any more.
    expect(find.text('My Properties'), findsNothing);
    expect(find.text('Add Property'), findsNothing);

    // No back arrow in the header beside the brand lockup. The header itself
    // IS on screen (AppBar + lockup + notification action), so the absence
    // below is a real "no back affordance", not a missing header.
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.byTooltip('Back'), findsNothing);

    // The brand lockup and the notification action remain.
    expect(find.text('SITEWISE'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
  });
}
