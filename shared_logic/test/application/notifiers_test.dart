import 'package:riverpod/riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// Behavioural tests for the shared application layer.
///
/// These protect the `Cubit` -> Riverpod `Notifier` translation: the rules
/// below were the ones most likely to be lost in the move. Notifiers run
/// inside a [ProviderContainer] with composition-root overrides standing in
/// for the demo repositories.
void main() {
  group('AppNotifier', () {
    late ProviderContainer container;
    late AppNotifier app;

    setUp(() {
      container = ProviderContainer();
      app = container.read(appNotifierProvider.notifier);
    });

    tearDown(() => container.dispose());

    test('starts with the entrepreneur role and empty sets', () {
      final state = container.read(appNotifierProvider);
      expect(state.role, AppRole.entrepreneur);
      expect(state.saved, isEmpty);
      expect(state.compared, isEmpty);
    });

    test('toggleSaved adds then removes', () {
      app.toggleSaved('p1');
      expect(container.read(appNotifierProvider).isSaved('p1'), isTrue);
      app.toggleSaved('p1');
      expect(container.read(appNotifierProvider).isSaved('p1'), isFalse);
    });

    test('compare is capped at three and a fourth add is a no-op', () {
      for (final id in ['a', 'b', 'c']) {
        app.toggleCompared(id);
      }
      expect(container.read(appNotifierProvider).compared,
          hasLength(AppState.maxCompare));

      app.toggleCompared('d');
      expect(container.read(appNotifierProvider).compared, hasLength(3));
      expect(container.read(appNotifierProvider).isCompared('d'), isFalse);
    });

    test('removing from compare is allowed at the cap, then adding works', () {
      for (final id in ['a', 'b', 'c']) {
        app.toggleCompared(id);
      }
      app.toggleCompared('a');
      expect(container.read(appNotifierProvider).compared, hasLength(2));

      app.toggleCompared('d');
      expect(container.read(appNotifierProvider).compared, hasLength(3));
    });

    test('clearCompared empties the set', () {
      app.toggleCompared('a');
      app.clearCompared();
      expect(container.read(appNotifierProvider).compared, isEmpty);
    });

    test('setRole and setPreview publish', () {
      app.setRole(AppRole.owner);
      expect(container.read(appNotifierProvider).role, AppRole.owner);

      app.setPreview(PreviewMode.web);
      expect(container.read(appNotifierProvider).preview, PreviewMode.web);
    });

    test('restore reseeds the whole state', () {
      app.restore(const AppState(saved: {'s1'}, compared: {'c1'}));
      final state = container.read(appNotifierProvider);
      expect(state.saved, contains('s1'));
      expect(state.compared, contains('c1'));
    });

    test('state is immutable — publishing does not mutate the previous value',
        () {
      final before = container.read(appNotifierProvider);
      app.toggleSaved('p1');
      expect(
        before.saved,
        isEmpty,
        reason: 'previous snapshot must be untouched',
      );
      expect(container.read(appNotifierProvider).saved, contains('p1'));
    });

    test('notifies listeners on every change', () {
      var notifications = 0;
      container.listen(appNotifierProvider, (_, __) => notifications++);
      app.toggleSaved('p1');
      app.setRole(AppRole.admin);
      expect(notifications, 2);
    });
  });

  group('FilterProperties', () {
    const filter = FilterProperties();

    test("filter 'All' matches everything", () {
      final all = _properties();
      expect(
        filter(properties: all, query: '', filter: 'All'),
        hasLength(all.length),
      );
    });

    test('an unmatched filter matches nothing', () {
      expect(
        filter(properties: _properties(), query: '', filter: '__nope__'),
        isEmpty,
      );
    });

    test('query matches against title, city or address', () {
      final all = _properties();
      final first = all.first;
      final byTitle = filter(
        properties: all,
        query: first.title,
        filter: 'All',
      );
      expect(byTitle, isNotEmpty);
      expect(byTitle.first.title, first.title);
    });

    test('query is case-insensitive', () {
      final all = _properties();
      final lower = filter(properties: all, query: 'a', filter: 'All');
      final upper = filter(properties: all, query: 'A', filter: 'All');
      expect(lower.length, upper.length);
    });
  });

  group('EntrepreneurNotifier', () {
    late ProviderContainer container;
    late EntrepreneurNotifier vm;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          getPropertiesProvider
              .overrideWithValue(GetProperties(PropertyRepositoryImpl())),
          getRecommendationsProvider
              .overrideWithValue(GetRecommendations(RecommendationRepositoryImpl())),
          getLocationAnalysisProvider
              .overrideWithValue(GetLocationAnalysis(RecommendationRepositoryImpl())),
          businessPreferencesProvider
              .overrideWithValue(DemoData.defaultPreferences),
        ],
      );
      // Listening keeps the autoDispose provider alive for the whole test.
      container.listen(entrepreneurNotifierProvider, (_, __) {});
      vm = container.read(entrepreneurNotifierProvider.notifier);
    });

    tearDown(() => container.dispose());

    test('starts idle and empty', () {
      final state = container.read(entrepreneurNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.explore, isEmpty);
      expect(state.query, '');
      expect(state.filter, 'All');
    });

    test('loadExplore populates listings and clears loading', () async {
      await vm.loadExplore();
      final state = container.read(entrepreneurNotifierProvider);
      expect(state.explore, isNotEmpty);
      expect(state.loading, isFalse);
      expect(state.error, isNull);
    });

    test('setFilter applies the filter and re-runs the search', () async {
      await vm.loadExplore();
      final all = container.read(entrepreneurNotifierProvider).explore.length;

      vm.setFilter('__nope__');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(entrepreneurNotifierProvider).explore, isEmpty);

      vm.setFilter('All');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(entrepreneurNotifierProvider).explore,
          hasLength(all));
    });

    test('setQuery records the query and filters', () async {
      vm.setQuery('zzzz-no-match');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final state = container.read(entrepreneurNotifierProvider);
      expect(state.query, 'zzzz-no-match');
      expect(state.explore, isEmpty);
    });

    test('loadRecommendations populates the ranked list', () async {
      await vm.loadRecommendations();
      final state = container.read(entrepreneurNotifierProvider);
      expect(state.recommendations, isNotEmpty);
      expect(state.loading, isFalse);
    });

    test('updatePreferences replaces the preferences in state', () async {
      final before = container.read(entrepreneurNotifierProvider).preferences;
      vm.updatePreferences(
        BusinessPreferences(
          businessType: 'Cafe',
          maxBudgetRm: before.maxBudgetRm,
          minSizeSqft: before.minSizeSqft,
        ),
      );
      expect(
        container.read(entrepreneurNotifierProvider).preferences.businessType,
        'Cafe',
      );
    });
  });
}

List<CommercialProperty> _properties() => DemoData.properties;
