import 'package:jaspr/jaspr.dart';
import 'package:jaspr_provider_compat/jaspr_provider_compat.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// A notifier that reports how many listeners are attached to it, which is how
/// these tests see whether a render subscribed.
class _Counter extends ChangeNotifier {
  int value = 0;
  bool disposed = false;
  int _live = 0;

  int get liveListeners => _live;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _live++;
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _live--;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  void increment([int by = 1]) {
    value += by;
    notifyListeners();
  }
}

/// A plain settings object — the kind of value [Provider] is for, where a
/// listenable-backed provider would be wrong.
class _Settings {
  const _Settings(this.label);
  final String label;
}

class _WatchCount extends StatelessComponent {
  const _WatchCount();

  @override
  Component build(BuildContext context) {
    return Component.text('n=${context.watch<_Counter>().value}');
  }
}

class _ReadCount extends StatelessComponent {
  const _ReadCount();

  @override
  Component build(BuildContext context) {
    // `read` deliberately does not subscribe, so this text is expected to go
    // stale until something else rebuilds the component.
    return Component.text('n=${context.read<_Counter>().value}');
  }
}

class _ThrowReader extends StatelessComponent {
  const _ThrowReader(this.onError);

  final void Function(Object error) onError;

  @override
  Component build(BuildContext context) {
    try {
      context.read<_Counter>();
    } on Object catch (error) {
      onError(error);
    }
    return Component.text('read attempted');
  }
}

void main() {
  group('Provider lookup', () {
    testComponents('a value provider is readable without any subscription', (
      tester,
    ) async {
      tester.pumpComponent(
        Provider<_Settings>.value(
          value: const _Settings('dark'),
          child: Builder(
            builder: (context) =>
                Component.text('label=${context.read<_Settings>().label}'),
          ),
        ),
      );

      expect(find.text('label=dark'), findsOneComponent);
    });

    testComponents('a missing provider raises ProviderNotFoundException', (
      tester,
    ) async {
      Object? captured;
      tester.pumpComponent(_ThrowReader((error) => captured = error));

      expect(captured, isA<ProviderNotFoundException>());
      expect(
        captured.toString(),
        contains('Could not find the correct Provider<_Counter>'),
      );
    });

    testComponents('providers match on the exact type argument', (
      tester,
    ) async {
      Object? captured;
      tester.pumpComponent(
        Provider<_Settings>.value(
          value: const _Settings('x'),
          child: _ThrowReader((error) => captured = error),
        ),
      );

      // A provider for `_Settings` cannot answer a read for `_Counter`.
      expect(captured, isA<ProviderNotFoundException>());
    });
  });

  group('ChangeNotifierProvider', () {
    testComponents('watch rebuilds when the notifier fires', (tester) async {
      final counter = _Counter();

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: counter,
          child: const _WatchCount(),
        ),
      );
      expect(find.text('n=0'), findsOneComponent);
      // The provider holds the only subscription; consumers depend on the
      // scope, not on the notifier itself.
      expect(counter.liveListeners, 1);

      counter.increment();
      await tester.pump();

      expect(find.text('n=1'), findsOneComponent);
      expect(find.text('n=0'), findsNothing);
      expect(counter.liveListeners, 1);
    });

    testComponents('read does not rebuild', (tester) async {
      final counter = _Counter();

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: counter,
          child: const _ReadCount(),
        ),
      );
      expect(find.text('n=0'), findsOneComponent);

      counter.increment();
      await tester.pump();

      expect(find.text('n=0'), findsOneComponent);
      expect(find.text('n=1'), findsNothing);
    });

    testComponents('create runs once, and its value is disposed on unmount', (
      tester,
    ) async {
      final created = <_Counter>[];

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>(
          create: (context) {
            final counter = _Counter();
            created.add(counter);
            return counter;
          },
          child: const _WatchCount(),
        ),
      );
      expect(created.length, 1);
      expect(created.single.liveListeners, 1);

      // The provider rebuilds on every notification, and must not re-create.
      created.single.increment();
      await tester.pump();
      expect(created.length, 1);
      expect(find.text('n=1'), findsOneComponent);

      tester.binding.detachRootComponent();
      expect(created.single.disposed, isTrue);
      expect(created.single.liveListeners, 0);
    });

    testComponents('.value keeps the object alive and drops its subscription', (
      tester,
    ) async {
      final counter = _Counter();

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: counter,
          child: const _WatchCount(),
        ),
      );
      tester.binding.detachRootComponent();

      expect(counter.disposed, isFalse);
      expect(counter.liveListeners, 0);
    });

    testComponents('a tree that is replaced resubscribes to its notifier', (
      tester,
    ) async {
      final first = _Counter();
      final second = _Counter();

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: first,
          child: const _WatchCount(),
        ),
      );
      tester.binding.detachRootComponent();
      expect(first.liveListeners, 0);

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: second,
          child: const _WatchCount(),
        ),
      );
      expect(second.liveListeners, 1);

      second.increment();
      await tester.pump();
      expect(find.text('n=1'), findsOneComponent);
    });
  });

  group('Consumer, Selector and context.select', () {
    testComponents('Consumer rebuilds on notification', (tester) async {
      final counter = _Counter();

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: counter,
          child: Consumer<_Counter>(
            builder:
                (context, value, child) => Component.text('n=${value.value}'),
          ),
        ),
      );
      expect(find.text('n=0'), findsOneComponent);

      counter.increment(3);
      await tester.pump();
      expect(find.text('n=3'), findsOneComponent);
    });

    testComponents('Selector skips notifications that leave its slice alone', (
      tester,
    ) async {
      final counter = _Counter();
      var builds = 0;

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: counter,
          child: Selector<_Counter, String>(
            selector: (context, value) => value.value.isOdd ? 'odd' : 'even',
            builder: (context, parity, child) {
              builds++;
              return Component.text('parity=$parity');
            },
          ),
        ),
      );
      expect(find.text('parity=even'), findsOneComponent);
      expect(builds, 1);

      // +2 keeps the parity identical: the selected value did not change, so
      // nothing is rebuilt even though the notifier fired.
      counter.increment(2);
      await tester.pump();
      expect(find.text('parity=even'), findsOneComponent);
      expect(builds, 1);

      counter.increment();
      await tester.pump();
      expect(find.text('parity=odd'), findsOneComponent);
      expect(builds, 2);
    });

    testComponents('rebuildWhen decides what counts as a change', (
      tester,
    ) async {
      final counter = _Counter();
      var builds = 0;

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: counter,
          child: Selector<_Counter, String>(
            selector: (context, value) => 'n${value.value}',
            // Rebuild only once the value has grown past 5.
            rebuildWhen: (previous, next) => counter.value > 5,
            builder: (context, label, child) {
              builds++;
              return Component.text(label);
            },
          ),
        ),
      );
      expect(find.text('n0'), findsOneComponent);
      expect(builds, 1);

      counter.increment(3);
      await tester.pump();
      expect(builds, 1);

      counter.increment(3); // now 6
      await tester.pump();
      expect(builds, 2);
      expect(find.text('n6'), findsOneComponent);
    });

    testComponents('context.select rebuilds only for its own slice', (
      tester,
    ) async {
      final counter = _Counter();
      var builds = 0;

      tester.pumpComponent(
        ChangeNotifierProvider<_Counter>.value(
          value: counter,
          child: Builder(
            builder: (context) {
              builds++;
              final isOdd = context.select(
                (_Counter value) => value.value.isOdd,
              );
              return Component.text('odd=$isOdd');
            },
          ),
        ),
      );
      expect(find.text('odd=false'), findsOneComponent);
      expect(builds, 1);

      counter.increment(2);
      await tester.pump();
      expect(builds, 1);

      counter.increment();
      await tester.pump();
      expect(find.text('odd=true'), findsOneComponent);
      expect(builds, 2);
    });
  });

  group('MultiProvider', () {
    testComponents('nests providers so each is readable by type', (
      tester,
    ) async {
      final counter = _Counter();

      tester.pumpComponent(
        MultiProvider(
          providers: [
            Provider<_Settings>.value(value: const _Settings('compact')),
            ChangeNotifierProvider<_Counter>.value(value: counter),
          ],
          child: Builder(
            builder: (context) {
              final settings = context.read<_Settings>();
              final value = context.watch<_Counter>().value;
              return Component.text('${settings.label}/$value');
            },
          ),
        ),
      );
      expect(find.text('compact/0'), findsOneComponent);
      expect(counter.liveListeners, 1);

      counter.increment();
      await tester.pump();
      expect(find.text('compact/1'), findsOneComponent);
    });

    testComponents('an inner provider may read an outer one', (tester) async {
      tester.pumpComponent(
        MultiProvider(
          providers: [
            Provider<_Settings>.value(value: const _Settings('roomy')),
            Provider<String>(
              create:
                  (context) => 'label=${context.read<_Settings>().label}',
            ),
          ],
          child: Builder(builder: (context) => Component.text(context.read<String>())),
        ),
      );

      expect(find.text('label=roomy'), findsOneComponent);
    });
  });

  group('Server rendering', () {
    testComponents(
      'attaches no listener and draws one frame of the current state',
      (tester) async {
        final counter = _Counter();
        counter.increment(); // the state has already moved before the render

        tester.pumpComponent(
          ChangeNotifierProvider<_Counter>.value(
            value: counter,
            child: const _WatchCount(),
          ),
        );

        expect(find.text('n=1'), findsOneComponent);
        expect(counter.liveListeners, 0, reason: 'SSR must not subscribe');

        counter.increment();
        await tester.pump();

        // Nothing re-renders on the server: the browser subscribes after
        // hydration, and this isolate's tree is discarded once the HTML is
        // written — which is exactly why an unattached listener would leak.
        expect(find.text('n=1'), findsOneComponent);
        expect(counter.liveListeners, 0);
      },
      isClient: false,
    );
  });
}
