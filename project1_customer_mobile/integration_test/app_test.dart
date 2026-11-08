import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project1_customer_mobile/view/project1_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android synthetic walkthrough, language toggle, optional skips and review editing',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: Project1App()));
      await tester.pumpAndSettle();
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('start')))
            .onPressed,
        isNull,
      );
      await tap(find.byKey(const ValueKey('consent')));
      await tap(find.byKey(const ValueKey('start')));
      for (final pair in [
        ('Q01', 'LIVE'),
        ('Q02', 'DAYS_4_10'),
        ('Q03', 'HOME'),
        ('Q04', 'ZERO'),
        ('Q05', 'PROB_YES'),
        ('Q06', 'COFFEE_ESPRESSO'),
        ('Q07', 'SOMEWHAT_ACCEPTABLE'),
        ('Q09', 'SOCIAL'),
      ]) {
        expect(find.text(pair.$1), findsOneWidget);
        await tap(find.byKey(ValueKey('option_${pair.$1}_${pair.$2}')));
        if (pair.$1 == 'Q05') {
          await tap(find.byKey(const ValueKey('language_bm')));
          expect(find.text('Mungkin berkemungkinan'), findsOneWidget);
          await tap(find.byKey(const ValueKey('language_en')));
        }
        await tap(find.byKey(const ValueKey('next')));
      }
      expect(find.text('Q10'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tap(find.byType(DropdownButtonFormField<String>).at(i));
        await tap(find.text('Very important').last);
      }
      await tap(find.byKey(const ValueKey('next')));
      for (final id in ['Q11', 'Q12', 'Q13']) {
        expect(find.text(id), findsOneWidget);
        await tap(find.byKey(const ValueKey('skip_optional')));
      }
      expect(find.textContaining('9 answered of 12 shown'), findsOneWidget);
      expect(find.text('13 of 13'), findsNothing);
      await tap(find.byKey(const ValueKey('review_group_Q01')));
      await tap(find.byKey(const ValueKey('edit_Q01')));
      await tap(find.byKey(const ValueKey('option_Q01_NEVER')));
      await tap(find.text('Return to review'));
      expect(find.textContaining('2 answered of 2 shown'), findsOneWidget);
      await tap(find.byKey(const ValueKey('submit')));
      expect(find.text('Thank you for trying Project1'), findsOneWidget);
      expect(
        find.textContaining('No responses were sent or saved.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
