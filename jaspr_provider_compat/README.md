# jaspr_provider_compat

A provider package for **Jaspr 0.23**, shaped like `provider` 6.x /
`jaspr_provider` 0.0.3.

## Why this exists instead of `jaspr_provider`

The Sitewise web app is specified to manage state with `jaspr_provider`. That
package cannot be installed here:

| | `jaspr_provider` | this workspace |
|---|---|---|
| last publish | 0.0.3 — 2022-09-03 (abandoned) | — |
| `jaspr` | `^0.1.4` | `^0.23.5` |
| Dart SDK | `>=2.16.0 <3.0.0` | `^3.12.x` |

`dart pub add jaspr_provider` fails outright:

> Because every version of jaspr_provider depends on jaspr ^0.1.4 and
> sitewise_jaspr_web depends on jaspr ^0.23.5, jaspr_provider is forbidden.

Jaspr 0.23 also ships no provider classes of its own (`jaspr` and
`jaspr_router` together expose zero `Provider`/`Consumer` symbols), and the
0.1.x API that `jaspr_provider` was written against — `Nested`,
`SingleChildComponent`, `Iterable<Component> build()` — no longer exists.

So the pattern is implemented here on the primitives Jaspr 0.23 really has:
`InheritedComponent` / `InheritedElement` (including its `aspect` channel, used
for `select` and `Selector`) and `Listenable` / `ChangeNotifier` from
`package:jaspr/jaspr.dart`. The `jaspr_provider` 0.0.3 archive was read before
writing this, so the names and constructor shapes line up with it rather than
being guessed.

## API

```dart
Provider<T>(create:, dispose:, builder:, child:)
Provider<T>.value(value:, updateShouldNotify:, builder:, child:)
ChangeNotifierProvider<T>(create:, builder:, child:)
ChangeNotifierProvider<T>.value(value:, builder:, child:)
MultiProvider(providers: [...], child:, builder:)
Consumer<T>(builder: (context, value, child) => ...)
Selector<A, S>(selector:, builder:, rebuildWhen:, child:)

Provider.of<T>(context, listen: true|false)
context.read<T>()
context.watch<T>()
context.select<T, R>((T value) => ...)
context.read as Locator            // pass a reader into a plain Dart class
ProviderNotFoundException
```

Nothing else from `provider` is implemented — no `ProxyProvider`,
`ListenableProvider`, `ValueListenableProvider`, `FutureProvider`,
`StreamProvider`, `Consumer2..6` or `Selector0`. If a screen needs one, add it
deliberately rather than importing a shim.

## Behaviour that differs from `provider`

1. **Server renders attach no listeners.** `addListener` is called only when
   `context.binding.isClient`. Jaspr builds the component tree once per
   request on the server and never unmounts it, so an unguarded subscription
   to a process-wide view model would accumulate one leaked listener per
   request. The server draws one frame of the current state; the browser
   subscribes after hydration.
2. **`create` runs on the first build, not lazily on the first read.** Same
   value and same lifecycle, one frame earlier.
3. **`context.select` tolerates a fresh closure each build.** Upstream throws
   if the selector's identity changes; here the aspect is simply re-registered
   and the selected value re-recorded, which is the behaviour everyone wants.
4. **A provider rendered with no `child` draws an empty text node**, because
   Jaspr's `InheritedComponent.child` is non-nullable. Inside `MultiProvider`
   the child is always supplied, so this only applies to a hand-written
   standalone provider.
5. **`Consumer`/`Selector` take one fewer type argument** than in Flutter:
   Jaspr's builders return `Component`, which is not generic, so there is no
   `ChildType` to carry.
6. **`Selector.rebuildWhen`, not `shouldRebuild`.** Every Jaspr component
   already inherits a `shouldRebuild` method, so a field with that name does
   not compile — the predicate is the same, only the spelling differs.

## Type matching

Providers are found by the *exact* generic instantiation of an internal
scope, so `Provider<AppController>` does not satisfy `context.read<AppController?>()`
and a subclass read (`context.read<SubController>()`) will not find a provider
declared with the supertype. Write the type argument on the provider when the
static type of the value would otherwise be inferred to something else.

## Tests

`test/provider_test.dart` runs on the Jaspr component-test binding
(`testComponents`) and covers: read/watch lookup, `ProviderNotFoundException`,
`ChangeNotifier` rebuilds driven by the revision counter, `create`/`dispose`
lifecycle, `.value` never disposing what it is handed, `Consumer`, `Selector`
and `context.select` skipping rebuilds whose slice did not change, and — with
`isClient: false` — that a server render attaches no listener at all.
