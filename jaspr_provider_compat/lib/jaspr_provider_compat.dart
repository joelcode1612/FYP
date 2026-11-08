/// A provider surface for Jaspr 0.23, modelled on the `provider` package.
///
/// ## Why this package exists
///
/// The web app is meant to manage state with `jaspr_provider`. That package
/// was published three times, last in September 2022, and every version
/// depends on `jaspr ^0.1.4` with `sdk >=2.16.0 <3.0.0`. This workspace uses
/// `jaspr ^0.23.5` on SDK ^3.12, so `jaspr_provider` cannot be resolved at all
/// (`dart pub add jaspr_provider` fails with a version conflict). Jaspr 0.23
/// ships no provider classes of its own.
///
/// So the API is implemented here, directly on the primitives Jaspr 0.23
/// actually exposes: [InheritedComponent] / `InheritedElement` for ambient
/// lookup and selective rebuilds, and `ChangeNotifier` / `Listenable` from
/// `package:jaspr/foundation`. Nothing is borrowed from Flutter's `provider`;
/// the shapes (`Provider<T>(create:)`, `ChangeNotifierProvider<T>.value`,
/// `MultiProvider`, `Consumer<T>`, `Selector<A, S>`, `context.read/watch/
/// select`) follow `jaspr_provider` 0.0.3 and `provider` 6.x so that call
/// sites look like the rest of the ecosystem.
///
/// ## Deliberate differences from `provider` / `jaspr_provider`
///
/// * **SSR-safe by construction.** No `Listenable` listener is attached while
///   a server render is running (`context.binding.isClient` is false), so a
///   server render cannot leak a subscription into an app-wide view model.
///   The server draws one frame of the current state; the browser subscribes
///   after hydration. Upstream `jaspr_provider` had no such guard.
/// * **No `StreamProvider` / `FutureProvider` / `ProxyProvider` /
///   `ValueListenableProvider` / `Consumer2..6` / `Selector0` /
///   `ListenableProvider`. Only what this workspace consumes is implemented —
///   see the README before adding to it.
/// * `Consumer` and `Selector` take one fewer type argument than their Flutter
///   counterparts: Jaspr's builder callbacks return `Component`, which is not
///   generic, so there is no `ChildType` parameter to carry.
/// * `Provider(create:)` calls `create` on the first build rather than
///   lazily on the first read. Same value, same lifecycle, one frame earlier.
/// * `Selector`'s rebuild predicate is spelled `rebuildWhen`, not
///   `shouldRebuild` — every Jaspr component already inherits a
///   `shouldRebuild` method, so the upstream field name would not compile.
/// * A provider rendered without a `child` draws an empty text node instead
///   of nothing, because Jaspr requires a non-null child on
///   [InheritedComponent].
library;

import 'package:jaspr/jaspr.dart';

part 'src/change_notifier_provider.dart';
part 'src/consumer.dart';
part 'src/context_extensions.dart';
part 'src/multi_provider.dart';
part 'src/provider.dart';
part 'src/provider_scope.dart';
part 'src/selector.dart';
