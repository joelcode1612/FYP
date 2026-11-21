import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/config/dev_auth_bypass.dart';
import 'package:fyp/core/routing/auth_route_guard.dart';

void main() {
  for (final page in ['Home', 'Assess', 'Profile']) {
    testWidgets(
      '$page uses a small development label without a corner ribbon',
      (tester) async {
        expect(
          devAuthBypassEnabled,
          isTrue,
          reason: 'Run with the explicit development bypass define.',
        );
        var taps = 0;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              home: AuthGuard(
                access: RouteAccess.workspace,
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text(page)),
                  body: TextButton(
                    onPressed: () => taps++,
                    child: const Text('Continue'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Banner), findsNothing);
        expect(
          find.byKey(const Key('development-access-label')),
          findsOneWidget,
        );
        expect(find.text(page), findsOneWidget);
        await tester.tap(find.text('Continue'));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
