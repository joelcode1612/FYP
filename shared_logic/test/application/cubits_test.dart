import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// Behavioural tests for the shared application layer.
///
/// These are the first tests over this logic in the project — the Flutter app
/// shipped the equivalent code (`AppState`, `EntrepreneurViewModel`) with no
/// test coverage at all. They exist mainly to protect the `ChangeNotifier` ->
/// `Cubit` translation: the rules below were the ones most likely to be lost in
/// the move.
void main() {
  group('AppCubit', () {
    late AppCubit cubit;

    setUp(() => cubit = AppCubit());

    test('starts with the entrepreneur role and empty sets', () {
      expect(cubit.state.role, AppRole.entrepreneur);
      expect(cubit.state.saved, isEmpty);
      expect(cubit.state.compared, isEmpty);
    });

    test('toggleSaved adds then removes', () {
      cubit.toggleSaved('p1');
      expect(cubit.state.isSaved('p1'), isTrue);
      cubit.toggleSaved('p1');
      expect(cubit.state.isSaved('p1'), isFalse);
    });

    test('compare is capped at three and a fourth add is a no-op', () {
      for (final id in ['a', 'b', 'c']) {
        cubit.toggleCompared(id);
      }
      expect(cubit.state.compared, hasLength(AppState.maxCompare));

      cubit.toggleCompared('d');
      expect(cubit.state.compared, hasLength(3));
      expect(cubit.state.isCompared('d'), isFalse);
    });

    test('removing from compare is allowed at the cap, then adding works', () {
      for (final id in ['a', 'b', 'c']) {
        cubit.toggleCompared(id);
      }
      cubit.toggleCompared('a');
      expect(cubit.state.compared, hasLength(2));

      cubit.toggleCompared('d');
      expect(cubit.state.compared, hasLength(3));
    });

    test('clearCompared empties the set', () {
      cubit.toggleCompared('a');
      cubit.clearCompared();
      expect(cubit.state.compared, isEmpty);
    });

    test('setRole and setPreview emit', () {
      cubit.setRole(AppRole.owner);
      expect(cubit.state.role, AppRole.owner);

      cubit.setPreview(PreviewMode.web);
      expect(cubit.state.preview, PreviewMode.web);
    });

    test(
      'state is immutable — emitting does not mutate the previous value',
      () {
        final before = cubit.state;
        cubit.toggleSaved('p1');
        expect(
          before.saved,
          isEmpty,
          reason: 'previous snapshot must be untouched',
        );
        expect(cubit.state.saved, contains('p1'));
      },
    );

    test('notifies listeners on every change', () {
      var notifications = 0;
      final sub = cubit.stream.listen((_) => notifications++);
      cubit.toggleSaved('p1');
      cubit.setRole(AppRole.admin);
      return Future<void>.delayed(Duration.zero).then((_) async {
        expect(notifications, 2);
        await sub.cancel();
      });
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

  group('EntrepreneurCubit', () {
    late EntrepreneurCubit cubit;

    setUp(() {
      final properties = PropertyRepositoryImpl();
      final recommendations = RecommendationRepositoryImpl();
      cubit = EntrepreneurCubit(
        getProperties: GetProperties(properties),
        getRecommendations: GetRecommendations(recommendations),
        getLocationAnalysis: GetLocationAnalysis(recommendations),
        preferences: DemoData.defaultPreferences,
      );
    });

    test('starts idle and empty', () {
      expect(cubit.state.loading, isFalse);
      expect(cubit.state.explore, isEmpty);
      expect(cubit.state.query, '');
      expect(cubit.state.filter, 'All');
    });

    test('loadExplore populates listings and clears loading', () async {
      await cubit.loadExplore();
      expect(cubit.state.explore, isNotEmpty);
      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, isNull);
    });

    test('setFilter applies the filter and re-runs the search', () async {
      await cubit.loadExplore();
      final all = cubit.state.explore.length;

      cubit.setFilter('__nope__');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cubit.state.explore, isEmpty);

      cubit.setFilter('All');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cubit.state.explore, hasLength(all));
    });

    test('setQuery records the query and filters', () async {
      cubit.setQuery('zzzz-no-match');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cubit.state.query, 'zzzz-no-match');
      expect(cubit.state.explore, isEmpty);
    });

    test('loadRecommendations populates the ranked list', () async {
      await cubit.loadRecommendations();
      expect(cubit.state.recommendations, isNotEmpty);
      expect(cubit.state.loading, isFalse);
    });

    test('updatePreferences replaces the preferences in state', () async {
      final before = cubit.state.preferences;
      cubit.updatePreferences(
        BusinessPreferences(
          businessType: 'Cafe',
          maxBudgetRm: before.maxBudgetRm,
          minSizeSqft: before.minSizeSqft,
        ),
      );
      expect(cubit.state.preferences.businessType, 'Cafe');
    });
  });
}

List<CommercialProperty> _properties() => DemoData.properties;
