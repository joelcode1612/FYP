part of '../jaspr_provider_compat.dart';

/// What [MultiProvider] nests: any provider that can be handed a child.
///
/// `provider` uses its `SingleChildComponent` base class for this, which does
/// not exist in Jaspr 0.23 (components carry no universal `child` field). The
/// providers in this package implement it instead, by returning a copy of
/// themselves configured with the child.
abstract interface class SingleChildProvider {
  /// A version of this provider that renders [child].
  Component wrappedWith(Component child);
}

/// Flattens a chain of providers into one list.
///
/// ```dart
/// MultiProvider(
///   providers: [
///     ChangeNotifierProvider.value(value: locator.auth),
///     ChangeNotifierProvider.value(value: locator.explore),
///     Provider.value(value: locator.settings),
///   ],
///   child: App(),
/// )
/// ```
///
/// Identical to nesting them by hand, in the same order: the first entry is
/// the outermost provider, so a later entry may read an earlier one inside
/// its `create`.
///
/// A provider in [providers] that already carries a child has that child
/// replaced by the next provider in the list (or [child] at the end), exactly
/// as in `provider`.
class MultiProvider extends StatelessComponent {
  const MultiProvider({
    required this.providers,
    this.child,
    this.builder,
    super.key,
  });

  final List<SingleChildProvider> providers;

  /// What the innermost provider renders. May be null when [builder] supplies
  /// the content instead.
  final Component? child;

  /// Gets a context that is a descendant of every provider in [providers].
  final TransitionBuilder? builder;

  @override
  Component build(BuildContext context) {
    Component current =
        builder != null
            ? Builder(builder: (context) => builder!(context, child))
            : (child ?? Component.text(''));
    for (final provider in providers.reversed) {
      current = provider.wrappedWith(current);
    }
    return current;
  }
}
