// Behavioural verification for the shared application layer.
//
// Type-checking proves the notifiers compile; this proves they *behave*. It
// exercises the state transitions directly, including the rules that were easy
// to get wrong when translating from `ChangeNotifier`:
//   * the compare set is capped at three, and a fourth add is a silent no-op
//   * removing from compare is always allowed, even at the cap
//   * `loadExplore` applies query + filter with the original predicate
//   * the query must be in state *before* the filter runs
//
// Run:  dart run tool/verify_notifiers.dart
// Not part of the package's public API and not shipped.

import 'package:riverpod/riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

int _failures = 0;

void check(String label, Object? actual, Object? expected) {
  final ok = '$actual' == '$expected';
  if (!ok) _failures++;
  print('${ok ? "PASS" : "FAIL"}  $label  (got: $actual, want: $expected)');
}

void checkTrue(String label, bool actual) {
  if (!actual) _failures++;
  print('${actual ? "PASS" : "FAIL"}  $label');
}

Future<void> main() async {
  // ------------------------------------------------------------- AppNotifier
  print('--- AppNotifier ---');
  final container = ProviderContainer();
  final app = container.read(appNotifierProvider.notifier);

  check('initial role', container.read(appNotifierProvider).role, AppRole.entrepreneur);
  check('initial saved is empty', container.read(appNotifierProvider).saved.length, 0);

  app.toggleSaved('p1');
  checkTrue('toggleSaved adds', container.read(appNotifierProvider).isSaved('p1'));
  app.toggleSaved('p1');
  checkTrue('toggleSaved removes on second call', !container.read(appNotifierProvider).isSaved('p1'));

  app.toggleCompared('a');
  app.toggleCompared('b');
  app.toggleCompared('c');
  check('compare holds 3', container.read(appNotifierProvider).compared.length, 3);

  app.toggleCompared('d');
  check('4th add is rejected (cap preserved)', container.read(appNotifierProvider).compared.length, 3);
  checkTrue('rejected id is absent', !container.read(appNotifierProvider).isCompared('d'));

  app.toggleCompared('a');
  check('removing at the cap is allowed', container.read(appNotifierProvider).compared.length, 2);
  app.toggleCompared('d');
  check('add succeeds again after a removal', container.read(appNotifierProvider).compared.length, 3);

  app.clearCompared();
  check('clearCompared empties the set', container.read(appNotifierProvider).compared.length, 0);

  app.setRole(AppRole.owner);
  check('setRole publishes', container.read(appNotifierProvider).role, AppRole.owner);
  checkTrue('role label extension is shared', container.read(appNotifierProvider).role.label.isNotEmpty);

  // Immutability: a published snapshot must not be mutated by later changes.
  // The old ChangeNotifier mutated its own fields in place, so this is the
  // property that most distinguishes the notifier from what it replaced.
  final snapshot = container.read(appNotifierProvider);
  final savedBefore = snapshot.saved.length;
  app.toggleSaved('later');
  check('previous snapshot is not mutated', snapshot.saved.length, savedBefore);
  checkTrue('new state has the change', container.read(appNotifierProvider).saved.contains('later'));

  // Listener notifications.
  var notifications = 0;
  container.listen(appNotifierProvider, (_, __) => notifications++);
  app.toggleSaved('p9');
  app.setPreview(PreviewMode.web);
  check('listeners notified per publish', notifications, 2);

  container.dispose();

  // ------------------------------------------------------------ FilterProperties
  print('');
  print('--- FilterProperties ---');
  const filter = FilterProperties();
  final allProps = DemoData.properties;
  check(
    "filter 'All' matches everything",
    filter(properties: allProps, query: '', filter: 'All').length,
    allProps.length,
  );
  check(
    'unmatched filter matches nothing',
    filter(properties: allProps, query: '', filter: '__nope__').length,
    0,
  );
  check(
    'query is case-insensitive',
    filter(properties: allProps, query: 'a', filter: 'All').length,
    filter(properties: allProps, query: 'A', filter: 'All').length,
  );

  // ------------------------------------------------------ EntrepreneurNotifier
  print('');
  print('--- EntrepreneurNotifier ---');

  final entrepreneurContainer = ProviderContainer(
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
  // Listening keeps the autoDispose provider alive for the whole run.
  entrepreneurContainer.listen(entrepreneurNotifierProvider, (_, __) {});
  final vm = entrepreneurContainer.read(entrepreneurNotifierProvider.notifier);

  check('starts not loading', entrepreneurContainer.read(entrepreneurNotifierProvider).loading, false);
  check('starts with no listings', entrepreneurContainer.read(entrepreneurNotifierProvider).explore.length, 0);

  await vm.loadExplore();
  final all = entrepreneurContainer.read(entrepreneurNotifierProvider).explore.length;
  checkTrue('loadExplore populated listings', all > 0);
  check('loading cleared after load', entrepreneurContainer.read(entrepreneurNotifierProvider).loading, false);

  // Filtering: an unmatched filter must yield nothing.
  vm.setFilter('__no_such_filter__');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  check('unmatched filter yields empty', entrepreneurContainer.read(entrepreneurNotifierProvider).explore.length, 0);

  vm.setFilter('All');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  check('filter All restores full list', entrepreneurContainer.read(entrepreneurNotifierProvider).explore.length, all);

  // A query that matches nothing must also yield nothing.
  vm.setQuery('zzzz-no-match');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  check('unmatched query yields empty', entrepreneurContainer.read(entrepreneurNotifierProvider).explore.length, 0);
  check('query is recorded in state', entrepreneurContainer.read(entrepreneurNotifierProvider).query, 'zzzz-no-match');

  await vm.loadRecommendations();
  checkTrue(
    'loadRecommendations populated',
    entrepreneurContainer.read(entrepreneurNotifierProvider).recommendations.isNotEmpty,
  );

  entrepreneurContainer.dispose();

  print('');
  print(_failures == 0 ? 'ALL CHECKS PASSED' : '$_failures CHECK(S) FAILED');
}
