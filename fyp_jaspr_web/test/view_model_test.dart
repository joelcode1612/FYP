import 'package:jaspr/jaspr.dart';
import 'package:jaspr_provider_compat/jaspr_provider_compat.dart' as provider;
import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/state/app_view_model.dart';

/// The web state surface: [AppViewModel] turns `shared_logic` controller
/// transitions into `ChangeNotifier` notifications, and the provider scope the
/// pages install publishes it to `Consumer`/`Selector` builders.
///
/// These replace the old `CubitBuilder` stream-subscription tests: the scoping
/// rule those checked (`when`) is now a `Selector` slice, so each case pins the
/// rebuild behaviour a page actually depends on.
void main() {
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
      // published and no widget rebuild happens.
      vm.toggleCompared('d');
      expect(vm.compared.length, AppState.maxCompare);
      expect(notifies, 0);

      vm.clearCompared();
      expect(vm.compared, isEmpty);
      expect(notifies, 1);
    });

    test('restore reseeds the cookie-installed selection', () {
      final vm = AppViewModel();
      vm.restore(const AppState(saved: {'s1'}, compared: {'c1'}));
      expect(vm.isSaved('s1'), isTrue);
      expect(vm.isCompared('c1'), isTrue);
      expect(vm.role, AppRole.entrepreneur);
    });
  });

  group('provider scope', () {
    testComponents('Consumer rebuilds on any notification', (tester) async {
      final vm = AppViewModel();
      var renders = 0;
      tester.pumpComponent(
        provider.ChangeNotifierProvider<AppViewModel>.value(
          value: vm,
          child: provider.Consumer<AppViewModel>(
            builder: (context, model, child) {
              renders++;
              return Component.text('saved=${model.saved.length}');
            },
          ),
        ),
      );
      expect(find.text('saved=0'), findsOneComponent);
      expect(renders, 1);

      vm.toggleSaved('p1');
      await tester.pump();
      expect(renders, 2);
      expect(find.text('saved=1'), findsOneComponent);

      // A role change leaves the rendered text alone but still rebuilds, which
      // is what the pages that read `saved` through the locator rely on.
      vm.setRole(AppRole.admin);
      await tester.pump();
      expect(renders, 3);
    });

    testComponents('Selector rebuilds only when its slice changes', (
      tester,
    ) async {
      final vm = AppViewModel();
      var renders = 0;
      tester.pumpComponent(
        provider.ChangeNotifierProvider<AppViewModel>.value(
          value: vm,
          child: provider.Selector<AppViewModel, int>(
            selector: (context, model) => model.saved.length,
            builder: (context, savedCount, child) {
              renders++;
              return Component.text('saved=$savedCount');
            },
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
      expect(find.text('saved=1'), findsOneComponent);
    });

    testComponents('.value does not dispose the instance the root owns', (
      tester,
    ) async {
      final vm = AppViewModel();
      tester.pumpComponent(
        provider.ChangeNotifierProvider<AppViewModel>.value(
          value: vm,
          child: provider.Consumer<AppViewModel>(
            builder: (context, model, child) =>
                Component.text('role=${model.role.name}'),
          ),
        ),
      );
      tester.pumpComponent(Component.text('scope removed'));
      await tester.pump();

      // Still usable after the scope unmounted: adding a listener after
      // dispose would throw, so this proves the provider never owned it.
      vm.toggleSaved('p1');
      expect(vm.isSaved('p1'), isTrue);
    });
  });
}
