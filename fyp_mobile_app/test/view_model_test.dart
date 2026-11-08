import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';

import 'support/fake_auth_repository.dart';

/// The mobile state surface: the Riverpod notifiers from `shared_logic`
/// publish the framework-free controllers' transitions, and the app reads
/// them through one [ProviderScope] whose overrides live in
/// `application/providers.dart`.
///
/// These are the counterparts of `fyp_jaspr_web/test/view_model_test.dart`:
/// the same controller rules, checked through the Riverpod subscription
/// mechanism this app uses.
void main() {
  /// The shared repositories resolve from in-memory demo data, so a drained
  /// microtask queue is enough to settle a load.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  ProviderContainer appContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  ProviderContainer entrepreneurContainer([
    void Function(BusinessPreferences)? onPreferencesUpdated,
  ]) {
    final recommendationRepo = RecommendationRepositoryImpl();
    final container = ProviderContainer(
      overrides: [
        getPropertiesProvider.overrideWithValue(
          GetProperties(PropertyRepositoryImpl()),
        ),
        getRecommendationsProvider.overrideWithValue(
          GetRecommendations(recommendationRepo),
        ),
        getLocationAnalysisProvider.overrideWithValue(
          GetLocationAnalysis(recommendationRepo),
        ),
        businessPreferencesProvider.overrideWithValue(
          DemoData.defaultPreferences,
        ),
        onPreferencesUpdatedProvider.overrideWithValue(
          onPreferencesUpdated ?? (_) {},
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AppNotifier', () {
    test('every controller transition publishes exactly once', () {
      final container = appContainer();
      var publishes = 0;
      container.listen(appNotifierProvider, (_, _) => publishes++);

      container.read(appNotifierProvider.notifier).toggleSaved('p1');
      expect(container.read(appNotifierProvider).saved.contains('p1'), isTrue);
      expect(publishes, 1);

      container.read(appNotifierProvider.notifier).toggleSaved('p1');
      expect(container.read(appNotifierProvider).saved.contains('p1'), isFalse);
      expect(publishes, 2);
    });

    test('the compare cap is a silent no-op, not an error', () {
      final container = appContainer();
      container.read(appNotifierProvider.notifier)
        ..toggleCompared('a')
        ..toggleCompared('b')
        ..toggleCompared('c');
      var publishes = 0;
      container.listen(appNotifierProvider, (_, _) => publishes++);

      expect(container.read(appNotifierProvider).compared.length, 3);

      // Adding a fourth entry leaves the state untouched, so nothing is
      // published and no screen rebuild happens.
      container.read(appNotifierProvider.notifier).toggleCompared('d');
      expect(container.read(appNotifierProvider).compared.length, 3);
      expect(publishes, 0);

      container.read(appNotifierProvider.notifier).clearCompared();
      expect(container.read(appNotifierProvider).compared, isEmpty);
      expect(publishes, 1);
    });

    test('restore reseeds the selection the app persisted', () {
      final container = appContainer();
      container
          .read(appNotifierProvider.notifier)
          .restore(const AppState(saved: {'s1'}, compared: {'c1'}));
      final state = container.read(appNotifierProvider);
      expect(state.saved.contains('s1'), isTrue);
      expect(state.compared.contains('c1'), isTrue);
      expect(state.role, AppRole.entrepreneur);
    });
  });

  group('EntrepreneurNotifier', () {
    test('a load publishes the loading and settled transitions', () async {
      final container = entrepreneurContainer();
      var publishes = 0;
      // The listener doubles as the keep-alive that stops autoDispose from
      // tearing the notifier down mid-test.
      container.listen(entrepreneurNotifierProvider, (_, _) => publishes++);

      await container
          .read(entrepreneurNotifierProvider.notifier)
          .loadExplore();
      await settle();

      final state = container.read(entrepreneurNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.error, isNull);
      expect(state.explore, isNotEmpty);
      // One publish for `loading: true`, one for the results.
      expect(publishes, 2);
    });

    test('setQuery refilters through the same controller', () async {
      final container = entrepreneurContainer();
      final keepAlive = container.listen(
        entrepreneurNotifierProvider,
        (_, _) {},
      );
      await container
          .read(entrepreneurNotifierProvider.notifier)
          .loadExplore();
      await settle();
      final all = container
          .read(entrepreneurNotifierProvider)
          .explore
          .length;

      // The notifier applies the query before re-running the search, so a
      // single call produces the filtered list.
      container
          .read(entrepreneurNotifierProvider.notifier)
          .setQuery('zzzz-no-such-listing');
      await settle();
      expect(
        container.read(entrepreneurNotifierProvider).query,
        'zzzz-no-such-listing',
      );
      expect(container.read(entrepreneurNotifierProvider).explore, isEmpty);

      container.read(entrepreneurNotifierProvider.notifier).setQuery('');
      await settle();
      expect(
        container.read(entrepreneurNotifierProvider).explore.length,
        all,
      );
      keepAlive.close();
    });

    test('a preference write reaches the state and the composition root', () {
      final written = <BusinessPreferences>[];
      final container = entrepreneurContainer(written.add);
      const next = BusinessPreferences(
        businessType: 'Bakery',
        maxBudgetRm: 4000,
        minSizeSqft: 600,
      );

      var publishes = 0;
      container.listen(entrepreneurNotifierProvider, (_, _) => publishes++);
      container
          .read(entrepreneurNotifierProvider.notifier)
          .updatePreferences(next);

      expect(
        container.read(entrepreneurNotifierProvider).preferences.businessType,
        'Bakery',
      );
      expect(written, [next]);
      expect(publishes, 1);
    });

    test('autoDispose rebuilds fresh once the last listener unsubscribes', () async {
      final container = entrepreneurContainer();
      final sub = container.listen(entrepreneurNotifierProvider, (_, _) {});
      await container
          .read(entrepreneurNotifierProvider.notifier)
          .loadExplore();
      await settle();
      container.read(entrepreneurNotifierProvider.notifier).setQuery('gone');
      await settle();

      sub.close();
      await settle();
      await settle();

      // A later listener sees a brand-new notifier: the browsing state was
      // dropped with its last screen, exactly like the old per-route
      // ChangeNotifierProvider lifetime.
      container.listen(entrepreneurNotifierProvider, (_, _) {});
      expect(container.read(entrepreneurNotifierProvider).query, isEmpty);
    });
  });

  group('AuthNotifier', () {
    ProviderContainer authContainer(FakeAuthRepository repo) {
      final container = ProviderContainer(
        overrides: [authServiceProvider.overrideWithValue(AuthService(repo))],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a restore publishes through to external listeners', () async {
      final repo = FakeAuthRepository()..user = testUser();
      final container = authContainer(repo);
      var publishes = 0;
      container.listen(authNotifierProvider, (_, _) => publishes++);

      await container.read(authNotifierProvider.notifier).start();
      await settle();

      final state = container.read(authNotifierProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.user?.role, AppRole.entrepreneur);
      expect(publishes, greaterThan(0));
    });

    test('sign-in and sign-out are the repository results', () async {
      final repo = FakeAuthRepository();
      final container = authContainer(repo);
      final notifier = container.read(authNotifierProvider.notifier);

      final ok = await notifier.signIn(
        email: 'sarah@artisanbrew.my',
        password: 'correct-horse',
      );
      await settle();

      expect(ok, isTrue);
      expect(container.read(authNotifierProvider).isAuthenticated, isTrue);
      expect(container.read(authNotifierProvider).email, isNull);
      expect(repo.lastSignInEmail, 'sarah@artisanbrew.my');

      await notifier.signOut();
      await settle();
      expect(container.read(authNotifierProvider).isAuthenticated, isFalse);
      expect(
        container.read(authNotifierProvider).status,
        AuthStatus.unauthenticated,
      );
      expect(repo.signOutCalls, 1);
    });

    test('an unavailable auth service becomes a status, not an exception',
        () async {
      final repo = FakeAuthRepository()
        ..restoreFailure = const AuthUnavailableFailure();
      final container = authContainer(repo);
      var publishes = 0;
      container.listen(authNotifierProvider, (_, _) => publishes++);

      await container.read(authNotifierProvider.notifier).start();
      await settle();

      expect(container.read(authNotifierProvider).status, AuthStatus.error);
      expect(container.read(authNotifierProvider).message, isNotNull);
      expect(publishes, greaterThan(0));
    });
  });

  group('provider scope', () {
    testWidgets('Consumer rebuilds on any state change', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var renders = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, child) {
                renders++;
                final saved = ref.watch(appNotifierProvider).saved.length;
                return Text('saved=$saved');
              },
            ),
          ),
        ),
      );
      expect(find.text('saved=0'), findsOneWidget);
      expect(renders, 1);

      container.read(appNotifierProvider.notifier).toggleSaved('p1');
      await tester.pump();
      expect(renders, 2);
      expect(find.text('saved=1'), findsOneWidget);

      // A role change leaves the rendered text alone but still rebuilds, which
      // is what the screens that read `saved` through the root scope rely on.
      container.read(appNotifierProvider.notifier).setRole(AppRole.admin);
      await tester.pump();
      expect(renders, 3);
    });

    testWidgets('select rebuilds only when its slice changes', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var renders = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, child) {
                final savedCount = ref.watch(
                  appNotifierProvider.select((state) => state.saved.length),
                );
                renders++;
                return Text('saved=$savedCount');
              },
            ),
          ),
        ),
      );
      expect(renders, 1);

      // The same slice after an unrelated transition: no rebuild.
      container.read(appNotifierProvider.notifier).setRole(AppRole.owner);
      await tester.pump();
      expect(renders, 1);

      container.read(appNotifierProvider.notifier).toggleSaved('p1');
      await tester.pump();
      expect(renders, 2);
      expect(find.text('saved=1'), findsOneWidget);
    });

    testWidgets(
      'select keeps the shell out of saved/compare rebuilds',
      (tester) async {
        // What `MobileAppShell` and the top bar rely on: they show the role and
        // the tab bar, and must not repaint when a property is shortlisted.
        final container = ProviderContainer();
        addTearDown(container.dispose);
        var renders = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Consumer(
                builder: (context, ref, child) {
                  final role = ref.watch(
                    appNotifierProvider.select((state) => state.role),
                  );
                  renders++;
                  return Text('role=${role.name}');
                },
              ),
            ),
          ),
        );
        expect(renders, 1);

        container.read(appNotifierProvider.notifier)
          ..toggleSaved('p1')
          ..toggleCompared('p2');
        await tester.pump();
        expect(renders, 1);

        container.read(appNotifierProvider.notifier).setRole(AppRole.agent);
        await tester.pump();
        expect(renders, 2);
        expect(find.text('role=agent'), findsOneWidget);
      },
    );

    testWidgets('the container owns the state, not the widget tree', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, child) =>
                  Text('role=${ref.watch(appNotifierProvider).role.name}'),
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

      // Still usable after the tree unmounted: the notifier is container-owned
      // (as [ServiceLocator]'s old app-lifetime singletons were), so tearing
      // down screens cannot drop the app state.
      container.read(appNotifierProvider.notifier).toggleSaved('p1');
      expect(container.read(appNotifierProvider).saved.contains('p1'), isTrue);
    });
  });
}
