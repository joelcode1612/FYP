import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/application/services/service_locator.dart';
import 'package:fyp/presentation/mobile/entrepreneur/pages/entrepreneur_favourites_mobile_page.dart';
import 'package:fyp/presentation/mobile/shell/entrepreneur_tab_scope.dart';
import 'package:fyp/presentation/mobile/shell/mobile_navigation.dart';
import 'package:fyp/presentation/mobile/widgets/mobile_property_card.dart';
import 'package:shared_logic/shared_logic.dart';

/// Rendering guards for the Favourites tab that replaced My Spaces.
///
/// What is pinned here is the part a static analysis cannot see: the tab is
/// one `ListView` (`M3Content`) whose property list arrives from an
/// `AsyncSection`, so a builder that returned another scrollable would throw
/// "Vertical viewport was given unbounded height" at runtime instead of at
/// compile time. Alongside the layout, the four states stay distinct —
/// populated cards from the saved refs, the empty invitation, a failed read
/// reported as a failure (never as "you saved nothing"), and removal through
/// the same authenticated save endpoint the Recommendations card uses.
///
/// No network: the catalogue and the saved-list repositories are faked, and
/// the tab host scope records the route the empty-state CTA asks for.
void main() {
  late PropertyRepository originalCatalogue;

  setUp(() => originalCatalogue = ServiceLocator.propertyRepo);
  tearDown(() => ServiceLocator.propertyRepo = originalCatalogue);

  Future<void> pumpScreen(
    WidgetTester tester,
    _FakeSavedRepo saved, {
    List<String>? openedTabs,
    List<CommercialProperty>? rows,
  }) async {
    ServiceLocator.propertyRepo = _FakeCatalogueRepo(rows ?? DemoData.properties);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The real composition root wires the bearer-token-backed
          // repository; here the same contract answers from memory.
          savedPropertiesRepositoryProvider.overrideWithValue(saved),
        ],
        child: MaterialApp(
          // The tab host owns the Scaffold; inside the scope the page renders
          // its body only, so the test mirrors that shape.
          home: Scaffold(
            body: EntrepreneurTabScope(
              onTabSelected: (route) => openedTabs?.add(route),
              child: const EntrepreneurFavouritesMobilePage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('the entrepreneur dock ends the My Spaces tab with Favourites', () {
    final dock = mobileDestinationsFor(AppRole.entrepreneur);

    expect(
      dock.map((d) => d.label).toList(),
      ['Home', 'Recommendations', 'Assess', 'Favourites', 'Profile'],
    );
    final favourites = dock.singleWhere((d) => d.label == 'Favourites');
    expect(favourites.route, '/entrepreneur/favourites');
    expect(favourites.icon, Icons.bookmark_border_rounded);

    // Old links still resolve: the retired tab path maps onto its replacement,
    // and the replacement is a real tab of the five-tab model.
    expect(
      EntrepreneurTabScope.resolveTabRoute('/entrepreneur/spaces'),
      '/entrepreneur/favourites',
    );
    expect(EntrepreneurTabScope.tabRoutes, contains('/entrepreneur/favourites'));
  });

  testWidgets('saved records render as recommendation cards', (
    tester,
  ) async {
    final catalogue = DemoData.properties;
    final first = catalogue[0];
    final second = catalogue[1];
    await pumpScreen(tester, _FakeSavedRepo({first.id, second.id}));

    expect(find.text('My Favourites'), findsOneWidget);
    expect(
      find.text("Properties you've saved for later."),
      findsOneWidget,
    );
    // The count is the server-owned saved set, not what the session tapped.
    expect(find.text('2 FAVOURITES'), findsOneWidget);

    // Every record carries the fields the Recommendations card shows.
    for (final p in [first, second]) {
      await _bringIntoView(tester, find.text(p.title));
      expect(find.text(p.title), findsOneWidget);
      expect(find.textContaining('${p.city}, ${p.state}'), findsOneWidget);
      expect(find.text(p.rentalDisplay), findsOneWidget);
      expect(find.text('/ month'), findsWidgets);
      expect(
        find.textContaining('${p.sizeSqft.toStringAsFixed(0)} sq ft'),
        findsOneWidget,
      );
      expect(find.textContaining(p.propertyType), findsOneWidget);
      // Saved rows show the filled bookmark, so the state is visible.
      expect(find.byIcon(Icons.bookmark_rounded), findsNWidgets(2));
    }

    expect(find.text('View Details'), findsNWidgets(2));
    expect(find.text('No favourite properties yet'), findsNothing);
  });

  testWidgets('removing a favourite updates the list and the server', (
    tester,
  ) async {
    final catalogue = DemoData.properties;
    final first = catalogue[0];
    final second = catalogue[1];
    final saved = _FakeSavedRepo({first.id, second.id});
    await pumpScreen(tester, saved);

    await tester.tap(find.byIcon(Icons.bookmark_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('Removed from favourites.'), findsOneWidget);
    expect(saved.refs, isNot(contains(first.id)));
    expect(find.text('1 FAVOURITE'), findsOneWidget);
    expect(find.text(first.title), findsNothing);
    expect(find.text(second.title), findsOneWidget);
    expect(find.text('View Details'), findsOneWidget);
  });

  testWidgets('an account with no favourites is invited to Recommendations', (
    tester,
  ) async {
    final opened = <String>[];
    await pumpScreen(tester, _FakeSavedRepo({}), openedTabs: opened);

    expect(find.text('No favourite properties yet'), findsOneWidget);
    expect(
      find.text('Save properties from Recommendations to find them here later.'),
      findsOneWidget,
    );
    expect(find.text('0 FAVOURITES'), findsOneWidget);
    expect(find.byType(MobilePropertyCard), findsNothing);

    await tester.tap(find.text('Explore Recommendations'));
    await tester.pumpAndSettle();

    // The CTA switches the existing tab instead of stacking a second dock.
    expect(opened, ['/entrepreneur/recommendations']);
  });

  testWidgets('a failed read is reported as a failure, not as an empty list', (
    tester,
  ) async {
    await pumpScreen(tester, _FakeSavedRepo({}, loadFailure: Exception('offline')));

    expect(
      find.text('Your saved properties could not be loaded.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    // The count is unknown, so nothing may claim there is nothing saved.
    expect(find.text('NOT LOADED'), findsOneWidget);
    expect(find.text('No favourite properties yet'), findsNothing);
    expect(find.text('My Favourites'), findsOneWidget);
  });

  testWidgets('a saved ref the catalogue no longer lists is quantified', (
    tester,
  ) async {
    final catalogue = DemoData.properties;
    await pumpScreen(
      tester,
      _FakeSavedRepo({catalogue[0].id, 'EP-99999'}),
      rows: catalogue,
    );

    // Both refs are still counted as saved; the one that no longer resolves
    // is stated rather than silently dropped or rendered as a ghost card.
    expect(find.text('2 FAVOURITES'), findsOneWidget);
    expect(
      find.textContaining('1 of your favourites are no longer listed'),
      findsOneWidget,
    );
    expect(find.text(catalogue[0].title), findsOneWidget);
    expect(find.text('View Details'), findsOneWidget);
  });
}

/// Scrollable assertions: the screen is one long `ListView`, so a card below
/// the fold is not built until it is brought into view.
Future<void> _bringIntoView(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return;
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// The `/api/v1/saved-properties` contract, answered from memory.
class _FakeSavedRepo implements SavedPropertiesRepository {
  _FakeSavedRepo(this.refs, {this.loadFailure});

  final Set<String> refs;
  final Object? loadFailure;

  @override
  Future<Set<String>> savedRefs() {
    if (loadFailure != null) return Future<Set<String>>.error(loadFailure!);
    return Future.value({...refs});
  }

  @override
  Future<({Set<String> resolved, Set<String> unresolved})>
  savedWithUnresolved() async =>
      (resolved: {...refs}, unresolved: const <String>{});

  @override
  Future<void> save(String propertyRef) async => refs.add(propertyRef);

  @override
  Future<void> unsave(String propertyRef) async => refs.remove(propertyRef);
}

/// Catalogue rows served through the same repository the Recommendations
/// list reads.
class _FakeCatalogueRepo implements PropertyRepository {
  _FakeCatalogueRepo(this.rows);

  final List<CommercialProperty> rows;

  @override
  Future<List<CommercialProperty>> getProperties() async => rows;

  @override
  Future<CommercialProperty?> getPropertyById(String id) async {
    for (final p in rows) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  Future<List<CommercialProperty>> getPropertiesByOwner(String ownerId) async =>
      rows.where((p) => p.ownerId == ownerId).toList();

  @override
  Future<CommercialProperty> createProperty(CommercialProperty property) async =>
      property;

  @override
  Future<void> updateProperty(CommercialProperty property) async {}

  @override
  Future<void> submitForVerification(String id) async {}

  @override
  Future<void> updateVerification(String id, VerificationStatus status) async {}
}
