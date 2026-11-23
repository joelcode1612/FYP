import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/features/property_management/presentation/pages/sitewise_add_property_mobile_page.dart';
import 'package:fyp/shared/presentation/layouts/mobile_bottom_nav.dart';
import 'package:fyp/shared/presentation/layouts/provider_tab_host.dart';
import 'package:shared_logic/shared_logic.dart';

class _TestAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => AuthState.initializing;
}

void main() {
  testWidgets(
    'Owner Add Property keeps the tab stack stable as the keyboard opens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(_TestAuthNotifier.new),
            appInitialStateProvider.overrideWithValue(
              const AppState(role: AppRole.owner),
            ),
          ],
          child: const MaterialApp(
            home: ProviderTabHost(initialRoute: ProviderTabHost.addRoute),
          ),
        ),
      );

      final form = find.byType(SitewiseAddPropertyMobilePage);
      final formHeight = tester.getSize(form).height;
      final viewport = find.descendant(
        of: form,
        matching: find.byType(SingleChildScrollView),
      );
      final closedViewportHeight = tester.getSize(viewport).height;
      final dock = find.byType(MobileBottomNav);
      final dockHeight = tester.getSize(dock).height;
      final title = find.byType(TextField).first;
      await tester.tap(title);
      await tester.pump();

      tester.view.padding = const FakeViewPadding();
      for (final inset in [20.0, 140.0, 320.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
        expect(tester.getSize(form).height, formHeight);
        expect(tester.getSize(dock).height, dockHeight);
        expect(dock.hitTestable(), findsNothing);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText).first)
              .focusNode
              .hasFocus,
          isTrue,
        );
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(title).bottom, lessThan(480));
      expect(tester.getRect(viewport).bottom, closeTo(480, 1));

      tester.view.viewInsets = const FakeViewPadding();
      tester.view.padding = const FakeViewPadding(bottom: 24);
      await tester.pumpAndSettle();
      expect(tester.getSize(dock).height, dockHeight);
      expect(dock.hitTestable(), findsOneWidget);
      expect(tester.getSize(viewport).height, closedViewportHeight);
      expect(tester.takeException(), isNull);
    },
  );
}
