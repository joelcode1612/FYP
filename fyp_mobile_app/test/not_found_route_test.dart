import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/presentation/shared/pages/not_found_mobile_page.dart';

/// Phone-sized surface so the page lays out without overflow (the default
/// 800x600 test window is landscape).
void _useMobileSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  /// A plain first route so `canPop` is true and both exits are exercised.
  /// The unknown route is pushed on top, exactly like a deep link landing
  /// inside an running session.
  Widget app() => MaterialApp(
    onGenerateRoute: AppRoutes.onGenerateRoute,
    home: const Scaffold(body: Center(child: Text('Origin screen'))),
  );

  Future<void> openUnknown(WidgetTester tester, String path) async {
    await tester.pumpWidget(app());
    Navigator.of(tester.element(find.text('Origin screen'))).pushNamed(path);
    await tester.pumpAndSettle();
  }

  testWidgets('an unknown route shows not-found, never the dashboard', (
    tester,
  ) async {
    _useMobileSurface(tester);
    await openUnknown(tester, '/entrepreneur/does-not-exist');

    expect(find.byType(NotFoundMobilePage), findsOneWidget);
    expect(find.text('Page not found'), findsOneWidget);
    expect(
      find.text('Requested: /entrepreneur/does-not-exist'),
      findsOneWidget,
    );
    expect(find.text('Origin screen'), findsNothing);
  });

  testWidgets('Go back returns to the screen the link was opened from', (
    tester,
  ) async {
    _useMobileSurface(tester);
    await openUnknown(tester, '/bogus');

    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();

    expect(find.text('Origin screen'), findsOneWidget);
    expect(find.byType(NotFoundMobilePage), findsNothing);
  });

  testWidgets('Go home unwinds to the first route', (tester) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(app());
    final navigator = Navigator.of(tester.element(find.text('Origin screen')));
    navigator.pushNamed('/first-bogus');
    await tester.pumpAndSettle();
    navigator.pushNamed('/second-bogus');
    await tester.pumpAndSettle();
    expect(find.text('Requested: /second-bogus'), findsOneWidget);

    await tester.tap(find.text('Go home'));
    await tester.pumpAndSettle();

    expect(find.text('Origin screen'), findsOneWidget);
    expect(find.byType(NotFoundMobilePage), findsNothing);
  });

  testWidgets('a cold deep link to an unknown route still resolves', (
    tester,
  ) async {
    _useMobileSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: AppRoutes.onGenerateRoute,
        initialRoute: '/no-such-page',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NotFoundMobilePage), findsOneWidget);
    // Nothing to pop back to, so only the home exit is offered.
    expect(find.text('Go back'), findsNothing);
    expect(find.text('Go home'), findsOneWidget);
  });

  // The mobile assessment flow is data collection and stays separate from the
  // web decision-support workspace. These routes and their tab mapping are a
  // regression guard: the not-found change must not rename or drop any of them.
  test('every mobile assessment route stays registered under the Assess tab', () {
    const assessmentRoutes = {
      '/entrepreneur/assess',
      '/entrepreneur/assessment-setup',
      '/entrepreneur/assessment-evidence',
      '/entrepreneur/assessment-summary',
      '/entrepreneur/report',
    };
    for (final path in assessmentRoutes) {
      expect(
        AppRoutes.onGenerateRoute(RouteSettings(name: path)),
        isNotNull,
        reason: '$path must remain a registered route',
      );
      expect(parentShellRoute(path), '/entrepreneur/assess');
    }
  });

  test('parentShellRoute normalises a query string before lookup', () {
    expect(
      parentShellRoute('/entrepreneur/assessment-setup?id=EP-01051'),
      '/entrepreneur/assess',
    );
    expect(parentShellRoute('/entrepreneur/spaces/'), '/entrepreneur/spaces');
  });
}