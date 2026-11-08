import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/application/state/app_view_model.dart';
import 'package:fyp/application/state/auth_view_model.dart';
import 'package:fyp/application/state/entrepreneur_view_model.dart';

import 'support/fake_auth_repository.dart';

/// The mobile state surface: three [ChangeNotifier] view models adapt the
/// framework-free controllers in `shared_logic`, and the root `MultiProvider`
/// plus the per-page `ChangeNotifierProvider`s publish them to
/// `Consumer`/`Selector`/`context.select` builders.
///
/// These are the counterparts of `fyp_jaspr_web/test/view_model_test.dart`: the
/// same controller rules, checked through the Flutter notification mechanism
/// this app uses instead of the Jaspr one.
void main() {
  /// The shared repositories resolve from in-memory demo data, so a drained
  /// microtask queue is enough to settle a load.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  EntrepreneurViewModel entrepreneurVm([
    void Function(BusinessPreferences)? onPreferencesUpdated,
  ]) {
    final recommendationRepo = RecommendationRepositoryImpl();
    return EntrepreneurViewModel(
      EntrepreneurController(
        getProperties: GetProperties(PropertyRepositoryImpl()),
        getRecommendations: GetRecommendations(recommendationRepo),
        getLocationAnalysis: GetLocationAnalysis(recommendationRepo),
        preferences: DemoData.defaultPreferences,
        onPreferencesUpdated: onPreferencesUpdated,
      ),
    );
  }

  group('AppViewModel as a ChangeNotifier', () {
    test('every controller transition notifies exactly once', () {
      final vm = AppViewModel();
      var notifies = 0;
      vm.addListener(() => notifies++);

      vm.toggleSaved('p1');
      expect(vm.isSaved('p1'), isTrue);
      expect(notifies, 1);

      vm.toggleSaved('p1');
      expect(vm.isSaved('p1'), isFalse);
      expect(notifies, 2);
    });

    test('the compare cap is a silent no-op, not an error', () {
      final vm = AppViewModel();
      var notifies = 0;
      vm
        ..toggleCompared('a')
        ..toggleCompared('b')
        ..toggleCompared('c')
        ..addListener(() => notifies++);

      expect(vm.compared.length, AppState.maxCompare);

      // Adding a fourth entry leaves the state untouched, so nothing is
      // published and no screen rebuild happens.
      vm.toggleCompared('d');
      expect(vm.compared.length, AppState.maxCompare);
      expect(notifies, 0);

      vm.clearCompared();
      expect(vm.compared, isEmpty);
      expect(notifies, 1);
    });

    test('restore reseeds the selection the app persisted', () {
      final vm = AppViewModel();
      vm.restore(const AppState(saved: {'s1'}, compared: {'c1'}));
      expect(vm.isSaved('s1'), isTrue);
      expect(vm.isCompared('c1'), isTrue);
      expect(vm.role, AppRole.entrepreneur);
    });
  });

  group('EntrepreneurViewModel as a ChangeNotifier', () {
    test('a load publishes the loading and settled transitions', () async {
      final vm = entrepreneurVm();
      var notifies = 0;
      vm.addListener(() => notifies++);

      await vm.loadExplore();
      await settle();

      expect(vm.loading, isFalse);
      expect(vm.error, isNull);
      expect(vm.explore, isNotEmpty);
      // One notification for `loading: true`, one for the results.
      expect(notifies, 2);

      vm.dispose();
    });

    test('setQuery refilters through the same controller', () async {
      final vm = entrepreneurVm();
      await vm.loadExplore();
      await settle();
      final all = vm.explore.length;

      // The controller applies the query before re-running the search, so a
      // single view-model call produces the filtered list.
      vm.setQuery('zzzz-no-such-listing');
      await settle();
      expect(vm.query, 'zzzz-no-such-listing');
      expect(vm.explore, isEmpty);

      vm.setQuery('');
      await settle();
      expect(vm.explore.length, all);

      vm.dispose();
    });

    test('a preference write reaches the state and the composition root', () {
      final vm = entrepreneurVm();
      final written = <BusinessPreferences>[];
      final captured = entrepreneurVm(written.add);
      const next = BusinessPreferences(
        businessType: 'Bakery',
        maxBudgetRm: 4000,
        minSizeSqft: 600,
      );

      var notifies = 0;
      captured.addListener(() => notifies++);
      captured.updatePreferences(next);

      expect(captured.prefs.businessType, 'Bakery');
      expect(written, [next]);
      expect(notifies, 1);

      vm.dispose();
      captured.dispose();
    });

    test('dispose unhooks the controller it owns', () async {
      final vm = entrepreneurVm();
      await vm.loadExplore();
      await settle();
      final loaded = vm.explore.length;
      var notifies = 0;
      vm.addListener(() => notifies++);

      vm.dispose();
      // The controller is disposed with the view model, so a late call is
      // inert: `setState` returns before notifying, and the already-disposed
      // notifier is never touched again.
      vm.setQuery('zzzz-no-such-listing');
      await settle();
      expect(notifies, 0);
      expect(vm.query, isEmpty);
      expect(vm.explore.length, loaded);
    });
  });

  group('AuthViewModel as a notification adapter', () {
    test('one notification per cubit emission, and none invented', () async {
      final repo = FakeAuthRepository()..user = testUser();
      final cubit = AuthCubit(auth: AuthService(repo));
      final vm = AuthViewModel(cubit: cubit);
      var emits = 0;
      var notifies = 0;
      cubit.stream.listen((_) => emits++);
      vm.addListener(() => notifies++);

      await vm.start();
      await settle();

      expect(vm.status, AuthStatus.authenticated);
      expect(vm.user?.role, AppRole.entrepreneur);
      expect(emits, greaterThan(0));
      expect(notifies, emits);

      await vm.dispose();
      await cubit.close();
    });

    test('sign-in and sign-out are the repository results', () async {
      final repo = FakeAuthRepository();
      final cubit = AuthCubit(auth: AuthService(repo));
      final vm = AuthViewModel(cubit: cubit);

      final ok = await vm.signIn(
        email: 'sarah@artisanbrew.my',
        password: 'correct-horse',
      );
      await settle();

      expect(ok, isTrue);
      expect(vm.isAuthenticated, isTrue);
      expect(vm.email, isNull);
      expect(repo.lastSignInEmail, 'sarah@artisanbrew.my');

      await vm.signOut();
      await settle();
      expect(vm.isAuthenticated, isFalse);
      expect(vm.status, AuthStatus.unauthenticated);
      expect(repo.signOutCalls, 1);

      await vm.dispose();
      await cubit.close();
    });

    test(
      'an unavailable auth service becomes a status, not an exception',
      () async {
        final repo = FakeAuthRepository()
          ..restoreFailure = const AuthUnavailableFailure();
        final cubit = AuthCubit(auth: AuthService(repo));
        final vm = AuthViewModel(cubit: cubit);
        var notifies = 0;
        vm.addListener(() => notifies++);

        await vm.start();
        await settle();

        expect(vm.status, AuthStatus.error);
        expect(vm.message, isNotNull);
        expect(notifies, greaterThan(0));

        await vm.dispose();
        await cubit.close();
      },
    );

    test('disposing the adapter leaves the cubit owning the session', () async {
      final repo = FakeAuthRepository();
      final cubit = AuthCubit(auth: AuthService(repo));
      final vm = AuthViewModel(cubit: cubit);

      await vm.dispose();
      expect(cubit.isClosed, isFalse);

      // The state machine still does its job — the adapter never owned it, so
      // removing a `provider` scope cannot drop a session.
      repo.user = testUser(role: AppRole.admin);
      await cubit.retry();
      expect(vm.status, AuthStatus.authenticated);
      expect(vm.role, AppRole.admin);

      await cubit.close();
    });
  });

  group('provider scope', () {
    testWidgets('Consumer rebuilds on any notification', (tester) async {
      final vm = AppViewModel();
      var renders = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ChangeNotifierProvider<AppViewModel>.value(
            value: vm,
            child: Consumer<AppViewModel>(
              builder: (context, model, child) {
                renders++;
                return Text('saved=${model.saved.length}');
              },
            ),
          ),
        ),
      );
      expect(find.text('saved=0'), findsOneWidget);
      expect(renders, 1);

      vm.toggleSaved('p1');
      await tester.pump();
      expect(renders, 2);
      expect(find.text('saved=1'), findsOneWidget);

      // A role change leaves the rendered text alone but still rebuilds, which
      // is what the screens that read `saved` through the root scope rely on.
      vm.setRole(AppRole.admin);
      await tester.pump();
      expect(renders, 3);

      vm.dispose();
    });

    testWidgets('Selector rebuilds only when its slice changes', (
      tester,
    ) async {
      final vm = AppViewModel();
      var renders = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ChangeNotifierProvider<AppViewModel>.value(
            value: vm,
            child: Selector<AppViewModel, int>(
              selector: (context, model) => model.saved.length,
              builder: (context, savedCount, child) {
                renders++;
                return Text('saved=$savedCount');
              },
            ),
          ),
        ),
      );
      expect(renders, 1);

      // The same slice after an unrelated transition: no rebuild.
      vm.setRole(AppRole.owner);
      await tester.pump();
      expect(renders, 1);

      vm.toggleSaved('p1');
      await tester.pump();
      expect(renders, 2);
      expect(find.text('saved=1'), findsOneWidget);

      vm.dispose();
    });

    testWidgets(
      'context.select keeps the shell out of saved/compare rebuilds',
      (tester) async {
        // What `MobileAppShell` and the top bar rely on: they show the role and
        // the tab bar, and must not repaint when a property is shortlisted.
        final vm = AppViewModel();
        var renders = 0;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ChangeNotifierProvider<AppViewModel>.value(
              value: vm,
              child: Builder(
                builder: (context) {
                  final role = context.select<AppViewModel, AppRole>(
                    (v) => v.role,
                  );
                  renders++;
                  return Text('role=${role.name}');
                },
              ),
            ),
          ),
        );
        expect(renders, 1);

        vm
          ..toggleSaved('p1')
          ..toggleCompared('p2');
        await tester.pump();
        expect(renders, 1);

        vm.setRole(AppRole.agent);
        await tester.pump();
        expect(renders, 2);
        expect(find.text('role=agent'), findsOneWidget);

        vm.dispose();
      },
    );

    testWidgets('.value does not dispose the instance the root owns', (
      tester,
    ) async {
      final vm = AppViewModel();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ChangeNotifierProvider<AppViewModel>.value(
            value: vm,
            child: Consumer<AppViewModel>(
              builder: (context, model, child) =>
                  Text('role=${model.role.name}'),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('scope removed'),
        ),
      );

      // Still usable after the scope unmounted: adding a listener after
      // dispose would throw, so this proves the provider never owned it — the
      // same rule [ServiceLocator.appViewModel] depends on.
      vm.toggleSaved('p1');
      expect(vm.isSaved('p1'), isTrue);

      vm.dispose();
    });
  });
}
