import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/presentation/mobile/entrepreneur/pages/entrepreneur_compare_mobile_page.dart';
import 'package:fyp/presentation/mobile/shell/entrepreneur_tab_scope.dart';
import 'package:shared_logic/shared_logic.dart';

/// Regression guards for the mobile Compare screen.
///
/// The confirmed cause this pins down: the screen used to call its sync
/// routine directly inside `build()`, which mutated `propertyCompareProvider`
/// while the widget tree was building — Riverpod throws
/// "modified during build" for exactly that. The screen now loads after the
/// first frame and observes selection changes through `ref.listen`, so:
///
/// 1. pumping the page with a selection never throws;
/// 2. one distinct selection → exactly one compare request;
/// 3. a changed selection → one follow-up request with the NEW ids;
/// 4. a resolved comparison renders, and unresolved ids show the backend's
///    own reason instead of a generic "not found".
///
/// No network: the compare repository answers from memory.
class _FakeCompareRepo implements PropertyCompareRepository {
  final List<List<String>> calls = [];

  @override
  Future<PropertyCompareResult> compare(List<String> propertyIds) async {
    calls.add(List<String>.from(propertyIds));
    return PropertyCompareResult(
      selectedCount: propertyIds.length,
      resolvedCount: propertyIds.length,
      properties: [
        for (final id in propertyIds)
          CompareProperty(id: id, title: 'Property $id'),
      ],
      unresolvedIds: const [],
      notes: const [],
    );
  }
}

class _UnresolvedCompareRepo implements PropertyCompareRepository {
  @override
  Future<PropertyCompareResult> compare(List<String> propertyIds) async {
    return PropertyCompareResult(
      selectedCount: propertyIds.length,
      resolvedCount: propertyIds.length - 1,
      unresolvedIds: const ['ZZ-404'],
      unresolvedDetails: const [
        CompareUnresolved(id: 'ZZ-404', reason: 'No such property exists.'),
      ],
      properties: [
        CompareProperty(id: propertyIds.first, title: 'Only resolved'),
      ],
    );
  }
}

/// A comparison that carries fit rows, i.e. the account HAS saved requirements.
class _FitCompareRepo implements PropertyCompareRepository {
  @override
  Future<PropertyCompareResult> compare(List<String> propertyIds) async {
    return PropertyCompareResult(
      selectedCount: propertyIds.length,
      resolvedCount: propertyIds.length,
      properties: [
        for (final id in propertyIds)
          CompareProperty(
            id: id,
            title: 'Property $id',
            preferenceFit: const [
              CompareFitRow(
                key: 'budget',
                label: 'Monthly rent',
                status: 'outside',
                detail: 'RM 6,000 per month is RM 1,000 above the RM 5,000 '
                    'maximum you saved.',
              ),
            ],
          ),
      ],
      fitBasis: const CompareFitBasis(
        saved: true,
        statement: 'Each fit row states one recorded property fact against a '
            'requirement you saved.',
        notCompared: [
          'Accessibility features are not recorded for any property.',
        ],
      ),
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required List<String> compared,
  PropertyCompareRepository? repo,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appInitialStateProvider.overrideWithValue(
          AppState(compared: {...compared}),
        ),
        propertyCompareRepositoryProvider.overrideWithValue(
          repo ?? _FakeCompareRepo(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EntrepreneurTabScope(
            // Non-nullable by contract; no navigation is asserted here.
            onTabSelected: (String route) {},
            child: const EntrepreneurCompareMobilePage(),
          ),
        ),
      ),
    ),
  );
  // Post-frame load + settle: any build-phase provider mutation throws here.
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('selection loads after the first frame without a build-phase '
      'provider mutation', (tester) async {
    final repo = _FakeCompareRepo();
    await _pump(tester, compared: ['MD-00510', 'MD-04816'], repo: repo);
    expect(tester.takeException(), isNull);
    expect(repo.calls, hasLength(1));
    expect(repo.calls.single, ['MD-00510', 'MD-04816']);
  });

  testWidgets('a changed selection triggers exactly one follow-up request '
      'with the new ids', (tester) async {
    final repo = _FakeCompareRepo();
    await _pump(tester, compared: ['MD-00510', 'MD-04816'], repo: repo);
    expect(repo.calls, hasLength(1));

    // The Recommendations screen adds a third property through the app
    // controller while this page stays mounted underneath.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EntrepreneurCompareMobilePage)),
    );
    container
        .read(appNotifierProvider.notifier)
        .addCompared('316');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(repo.calls, hasLength(2));
    expect(repo.calls.last, ['MD-00510', 'MD-04816', '316']);
  });

  testWidgets('an ordinary rebuild does not re-request the comparison',
      (tester) async {
    final repo = _FakeCompareRepo();
    await _pump(tester, compared: ['MD-00510', 'MD-04816'], repo: repo);
    expect(repo.calls, hasLength(1));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(repo.calls, hasLength(1));
  });

  testWidgets('unresolved ids surface the backend reason, not a generic '
      'notice', (tester) async {
    await _pump(
      tester,
      compared: ['MD-00510', 'ZZ-404'],
      repo: _UnresolvedCompareRepo(),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('No such property exists.'), findsOneWidget);
  });

  testWidgets('saved requirements render as fit facts, one per property, and '
      'say what cannot be checked', (tester) async {
    await _pump(
      tester,
      compared: ['MD-00510', 'MD-04816'],
      repo: _FitCompareRepo(),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Fit against your saved requirements'), findsOneWidget);
    // Facts, never a score: the backend's own wording is what shows.
    expect(
      find.textContaining('above the RM 5,000 maximum you saved'),
      findsNWidgets(2),
    );
    expect(
      find.textContaining('Accessibility features are not recorded'),
      findsOneWidget,
    );
  });

  testWidgets('an account with no saved requirements is told fit is not '
      'available', (tester) async {
    await _pump(tester, compared: ['MD-00510', 'MD-04816']);
    expect(tester.takeException(), isNull);
    expect(find.text('Fit against your saved requirements'), findsOneWidget);
    expect(
      find.textContaining('fit against your requirements is not available'),
      findsOneWidget,
    );
  });
}
