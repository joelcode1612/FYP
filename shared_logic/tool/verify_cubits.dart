// Behavioural verification for the shared application layer.
//
// Type-checking proves the cubits compile; this proves they *behave*. It
// exercises the state transitions directly, including the rules that were easy
// to get wrong when translating from `ChangeNotifier`:
//   * the compare set is capped at three, and a fourth add is a silent no-op
//   * removing from compare is always allowed, even at the cap
//   * `loadExplore` applies query + filter with the original predicate
//   * the query must be in state *before* the filter runs
//
// Run:  dart run tool/verify_cubits.dart
// Not part of the package's public API and not shipped.

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
  // ---------------------------------------------------------------- AppCubit
  print('--- AppCubit ---');
  final app = AppCubit();

  check('initial role', app.state.role, AppRole.entrepreneur);
  check('initial saved is empty', app.state.saved.length, 0);

  app.toggleSaved('p1');
  checkTrue('toggleSaved adds', app.state.isSaved('p1'));
  app.toggleSaved('p1');
  checkTrue('toggleSaved removes on second call', !app.state.isSaved('p1'));

  app.toggleCompared('a');
  app.toggleCompared('b');
  app.toggleCompared('c');
  check('compare holds 3', app.state.compared.length, 3);

  app.toggleCompared('d');
  check('4th add is rejected (cap preserved)', app.state.compared.length, 3);
  checkTrue('rejected id is absent', !app.state.isCompared('d'));

  app.toggleCompared('a');
  check('removing at the cap is allowed', app.state.compared.length, 2);
  app.toggleCompared('d');
  check('add succeeds again after a removal', app.state.compared.length, 3);

  app.clearCompared();
  check('clearCompared empties the set', app.state.compared.length, 0);

  app.setRole(AppRole.owner);
  check('setRole emits', app.state.role, AppRole.owner);
  checkTrue('role label extension is shared', app.state.role.label.isNotEmpty);

  // Immutability: an emitted snapshot must not be mutated by later changes.
  // The old ChangeNotifier mutated its own fields in place, so this is the
  // property that most distinguishes the cubit from what it replaced.
  final snapshot = app.state;
  final savedBefore = snapshot.saved.length;
  app.toggleSaved('later');
  check('previous snapshot is not mutated', snapshot.saved.length, savedBefore);
  checkTrue('new state has the change', app.state.saved.contains('later'));

  // Listener notifications.
  var notifications = 0;
  final sub = app.stream.listen((_) => notifications++);
  app.toggleSaved('p9');
  app.setPreview(PreviewMode.web);
  await Future<void>.delayed(Duration.zero);
  check('listeners notified per emit', notifications, 2);
  await sub.cancel();

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

  // -------------------------------------------------------- EntrepreneurCubit
  print('');
  print('--- EntrepreneurCubit ---');

  final properties = PropertyRepositoryImpl();
  final recommendations = RecommendationRepositoryImpl();

  final cubit = EntrepreneurCubit(
    getProperties: GetProperties(properties),
    getRecommendations: GetRecommendations(recommendations),
    getLocationAnalysis: GetLocationAnalysis(recommendations),
    preferences: DemoData.defaultPreferences,
  );

  check('starts not loading', cubit.state.loading, false);
  check('starts with no listings', cubit.state.explore.length, 0);

  await cubit.loadExplore();
  final all = cubit.state.explore.length;
  checkTrue('loadExplore populated listings', all > 0);
  check('loading cleared after load', cubit.state.loading, false);

  // Filtering: an unmatched filter must yield nothing.
  cubit.setFilter('__no_such_filter__');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  check('unmatched filter yields empty', cubit.state.explore.length, 0);

  cubit.setFilter('All');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  check('filter All restores full list', cubit.state.explore.length, all);

  // A query that matches nothing must also yield nothing.
  cubit.setQuery('zzzz-no-match');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  check('unmatched query yields empty', cubit.state.explore.length, 0);
  check('query is recorded in state', cubit.state.query, 'zzzz-no-match');

  await cubit.loadRecommendations();
  checkTrue(
    'loadRecommendations populated',
    cubit.state.recommendations.isNotEmpty,
  );

  print('');
  print(_failures == 0 ? 'ALL CHECKS PASSED' : '$_failures CHECK(S) FAILED');
}
