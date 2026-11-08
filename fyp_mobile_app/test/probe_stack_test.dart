import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/application/providers.dart';
import 'package:fyp/core/routing/app_routes.dart';

void main() {
  testWidgets('probe canPop', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: sitewiseOverrides(),
        child: MaterialApp(
          onGenerateRoute: AppRoutes.onGenerateRoute,
          initialRoute: '/no-such-page',
        ),
      ),
    );
    await tester.pump();
    final ctx = tester.element(find.text('Page not found'));
    debugPrint('after-pump canPop=${Navigator.of(ctx).canPop()}');
    await tester.pumpAndSettle();
    debugPrint('after-settle canPop=${Navigator.of(ctx).canPop()}');
    final route = ModalRoute.of(ctx);
    debugPrint('route name=${route?.settings.name} isActive=${route?.isActive}');
  });
}
