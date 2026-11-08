import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';

/// The web state surface: pages watch the shared Riverpod notifiers through
/// the root `ProviderScope`, with `select` slices for the hot regions.
///
/// These tests pin the wiring the pages depend on — the cookie seed override,
/// full-watch and slice rebuild behaviour. The notifier semantics themselves
/// (toggle, the compare cap, restore) are covered in `shared_logic`'s
/// `notifiers_test.dart`.
void main() {
  group('provider scope', () {
    testComponents('the seed override populates the scope', (tester) async {
      // The web composition root (`AppLocator.webOverrides`) installs the
      // cookie-restored state exactly this way.
      tester.pumpComponent(
        ProviderScope(
          overrides: [
            appInitialStateProvider.overrideWithValue(
              const AppState(saved: {'s1'}, compared: {'c1'}),
            ),
          ],
          child: const _WatchProbe(label: 'seeded'),
        ),
      );
      expect(find.text('saved=1'), findsOneComponent);
    });

    testComponents('a full watch rebuilds on any state change', (tester) async {
      var renders = 0;
      tester.pumpComponent(
        ProviderScope(
          child: div([
            _WatchProbe(label: 'full', onBuild: (_) => renders++),
            const _Controls(),
          ]),
        ),
      );
      expect(renders, 1);
      expect(find.text('saved=0'), findsOneComponent);

      await tester.click(
        find.ancestor(of: find.text('toggle'), matching: find.tag('button')),
      );
      await tester.pump();
      expect(renders, 2);
      expect(find.text('saved=1'), findsOneComponent);

      // A role change leaves the rendered count alone but still rebuilds,
      // which is what the pages reading the whole state rely on.
      await tester.click(
        find.ancestor(of: find.text('role'), matching: find.tag('button')),
      );
      await tester.pump();
      expect(renders, 3);
    });

    testComponents('a select slice rebuilds only when the slice changes', (
      tester,
    ) async {
      var renders = 0;
      tester.pumpComponent(
        ProviderScope(
          child: div([
            _SliceProbe(onBuild: (_) => renders++),
            const _Controls(),
          ]),
        ),
      );
      expect(renders, 1);

      // The same slice after an unrelated transition: no rebuild.
      await tester.click(
        find.ancestor(of: find.text('role'), matching: find.tag('button')),
      );
      await tester.pump();
      expect(renders, 1);

      await tester.click(
        find.ancestor(of: find.text('toggle'), matching: find.tag('button')),
      );
      await tester.pump();
      expect(renders, 2);
      expect(find.text('slice=1'), findsOneComponent);
    });
  });
}

/// Renders the saved-set size, watching the whole [AppState].
class _WatchProbe extends StatelessComponent {
  final String label;
  final void Function(AppState app)? onBuild;

  const _WatchProbe({required this.label, this.onBuild});

  @override
  Component build(BuildContext context) {
    final app = context.watch(appNotifierProvider);
    onBuild?.call(app);
    return Component.text('saved=${app.saved.length}');
  }
}

/// Renders the saved-set size through a `select` slice.
class _SliceProbe extends StatelessComponent {
  final void Function(int savedCount)? onBuild;

  const _SliceProbe({this.onBuild});

  @override
  Component build(BuildContext context) {
    final savedCount = context.watch(
      appNotifierProvider.select((app) => app.saved.length),
    );
    onBuild?.call(savedCount);
    return Component.text('slice=$savedCount');
  }
}

/// In-scope triggers, so the transitions fire through the same
/// `context.read(...notifier)` path the real pages use.
class _Controls extends StatelessComponent {
  const _Controls();

  @override
  Component build(BuildContext context) {
    return div([
      button(
        attributes: const {'type': 'button'},
        events: events(
          onClick: () =>
              context.read(appNotifierProvider.notifier).toggleSaved('p1'),
        ),
        [Component.text('toggle')],
      ),
      button(
        attributes: const {'type': 'button'},
        events: events(
          onClick: () =>
              context.read(appNotifierProvider.notifier).setRole(AppRole.admin),
        ),
        [Component.text('role')],
      ),
    ]);
  }
}
